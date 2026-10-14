# Translating Purrcast

Every language is a `<code>.lproj` folder with two files:

- `Localizable.strings` – the app's texts. **The keys are the English texts**; only the value is translated.
- `InfoPlist.strings` – the macOS permission prompt text (`NSLocalNetworkUsageDescription`).

`en.lproj` is empty on purpose (English = the keys). `hu.lproj` is a complete example.
After editing run `Resources/Localization/check.sh`: it reports missing/unused keys and placeholder mismatches for every language.

## Rules

- Keep every `%@` placeholder, the same number of times as in the key. Order may change only if the grammar needs it — then use positional placeholders `%1$@`, `%2$@`.
- Keep `\n` line breaks.
- Do not translate: `AirPlay`, `Purrcast`, `Apple TV 4K`, `TV` (may use the local word for television), `H.264`, `HEVC`, `HDR`, `SDR`, `AAC`, `MKV`, `MP4`, `AVI`, `ffmpeg`, `brew install ffmpeg`, `⌘O`, `~/Library/Logs/Purrcast.log`.
- Use the informal/friendly tone usual in the language's consumer software (like VLC or macOS itself). Keep texts short: many are buttons, menu items or a window subtitle.
- Use the typographic characters of the language (quotes, ellipsis `…`). The arrow `→` and the dash `–` stay as they are.
- File format: UTF-8, one entry per line: `"key" = "value";` – escape `"` inside values as `\"`.

## Texts and where they appear

| Key | Where / meaning |
| --- | --- |
| `timed out` | Detail inside an error message: the local web server didn't start in time |
| `Not found: %@. Install it with: brew install ffmpeg` | Error: a required program (`%@` = ffmpeg or ffprobe) is missing |
| `Couldn't read the file: %@` | Error when opening a video; `%@` = technical reason |
| `The file has no video track.` | Error when opening a file |
| `ffmpeg stopped with an error:\n%@` | Error; `%@` = ffmpeg's own (English) output |
| `Not enough free space for the temporary stream files (needs about %@, free: %@).` | Error; `%@` = sizes like "12 GB" |
| `The local stream server didn't start: %@` | Error |
| `Didn't start with the previous settings, retrying in a safer mode…` | Notice while the app automatically retries with more compatible settings |
| `Couldn't start playback:\n%@\n\nDetails: ~/Library/Logs/Purrcast.log` | Final error message; `%@` = reason |
| `player error: %@` | Short reason inside the message above |
| `playback didn't start within 20 seconds` | Short reason inside the message above |
| `Error` | Window subtitle when something failed |
| `Audio %@` | Name of an audio track without a language, e.g. "Audio 2" |
| `Subtitle %@` | Name of a subtitle track without a language, e.g. "Subtitle 3" |
| `(forced)` | Appended to a subtitle name: forced subtitles (only foreign-language parts) |
| `External subtitle` | Subtitle loaded from a separate .srt file next to the video |
| `(external)` | Appended to the name of such a subtitle |
| `unknown` | Unknown language |
| `mono` / `stereo` | Audio channel layout |
| `%@ channels` | Audio channel count, e.g. "4 channels" |
| `%@ → H.264, plays on every TV` | Why the video gets converted; `%@` = source codec, e.g. "HEVC" |
| `%@ H.264 → 8-bit H.264` | Why the video gets converted; `%@` = pixel format, e.g. "yuv420p10le" |
| `interlaced → progressive` | Why the video gets converted (deinterlacing) |
| `re-encoded for reliable playback` | Why the video gets converted |
| `Video: %@ – passed through in original quality` | Line in the track overview; `%@` = e.g. "H.264 1920×1080" |
| `Video: %@ → H.264 %@ (%@)` | Line in the track overview: source → output size (reason) |
| `Audio: %@ – original` | Line in the track overview; `%@` = track name |
| `Audio: %@ → %@ %@` | Line in the track overview: track → output codec + channels |
| `Subtitle: %@ – on by default` | Line in the track overview |
| `Subtitle: %@` | Line in the track overview |
| `Subtitle skipped: %@ (%@ is image-based and can't be converted)` | Line in the track overview; `%@` = language, then format (PGS/VobSub) |
| `Preparing…` | Shown while the video is being prepared for streaming |
| `Playing via AirPlay` | Window subtitle while the TV plays the video |
| `Conversion stopped: %@` | Window subtitle when background conversion failed |
| `Prepared: %@ / %@` | Window subtitle: converted so far / total duration, e.g. "12:30 / 1:52:00" |
| `Prepared: %@ / %@ – you can only skip ahead this far` | Same, in the track overview popover |
| `Open…` | Menu item and button: open a video file |
| `Open` | Toolbar button label |
| `Open another file…` | Button on the error screen |
| `Open a video (⌘O)` | Toolbar tooltip |
| `Tracks` | Toolbar button: shows the audio/subtitle tracks overview |
| `Audio and subtitle tracks, conversion` | Tooltip of that button |
| `AirPlay – choose your TV` | Tooltip of the AirPlay button |
| `Drop a video here (MKV, MP4, AVI…)` | Empty window, main text |
| `or open one with ⌘O, then pick your TV with the AirPlay button` | Empty window, secondary text |
| `Playback` | Menu bar menu title |
| `Original quality (HEVC, HDR, surround – for Apple TV 4K)` | Checkbox menu item in the Playback menu |
| `Language` | Menu item (submenu) to choose the app's language |
| `System default` | First entry of that submenu |
| `The new language takes effect after a restart.` | Alert title after choosing a language |
| `Restart Purrcast now? Playback stops.` | Alert text |
| `Restart` / `Later` | Alert buttons |
| `NSLocalNetworkUsageDescription` (InfoPlist.strings) | macOS permission prompt: "Your TV (the AirPlay receiver) downloads the video from this Mac over the local network." |

