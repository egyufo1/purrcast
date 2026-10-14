import Foundation

/// RFC 6381 codec strings for the master playlist's CODECS attribute. ffmpeg leaves CODECS out for
/// HEVC, and without it AirPlay receivers assume H.264 and never start playback.
enum CodecString {
    /// Reads the avcC / hvcC configuration box from an fMP4 init segment.
    static func video(initSegment url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)

        if let i = find("hvcC", in: bytes), i + 4 + 13 <= bytes.count {
            let b = Array(bytes[(i + 4)..<(i + 4 + 13)])
            let space = ["", "A", "B", "C"][Int(b[1] >> 6)]
            let tier = (b[1] >> 5) & 1 == 1 ? "H" : "L"
            let profile = b[1] & 0x1F
            let compat = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
            var constraints = Array(b[6..<12])
            while constraints.last == 0 { constraints.removeLast() }
            var parts = ["hvc1", "\(space)\(profile)", String(reverseBits(compat), radix: 16, uppercase: true), "\(tier)\(b[12])"]
            parts += constraints.map { String($0, radix: 16, uppercase: true) }
            return parts.joined(separator: ".")
        }
        if let i = find("avcC", in: bytes), i + 4 + 4 <= bytes.count {
            return String(format: "avc1.%02X%02X%02X", bytes[i + 5], bytes[i + 6], bytes[i + 7])
        }
        return nil
    }

    /// HLS VIDEO-RANGE from the init segment's colr/nclx box (transfer 16 = PQ, 18 = HLG). Players reject a
    /// PQ stream that the playlist calls SDR, and container tags are often missing, so the bitstream decides.
    static func videoRange(initSegment url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard let i = find("colr", in: bytes), i + 12 <= bytes.count,
              bytes[(i + 4)..<(i + 8)].elementsEqual("nclx".utf8) else { return nil }
        switch UInt16(bytes[i + 10]) << 8 | UInt16(bytes[i + 11]) {
        case 16: return "PQ"
        case 18: return "HLG"
        default: return "SDR"
        }
    }

    static func audio(codec: String, profile: String?) -> String? {
        switch codec {
        case "aac":
            let p = profile ?? ""
            return p.contains("HE-AACv2") ? "mp4a.40.29" : p.contains("HE-AAC") ? "mp4a.40.5" : "mp4a.40.2"
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        default: return nil
        }
    }

    private static func find(_ type: String, in bytes: [UInt8]) -> Int? {
        let t = Array(type.utf8)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == t[0] && bytes[i + 1] == t[1] && bytes[i + 2] == t[2] && bytes[i + 3] == t[3] {
            return i
        }
        return nil
    }

    private static func reverseBits(_ v: UInt32) -> UInt32 {
        var v = v, r: UInt32 = 0
        for _ in 0..<32 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }
}

/// Append-only diagnostic log: ~/Library/Logs/Purrcast.log
public enum Log {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Purrcast.log")
    private static let queue = DispatchQueue(label: "log")

    public static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
