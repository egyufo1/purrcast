import PurrcastCore
import AVFoundation
import AppKit
import Combine
import SwiftUI

@main
struct PurrcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model: PlayerModel

    init() {
        // Before the model reads its settings (playlist, recent files…) on creation.
        AppDelegate.migrateSettingsFromAirPlayPlayer()
        _model = ObservedObject(wrappedValue: PlayerModel.shared)
    }

    var body: some Scene {
        Window("Purrcast", id: "main") {
            ContentView(model: model, playlist: model.playlist)
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 660)
        .commands { PlayerCommands(model: model, playlist: model.playlist) }

        Window("Media Information", id: "info") {
            InfoView(model: model)
        }
        .defaultSize(width: 560, height: 640)
    }
}

/// The menu bar, with VLC's keyboard shortcuts where macOS allows them.
struct PlayerCommands: Commands {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playlist: Playlist
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hideControlsAfter") private var hideControlsAfter = 3.0
    @AppStorage("appearance") private var appearance = "system"

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }.keyboardShortcut("o")
            Button("Open Network Stream…") { model.showOpenURL = true }.keyboardShortcut("n")
            Menu("Open Recent") {
                ForEach(model.recentURLs, id: \.self) { url in
                    Button(url.isFileURL ? url.lastPathComponent : url.absoluteString) { model.open([url]) }
                }
                if !model.recentURLs.isEmpty { Divider() }
                Button("Clear Menu") { model.clearRecent() }.disabled(model.recentURLs.isEmpty)
            }
            Divider()
            Button("Add Subtitle File…") { model.addSubtitleFile() }.disabled(model.phase != .playing)
            Button("Save Playlist…") { model.savePlaylist() }.keyboardShortcut("s").disabled(playlist.items.isEmpty)
            Divider()
            Button("Media Information") { openWindow(id: "info") }.keyboardShortcut("i")
        }

        CommandMenu("Playback") {
            Button("Play/Pause") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Stop") { model.stopPlayback() }.keyboardShortcut(".")
            Button("Previous") { model.previous() }.keyboardShortcut(.leftArrow)
            Button("Next") { model.next() }.keyboardShortcut(.rightArrow)
            Divider()
            Button("Jump Back 10 Seconds") { model.jump(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Button("Jump Forward 10 Seconds") { model.jump(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Button("Jump Back 1 Minute") { model.jump(by: -60) }.keyboardShortcut(.leftArrow, modifiers: [.shift, .command])
            Button("Jump Forward 1 Minute") { model.jump(by: 60) }.keyboardShortcut(.rightArrow, modifiers: [.shift, .command])
            Button("Jump to Time…") { model.showGoTo = true }.keyboardShortcut("j")
            Button("Next Frame") { model.nextFrame() }.keyboardShortcut("e", modifiers: [])
            Button("Previous Chapter") { model.previousChapter() }.keyboardShortcut("p", modifiers: .shift)
                .disabled(model.chapters.isEmpty)
            Button("Next Chapter") { model.nextChapter() }.keyboardShortcut("n", modifiers: .shift)
                .disabled(model.chapters.isEmpty)
            if let chapters = model.info?.chapters, !chapters.isEmpty {
                Menu("Chapters") {
                    ForEach(chapters, id: \.self) { c in
                        Button { model.goTo(chapter: c) } label: { Text(verbatim: "\(PlayerModel.time(c.start))  \(c.title)") }
                    }
                }
            }
            Divider()
            Button("Faster") { model.changeRate(faster: true) }.keyboardShortcut("]", modifiers: [])
            Button("Slower") { model.changeRate(faster: false) }.keyboardShortcut("[", modifiers: [])
            Button("Normal Speed") { model.rate = 1 }.keyboardShortcut("=", modifiers: [])
            Divider()
            Button { model.toggleLoop() } label: {
                if model.loopA == nil { Text("Set Loop Start (A)") } else if model.loopB == nil { Text("Set Loop End (B)") } else { Text("Loop Off") }
            }
            .keyboardShortcut("l", modifiers: [.option, .command])
            Picker("Repeat", selection: $playlist.repeatMode) {
                Text("Off").tag(Playlist.RepeatMode.off)
                Text("All").tag(Playlist.RepeatMode.all)
                Text("One").tag(Playlist.RepeatMode.one)
            }
            Toggle("Shuffle", isOn: $playlist.shuffle)
            Divider()
            Toggle("Original quality (HEVC, HDR, surround – for Apple TV 4K)", isOn: $model.originalQuality)
        }

        CommandMenu("Audio") {
            Button("Volume Up") { model.changeVolume(by: 0.1) }.keyboardShortcut(.upArrow)
            Button("Volume Down") { model.changeVolume(by: -0.1) }.keyboardShortcut(.downArrow)
            Toggle("Mute", isOn: $model.isMuted).keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Divider()
            Picker("Audio Track", selection: Binding(get: { model.selectedAudio ?? -1 }, set: { model.selectAudio($0) })) {
                ForEach(Array(model.audioTracks.enumerated()), id: \.offset) { i, name in Text(verbatim: name).tag(i) }
            }
            .disabled(model.audioTracks.isEmpty)
        }

        CommandMenu("Video") {
            Button("Full Screen") { model.toggleFullScreen() }.keyboardShortcut("f")
            Button("Picture in Picture") { model.togglePictureInPicture() }.keyboardShortcut("p", modifiers: [.option, .command])
                .disabled(!model.canPictureInPicture)
            Toggle("Float on Top", isOn: $model.floatOnTop).keyboardShortcut("t", modifiers: [.option, .command])
            Picker("Aspect", selection: $model.videoGravity) {
                Text("Fit").tag(AVLayerVideoGravity.resizeAspect)
                Text("Fill (Crop)").tag(AVLayerVideoGravity.resizeAspectFill)
                Text("Stretch").tag(AVLayerVideoGravity.resize)
            }
            Picker("Hide Controls", selection: $hideControlsAfter) {
                ForEach([2.0, 3, 5, 10], id: \.self) { seconds in
                    Text("After \(String(Int(seconds))) seconds").tag(seconds)
                }
                Text("Never").tag(0.0)
            }
            Divider()
            Button("Snapshot") { model.takeSnapshot() }.keyboardShortcut("s", modifiers: [.option, .command])
                .disabled(model.phase != .playing)
            Button("Show Snapshots Folder") { NSWorkspace.shared.open(Snapshot.folder) }
        }

        CommandMenu("Subtitles") {
            Picker("Subtitle Track", selection: Binding(get: { model.selectedSubtitle ?? -1 },
                                                        set: { model.selectSubtitle($0 < 0 ? nil : $0) })) {
                Text("Off").tag(-1)
                ForEach(Array(model.subtitleTracks.enumerated()), id: \.offset) { i, name in Text(verbatim: name).tag(i) }
            }
            Button("Next Subtitle Track") { model.cycleSubtitle() }.keyboardShortcut("v", modifiers: [])
            Divider()
            Button("Add Subtitle File…") { model.addSubtitleFile() }.disabled(model.phase != .playing)
            Button("Subtitles Earlier (G)") { model.changeSubtitleDelay(by: -0.05) }.keyboardShortcut("g", modifiers: [])
            Button("Subtitles Later (H)") { model.changeSubtitleDelay(by: 0.05) }.keyboardShortcut("h", modifiers: [])
            Button("Reset Subtitle Delay") { model.setSubtitleDelay(0) }.disabled(model.subtitleDelay == 0)
        }

        CommandGroup(replacing: .help) {
            Button("Open-Source Licenses") {
                if let url = Bundle.main.url(forResource: "Licenses", withExtension: nil) { NSWorkspace.shared.open(url) }
            }
        }

        CommandGroup(before: .windowList) {
            Toggle("Playlist", isOn: $model.showPlaylist).keyboardShortcut("l")
            Button("Media Information") { openWindow(id: "info") }
            Divider()
        }

        CommandGroup(after: .appSettings) {
            Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; Appearance.apply($0) })) {
                Text("System default").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Language", selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.switchTo($0) })) {
                Text("System default").tag(AppLanguage.system)
                Divider()
                ForEach(AppLanguage.available, id: \.code) { language in
                    Text(verbatim: language.name).tag(language.code)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        Appearance.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system")
    }

    /// The app used to be called "AirPlay Player" (bundle id local.airplayplayer): take over its playlist, recent
    /// files, resume positions and settings once.
    static func migrateSettingsFromAirPlayPlayer() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromAirPlayPlayer"),
              let old = defaults.persistentDomain(forName: "local.airplayplayer"),
              let id = Bundle.main.bundleIdentifier, id != "local.airplayplayer" else { return }
        var current = defaults.persistentDomain(forName: id) ?? [:]
        for (key, value) in old where current[key] == nil && !key.hasPrefix("NS") { current[key] = value }
        current["migratedFromAirPlayPlayer"] = true
        defaults.setPersistentDomain(current, forName: id)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StreamSession.cleanupLeftovers()
        if let dir = ProcessInfo.processInfo.environment["AIRPLAY_UI_SNAPSHOT"] {
            UISnapshot.run(into: URL(fileURLWithPath: dir))
        } else {
            // Needed when started as a bare executable (swift run) instead of the .app bundle.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !files.isEmpty { PlayerModel.shared.open(files.map { URL(fileURLWithPath: $0) }) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PlayerModel.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerModel.shared.shutdown()
    }
}

/// Per-app interface language. Stored in the app's AppleLanguages default, which macOS reads at launch,
/// so changing it relaunches the app. The choices are the .lproj folders bundled with the app.
enum AppLanguage {
    static let system = ""

    /// Bundled languages, each named in its own language ("Deutsch", "日本語"), sorted by that name.
    static let available: [(code: String, name: String)] = Bundle.main.localizations
        .filter { $0 != "Base" }
        .map { code in
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code) ?? code
            return (code, name.prefix(1).uppercased(with: locale) + name.dropFirst())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static var current: String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let first = (domain?["AppleLanguages"] as? [String])?.first,
              available.contains(where: { $0.code == first }) else { return system }
        return first
    }

    @MainActor
    static func switchTo(_ code: String) {
        guard code != current else { return }
        if code == system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }

        let alert = NSAlert()
        alert.messageText = loc("The new language takes effect after a restart.")
        alert.informativeText = loc("Restart Purrcast now? Playback stops.")
        alert.addButton(withTitle: loc("Restart"))
        alert.addButton(withTitle: loc("Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Development aid: AIRPLAY_UI_SNAPSHOT=<dir> renders the window in a few states to PNGs, then quits.
/// (Window contents are drawn by the app itself, so no screen recording permission is involved.)
@MainActor
enum UISnapshot {
    static func run(into dir: URL) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = PlayerModel.shared
        Task { @MainActor in
            await shot("1-idle", after: 2)
            if model.phase != .idle {
                await shot("2-playing", after: 8)
                // The menu bar observes the model: while playing it must not change several times a second.
                var changes = 0
                let counter = model.objectWillChange.sink { changes += 1 }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                counter.cancel()
                Log.write("ui-snapshot: model changes during 5 s of playback: \(changes)")
                model.showPlaylist = true
                model.flash("Hangerő: 80%")
                await shot("3-playlist", after: 1.5)
                model.showPlaylist = false
                await shot("4-idle-mouse", after: 6)   // no mouse activity: the controls should be hidden
                Log.write("ui-snapshot: PiP possible: \(model.canPictureInPicture)")
                model.togglePictureInPicture()
                await shot("5-pip", after: 3)
                Log.write("ui-snapshot: PiP active: \(model.isPictureInPicture)")
                model.togglePictureInPicture()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Log.write("ui-snapshot: PiP active after stop: \(model.isPictureInPicture)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func shot(_ name: String, after seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let dir = ProcessInfo.processInfo.environment["AIRPLAY_UI_SNAPSHOT"].map({ URL(fileURLWithPath: $0) }),
              let view = PlayerModel.shared.mainWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// Light / dark / follow the system, for the whole app.
enum Appearance {
    @MainActor
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
