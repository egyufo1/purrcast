import Foundation

/// One playback: runs ffmpeg (any video -> HLS), converts the text subtitles to WebVTT and serves everything
/// over HTTP. The returned master playlist URL can be handed to AVPlayer, which passes it on to the
/// AirPlay receiver; the receiver then streams directly from this Mac.
///
/// Two ways of producing the stream (see `StreamPlan.isOnDemand`):
/// - remux (copied video): one ffmpeg run writes an fMP4 EVENT playlist; it is fast, but the player can only seek
///   into the part that is done.
/// - on demand (re-encoded video): the complete playlist of fixed 4 s MPEG-TS segments is served up front; when the
///   player asks for a segment that doesn't exist and isn't coming soon, ffmpeg is restarted at that segment. So
///   seeking works anywhere, immediately, like in a local player.
public final class StreamSession {
    public let input: URL
    public let plan: StreamPlan
    public let workDir: URL

    /// Seconds of the movie converted so far (remux mode; on demand it is the position of the running ffmpeg).
    public var onProgress: ((Double) -> Void)?
    /// ffmpeg finished; nil on success. Not called for runs the session replaced itself.
    public var onFinished: ((Error?) -> Void)?
    /// A subtitle became available after start-up (late conversion or added file); the player item has to be
    /// reloaded to see it.
    public var onSubtitlesChanged: (() -> Void)?

    public var isOnDemand: Bool { plan.isOnDemand }

    /// Playback started before the remux was complete: the player only knows part of the playlist and has to
    /// reload the stream when onFinished(nil) arrives.
    public private(set) var remuxPending = false

