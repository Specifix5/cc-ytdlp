import {
  FFMPEG_BINARY,
  METADATA_TIMEOUT_MS,
  PLAYLIST_LIMIT,
  SEARCH_LIMIT,
  YT_DLP_BINARY,
  YT_DLP_COOKIES_PATH,
} from "./constants";
import type { YtDlpPlaylistMetadata, YtDlpVideoMetadata } from "./types";

type UnknownRecord = Record<string, unknown>;

const MAX_DIAGNOSTIC_OUTPUT_LENGTH = 8_000;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readString(
  record: UnknownRecord,
  keys: readonly string[],
): string | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) {
      return value;
    }
  }

  return null;
}

function readNumber(
  record: UnknownRecord,
  keys: readonly string[],
): number | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      return value;
    }
  }

  return null;
}

function parseVideoMetadata(value: unknown): YtDlpVideoMetadata | null {
  if (!isRecord(value)) {
    return null;
  }

  const id = readString(value, ["id"]);
  const title = readString(value, ["title"]);

  if (id === null || title === null) {
    return null;
  }

  return {
    id,
    title,
    duration: readNumber(value, ["duration"]),
    channel: readString(value, ["channel", "uploader"]) ?? "",
  };
}

function parsePlaylistMetadata(value: unknown): YtDlpPlaylistMetadata | null {
  if (!isRecord(value)) {
    return null;
  }

  const id = readString(value, ["id", "playlist_id"]);
  const title = readString(value, ["title", "playlist_title"]);
  const rawEntries = value.entries;

  if (id === null || title === null || !Array.isArray(rawEntries)) {
    return null;
  }

  const entries = rawEntries
    .map(parseVideoMetadata)
    .filter((entry): entry is YtDlpVideoMetadata => entry !== null);
  const reportedCount = readNumber(value, ["playlist_count", "n_entries"]);

  return {
    id,
    title,
    channel: readString(value, ["channel", "uploader"]) ?? "",
    videoCount:
      reportedCount === null
        ? entries.length
        : Math.max(0, Math.floor(reportedCount)),
    entries,
  };
}

function parseJson(output: string): unknown {
  try {
    return JSON.parse(output) as unknown;
  } catch (error: unknown) {
    throw new Error("yt-dlp returned invalid JSON", { cause: error });
  }
}

function formatDiagnosticOutput(output: string): string {
  const trimmed = output.trim();

  if (trimmed.length === 0) {
    return "(empty)";
  }

  if (trimmed.length <= MAX_DIAGNOSTIC_OUTPUT_LENGTH) {
    return trimmed;
  }

  return `${trimmed.slice(0, MAX_DIAGNOSTIC_OUTPUT_LENGTH)}\n... (truncated)`;
}

function formatError(error: unknown, depth = 0): string {
  if (!(error instanceof Error)) {
    return String(error);
  }

  let description = error.stack ?? `${error.name}: ${error.message}`;

  if (error.cause !== undefined && depth < 3) {
    description += `\nCaused by: ${formatError(error.cause, depth + 1)}`;
  }

  return description;
}

function makeYtDlpArguments(arguments_: readonly string[]): readonly string[] {
  return [
    "--ignore-config",
    "--js-runtimes",
    "deno:/usr/local/bin/deno",
    "--extractor-args",
    "youtube:player_client=mweb",
    "--quiet",
    "--no-warnings",
    ...(YT_DLP_COOKIES_PATH === undefined
      ? []
      : ["--cookies", YT_DLP_COOKIES_PATH]),
    ...arguments_,
  ] as const;
}

function spawnYtDlpForJson(arguments_: readonly string[], signal: AbortSignal) {
  return Bun.spawn([YT_DLP_BINARY, ...arguments_], {
    stdout: "pipe",
    stderr: "pipe",
    signal,
  });
}

function logYtDlpDiagnostic(options: {
  operation: string;
  arguments_: readonly string[];
  process: ReturnType<typeof spawnYtDlpForJson> | null;
  timedOut: boolean;
  stdout: string;
  stderr: string;
  error: unknown;
}): void {
  const { operation, arguments_, process, timedOut, stdout, stderr, error } =
    options;
  const resolvedBinary = Bun.which(YT_DLP_BINARY);

  console.error(
    [
      `[yt-dlp:metadata] ${operation} failed`,
      `configured binary: ${JSON.stringify(YT_DLP_BINARY)}`,
      `resolved binary: ${resolvedBinary ?? "(not found on PATH)"}`,
      `arguments: ${JSON.stringify(arguments_)}`,
      `pid: ${process?.pid ?? "(not started)"}`,
      `exit code: ${process?.exitCode ?? "(unavailable)"}`,
      `signal: ${process?.signalCode ?? "(none)"}`,
      `timeout: ${METADATA_TIMEOUT_MS} ms`,
      `timed out: ${timedOut}`,
      `stderr:\n${formatDiagnosticOutput(stderr)}`,
      `stdout:\n${formatDiagnosticOutput(stdout)}`,
      `runtime error:\n${formatError(error)}`,
    ].join("\n"),
  );
}

