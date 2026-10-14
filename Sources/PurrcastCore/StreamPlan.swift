import Foundation

/// Decides what ffmpeg has to do so the result plays on every AirPlay receiver.
///
/// Compatible mode (default) targets what every receiver supports, Apple TV HD and smart TVs included:
/// H.264 8-bit SDR up to 1080p with regular keyframes, AAC stereo audio. Only video that already is exactly
/// that gets copied. Original mode keeps HEVC / HDR / surround sound for Apple TV 4K class receivers.
public struct StreamPlan {
    public enum Mode: String {
        case compatible
        case original
    }

    public struct Options {
        public var mode: Mode = .compatible
        /// Re-encode the video even when it could be copied (fallback after a failed start).
        public var forceVideoTranscode = false
        /// Software decoding instead of VideoToolbox (fallback when the hardware path fails).
        public var softwareDecode = false

        public init(mode: Mode = .compatible, forceVideoTranscode: Bool = false, softwareDecode: Bool = false) {
            self.mode = mode
            self.forceVideoTranscode = forceVideoTranscode
            self.softwareDecode = softwareDecode
        }
    }

    public struct VideoTranscode {
        public let encoder: String
        public let bitrate: Int
        public let width: Int
        public let height: Int
        public let hardwareDecode: Bool
        public let reason: String
    }

    public enum VideoAction {
        case copy
        case transcode(VideoTranscode)
    }

    public enum AudioAction {
        case copy
        case transcode(encoder: String, bitrate: String, channels: Int)
    }

    public struct AudioRendition {
        public let track: MediaInfo.Audio
        public let action: AudioAction
        public let name: String
        public let isDefault: Bool

        public var outputChannels: Int {
            if case .transcode(_, _, let channels) = action { return channels }
            return track.channels
        }
    }

    public struct SubtitleRendition {
        public enum Source {
            case embedded(index: Int)
            case file(URL)
        }
        public let source: Source
        public let name: String
        public let language: String?
        public let isDefault: Bool
        public let isForced: Bool
    }

    public let info: MediaInfo
    public let options: Options
    public let video: VideoAction
    public let audio: [AudioRendition]
    public let subtitles: [SubtitleRendition]
    /// Image based subtitles (PGS, VobSub) can't be turned into WebVTT without OCR.
    public let skippedSubtitles: [MediaInfo.Subtitle]

    public init(info: MediaInfo, input: URL, options: Options = Options()) {
        self.info = info
        self.options = options
        video = Self.videoAction(info.video, options: options, network: !input.isFileURL && info.duration > 0)

        let defaultAudio = info.audio.firstIndex(where: \.isDefault) ?? 0
        var usedNames = Set<String>()
        audio = info.audio.enumerated().map { i, track in
            let action = Self.audioAction(track, mode: options.mode)
            var name = [Language.displayName(track.language), track.title.flatMap { $0.isEmpty ? nil : $0 }]
                .compactMap { $0 }.joined(separator: " – ")
            if name.isEmpty { name = loc("Audio \(String(i + 1))") }
            name += " (\(Self.codecName(track.codec, profile: track.profile)) \(Self.channelName(track.channels)))"
            return AudioRendition(track: track, action: action, name: Self.unique(name, &usedNames), isDefault: i == defaultAudio)
        }

        var subs: [SubtitleRendition] = []
        for track in info.subtitles where track.isText {
            var name = Language.displayName(track.language) ?? loc("Subtitle \(String(subs.count + 1))")
            if let title = track.title, !title.isEmpty { name += " – \(title)" }
            if track.isForced { name += " " + loc("(forced)") }
            subs.append(SubtitleRendition(source: .embedded(index: track.index), name: Self.unique(name, &usedNames),
                                          language: Language.bcp47(track.language),
                                          isDefault: track.isDefault, isForced: track.isForced))
        }
        for file in Self.sidecarSubtitles(for: input) {
            let sub = Self.externalSubtitle(file, video: input, usedNames: usedNames)
            usedNames.insert(sub.name)
            subs.append(sub)
        }
        // No subtitle marked default: foreign-language audio gets subtitles in the app's language.
        let pref = Language.subtitlePreference
        if !subs.contains(where: \.isDefault), Language.bcp47(info.audio[safe: defaultAudio]?.language) != pref,
           let i = subs.firstIndex(where: { $0.language == pref && !$0.isForced }) {
            let s = subs[i]
            subs[i] = SubtitleRendition(source: s.source, name: s.name, language: s.language, isDefault: true, isForced: false)
        }
        subtitles = subs
        skippedSubtitles = info.subtitles.filter { !$0.isText }
    }

