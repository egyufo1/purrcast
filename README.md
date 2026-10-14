# Purrcast

![Purrcast — AirPlay any video from your Mac to your TV](docs/cover.png)

A macOS video player that sends **any video file to your TV over AirPlay** — MKV, AVI, WebM, HEVC, HDR / Dolby Vision, DTS, TrueHD, VobSub DVDs and more — as a real AirPlay video stream (not screen mirroring), with all audio tracks and subtitles, and seeking that works anywhere.

[Magyar leírás → README.hu.md](README.hu.md)

## Why

AirPlay receivers (Apple TV, and AirPlay 2 TVs from Samsung, LG, Sony, …) only play HLS / MP4 with H.264 or HEVC video and AAC / AC-3 audio. Most downloaded videos are MKV files with something else inside, and players like VLC or IINA can't send those over AirPlay properly. Purrcast converts on the fly, on your Mac, into a stream every receiver accepts.

## Features

- **Plays on every AirPlay receiver.** Compatible mode (default): H.264 8-bit SDR up to 1080p, AAC stereo. Video that already fits is passed through untouched; everything else is re-encoded with Apple's VideoToolbox (hardware), HDR is tone-mapped to SDR, DVDs are deinterlaced and their aspect ratio fixed.
- **Original quality** mode (Playback menu) for Apple TV 4K: HEVC, HDR and surround sound without re-encoding.
- **Automatic fallback.** If a stream doesn't start (ffmpeg error, player error, or no picture within 20 s), it retries with safer settings by itself.
- **Seek anywhere, immediately**, even while converting: re-encoded video is produced on demand in 4-second segments and ffmpeg restarts where you jump.
- **All audio tracks and subtitles**, selectable on the Mac or with the TV remote. Text subtitles (SRT, ASS, embedded or next to the video like `Movie.hun.srt`, including Windows-1250 encoded ones) are converted to WebVTT; subtitles can be added and shifted (G / H) while playing.
- **VLC-style player:** playlist with folders, M3U, repeat / shuffle and total length; resume where you left off; chapters with a chapter jumper; speed control; A–B loop; frame stepping; jump to time; snapshots (HDR-correct); media information window; network streams (HTTP/HTTPS/RTSP/…, HLS links play directly); Picture in Picture; media keys; keyboard shortcuts close to VLC's.
- **Design** taken from [webapp.wtf](https://webapp.wtf): paper and ink, acid / lavender / coral, hard shadows, Geist fonts. Light and dark mode.
- **76 interface languages** (the same set as VLC for Mac).
- **Self-contained:** bundles its own LGPL build of FFmpeg — no Homebrew needed at runtime.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon Mac
- To build: Xcode or the Xcode Command Line Tools (`xcode-select --install`), Swift 5.10+
- An AirPlay receiver on the same network as the Mac

## Install

```bash
git clone https://github.com/egyufo1/purrcast.git
cd purrcast
./build_app.sh --install
```

This builds `Purrcast.app` and copies it to `/Applications`. The **first** build also downloads and compiles FFmpeg and OpenSSL from source (checksums verified) — that takes a few minutes; later builds reuse it from `vendor/ffmpeg`.

Without `--install` the app is only built into `build/Purrcast.app`.

The app is ad-hoc signed (not notarized). If macOS refuses to open it the first time, right-click the app → **Open**, or allow it under System Settings → Privacy & Security.

On first use macOS may ask whether Purrcast may accept **incoming network connections / access the local network** — allow it: the TV downloads the video from your Mac.

### Updating

```bash
cd purrcast
git pull
./build_app.sh --install
```

Quit Purrcast before installing.

## Usage

1. Drop a video (or a folder) on the window, or press ⌘O. Network streams: ⌘N.
2. Click the **AirPlay button** in the control bar and choose your TV.
3. Audio track, subtitles, speed and chapters are in the control bar and in the menus.

| Shortcut | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Jump 10 s back / forward (⌥⌘← / ⌥⌘→ in the menu) |
| ⇧⌘← / ⇧⌘→ | Jump 1 minute |
| ⌘← / ⌘→ | Previous / next in playlist |
| ⇧P / ⇧N | Previous / next chapter |
| ⌘J | Jump to time |
| `[` `]` `=` | Slower / faster / normal speed |
| E | Next frame |
| ⌥⌘L | A–B loop |
| ↑ / ↓ | Volume |
| V | Next subtitle track |
| G / H | Subtitles earlier / later (50 ms) |
| ⌘F, double click | Full screen |
| ⌥⌘P | Picture in Picture |
| ⌥⌘S | Snapshot (saved to `~/Pictures/Purrcast`) |
| ⌘L | Playlist |
| ⌘I | Media information |

Clicking the total length right of the timeline switches to the remaining time. Dragging the picture moves the window. Controls hide after a few seconds of inactivity (Video → Hide Controls).

Language: Purrcast menu → Language. Appearance: Purrcast menu → Appearance.

## Troubleshooting

- **The TV shows the AirPlay screen but nothing plays:** give it a few seconds — third-party TVs take a while to take over. Check that the Mac and the TV are on the same network and that the macOS firewall allows Purrcast.
- **Log file:** `~/Library/Logs/Purrcast.log` lists what the TV requested, ffmpeg errors and player errors.
- Image-based subtitles (Blu-ray PGS, DVD VobSub) can't be converted to WebVTT and are skipped.
- While a video is playing, its stream needs temporary disk space roughly the size of the video (deleted on close).

## How it works

```
video file ──ffprobe──▶ StreamPlan (copy or re-encode, per track)
           ──ffmpeg───▶ HLS segments (fMP4 remux, or MPEG-TS on demand)
                          │
       StreamSession: built-in HTTP server on the Mac (LAN address)
                          │
      AVPlayer ───────────┴──── AirPlay ───▶ TV fetches the stream directly from the Mac
```

- `Sources/PurrcastCore` — probing, the stream plan, the on-demand HLS session and HTTP server, subtitles, snapshots
- `Sources/Purrcast` — the SwiftUI app: player model, playlist, views, menus
- `Sources/SmokeTest` — end-to-end test: converts a file, plays it with AVPlayer like a receiver would, seeks, checks subtitles

## Development

```bash
swift build
swift run Purrcast /path/to/video.mkv
swift run SmokeTest /path/to/video.mkv          # stream + playback + seeking test
swift run SmokeTest --net <url>                 # network source
swift run SmokeTest --subtiming /path/to.mkv    # when do subtitle cues arrive
PURRCAST_FFMPEG_DIR=build/Purrcast.app/Contents/MacOS swift run SmokeTest video.mkv   # test with the bundled FFmpeg
AIRPLAY_UI_SNAPSHOT=/tmp/ui swift run Purrcast video.mkv   # renders the window to PNGs, then quits
```

During development the app falls back to an `ffmpeg` / `ffprobe` from Homebrew if no bundled one is found.

**Translations:** keys are the English texts (`loc("…")`, `Text("…")`); each language lives in `Resources/Localization/<code>.lproj`. `Resources/Localization/check.sh` reports missing or unused translations and placeholder mismatches — `build_app.sh` refuses to build when something is missing. See `Resources/Localization/README.md` for the translator notes.

**Mascot:** an original cat drawn in code by `Resources/Icon/make_mascot.py` (`purr.svg`, `purr_fire.svg`).
**Icon:** `Resources/Icon/make_icon.sh` renders `Resources/AppIcon.icns` from `render_icon.swift`.
**Cover image:** `swift Resources/Cover/render_cover.swift` renders `docs/cover.png`.

## Licenses

- **FFmpeg** 8.1.1 is built by `scripts/build_ffmpeg.sh` under the **LGPL v2.1**: no `--enable-gpl`, no nonfree parts, shared libraries in `Contents/Frameworks` that can be replaced. Video encoding uses VideoToolbox, so the GPL x264 / x265 encoders are not needed. Source: <https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.xz>.
- **OpenSSL** 3.5 (Apache License 2.0), linked statically into libavformat for HTTPS.
- **Geist / Geist Mono** fonts by Vercel (SIL Open Font License 1.1).
- The licence texts ship inside the app: Help → Open-Source Licenses.
- AirPlay is a trademark of Apple Inc. Purrcast is not affiliated with Apple.
