import { HEALTH_ROUTE, IPOD_ROUTE, PORT } from "./constants";
import type { SearchResult } from "./types";
import {
  formatPlaylistResult,
  formatTrack,
  getPlaylistIdFromYouTubeUrl,
  getVideoIdFromYouTubeUrl,
  isVideoId,
  latin1JsonResponse,
  textResponse,
} from "./utils";
import {
  getPlaylistInfo,
  getVideoInfo,
  searchYouTube,
  streamVideoAsDfpwm,
} from "./youtube";

Bun.serve({
  port: PORT,
  async fetch(request, server): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "GET") {
      return textResponse("Not found", 404);
    }

    if (url.pathname === HEALTH_ROUTE) {
      return textResponse("ok");
    }

    if (url.pathname !== IPOD_ROUTE) {
      return textResponse("Not found", 404);
    }

    server.timeout(request, 0);

    const videoId = url.searchParams.get("id");
    if (videoId) {
      if (!isVideoId(videoId)) {
        return textResponse("Bad request", 400);
      }

      try {
        return new Response(streamVideoAsDfpwm(videoId, request.signal), {
          status: 200,
          headers: { "Content-Type": "application/octet-stream" },
        });
      } catch (error: unknown) {
        console.error("Audio stream failed:", error);
        return textResponse("Error 500", 500);
      }
    }

    const search = url.searchParams.get("search");
    if (!search) {
      return textResponse("Bad request", 400);
    }

    try {
      const directVideoId = getVideoIdFromYouTubeUrl(search);
      if (directVideoId !== null) {
        const metadata = await getVideoInfo(directVideoId, request.signal);
        const results: SearchResult[] =
          metadata === null ? [] : [formatTrack(metadata)];
        return latin1JsonResponse(results);
      }

      const playlistId = getPlaylistIdFromYouTubeUrl(search);
      const version = Number(url.searchParams.get("v") ?? 0);
      if (playlistId !== null && version >= 2) {
        const metadata = await getPlaylistInfo(playlistId, request.signal);
        const results: SearchResult[] =
          metadata === null || metadata.entries.length === 0
            ? []
            : [formatPlaylistResult(metadata)];
        return latin1JsonResponse(results);
      }

      const metadata = await searchYouTube(
        search.split("+").join(" "),
        request.signal,
      );
      return latin1JsonResponse(metadata.map(formatTrack));
    } catch (error: unknown) {
      console.error("YouTube metadata request failed:", error);
      return textResponse("Error 500", 500);
    }
  },
});
