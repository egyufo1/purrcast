import Foundation

public enum Snapshot {
    public static var folder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Purrcast")
    }

    /// Saves the frame at `time` of the source file as PNG (full resolution, square pixels, HDR tone mapped to SDR)
    /// into ~/Pictures/Purrcast and returns the file.
    public static func save(input: URL, info: MediaInfo, at time: Double) async throws -> URL {
        let ffmpeg = try Tools.require("ffmpeg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = input.deletingPathExtension().lastPathComponent
        let stamp = MediaInfo.formatTime(time).replacingOccurrences(of: ":", with: ".")
        var out = folder.appendingPathComponent("\(name) \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(name) \(stamp) (\(n)).png")
            n += 1
        }

        let v = info.video
        let width = Int((Double(v.width) * v.pixelAspect / 2).rounded()) * 2
        let base = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        let software = base + ["-ss", String(time)] + input.ffmpegInputOptions + ["-i", input.ffmpegInput, "-map", "0:\(v.index)", "-frames:v", "1",
                               "-vf", "\(v.isInterlaced ? "yadif," : "")scale=\(width):\(v.height):flags=lanczos,setsar=1", out.path]
        var attempts = [software]
        if v.isHDR, StreamPlan.hardwareDecodable.contains(v.codec) {
            // VideoToolbox tone maps HDR to SDR like the stream does; plain software decoding would look washed out.
            let hardware = base + ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld",
                                   "-ss", String(time)] + input.ffmpegInputOptions + ["-i", input.ffmpegInput, "-map", "0:\(v.index)", "-frames:v", "1",
                                   "-vf", "scale_vt=w=\(width):h=\(v.height):color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=rgb24",
                                   out.path]
            attempts.insert(hardware, at: 0)
        }
        var lastError = ""
        for args in attempts {
            let result = try await Tools.capture(ffmpeg, args)
            if result.status == 0, FileManager.default.fileExists(atPath: out.path) { return out }
            lastError = result.err
        }
        throw PlayerError.ffmpegFailed(lastError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
