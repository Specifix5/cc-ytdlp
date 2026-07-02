import { Buffer } from "node:buffer";

import type {
  PlaylistResult,
  SearchResult,
  Track,
  YtDlpPlaylistMetadata,
  YtDlpVideoMetadata,
} from "./types";

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
const PLAYLIST_ID_PATTERN = /^[A-Za-z0-9_-]{34}$/;
const YOUTUBE_HOSTS = new Set([
  "youtube.com",
  "m.youtube.com",
  "music.youtube.com",
]);

function parseYouTubeUrl(value: string): URL | null {
  const input = value.trim();

  if (input.length === 0) {
    return null;
  }

  try {
    const url = new URL(
      /^[a-z][a-z\d+.-]*:\/\//i.test(input) ? input : `https://${input}`,
    );

    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return null;
    }

    url.hostname = url.hostname.toLowerCase().replace(/^www\./, "");
    return url;
  } catch {
    return null;
  }
}

export function isVideoId(value: string): boolean {
  return VIDEO_ID_PATTERN.test(value);
}

export function isPlaylistId(value: string): boolean {
  return PLAYLIST_ID_PATTERN.test(value);
}

export function getVideoIdFromYouTubeUrl(value: string): string | null {
  const url = parseYouTubeUrl(value);

  if (url === null) {
    return null;
  }

  if (url.hostname === "youtu.be") {
    const videoId = url.pathname.split("/").filter(Boolean)[0] ?? "";
    return isVideoId(videoId) ? videoId : null;
  }

  if (!YOUTUBE_HOSTS.has(url.hostname)) {
    return null;
  }

  if (url.pathname === "/watch") {
    const videoId = url.searchParams.get("v") ?? "";
    return isVideoId(videoId) ? videoId : null;
  }

  const [kind, videoId = ""] = url.pathname.split("/").filter(Boolean);
  return ["shorts", "embed", "live", "v"].includes(kind ?? "") &&
    isVideoId(videoId)
    ? videoId
    : null;
}

export function getPlaylistIdFromYouTubeUrl(value: string): string | null {
  const url = parseYouTubeUrl(value);

  if (
    url === null ||
    !YOUTUBE_HOSTS.has(url.hostname) ||
    !["/playlist", "/playlist/"].includes(url.pathname)
  ) {
    return null;
  }

  const playlistId = url.searchParams.get("list") ?? "";
  return isPlaylistId(playlistId) ? playlistId : null;
}

export function cleanText(value: string): string {
  return (
    value
      .replace(/—/g, "-")
      .replace(/–/g, "-")
      .replace(/‘/g, "'")
      .replace(/’/g, "'")
      .replace(/“/g, '"')
      .replace(/”/g, '"')
      .replace(/…/g, "...")
      .replace(/•/g, "·")
      // eslint-disable-next-line no-control-regex -- This intentionally preserves Latin-1 bytes.
      .replace(/[^\x00-\xFF]/g, "?")
  );
}

export function formatDuration(totalSeconds: number | null): string {
  const seconds = Math.max(0, Math.floor(totalSeconds ?? 0));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainingSeconds = seconds % 60;
  const formattedMinutes =
    hours > 0 ? minutes.toString().padStart(2, "0") : minutes.toString();
  const formattedSeconds = remainingSeconds.toString().padStart(2, "0");

  return hours > 0
    ? `${hours}:${formattedMinutes}:${formattedSeconds}`
    : `${formattedMinutes}:${formattedSeconds}`;
}

export function formatTrack(metadata: YtDlpVideoMetadata): Track {
  return {
    id: metadata.id,
    name: cleanText(metadata.title),
    artist: `${formatDuration(metadata.duration)} · ${cleanText(
      metadata.channel.split(" - Topic")[0] ?? "",
    )}`,
  };
}

export function formatPlaylistResult(
  metadata: YtDlpPlaylistMetadata,
): PlaylistResult {
  return {
    id: metadata.id,
    name: cleanText(metadata.title),
    artist: `Playlist · ${metadata.videoCount} videos · ${cleanText(
      metadata.channel,
    )}`,
    type: "playlist",
    playlist_items: metadata.entries.map(formatTrack),
  };
}

export function latin1JsonResponse(results: readonly SearchResult[]): Response {
  return new Response(Buffer.from(JSON.stringify(results), "latin1"), {
    status: 200,
    headers: { "Content-Type": "application/json; charset=latin1" },
  });
}

export function textResponse(text: string, status = 200): Response {
  return new Response(text, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