async function runYtDlpForJson(
  operation: string,
  arguments_: readonly string[],
  signal: AbortSignal,
): Promise<unknown> {
  const commandArguments = makeYtDlpArguments(arguments_);
  const controller = new AbortController();
  let timedOut = false;
  let failureLogged = false;
  let process: ReturnType<typeof spawnYtDlpForJson> | null = null;
  let stdout = "";
  let stderr = "";
  const abort = (): void => controller.abort();

  if (signal.aborted) {
    controller.abort();
  } else {
    signal.addEventListener("abort", abort, { once: true });
  }

  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, METADATA_TIMEOUT_MS);

  try {
    process = spawnYtDlpForJson(commandArguments, controller.signal);
    const output = Promise.all([
      new Response(process.stdout).text(),
      new Response(process.stderr).text(),
    ]);
    const exitCode = await process.exited;
    [stdout, stderr] = await output;

    if (exitCode !== 0) {
      if (!signal.aborted) {
        failureLogged = true;
        logYtDlpDiagnostic({
          operation,
          arguments_: commandArguments,
          process,
          timedOut,
          stdout,
          stderr,
          error: new Error(`yt-dlp exited with code ${exitCode}`),
        });
      }
      throw new Error("yt-dlp failed");
    }

    return parseJson(stdout);
  } catch (error: unknown) {
    if (!signal.aborted && !failureLogged) {
      logYtDlpDiagnostic({
        operation,
        arguments_: commandArguments,
        process,
        timedOut,
        stdout,
        stderr,
        error,
      });
    }
    throw new Error("yt-dlp failed", { cause: error });
  } finally {
    clearTimeout(timeout);
    signal.removeEventListener("abort", abort);
  }
}

function spawnFfmpeg(input: ReadableStream<Uint8Array>, signal: AbortSignal) {
  return Bun.spawn(
    [
      FFMPEG_BINARY,
      "-analyzeduration",
      "0",
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      "pipe:0",
      "-f",
      "dfpwm",
      "-ar",
      "48000",
      "-ac",
      "1",
      "pipe:1",
    ],
    {
      stdin: input,
      stdout: "pipe",
      stderr: "pipe",
      signal,
    },
  );
}

async function monitorProcess(
  name: string,
  exited: Promise<number>,
  errors: Promise<string>,
  signal: AbortSignal,
): Promise<void> {
  try {
    const [exitCode, errorOutput] = await Promise.all([exited, errors]);
    if (exitCode !== 0 && !signal.aborted) {
      console.error(
        `${name} failed with exit code ${exitCode}: ${errorOutput.trim()}`,
      );
    }
  } catch (error: unknown) {
    if (!signal.aborted) {
      console.error(`${name} process failure:`, error);
    }
  }
}

export function streamVideoAsDfpwm(
  videoId: string,
  signal: AbortSignal,
): ReadableStream<Uint8Array> {
  const controller = new AbortController();
  const abort = (): void => controller.abort();

  if (signal.aborted) {
    controller.abort();
  } else {
    signal.addEventListener("abort", abort, { once: true });
  }

  const ytDlp = Bun.spawn(
    [
      YT_DLP_BINARY,
      ...makeYtDlpArguments([
        "--no-playlist",
        "-f",
        "bestaudio/best",
        "-o",
        "-",
        `https://www.youtube.com/watch?v=${videoId}`,
      ]),
    ],
    {
      stdout: "pipe",
      stderr: "pipe",
      signal: controller.signal,
    },
  );

  let ffmpeg: ReturnType<typeof spawnFfmpeg>;
  try {
    ffmpeg = spawnFfmpeg(ytDlp.stdout, controller.signal);
  } catch (error: unknown) {
    controller.abort();
    signal.removeEventListener("abort", abort);
    console.error("ffmpeg process failure:", error);
    throw new Error("ffmpeg failed", { cause: error });
  }

  void monitorProcess(
    "yt-dlp",
    ytDlp.exited,
    new Response(ytDlp.stderr).text(),
    controller.signal,
  );
  void monitorProcess(
    "ffmpeg",
    ffmpeg.exited,
    new Response(ffmpeg.stderr).text(),
    controller.signal,
  );

  const reader = ffmpeg.stdout.getReader();
  let finished = false;

  const finish = (killProcesses: boolean): void => {
    if (finished) {
      return;
    }

    finished = true;
    signal.removeEventListener("abort", abort);
    if (killProcesses) {
      controller.abort();
    }
  };

  return new ReadableStream<Uint8Array>({
    async pull(streamController): Promise<void> {
      try {
        const { done, value } = await reader.read();
        if (done) {
          finish(false);
          streamController.close();
        } else {
          streamController.enqueue(value);
        }
      } catch (error: unknown) {
        finish(true);
        streamController.error(error);
      }
    },
    async cancel(): Promise<void> {
      finish(true);
      await reader.cancel();
    },
  });
}

export async function searchYouTube(
  query: string,
  signal: AbortSignal,
): Promise<YtDlpVideoMetadata[]> {
  const metadata = await runYtDlpForJson(
    "search",
    [
      "--skip-download",
      "--flat-playlist",
      "--dump-single-json",
      `ytsearch${SEARCH_LIMIT}:${query}`,
    ],
    signal,
  );

  if (!isRecord(metadata) || !Array.isArray(metadata.entries)) {
    return [];
  }

  return metadata.entries
    .map(parseVideoMetadata)
    .filter((entry): entry is YtDlpVideoMetadata => entry !== null);
}

export async function getVideoInfo(
  videoId: string,
  signal: AbortSignal,
): Promise<YtDlpVideoMetadata | null> {
  const metadata = await runYtDlpForJson(
    "video metadata",
    [
      "--skip-download",
      "--no-playlist",
      "--dump-single-json",
      `https://www.youtube.com/watch?v=${videoId}`,
    ],
    signal,
  );

  return parseVideoMetadata(metadata);
}

export async function getPlaylistInfo(
  playlistId: string,
  signal: AbortSignal,
): Promise<YtDlpPlaylistMetadata | null> {
  const metadata = await runYtDlpForJson(
    "playlist metadata",
    [
      "--skip-download",
      "--flat-playlist",
      "--playlist-end",
      PLAYLIST_LIMIT.toString(),
      "--dump-single-json",
      `https://www.youtube.com/playlist?list=${playlistId}`,
    ],
    signal,
  );

  return parsePlaylistMetadata(metadata);
}