## Player, menus, playlist, media information (second batch)

Most of these are standard media player menu items: translate them the way VLC / QuickTime Player / IINA do in your language. Notes for the ambiguous ones:

| Key | Where / meaning |
| --- | --- |
| `Chapter %@` | Default chapter name, `%@` = number |
| `File`, `Format`, `Duration`, `Size`, `Bitrate`, `General`, `Codec`, `Title`, `Resolution`, `Frame rate`, `Pixel format`, `Dynamic range`, `Channels`, `Sample rate` | Labels in the Media Information window (technical details of the file) |
| `Video`, `Audio`, `Subtitle` | Stream type in the Media Information window; `Audio`/`Video` are also menu bar menu titles |
| `Stream %@: %@` | Section title, e.g. "Stream 2: Audio" |
| `Purrcast` | App name – keep as is |
| `Open Recent`, `Clear Menu` | File menu, like in every macOS app |
| `Off`, `All`, `One` | Choices of the Repeat menu (repeat off / all items / the current item) |
| `Repeat: off` / `Repeat: all` / `Repeat: one` | Tooltip of the repeat button |
| `Fit`, `Fill (Crop)`, `Stretch` | Video › Aspect: how the picture fills the window |
| `Float on Top` | Window always stays above other windows |
| `Snapshot` | Save the current video frame as an image |
| `Subtitles Earlier (G)`, `Subtitles Later (H)` | Shift subtitle timing; keep the key letters G and H |
| `Set Loop Start (A)`, `Set Loop End (B)`, `Loop Off` | A–B repeat of a part of the video |
| `%@ items` | Number of playlist entries |
| `Streaming` | Section in Media Information listing how the video is converted for the TV |
| `Jump` | Button in the "Jump to Time" dialog |
| `Recent` | Heading above recently played files on the start screen |
| `Start Over` | Button shown after resuming a video where it was left off: play from the beginning |
| `Resumed at %@` | On-screen message, `%@` = time like "1:02:03" |
| `Volume: %@` | On-screen message, `%@` = e.g. "80%" |
| `Speed: %@` | On-screen message, `%@` = e.g. "1.5×" |
| `Subtitle delay: %@ ms` | On-screen message, `%@` = e.g. "-150" |
| `Play/Pause (Space)`, `Playlist (⌘L)`, `Full Screen (⌘F)` | Tooltips; keep the key in parentheses |
| `network stream – seekable anywhere` | Why a network video is converted (lowercase, shown in parentheses) |
| `Network HLS stream – played directly, without conversion` | Track overview line for HLS links, which need no conversion |
| `Previous Chapter`, `Next Chapter` (+ tooltip versions with ⇧P / ⇧N) | Chapter navigation buttons and menu items |
| `Chapter: %@` | On-screen message after jumping to a chapter, `%@` = chapter name |
| `Hide Controls`, `After %@ seconds`, `Never` | Video menu: how long until the on-screen controls hide while playing |
| `Show total length`, `Show remaining time` | Tooltip of the time label right of the timeline; clicking switches between total length and countdown |
| `Picture in Picture`, `Playing in Picture in Picture` | Button / menu item and the placeholder shown in the window while the video plays in a floating PiP window |
| `Appearance`, `Light`, `Dark` | App menu: follow the system / always light / always dark |
| `Open-Source Licenses` | Help menu item: opens the licence texts of FFmpeg, OpenSSL and the Geist fonts |
