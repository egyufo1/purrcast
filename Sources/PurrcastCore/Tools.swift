import Foundation

public enum PlayerError: LocalizedError {
    case toolMissing(String)
    case probeFailed(String)
    case noVideo
    case ffmpegFailed(String)
    case diskSpace(needed: Int64, available: Int64)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return loc("Not found: \(name). Install it with: brew install ffmpeg")
        case .probeFailed(let msg):
            return loc("Couldn't read the file: \(msg)")
        case .noVideo:
            return loc("The file has no video track.")
        case .ffmpegFailed(let msg):
            return loc("ffmpeg stopped with an error:\n\(msg)")
        case .diskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return loc("Not enough free space for the temporary stream files (needs about \(f.string(fromByteCount: needed)), free: \(f.string(fromByteCount: available))).")
        case .server(let msg):
            return loc("The local stream server didn't start: \(msg)")
        }
    }
}

/// Localized string from the app bundle's Localizable.strings (English keys; untranslated keys show as is).
public func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

public enum Tools {
    /// Looks for a bundled binary first, then the usual Homebrew/MacPorts locations and $PATH.
    /// Apps started from Finder don't inherit the shell PATH, so the fixed locations matter.
    public static func find(_ name: String) -> String? {
        // PURRCAST_FFMPEG_DIR: use a specific build (tests run against vendor/ffmpeg/bin, the one the app bundles).
        if let dir = ProcessInfo.processInfo.environment["PURRCAST_FFMPEG_DIR"],
           FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + envPath {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static func require(_ name: String) throws -> String {
        guard let path = find(name) else { throw PlayerError.toolMissing(name) }
        return path
    }

    /// Runs a tool to completion and returns its exit status, stdout and stderr.
    static func capture(_ exe: String, _ args: [String]) async throws -> (status: Int32, out: Data, err: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(throwing: error); return }

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus, outData, String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

enum Language {
    /// Matroska uses ISO 639-2/B codes; Foundation only knows the /T variants.
    private static let bibliographic: [String: String] = [
        "ger": "deu", "fre": "fra", "cze": "ces", "dut": "nld", "chi": "zho", "gre": "ell",
        "per": "fas", "rum": "ron", "slo": "slk", "alb": "sqi", "arm": "hye", "baq": "eus",
        "bur": "mya", "geo": "kat", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "tib": "bod", "wel": "cym", "scc": "srp", "scr": "hrv",
    ]

    /// BCP-47 code for the HLS LANGUAGE attribute ("hun" -> "hu"), nil when unknown.
    static func bcp47(_ code: String?) -> String? {
        guard var c = code?.lowercased().trimmingCharacters(in: .whitespaces), !c.isEmpty, c != "und" else { return nil }
        c = bibliographic[c] ?? c
        if let alpha2 = Locale.Language(identifier: c).languageCode?.identifier(.alpha2) { return alpha2 }
        return c.count <= 3 ? c : nil
    }

    static func displayName(_ code: String?) -> String? {
        guard let tag = bcp47(code),
              let name = Locale(identifier: uiLanguage).localizedString(forLanguageCode: tag) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The language the app's interface is shown in ("hu", "en").
    public static var uiLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Subtitles in this language are switched on for foreign-language audio.
    static var subtitlePreference: String {
        Locale.Language(identifier: uiLanguage).languageCode?.identifier(.alpha2) ?? uiLanguage
    }
}

extension URL {
    /// What ffmpeg/ffprobe get as input: the path for files, the URL itself for network streams.
    public var ffmpegInput: String { isFileURL ? path : absoluteString }

    /// Input options that go before "-i": HTTP sources reconnect when the server drops the connection.
    public var ffmpegInputOptions: [String] {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        return ["-reconnect", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "10"]
    }
}
