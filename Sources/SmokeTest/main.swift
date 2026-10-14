import PurrcastCore
import AVFoundation
import Foundation

// Usage: swift run SmokeTest <video file>
// Converts the file, loads the stream with AVPlayer (as an AirPlay receiver would) and plays a few seconds.

guard CommandLine.arguments.count > 1 else {
    print("usage: SmokeTest <video file>")
    exit(2)
}
// "--net <url>" converts a network stream like a file.
let input = CommandLine.arguments[1] == "--net" ? URL(string: CommandLine.arguments[2])! : URL(fileURLWithPath: CommandLine.arguments[1])

func check(_ ok: Bool, _ message: String) {
    print(ok ? "OK   \(message)" : "FAIL \(message)")
    if !ok { exit(1) }
}

// --subtiming <file>: plays with the first subtitle on and prints when each cue arrives.
final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var player: AVPlayer?
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: " | ")
        print(String(format: "     cue at item %.2fs (player %.2fs): %@", itemTime.seconds, player?.currentTime().seconds ?? -1, text))
    }
}
if CommandLine.arguments[1] == "--subtiming" {
    let file = URL(fileURLWithPath: CommandLine.arguments[2])
    let info = try await MediaInfo.probe(file)
    let session = StreamSession(input: file, plan: StreamPlan(info: info, input: file))
    let url = try await session.start()
    let item = AVPlayerItem(url: url)
    item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
    let collector = CueCollector()
    let output = AVPlayerItemLegibleOutput()
    output.setDelegate(collector, queue: .main)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    collector.player = player
    player.isMuted = true
    if let group = try await item.asset.loadMediaSelectionGroup(for: .legible), let first = group.options.first {
        item.select(first, in: group)
    }
    player.play()
    try await Task.sleep(nanoseconds: 6_000_000_000)
    print("     on-demand: \(session.isOnDemand)")
    session.stop(waitUntilDone: true)
    exit(0)
}

// --snapshot <file> <seconds>: saves a frame and prints the path.
if CommandLine.arguments[1] == "--snapshot" {
    let file = URL(fileURLWithPath: CommandLine.arguments[2])
    let url = try await Snapshot.save(input: file, info: try await MediaInfo.probe(file), at: Double(CommandLine.arguments[3]) ?? 0)
    print(url.path)
    exit(0)
}

// An http URL tests an already running stream (e.g. the one the app is serving right now).
if CommandLine.arguments[1].hasPrefix("http") {
    let item = AVPlayerItem(url: URL(string: CommandLine.arguments[1])!)
    item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))   // a video sink, like the app's player view
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.play()
    for _ in 0..<60 where item.status != .failed && player.currentTime().seconds < 4 {
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    if let error = item.error { print("     item error: \(error)") }
    item.errorLog()?.events.forEach { print("     errorLog: \($0.errorStatusCode) \($0.errorComment ?? "")") }
    print("     status \(item.status.rawValue) timeControl \(player.timeControlStatus.rawValue) waiting \(player.reasonForWaitingToPlay?.rawValue ?? "-") loaded \(item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }) likely \(item.isPlaybackLikelyToKeepUp)")
    item.accessLog()?.events.forEach { print("     access: segs \($0.numberOfMediaRequests) bytes \($0.numberOfBytesTransferred) indicated \($0.indicatedBitrate)") }
    check(player.currentTime().seconds > 2, "remote stream plays (\(player.currentTime().seconds)s)")
    exit(0)
}

print("     eligibleForHDRPlayback: \(AVPlayer.eligibleForHDRPlayback)")
let info = try await MediaInfo.probe(input)
let plan = StreamPlan(info: info, input: input)
plan.summary.forEach { print("     \($0)") }

let session = StreamSession(input: input, plan: plan)
let started = Date()
let url = try await session.start()
print("     stream: \(url)  (ready after \(String(format: "%.1f", Date().timeIntervalSince(started)))s)")

if let hold = ProcessInfo.processInfo.environment["SMOKE_HOLD"].flatMap(Double.init) {
    FileHandle.standardError.write(Data("HOLD \(url)\n".utf8))
    try await Task.sleep(nanoseconds: UInt64(hold * 1e9))
}
let (masterData, _) = try await URLSession.shared.data(from: url)
print(String(decoding: masterData, as: UTF8.self))

let asset = AVURLAsset(url: url)
let playable = try await asset.load(.isPlayable)
check(playable, "asset playable")
let characteristics = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
for c in characteristics {
    if let group = try await asset.loadMediaSelectionGroup(for: c) {
        print("     \(c.rawValue): " + group.options.map(\.displayName).joined(separator: " | "))
        for o in group.options {
            let titles = AVMetadataItem.metadataItems(from: o.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            print("       title=\((try? await titles.first?.load(.stringValue)) ?? "nil") ext=\(o.extendedLanguageTag ?? "-") hu=\(o.displayName(with: Locale(identifier: "hu")))")
        }
    }
}
if !plan.audio.isEmpty { check(characteristics.contains(.audible), "audio renditions visible") }
if !plan.subtitles.isEmpty { check(characteristics.contains(.legible), "subtitle renditions visible") }

let item = AVPlayerItem(asset: asset)
item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))   // a video sink, like the app's player view
let player = AVPlayer(playerItem: item)
player.isMuted = true
player.play()
for _ in 0..<40 where item.status != .failed && player.currentTime().seconds < 4 {
    try await Task.sleep(nanoseconds: 250_000_000)
}
if let error = item.error { print("     item error: \(error)") }
item.errorLog()?.events.forEach { print("     errorLog: \($0.errorStatusCode) \($0.errorComment ?? "")") }
let position = player.currentTime().seconds
check(item.status == .readyToPlay && position > 2, "playback advances (position \(String(format: "%.1f", position))s, starts from the beginning)")

// Seek far ahead (on demand: into a part that isn't converted yet, ffmpeg has to restart there).
if info.duration > 60 {
    let target = (info.duration * 0.7).rounded()
    let seekStart = Date()
    _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    for _ in 0..<120 where item.status != .failed && player.currentTime().seconds < target + 2 {
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    let t = player.currentTime().seconds
    check(t >= target + 2 && t < target + 30,
          "seek to \(Int(target))s plays from there (now \(String(format: "%.1f", t))s, took \(String(format: "%.1f", Date().timeIntervalSince(seekStart)))s, on-demand: \(plan.isOnDemand))")
}

if !plan.subtitles.isEmpty, let legible = try await asset.loadMediaSelectionGroup(for: .legible), let last = legible.options.last {
    item.select(last, in: legible)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    check(item.currentMediaSelection.selectedMediaOption(in: legible) == last, "subtitle selectable")
    // Cue at 00:01-00:04 in the test file: check the converted WebVTT is served with it.
    let vtt = url.deletingLastPathComponent().appendingPathComponent("sub_0.vtt")
    let text = String(decoding: try await URLSession.shared.data(from: vtt).0, as: UTF8.self)
    check(text.hasPrefix("WEBVTT") && text.contains("-->"), "WebVTT served")
}
session.stop(waitUntilDone: true)
print("done")
