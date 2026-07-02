function readPositiveInteger(
  name: string,
  fallback: number,
  maximum = Number.MAX_SAFE_INTEGER,
): number {
  const value = Bun.env[name];

  if (value === undefined || !/^\d+$/.test(value)) {
    return fallback;
  }

  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= maximum
    ? parsed
    : fallback;
}

function readBinaryName(name: string, fallback: string): string {
  return Bun.env[name]?.trim() || fallback;
}

function readOptionalValue(name: string): string | undefined {
  return Bun.env[name]?.trim() || undefined;
}

export const PORT = readPositiveInteger("PORT", 3000, 65_535);
export const YT_DLP_BINARY = readBinaryName("YT_DLP_BINARY", "yt-dlp");
export const YT_DLP_COOKIES_PATH = readOptionalValue("YT_DLP_COOKIES_PATH");
export const FFMPEG_BINARY = readBinaryName("FFMPEG_BINARY", "ffmpeg");
export const SEARCH_LIMIT = readPositiveInteger("SEARCH_LIMIT", 20);
export const PLAYLIST_LIMIT = readPositiveInteger("PLAYLIST_LIMIT", 100);
export const METADATA_TIMEOUT_MS = readPositiveInteger(
  "METADATA_TIMEOUT_MS",
  15_000,
);

export const HEALTH_ROUTE = "/health";
export const IPOD_ROUTE = "/ipod";
