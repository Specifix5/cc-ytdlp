# cc-ytdlp

<!-- prettier-ignore -->
This is a yt-dlp based fork of https://github.com/terreng/computercraft-streaming-music that does not depend on RapidAPI and Firebase, it is intended for you to self-host and DIY.

# Prerequisites

- yt-dlp >= `2026.03.17`
- FFmpeg >= `5.1`
- Bun >= `1.2.18`
- Deno >= `2.3.0`

FFmpeg must include the `dfpwm` muxer. Check with:

```bash
ffmpeg -hide_banner -muxers | grep -w dfpwm
```

# Setup

```bash
bun install
cp .env.example .env
bun run start
```

The server listens on port `3000` by default.

# Configuration

| Variable              | Default  | Purpose                                 |
| --------------------- | -------- | --------------------------------------- |
| `PORT`                | `3000`   | HTTP listen port                        |
| `YT_DLP_BINARY`       | `yt-dlp` | yt-dlp command or absolute path         |
| `YT_DLP_COOKIES_PATH` | Not set  | Optional Netscape-format cookies file   |
| `FFMPEG_BINARY`       | `ffmpeg` | FFmpeg command or absolute path         |
| `SEARCH_LIMIT`        | `20`     | Maximum ordinary search results         |
| `PLAYLIST_LIMIT`      | `100`    | Maximum playlist entries returned       |
| `METADATA_TIMEOUT_MS` | `15000`  | yt-dlp metadata timeout in milliseconds |

To use exported YouTube cookies, place `cookies.txt` in the project directory
and set:

```env
YT_DLP_COOKIES_PATH=./cookies.txt
```

The path may be relative to the server's working directory or absolute.
`cookies.txt` is ignored by Git and must never be committed. Leave
`YT_DLP_COOKIES_PATH` empty or unset to run yt-dlp without cookies.

# API

All endpoints use `GET`.

| Request                                 | Response                                  |
| --------------------------------------- | ----------------------------------------- |
| `/health`                               | `ok`                                      |
| `/ipod?id=VIDEO_ID`                     | Streaming 48 kHz mono DFPWM audio         |
| `/ipod?search=QUERY`                    | Search results as Latin-1 JSON            |
| `/ipod?search=YOUTUBE_VIDEO_URL`        | One matching track                        |
| `/ipod?search=YOUTUBE_PLAYLIST_URL&v=2` | One playlist object with `playlist_items` |

# ComputerCraft client

Copy `client/music.lua` onto the ComputerCraft computer and point it at the
complete `/ipod` endpoint without a trailing slash:

```lua
youtubeApi = "https://example.com/ipod",
youtubeVersion = "2.1",
```

`youtubeVersion` only enables playlist expansion when its value is `2` or
newer.
