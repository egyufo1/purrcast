import Foundation

public struct MediaInfo {
    public struct Video {
        public let index: Int
        public let codec: String
        public let profile: String?
        public let pixFmt: String?
        public let colorTransfer: String?
        public let width: Int
        public let height: Int
        public let level: Int?
        public let fieldOrder: String?
        /// Pixel aspect ratio (DVDs and TV recordings are anamorphic), 1 when square.
        public let pixelAspect: Double

        public var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }
        public var isInterlaced: Bool { ["tt", "bb", "tb", "bt"].contains(fieldOrder ?? "") }
    }

    public struct Audio {
        public let index: Int
        public let codec: String
        public let profile: String?
        public let channels: Int
        public let language: String?
        public let title: String?
        public let isDefault: Bool
    }

    public struct Subtitle {
        public let index: Int
        public let codec: String
        public let language: String?
        public let title: String?
        public let isDefault: Bool
        public let isForced: Bool

        static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]
        public var isText: Bool { Self.textCodecs.contains(codec) }
    }

    public struct Chapter: Hashable {
        public let title: String
        public let start: Double
    }

    /// One block of the media information window: a title and label/value rows (labels already localized).
    public struct Section: Identifiable {
        public let id = UUID()
        public let title: String
        public let rows: [(String, String)]
    }

    public let duration: Double
    public let chapters: [Chapter]
    public let sections: [Section]
    public let video: Video
    public let audio: [Audio]
    public let subtitles: [Subtitle]

    /// Just the length (for playlists); nil when unknown (live streams, unreadable files).
    public static func quickDuration(_ url: URL) async -> Double? {
        guard let ffprobe = Tools.find("ffprobe") else { return nil }
        var args = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"]
        if !url.isFileURL { args += ["-rw_timeout", "10000000"] }
        guard let result = try? await Tools.capture(ffprobe, args + [url.ffmpegInput]), result.status == 0,
              let seconds = Double(String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds > 0 else { return nil }
        return seconds
    }

    public static func probe(_ url: URL) async throws -> MediaInfo {
        let ffprobe = try Tools.require("ffprobe")
        let result = try await Tools.capture(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.ffmpegInput,
        ])
        guard result.status == 0 else {
            throw PlayerError.probeFailed(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: result.out)
        } catch {
            throw PlayerError.probeFailed(error.localizedDescription)
        }

        // Cover art in MKV shows up as an attached_pic "video" stream.
        guard let v = raw.streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw PlayerError.noVideo
        }
        let video = Video(index: v.index, codec: v.codec_name ?? "?", profile: v.profile, pixFmt: v.pix_fmt,
                          colorTransfer: v.color_transfer,
                          width: v.width ?? 0, height: v.height ?? 0, level: v.level, fieldOrder: v.field_order,
                          pixelAspect: Self.ratio(v.sample_aspect_ratio))

        let audio = raw.streams.filter { $0.codec_type == "audio" }.map {
            Audio(index: $0.index, codec: $0.codec_name ?? "?", profile: $0.profile, channels: $0.channels ?? 2,
                  language: $0.tag("language"), title: $0.tag("title"), isDefault: $0.disposition?["default"] == 1)
        }
        let subtitles = raw.streams.filter { $0.codec_type == "subtitle" }.map {
            Subtitle(index: $0.index, codec: $0.codec_name ?? "?", language: $0.tag("language"), title: $0.tag("title"),
                     isDefault: $0.disposition?["default"] == 1, isForced: $0.disposition?["forced"] == 1)
        }
        let duration = Double(raw.format?.duration ?? "") ?? Double(v.duration ?? "") ?? 0
        let chapters = (raw.chapters ?? []).enumerated().compactMap { i, c -> Chapter? in
            guard let start = Double(c.start_time ?? "") else { return nil }
            let title = c.tags?.first(where: { $0.key.lowercased() == "title" })?.value
            return Chapter(title: title?.isEmpty == false ? title! : loc("Chapter \(String(i + 1))"), start: start)
        }
        return MediaInfo(duration: duration, chapters: chapters, sections: sections(raw, url: url, duration: duration),
                         video: video, audio: audio, subtitles: subtitles)
    }

    private static func sections(_ raw: Raw, url: URL, duration: Double) -> [Section] {
        var result: [Section] = []
        let f = raw.format
        var general: [(String, String)] = [(loc("File"), url.isFileURL ? url.path : url.absoluteString)]
        if let name = f?.format_long_name { general.append((loc("Format"), name)) }
        if duration > 0 { general.append((loc("Duration"), formatTime(duration))) }
        if let size = f?.size.flatMap(Int64.init) {
            general.append((loc("Size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let rate = f?.bit_rate.flatMap(Double.init) { general.append((loc("Bitrate"), bitrate(rate))) }
        for (key, value) in (f?.tags ?? [:]).sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            general.append((key.capitalized, value))
        }
        result.append(Section(title: loc("General"), rows: general))

        for st in raw.streams {
            var rows: [(String, String)] = []
            rows.append((loc("Codec"), [st.codec_long_name ?? st.codec_name, st.profile].compactMap { $0 }.joined(separator: " – ")))
            if let lang = st.tag("language"), let name = Language.displayName(lang) { rows.append((loc("Language"), name)) }
            if let title = st.tag("title"), !title.isEmpty { rows.append((loc("Title"), title)) }
            if let w = st.width, let h = st.height { rows.append((loc("Resolution"), "\(w)×\(h)")) }
            if let fps = st.avg_frame_rate.flatMap(ratio), fps > 0, st.codec_type == "video" {
                rows.append((loc("Frame rate"), String(format: "%.3g fps", fps)))
            }
            if let pix = st.pix_fmt { rows.append((loc("Pixel format"), pix)) }
            if let trc = st.color_transfer, trc != "unknown" {
                let hdr = trc == "smpte2084" ? "HDR10 (PQ)" : trc == "arib-std-b67" ? "HLG" : "SDR"
                rows.append((loc("Dynamic range"), "\(hdr) – \(trc)"))
            }
            if let ch = st.channels {
                rows.append((loc("Channels"), [String(ch), st.channel_layout].compactMap { $0 }.joined(separator: " – ")))
            }
            if let sr = st.sample_rate.flatMap(Int.init) { rows.append((loc("Sample rate"), "\(sr) Hz")) }
            if let rate = st.bit_rate.flatMap(Double.init) { rows.append((loc("Bitrate"), bitrate(rate))) }
            let kind: String
            switch st.codec_type {
            case "video": kind = loc("Video")
            case "audio": kind = loc("Audio")
            case "subtitle": kind = loc("Subtitle")
            default: kind = st.codec_type ?? "?"
            }
            result.append(Section(title: loc("Stream \(String(st.index)): \(kind)"), rows: rows))
        }
        return result
    }

    private static func bitrate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbit/s", bps / 1_000_000) : String(format: "%.0f kbit/s", bps / 1000)
    }

    private static func ratio(_ s: String) -> Double? {
        let p = s.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] > 0 else { return Double(s) }
        return p[0] / p[1]
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func ratio(_ s: String?) -> Double {
        let parts = (s ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 1 }
        return parts[0] / parts[1]
    }

    private struct Raw: Decodable {
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let profile: String?
            let pix_fmt: String?
            let color_transfer: String?
            let codec_long_name: String?
            let avg_frame_rate: String?
            let sample_rate: String?
            let bit_rate: String?
            let channel_layout: String?
            let level: Int?
            let field_order: String?
            let sample_aspect_ratio: String?
            let width: Int?
            let height: Int?
            let channels: Int?
            let duration: String?
            let tags: [String: String]?
            let disposition: [String: Int]?

            func tag(_ key: String) -> String? {
                tags?.first(where: { $0.key.lowercased() == key })?.value
            }
        }
        struct Format: Decodable {
            let duration: String?
            let format_long_name: String?
            let size: String?
            let bit_rate: String?
            let tags: [String: String]?
        }
        struct Chapter: Decodable {
            let start_time: String?
            let tags: [String: String]?
        }
        let streams: [Stream]
        let format: Format?
        let chapters: [Chapter]?
    }
}