    /// Shifts all subtitles: positive = later. Takes effect when the player reloads the subtitle files.
    public var subtitleDelay: Double {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    private let server = HLSServer()
    private let lock = NSLock()
    private var ffmpegPath = ""
    private var current: Run?
    private var generation = 0
    private var helpers: [Process] = []
    private var subtitles: [StreamPlan.SubtitleRendition]
    private var readySubtitles = Set<Int>()
    private var pendingSubtitles = Set<Int>()
    private var stderrTail = ""
    private var failure: String?
    private var stopped = false
    private var started = false
    private var delay = 0.0
    private var videoCodec: String?

    private struct Run {
        let process: Process
        let generation: Int
        let startSegment: Int
        /// First segment index this run hasn't written yet (advanced lazily by looking at the files).
        var next: Int
    }

    private static let segmentLength = Double(StreamPlan.onDemandSegmentSeconds)
    /// A request this many segments ahead of the running ffmpeg waits for it instead of restarting it.
    private static let lookahead = 5

    public init(input: URL, plan: StreamPlan) {
        self.input = input
        self.plan = plan
        subtitles = plan.subtitles
        // The PID prefix tells cleanupLeftovers() which directories still belong to a running instance.
        workDir = Self.root.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
    }

    public static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purrcast", isDirectory: true)

    /// Removes stream files left behind by crashed or force-quit runs, but not those of another running instance.
    public static func cleanupLeftovers() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let pid = dir.lastPathComponent.split(separator: "-").first.flatMap { pid_t($0) }
            if let pid, pid != getpid(), kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public var subtitlesPending: Bool { lock.withLock { !pendingSubtitles.isEmpty } }

    private var segmentCount: Int { max(1, Int((plan.info.duration / Self.segmentLength).rounded(.up))) }

    // MARK: - Start / stop

    /// Starts converting and serving; returns the master playlist URL once playback can begin.
    /// `position` (on demand only) starts the conversion there, for resuming.
    public func start(at position: Double = 0) async throws -> URL {
        ffmpegPath = try Tools.require("ffmpeg")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try checkDiskSpace()

        server.handler = { [weak self] in self?.serve($0) }
        let port = try server.start()
        let host = HLSServer.lanAddress() ?? "127.0.0.1"
        Log.write("open \(input.lastPathComponent) -> http://\(host):\(port)/ on-demand=\(isOnDemand) ; \(plan.summary.joined(separator: " | "))")

        startSubtitleConversion()
        let firstSegment = isOnDemand ? min(Int(max(position, 0) / Self.segmentLength), segmentCount - 1) : 0
        try lock.withLock { try launch(startSegment: firstSegment) }

        // Wait until there is something to play.
        let begin = Date()
        while !isReady(firstSegment) {
            try Task.checkCancellation()
            if let failure = lock.withLock({ failure }) { throw PlayerError.ffmpegFailed(failure) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if isOnDemand {
            videoCodec = await Self.h264CodecString(of: segmentURL("v", firstSegment))
        } else {
            // A remux is usually done in seconds: waiting for it gives the player the complete playlist, so it can
            // seek anywhere. A slow one (huge file, network disk) starts playing and is reloaded when done.
            while lock.withLock({ current?.process.isRunning ?? false }), Date().timeIntervalSince(begin) < 8 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            remuxPending = lock.withLock { current?.process.isRunning ?? false }
        }
        // Give the subtitles a little time too; late ones are announced through onSubtitlesChanged.
        // (Not for network streams: extracting their subtitles means downloading the whole stream.)
        while subtitlesPending, input.isFileURL, Date().timeIntervalSince(begin) < 15 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        lock.withLock { started = true }
        return URL(string: "http://\(host):\(port)/\(StreamFiles.master)")!
    }

    /// Kills ffmpeg and deletes the stream files. `waitUntilDone` is for app termination.
    public func stop(waitUntilDone: Bool = false) {
        let processes: [Process] = lock.withLock {
            stopped = true
            return ([current?.process] + helpers).compactMap { $0 }
        }
        server.stop()
        let dir = workDir
        let cleanup = {
            for p in processes where p.isRunning {
                p.terminate()
                p.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: dir)
        }
        if waitUntilDone { cleanup() } else { DispatchQueue.global().async(execute: cleanup) }
    }

    private func checkDiskSpace() throws {
        let fileSize = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var needed = fileSize
        if case .transcode(let t) = plan.video {
            needed = Int64(Double(t.bitrate) * 1.5 * plan.info.duration / 8)
        }
        let values = try? workDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed + 1_000_000_000 {
            throw PlayerError.diskSpace(needed: needed, available: available)
        }
    }

    // MARK: - ffmpeg

    /// Starts an ffmpeg run, replacing the current one. Call with `lock` held.
    private func launch(startSegment: Int) throws {
        if let old = current?.process, old.isRunning {
            // SIGKILL: on SIGTERM ffmpeg would finish (and publish) a truncated segment.
            kill(old.processIdentifier, SIGKILL)
        }
        generation += 1
        let gen = generation
        let offset = Double(startSegment) * Self.segmentLength
        failure = nil
        stderrTail = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = plan.ffmpegArguments(input: input, dir: workDir, startSegment: startSegment)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, self.lock.withLock({ self.generation == gen }) else { return }
            // -progress output: key=value lines, out_time_us is the converted position.
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) { self.onProgress?(offset + us / 1_000_000) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.withLock {
                guard self.generation == gen else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let report: (Bool, String)? = self.lock.withLock {
                guard self.generation == gen, !self.stopped else { return nil }   // replaced or stopped on purpose
                let ok = p.terminationStatus == 0
                if !ok { self.failure = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) }
                return (ok, self.stderrTail)
            }
            guard let (ok, tail) = report else { return }
            Log.write("ffmpeg exit \(p.terminationStatus) (run from segment \(startSegment)) \(tail.suffix(300))")
            if ok {
                self.onProgress?(self.plan.info.duration)
                self.onFinished?(nil)
            } else {
                self.onFinished?(PlayerError.ffmpegFailed(tail.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        try process.run()
        current = Run(process: process, generation: gen, startSegment: startSegment, next: startSegment)
        if startSegment > 0 { Log.write("ffmpeg restarted at segment \(startSegment) (\(Int(offset)) s)") }
    }

    private func segmentURL(_ variant: String, _ index: Int) -> URL {
        workDir.appendingPathComponent(String(format: "s%@_%05d.ts", variant, index))
    }

    private func isReady(_ firstSegment: Int) -> Bool {
        let fm = FileManager.default
        if isOnDemand {
            let variants = ["v"] + plan.audio.indices.map { "a\($0)" }
            return variants.allSatisfy { fm.fileExists(atPath: segmentURL($0, firstSegment).path) }
        }
        guard fm.fileExists(atPath: workDir.appendingPathComponent(StreamFiles.ffmpegMaster).path) else { return false }
        func segments(_ name: String) -> Int {
            guard let text = try? String(contentsOf: workDir.appendingPathComponent(name), encoding: .utf8) else { return 0 }
            if text.contains("#EXT-X-ENDLIST") { return .max }
            return text.components(separatedBy: "#EXTINF").count - 1
        }
        guard segments(StreamFiles.videoPlaylist) >= 2 else { return false }
        return plan.audio.indices.allSatisfy { segments(StreamFiles.audioPlaylist($0)) >= 1 }
    }

    /// "avc1.640028" from the SPS of a produced segment.
    private static func h264CodecString(of segment: URL) async -> String? {
        guard let ffprobe = Tools.find("ffprobe"),
              let result = try? await Tools.capture(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                              "stream=profile,level", "-of", "default=nw=1", segment.path])
        else { return nil }
        let text = String(decoding: result.out, as: UTF8.self)
        guard let level = text.split(separator: "\n").first(where: { $0.hasPrefix("level=") }).flatMap({ Int($0.dropFirst(6)) })
        else { return nil }
        let profile = text.contains("profile=Main") ? 0x4D : text.contains("profile=Baseline") || text.contains("Constrained") ? 0x42 : 0x64
        return String(format: "avc1.%02X00%02X", profile, level)
    }

    // MARK: - On-demand segments

    /// Returns the segment, restarting ffmpeg at it when it isn't produced and isn't coming soon. Blocks the
    /// (concurrent) HTTP queue until it exists.
    private func onDemandSegment(_ path: String, index: Int) -> HLSServer.Response? {
        let url = workDir.appendingPathComponent(path)
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url) { return segmentResponse(data) }
        guard index < segmentCount else { return nil }

        lock.withLock {
            guard !stopped else { return }
            if var run = current, run.process.isRunning, run.startSegment <= index {
                while fm.fileExists(atPath: segmentURL("v", run.next).path) { run.next += 1 }
                current = run
                if index <= run.next + Self.lookahead { return }          // the running ffmpeg gets there soon
            }
            try? launch(startSegment: index)
        }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) { return segmentResponse(data) }
            if lock.withLock({ stopped || (failure != nil) }) { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Log.write("segment \(path) timed out")
        return nil
    }

    private func segmentResponse(_ data: Data) -> HLSServer.Response {
        HLSServer.Response(status: 200, contentType: "video/mp2t", body: data)
    }

    /// The complete VOD playlist of one variant ("v", "a0", …).
    private func onDemandPlaylist(_ variant: String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(StreamPlan.onDemandSegmentSeconds)",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let count = segmentCount
        for i in 0..<count {
            let length = i == count - 1 ? plan.info.duration - Double(i) * Self.segmentLength : Self.segmentLength
            lines.append(String(format: "#EXTINF:%.3f,", max(length, 0.1)))
            lines.append(String(format: "s%@_%05d.ts", variant, i))
        }
        lines += ["#EXT-X-ENDLIST", ""]
        return lines.joined(separator: "\n")
    }

    // MARK: - Subtitles

    /// Adds a subtitle file (.srt, .ass, .vtt) during playback; announced through onSubtitlesChanged when converted.
    public func addSubtitle(_ file: URL) {
        let index: Int = lock.withLock {
            let used = Set(subtitles.map(\.name))
            subtitles.append(StreamPlan.externalSubtitle(file, video: input, usedNames: used))
            pendingSubtitles.insert(subtitles.count - 1)
            return subtitles.count - 1
        }
        convertSidecar(file, index: index)
    }

    /// Names of all subtitles (index = position), for the app's menus.
    public var subtitleNames: [String] { lock.withLock { subtitles.map(\.name) } }

    private func startSubtitleConversion() {
        let subs = lock.withLock { subtitles }
        guard !subs.isEmpty else { return }
        lock.withLock { pendingSubtitles = Set(subs.indices) }

        // Embedded subtitles: one extra pass over the file writes all of them.
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + input.ffmpegInputOptions + ["-i", input.ffmpegInput]
        var embedded: [Int] = []
        for (i, sub) in subs.enumerated() {
            guard case .embedded(let index) = sub.source else { continue }
            args += ["-map", "0:\(index)", "-c:s", "webvtt", "-f", "webvtt", partPath(i)]
            embedded.append(i)
        }
        if !embedded.isEmpty { runHelper(args, subtitles: embedded) }

        for (i, sub) in subs.enumerated() {
            if case .file(let url) = sub.source { convertSidecar(url, index: i) }
        }
    }

    /// Hungarian .srt files are often Windows-1250, ffmpeg expects UTF-8.
    private func convertSidecar(_ url: URL, index i: Int) {
        do {
            let utf8 = workDir.appendingPathComponent("side_\(i).\(url.pathExtension.lowercased())")
            try Self.utf8Text(of: url).write(to: utf8, atomically: true, encoding: .utf8)
            runHelper(["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", utf8.path,
                       "-c:s", "webvtt", "-f", "webvtt", partPath(i)], subtitles: [i])
        } catch {
            finishSubtitles([i], success: false)
        }
    }

    private func partPath(_ i: Int) -> String {
        workDir.appendingPathComponent(StreamFiles.subtitleFile(i) + ".part").path
    }

    private func runHelper(_ args: [String], subtitles: [Int]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            var ok: [Int] = [], failed: [Int] = []
            for i in subtitles {
                let part = URL(fileURLWithPath: self.partPath(i))
                let final = self.workDir.appendingPathComponent(StreamFiles.subtitleFile(i))
                if p.terminationStatus == 0, (try? FileManager.default.moveItem(at: part, to: final)) != nil {
                    ok.append(i)
                } else {
                    failed.append(i)
                }
            }
            self.finishSubtitles(ok, success: true)
            self.finishSubtitles(failed, success: false)
        }
        do {
            try process.run()
            lock.withLock { helpers.append(process) }
        } catch {
            finishSubtitles(subtitles, success: false)
        }
    }

    private func finishSubtitles(_ indices: [Int], success: Bool) {
        guard !indices.isEmpty else { return }
        let notify = lock.withLock { () -> Bool in
            pendingSubtitles.subtract(indices)
            if success { readySubtitles.formUnion(indices) }
            return started && success
        }
        if notify { onSubtitlesChanged?() }
    }

    static func utf8Text(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .windowsCP1250) ?? String(decoding: data, as: UTF8.self)
    }

    /// Moves every cue by `seconds` (cues that would start before 0 are clamped).
    static func shiftVTT(_ text: String, by seconds: Double) -> String {
        guard seconds != 0 else { return text }
        let pattern = try! NSRegularExpression(pattern: #"(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})"#)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.contains("-->") else { return String(line) }
            let s = String(line), ns = s as NSString
            var result = s
            for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                func part(_ i: Int) -> Double {
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? 0 : Double(ns.substring(with: r)) ?? 0
                }
                let t = max(0, part(1) * 3600 + part(2) * 60 + part(3) + part(4) / 1000 + seconds)
                let ms = Int((t * 1000).rounded())
                let stamp = String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
                result = (result as NSString).replacingCharacters(in: m.range, with: stamp)
            }
            return result
        }.joined(separator: "\n")
    }

    // MARK: - HTTP

    private func serve(_ path: String) -> HLSServer.Response? {
        guard path.range(of: "^[A-Za-z0-9_-]+\\.(m3u8|m4s|mp4|vtt|ts)$", options: .regularExpression) != nil,
              path != StreamFiles.ffmpegMaster, !path.hasPrefix("run") else { return nil }
        if path == StreamFiles.master {
            return masterPlaylist().map { playlist($0) }
        }
        if let i = subtitleIndex(path, ext: "m3u8") {
            return lock.withLock({ readySubtitles.contains(i) }) ? playlist(subtitlePlaylist(i)) : nil
        }
        if let i = subtitleIndex(path, ext: "vtt") {
            guard lock.withLock({ readySubtitles.contains(i) }),
                  let text = try? String(contentsOf: workDir.appendingPathComponent(path), encoding: .utf8) else { return nil }
            var vtt = Self.shiftVTT(text, by: subtitleDelay)
            if isOnDemand, !vtt.contains("X-TIMESTAMP-MAP"), let r = vtt.range(of: "WEBVTT") {
                // TS segments carry absolute timestamps plus ffmpeg's 1.4 s mux delay: movie time 0 is MPEG-TS 126000.
                let lineEnd = vtt[r.upperBound...].firstIndex(of: "\n") ?? vtt.endIndex
                vtt.insert(contentsOf: "\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000", at: lineEnd)
            }
            return HLSServer.Response(status: 200, contentType: "text/vtt; charset=utf-8", body: Data(vtt.utf8))
        }
        if isOnDemand {
            if path == StreamFiles.videoPlaylist { return playlist(onDemandPlaylist("v")) }
            if path.hasPrefix("p_a"), let i = Int(path.dropFirst(3).dropLast(5)), plan.audio.indices.contains(i) {
                return playlist(onDemandPlaylist("a\(i)"))
            }
            if path.hasSuffix(".ts"), let n = Int(path.dropLast(3).suffix(5)) {
                return onDemandSegment(path, index: n)
            }
            return nil
        }
        guard let data = try? Data(contentsOf: workDir.appendingPathComponent(path)) else { return nil }
        if path.hasSuffix(".m3u8") {
            // ffmpeg writes EVENT playlists; without EXT-X-START players jump to the "live" edge.
            var text = String(decoding: data, as: UTF8.self)
            if !text.contains("#EXT-X-START"), let r = text.range(of: "#EXTM3U\n") {
                text.insert(contentsOf: "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n", at: r.upperBound)
            }
            return playlist(text)
        }
        return HLSServer.Response(status: 200, contentType: "video/mp4", body: data)
    }

    private func subtitleIndex(_ path: String, ext: String) -> Int? {
        guard path.hasPrefix("sub_"), path.hasSuffix(".\(ext)") else { return nil }
        return Int(path.dropFirst(4).dropLast(ext.count + 1))
    }

    private func playlist(_ text: String) -> HLSServer.Response {
        HLSServer.Response(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
    }

    /// The master playlist with friendly track names and the subtitles. In remux mode ffmpeg's own STREAM-INF line
    /// (resolution) is the base; CODECS and VIDEO-RANGE always come from the actual output.
    private func masterPlaylist() -> String? {
        var streamInf: String
        if isOnDemand {
            guard case .transcode(let t) = plan.video else { return nil }
            streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(peakBandwidth),RESOLUTION=\(t.width)x\(t.height)"
            if !plan.audio.isEmpty { streamInf += #",AUDIO="aud""# }
            if let videoCodec { streamInf += ",CODECS=\"\(([videoCodec] + plan.audioCodecStrings).joined(separator: ","))\"" }
            streamInf += ",VIDEO-RANGE=SDR"
        } else {
            guard let ffMaster = try? String(contentsOf: workDir.appendingPathComponent(StreamFiles.ffmpegMaster), encoding: .utf8),
                  let line = ffMaster.components(separatedBy: .newlines).first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") })
            else { return nil }
            streamInf = line.replacingOccurrences(of: #"AUDIO="[^"]*""#, with: #"AUDIO="aud""#, options: .regularExpression)
            // ffmpeg derives BANDWIDTH from the first segment only; players log errors when later segments exceed it.
            streamInf = streamInf.replacingOccurrences(of: #",AVERAGE-BANDWIDTH=\d+"#, with: "", options: .regularExpression)
            streamInf = streamInf.replacingOccurrences(of: #"BANDWIDTH=\d+"#, with: "BANDWIDTH=\(peakBandwidth)", options: .regularExpression)
            streamInf = streamInf.replacingOccurrences(of: #",CODECS="[^"]*""#, with: "", options: .regularExpression)
            let initName = plan.audio.isEmpty ? "init.mp4" : "init_0.mp4"
            if let video = CodecString.video(initSegment: workDir.appendingPathComponent(initName)) {
                streamInf += ",CODECS=\"\(([video] + plan.audioCodecStrings).joined(separator: ","))\""
            }
            let range = plan.keepsVideoRange
                ? CodecString.videoRange(initSegment: workDir.appendingPathComponent(initName)) ?? plan.videoRange : "SDR"
            streamInf += ",VIDEO-RANGE=\(range)"
        }

        let (subs, ready) = lock.withLock { (subtitles, readySubtitles) }
        if !ready.isEmpty { streamInf += #",SUBTITLES="subs""# }

        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:\(isOnDemand ? 4 : 7)", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if !isOnDemand { lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES") }
        for (i, a) in plan.audio.enumerated() {
            var attrs = ["TYPE=AUDIO", "GROUP-ID=\"aud\"", "NAME=\(quoted(a.name))"]
            if let lang = Language.bcp47(a.track.language) { attrs.append("LANGUAGE=\(quoted(lang))") }
            attrs += ["DEFAULT=\(a.isDefault ? "YES" : "NO")", "AUTOSELECT=YES", "CHANNELS=\"\(a.outputChannels)\"",
                      "URI=\(quoted(StreamFiles.audioPlaylist(i)))"]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }
        for i in ready.sorted() where subs.indices.contains(i) {
            let s = subs[i]
            var attrs = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"", "NAME=\(quoted(s.name))"]
            if let lang = s.language { attrs.append("LANGUAGE=\(quoted(lang))") }
            attrs += ["DEFAULT=\(s.isDefault ? "YES" : "NO")", "AUTOSELECT=YES", "FORCED=\(s.isForced ? "YES" : "NO")",
                      "URI=\(quoted(StreamFiles.subtitlePlaylist(i)))"]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }
        lines += [streamInf, StreamFiles.videoPlaylist, ""]
        return lines.joined(separator: "\n")
    }

    private lazy var peakBandwidth: Int = {
        if case .transcode(let t) = plan.video { return t.bitrate * 3 / 2 + 1_000_000 }
        let size = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard plan.info.duration > 0, size > 0 else { return 40_000_000 }
        return Int(Double(size) * 8 / plan.info.duration * 2)
    }()

    /// The whole WebVTT file as a single segment.
    private func subtitlePlaylist(_ i: Int) -> String {
        let duration = max(plan.info.duration, 1)
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(String(format: "%.3f", duration)),
        \(StreamFiles.subtitleFile(i))
        #EXT-X-ENDLIST

        """
    }
}