    // MARK: - Decisions

    /// Codecs VideoToolbox reliably decodes on every Apple Silicon Mac. The hardware path is only used where it
    /// matters: HDR (tone mapping happens in VideoToolbox) and 4K (speed). Everything else is decoded by ffmpeg.
    static let hardwareDecodable: Set<String> = ["h264", "hevc"]

    private static func videoAction(_ v: MediaInfo.Video, options: Options, network: Bool) -> VideoAction {
        let pix = v.pixFmt ?? ""
        let reason: String?
        switch options.mode {
        case .compatible:
            if v.codec != "h264" {
                reason = loc("\(codecName(v.codec, profile: v.profile)) → H.264, plays on every TV")
            } else if pix != "yuv420p" && pix != "yuvj420p" {
                reason = loc("\(pix) H.264 → 8-bit H.264")
            } else if v.isHDR {
                reason = "HDR → SDR"
            } else if v.width > 1920 || v.height > 1088 || (v.level ?? 0) > 42 {
                reason = "\(v.width)×\(v.height) → 1080p"
            } else if v.isInterlaced {
                reason = loc("interlaced → progressive")
            } else if options.forceVideoTranscode {
                reason = loc("re-encoded for reliable playback")
            } else if network {
                // Remuxing a remote file runs at download speed; on-demand conversion can seek anywhere at once.
                reason = loc("network stream – seekable anywhere")
            } else {
                return .copy
            }
        case .original:
            let exotic = pix.contains("422") || pix.contains("444") || pix.contains("12")
            switch v.codec {
            case "h264" where !(pix.contains("10") || exotic), "hevc" where !exotic:
                reason = options.forceVideoTranscode ? loc("re-encoded for reliable playback") : nil
            default:
                reason = "\(codecName(v.codec, profile: v.profile)) → H.264"
            }
            guard reason != nil else { return .copy }
        }

        // Square pixels, fit into 1920×1080, even dimensions.
        let displayWidth = Double(max(v.width, 2)) * v.pixelAspect
        let height = Double(max(v.height, 2))
        let scale = min(1, 1920 / displayWidth, 1080 / height)
        let w = Int((displayWidth * scale / 2).rounded()) * 2
        let h = Int((height * scale / 2).rounded()) * 2
        let bitrate = h <= 576 ? 3_000_000 : h <= 720 ? 5_000_000 : 8_000_000
        let hardware = !options.softwareDecode && !v.isInterlaced && hardwareDecodable.contains(v.codec)
            && (v.isHDR || v.height > 1088)
        return .transcode(VideoTranscode(encoder: "h264_videotoolbox", bitrate: bitrate, width: w, height: h,
                                         hardwareDecode: hardware, reason: reason!))
    }

    private static func audioAction(_ a: MediaInfo.Audio, mode: Mode) -> AudioAction {
        switch mode {
        case .compatible:
            // AAC stereo is the one audio format every AirPlay receiver decodes.
            if a.codec == "aac", a.channels <= 2, !(a.profile ?? "").contains("HE-AACv2") { return .copy }
            return .transcode(encoder: "aac", bitrate: "192k", channels: min(max(a.channels, 1), 2))
        case .original:
            switch a.codec {
            case "aac", "ac3", "eac3":
                return .copy
            default:
                if a.channels > 2 { return .transcode(encoder: "ac3", bitrate: "640k", channels: min(a.channels, 6)) }
                return .transcode(encoder: "aac", bitrate: "192k", channels: max(a.channels, 1))
            }
        }
    }

    // MARK: - ffmpeg

    /// Re-encoded files are streamed on demand: MPEG-TS segments of a fixed length, so the complete playlist is known
    /// up front and ffmpeg can be restarted at whatever segment the player seeks to (TS segments carry absolute
    /// timestamps; fMP4 fragments from a restarted muxer would start at zero). Copied video is remuxed once into an
    /// fMP4 EVENT playlist instead: that is fast and its segments follow the source's keyframes, which can't be predicted.
    public var isOnDemand: Bool {
        if case .transcode = video, info.duration > 0 { return true }
        return false
    }

    public static let onDemandSegmentSeconds = 4

    /// The name shown for a video: the file name without extension, or host and last path component for a URL.
    public static func displayTitle(_ url: URL) -> String {
        url.isFileURL ? url.deletingPathExtension().lastPathComponent : (url.host.map { "\($0) – " } ?? "") + url.lastPathComponent
    }

    /// Arguments for an ffmpeg process that writes the HLS stream into `dir`, starting at `startSegment` (on demand only).
    public func ffmpegArguments(input: URL, dir: URL, startSegment: Int = 0) -> [String] {
        let segmentLength = isOnDemand ? Self.onDemandSegmentSeconds : segmentSeconds
        let startTime = startSegment * Self.onDemandSegmentSeconds
        var args = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-progress", "pipe:1"]
        if case .transcode(let t) = video, t.hardwareDecode {
            args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
        }
        if isOnDemand && startSegment > 0 { args += ["-ss", "\(startTime)"] }
        args += input.ffmpegInputOptions + ["-i", input.ffmpegInput, "-map", "0:\(info.video.index)"]
        for a in audio { args += ["-map", "0:\(a.track.index)"] }
        // The receiver shows the stream's title tag; release files often carry unrelated ones (a song title, a
        // release group), so drop the container's tags and use the file name. Per-track language tags stay.
        args += ["-map_metadata:g", "-1", "-metadata", "title=\(Self.displayTitle(input))"]

        switch video {
        case .copy:
            args += ["-c:v", "copy"]
            if info.video.codec == "hevc" { args += ["-tag:v", "hvc1"] }
        case .transcode(let t):
            if t.hardwareDecode {
                // VideoToolbox scales and converts to BT.709 SDR (tone mapping HDR) on the GPU.
                args += ["-vf", "scale_vt=w=\(t.width):h=\(t.height):color_matrix=bt709:color_primaries=bt709:color_transfer=bt709"]
            } else {
                let deinterlace = info.video.isInterlaced ? "yadif," : ""
                args += ["-vf", "\(deinterlace)scale=\(t.width):\(t.height):flags=bicubic,setsar=1,format=yuv420p",
                         "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }
            // Keyframes exactly on the segment grid, so every segment starts where the playlist says it does.
            args += ["-c:v", t.encoder, "-allow_sw", "1", "-profile:v", "high",
                     "-b:v", "\(t.bitrate)", "-maxrate", "\(t.bitrate * 3 / 2)", "-bufsize", "\(t.bitrate * 2)",
                     "-force_key_frames", "expr:gte(t,n_forced*\(segmentLength))", "-tag:v", "avc1"]
        }

        for (i, a) in audio.enumerated() {
            switch a.action {
            case .copy:
                args += ["-c:a:\(i)", "copy"]
            case .transcode(let encoder, let bitrate, let channels):
                args += ["-c:a:\(i)", encoder, "-b:a:\(i)", bitrate, "-ac:a:\(i)", "\(channels)"]
            }
        }

        args += ["-max_muxing_queue_size", "4096", "-f", "hls", "-hls_time", "\(segmentLength)"]
        let ext: String
        if isOnDemand {
            ext = "ts"
            args += ["-output_ts_offset", "\(startTime)",
                     "-hls_segment_type", "mpegts", "-hls_list_size", "0", "-hls_flags", "independent_segments+temp_file",
                     "-start_number", "\(startSegment)"]
        } else {
            ext = "m4s"
            args += ["-hls_playlist_type", "event", "-hls_segment_type", "fmp4", "-hls_flags", "independent_segments+temp_file",
                     "-hls_fmp4_init_filename", "init.mp4", "-master_pl_name", StreamFiles.ffmpegMaster]
        }
        // On demand, ffmpeg's own playlists are unused (the session serves complete ones); each run gets its own
        // names so a restart never picks up the previous run's playlist.
        let playlistPrefix = isOnDemand ? "run\(startSegment)_" : "p_"
        if audio.isEmpty {
            args += ["-hls_segment_filename", dir.appendingPathComponent("sv_%05d.\(ext)").path,
                     dir.appendingPathComponent("\(playlistPrefix)v.m3u8").path]
        } else {
            let map = (["v:0,agroup:aud,name:v"] + audio.indices.map { "a:\($0),agroup:aud,name:a\($0)" }).joined(separator: " ")
            args += ["-hls_segment_filename", dir.appendingPathComponent("s%v_%05d.\(ext)").path,
                     "-var_stream_map", map, dir.appendingPathComponent("\(playlistPrefix)%v.m3u8").path]
        }
        return args
    }

    let segmentSeconds = 6

    /// HLS VIDEO-RANGE: HDR10 / HLG stays HDR when the video is copied (or re-encoded to 10-bit HEVC).
    var keepsVideoRange: Bool {
        switch video {
        case .copy: return true
        case .transcode: return false
        }
    }

    var videoRange: String {
        guard keepsVideoRange else { return "SDR" }
        switch info.video.colorTransfer {
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        default: return "SDR"
        }
    }

    /// Codec strings of the audio renditions as they come out of ffmpeg.
    var audioCodecStrings: [String] {
        var result: [String] = []
        for a in audio {
            let s: String?
            switch a.action {
            case .copy: s = CodecString.audio(codec: a.track.codec, profile: a.track.profile)
            case .transcode(let encoder, _, _): s = CodecString.audio(codec: encoder, profile: nil)
            }
            if let s, !result.contains(s) { result.append(s) }
        }
        return result
    }

    // MARK: - Helpers

    public var summary: [String] {
        var lines: [String] = []
        let v = info.video
        let videoDesc = "\(Self.codecName(v.codec, profile: v.profile)) \(v.width)×\(v.height)"
        switch video {
        case .copy:
            lines.append(loc("Video: \(videoDesc) – passed through in original quality"))
        case .transcode(let t):
            lines.append(loc("Video: \(videoDesc) → H.264 \("\(t.width)×\(t.height)") (\(t.reason))"))
        }
        for a in audio {
            switch a.action {
            case .copy: lines.append(loc("Audio: \(a.name) – original"))
            case .transcode(let encoder, _, let ch):
                lines.append(loc("Audio: \(a.name) → \(encoder == "ac3" ? "Dolby Digital" : "AAC") \(Self.channelName(ch))"))
            }
        }
        for s in subtitles { lines.append(s.isDefault ? loc("Subtitle: \(s.name) – on by default") : loc("Subtitle: \(s.name)")) }
        for s in skippedSubtitles {
            lines.append(loc("Subtitle skipped: \(Language.displayName(s.language) ?? loc("unknown")) (\(Self.codecName(s.codec, profile: nil)) is image-based and can't be converted)"))
        }
        return lines
    }

    static func codecName(_ codec: String, profile: String?) -> String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vc1": return "VC-1"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4 (DivX/Xvid)"
        case "dts": return profile.map { $0.hasPrefix("DTS") ? $0 : "DTS \($0)" } ?? "DTS"
        case "truehd": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "aac": return "AAC"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "dvb_subtitle": return "DVB"
        default:
            if codec.hasPrefix("pcm_") { return "PCM" }
            return codec.uppercased()
        }
    }

    static func channelName(_ n: Int) -> String {
        switch n {
        case 1: return loc("mono")
        case 2: return loc("stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return loc("\(String(n)) channels")
        }
    }

    /// A subtitle file next to the video ("Film.hun.srt") or added by the user: the language comes from the suffix.
    public static func externalSubtitle(_ file: URL, video: URL, usedNames: Set<String>) -> SubtitleRendition {
        var suffix = sidecarSuffix(file, video: video)
        if !file.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(video.deletingPathExtension().lastPathComponent.lowercased()) {
            suffix = file.deletingPathExtension().lastPathComponent
        }
        let lang = suffix.split(whereSeparator: { ".-_ ".contains($0) }).lazy.compactMap { Language.bcp47(String($0)) }.first
        let base = lang.flatMap(Language.displayName) ?? (suffix.isEmpty ? loc("External subtitle") : suffix)
        var used = usedNames
        return SubtitleRendition(source: .file(file), name: unique(base + " " + loc("(external)"), &used),
                                 language: lang, isDefault: false, isForced: false)
    }

    private static func unique(_ name: String, _ used: inout Set<String>) -> String {
        var candidate = name, n = 2
        while used.contains(candidate) { candidate = "\(name) \(n)"; n += 1 }
        used.insert(candidate)
        return candidate
    }

    static let sidecarExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    /// "Film.mkv" -> "Film.srt", "Film.hun.srt", "Film.hu.forced.srt", …
    static func sidecarSubtitles(for video: URL) -> [URL] {
        guard video.isFileURL else { return [] }
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(),
                                                                   includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            sidecarExtensions.contains($0.pathExtension.lowercased())
                && $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func sidecarSuffix(_ file: URL, video: URL) -> String {
        let base = video.deletingPathExtension().lastPathComponent
        let name = file.deletingPathExtension().lastPathComponent
        return String(name.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: ". _-"))
    }
}

enum StreamFiles {
    static let ffmpegMaster = "ffmpeg_master.m3u8"
    static let master = "master.m3u8"
    static let videoPlaylist = "p_v.m3u8"
    static func audioPlaylist(_ i: Int) -> String { "p_a\(i).m3u8" }
    static func subtitlePlaylist(_ i: Int) -> String { "sub_\(i).m3u8" }
    static func subtitleFile(_ i: Int) -> String { "sub_\(i).vtt" }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
