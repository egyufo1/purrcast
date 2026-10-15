import PurrcastCore
import AVKit
import Combine
import CoreText
import SwiftUI

/// The look of webapp.wtf: paper background with a dot grid, ink outlines with hard offset shadows,
/// acid / lavender / coral stickers, Geist and Geist Mono.
/// In dark mode paper and ink swap (near-black paper, paper-coloured ink); the accent colours stay, and text on them
/// uses `onAccent`, which is always dark.
enum Theme {
    static let paper = Color(light: 0xF5F0E7, dark: 0x1A1816)
    static let cream = Color(light: 0xFFFAF0, dark: 0x25221F)
    static let ink = Color(light: 0x25221F, dark: 0xF5F0E7)
    static let muted = Color(light: 0x67605A, dark: 0xA39B92)
    static let onAccent = Color(hex: 0x25221F)
    static let acid = Color(hex: 0xDFEF68)
    static let lavender = Color(hex: 0xBFABEF)
    static let lavenderLight = Color(light: 0xEBE4F5, dark: 0x3B3452)
    static let coral = Color(hex: 0xFF8059)
    static let amber = Color(hex: 0xE9AD56)
    static let violet = Color(hex: 0x6F55C9)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist", size: size).weight(weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist Mono", size: size).weight(weight) }

    /// Resources live in the app bundle; during development (swift run) straight in the repository.
    static func resource(_ path: String) -> URL? {
        let name = (path as NSString).lastPathComponent
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension) {
            return url
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("Resources").appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func registerFonts() {
        for file in ["Fonts/Geist-Variable.ttf", "Fonts/GeistMono-Variable.ttf"] {
            if let url = resource(file) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }

    static let mascot: NSImage? = resource("Icon/purr.svg").flatMap(NSImage.init(contentsOf:))
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: .dynamic(light: light, dark: dark))
    }

    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Ink outline + hard offset shadow, the signature of the site.
struct Brutal: ViewModifier {
    var fill: Color
    var shadow: Color = Theme.ink
    var offset: CGFloat = 4
    var border: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .background(fill, ignoresSafeAreaEdges: [])   // colour backgrounds would otherwise run up into the title bar
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: border))
            .background(Rectangle().fill(shadow).offset(x: offset, y: offset))
    }
}

extension View {
    func brutal(_ fill: Color, shadow: Color = Theme.ink, offset: CGFloat = 4, border: CGFloat = 2) -> some View {
        modifier(Brutal(fill: fill, shadow: shadow, offset: offset, border: border))
    }

    /// Small uppercase mono sticker, slightly tilted.
    func sticker(_ fill: Color = Theme.acid, angle: Double = -2) -> some View {
        self.font(Theme.mono(11, .medium)).textCase(.uppercase).tracking(0.7).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .brutal(fill, offset: 2, border: 1.2)
            .rotationEffect(.degrees(angle))
    }
}

/// Paper with a faint dot grid.
struct PaperBackground: View {
    var body: some View {
        Theme.paper.overlay(
            Canvas { context, size in
                let step: CGFloat = 22
                var path = Path()
                for x in stride(from: step / 2, to: size.width, by: step) {
                    for y in stride(from: step / 2, to: size.height, by: step) {
                        path.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    }
                }
                context.fill(path, with: .color(Theme.ink.opacity(0.09)))
            }
        )
    }
}

// MARK: - Activity (auto-hiding controls)

/// Mouse / keyboard activity in the app's windows. A local event monitor sees mouse moves even over the AppKit
/// views (video, drag area), which swallow them before SwiftUI's hover tracking would.
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var lastActivity = Date()
    /// Lives as long as the monitor (a @StateObject): a timer created in the view's body would be recreated, and
    /// never fire, on every re-render (the time display re-renders the window several times a second).
    let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged,
                                                              .scrollWheel, .keyDown]) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
    }
}

// MARK: - Window content

struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playlist: Playlist
    @StateObject private var activity = ActivityMonitor()
    @AppStorage("hideControlsAfter") private var hideAfter = 3.0
    @State private var dropTargeted = false
    @State private var controlsVisible = true
    @State private var overControls = false

    var body: some View {
        HStack(spacing: 0) {
            stage
            if model.showPlaylist {
                PlaylistView(model: model, playlist: playlist)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showPlaylist)
        .background(Theme.paper)
        .ignoresSafeArea()
        .sheet(isPresented: $model.showOpenURL) { OpenURLSheet(model: model) }
        .sheet(isPresented: $model.showGoTo) { GoToSheet(model: model) }
        .navigationTitle(model.title.isEmpty ? "Purrcast" : model.title)
        .onAppear { model.mainWindow?.acceptsMouseMovedEvents = true }
    }

    private var stage: some View {
        ZStack {
            PaperBackground()
            WindowDragArea { model.toggleFullScreen() }
            switch model.phase {
            case .idle:
                IdleView(model: model, playlist: playlist)
            case .preparing:
                PreparingView(model: model)
            case .failed(let message):
                FailedView(model: model, playlist: playlist, message: message)
            case .playing:
                Color.black
                PlayerView(model: model, gravity: model.videoGravity)
                if model.isAirPlaying {
                    AirPlayPlaceholder(model: model)
                } else if model.isPictureInPicture {
                    PictureInPicturePlaceholder(model: model)
                }
                // Dragging the picture moves the window, double click = full screen.
                WindowDragArea { model.toggleFullScreen() }
                chrome
            }
            OSD(text: model.notice)
            if dropTargeted {
                Rectangle().stroke(Theme.ink, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(12)
                    .background(Theme.acid.opacity(0.18)).allowsHitTesting(false)
            }
        }
        .onReceive(activity.ticker) { _ in updateControls() }
        .onReceive(activity.$lastActivity) { _ in showControls() }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.jump(by: -10); return .handled }
        .onKeyPress(.rightArrow) { model.jump(by: 10); return .handled }
        .onKeyPress(.upArrow) { model.changeVolume(by: 0.05); return .handled }
        .onKeyPress(.downArrow) { model.changeVolume(by: -0.05); return .handled }
        .onKeyPress(.escape) {
            if model.mainWindow?.styleMask.contains(.fullScreen) == true { model.toggleFullScreen(); return .handled }
            return .ignored
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Spacer(minLength: 0)
            ControlBar(model: model)
                .onHover { overControls = $0 }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
    }

    /// Controls fade out `hideAfter` seconds after the last mouse / key activity while playing (0 = never).
    private func updateControls() {
        // Mouse-moved events only arrive for windows that ask for them.
        if let window = model.mainWindow, !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
        let idle = Date().timeIntervalSince(activity.lastActivity)
        let hide = hideAfter > 0 && model.phase == .playing && model.isPlaying && !overControls && idle > hideAfter
        if hide && controlsVisible {
            withAnimation(.easeInOut(duration: 0.35)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        } else if !hide && !controlsVisible {
            showControls()
        }
    }

    private func showControls() {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
    }
}

// MARK: - Start screen

struct IdleView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playlist: Playlist

    var body: some View {
        // The cat card only when there is room for it next to the text (e.g. not with the playlist open).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 56) {
                intro.frame(width: 540, alignment: .leading)
                CatCard(width: 300)
            }
            intro.frame(maxWidth: 540, alignment: .leading)
        }
        .padding(48)
    }

    private var intro: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text(verbatim: "MKV · MP4 · AVI · HEVC · HDR → TV").sticker()
                VStack(alignment: .leading, spacing: -6) {
                    Text(verbatim: "Purr")
                    Text(verbatim: "cast")
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .background(Theme.lavender)
                }
                .font(Theme.sans(78, .heavy)).tracking(-5).foregroundStyle(Theme.ink)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Drop a video here (MKV, MP4, AVI…)").font(Theme.sans(17, .medium)).foregroundStyle(Theme.ink)
                    Text("or open one with ⌘O, then pick your TV with the AirPlay button")
                        .font(Theme.sans(14)).foregroundStyle(Theme.muted)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { buttons }
                    VStack(alignment: .leading, spacing: 14) { buttons }
                }

                if !model.recentURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent").font(Theme.mono(11)).textCase(.uppercase).tracking(0.7).foregroundStyle(Theme.muted)
                            .padding(.bottom, 6)
                        ForEach(Array(model.recentURLs.prefix(4).enumerated()), id: \.offset) { i, url in
                            Button { model.open([url]) } label: {
                                HStack(spacing: 10) {
                                    Text(verbatim: String(format: "%02d", i + 1)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    Text(verbatim: url.isFileURL ? url.lastPathComponent : url.absoluteString)
                                        .font(Theme.sans(13)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                                }
                                .padding(.vertical, 6)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink.opacity(0.18)).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoverRowStyle())
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
    }

    @ViewBuilder private var buttons: some View {
        Button { model.showOpenPanel() } label: { Label("Open…", systemImage: "arrow.up.right") }
            .buttonStyle(BrutalButtonStyle(kind: .dark))
        Button { model.showOpenURL = true } label: { Label("Open Network Stream…", systemImage: "network") }
            .buttonStyle(BrutalButtonStyle(kind: .paper))
        if !playlist.items.isEmpty {
            Button { model.togglePlay() } label: { Label("Play Playlist", systemImage: "play.fill") }
                .buttonStyle(BrutalButtonStyle(kind: .acid))
        }
    }
}

/// The lavender card with the mascot peeking up from its bottom edge, like the hero of webapp.wtf.
struct CatCard: View {
    var width: CGFloat
    var caption = "CHIEF PURR OFFICER"

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let cat = Theme.mascot {
                    Image(nsImage: cat).resizable().scaledToFit().frame(width: width * 0.74).offset(y: width * 0.09)
                }
            }
            .frame(width: width - 36, height: width * 0.92)
            .clipped()
            Rectangle().fill(Theme.onAccent).frame(height: 1.5).padding(.horizontal, 16)
            HStack {
                Text(verbatim: caption).font(Theme.mono(9)).tracking(0.6).foregroundStyle(Theme.onAccent).lineLimit(1)
                Spacer()
                Text(verbatim: "AirPlay ↗").sticker(Theme.acid, angle: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: width)
        .brutal(Theme.lavender, offset: 8)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 1) {
                Text(verbatim: "100% AIRPLAY").font(Theme.sans(16, .heavy)).tracking(-0.5)
                Text(verbatim: "0% MIRRORING").font(Theme.mono(8))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .brutal(Theme.coral, offset: 3)
            .rotationEffect(.degrees(8))
            .offset(x: 26, y: -18)
        }
        .rotationEffect(.degrees(2))
    }
}

struct PreparingView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preparing…").sticker(Theme.acid)
            Text(verbatim: model.title).font(Theme.sans(34, .heavy)).tracking(-1.5).foregroundStyle(Theme.ink).lineLimit(2)
            BrutalProgress()
            if let notice = model.notice {
                Text(verbatim: notice).font(Theme.sans(14, .medium)).foregroundStyle(Theme.onAccent)
                    .padding(10).brutal(Theme.coral, offset: 3)
            }
            SummaryList(lines: model.summary)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(30)
        .brutal(Theme.cream, offset: 7)
        .padding(40)
    }
}

/// Indeterminate progress: a lavender block sliding inside an ink frame.
struct BrutalProgress: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(Theme.lavender)
                .frame(width: geo.size.width * 0.3)
                .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1.5))
                .offset(x: phase ? geo.size.width * 0.7 : 0)
        }
        .frame(height: 12)
        .background(Theme.paper)
        .overlay(Rectangle().stroke(Theme.ink, lineWidth: 2))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true } }
    }
}

struct FailedView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playlist: Playlist
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Error").sticker(Theme.coral)
            Text(verbatim: message).font(Theme.sans(14)).foregroundStyle(Theme.ink).textSelection(.enabled)
            HStack(spacing: 14) {
                Button { model.showOpenPanel() } label: { Text("Open another file…") }.buttonStyle(BrutalButtonStyle(kind: .dark))
                if playlist.items.count > 1 {
                    Button { model.next() } label: { Text("Next in Playlist") }.buttonStyle(BrutalButtonStyle(kind: .paper))
                }
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(28)
        .brutal(Theme.cream, offset: 7)
        .padding(40)
    }
}

struct AirPlayPlaceholder: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 26) {
                CatCard(width: 230, caption: model.title.uppercased())
                Label("Playing via AirPlay", systemImage: "airplayvideo").sticker(Theme.acid, angle: -1.5)
            }
        }
    }
}

struct PictureInPicturePlaceholder: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 26) {
                CatCard(width: 230, caption: model.title.uppercased())
                Label("Playing in Picture in Picture", systemImage: "pip").sticker(Theme.lavenderLight, angle: -1.5)
                Button { model.togglePictureInPicture() } label: { Label("Picture in Picture", systemImage: "pip.exit") }
                    .buttonStyle(BrutalButtonStyle(kind: .dark))
            }
        }
    }
}

struct SummaryList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines, id: \.self) {
                Text(verbatim: $0).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// VLC style on-screen message, as an acid sticker.
struct OSD: View {
    let text: String?

    var body: some View {
        VStack {
            if let text {
                Text(verbatim: text)
                    .font(Theme.mono(14, .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .brutal(Theme.acid, offset: 3)
                    .rotationEffect(.degrees(-1.5))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 58)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: text)
        .allowsHitTesting(false)
    }
}

// MARK: - Player chrome

struct TopBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var clock: PlaybackClock

    init(model: PlayerModel) {
        self.model = model
        self.clock = model.clock
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.title).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if !model.status.isEmpty {
                    Text(verbatim: model.status).font(Theme.mono(10)).textCase(.uppercase).tracking(0.5)
                        .foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .brutal(Theme.paper, offset: 3)
            .frame(maxWidth: 520, alignment: .leading)
            Spacer()
            if model.resumedFrom != nil {
                Button { model.startOver() } label: { Label("Start Over", systemImage: "backward.end.fill") }
                    .buttonStyle(BrutalButtonStyle(kind: .acid, small: true))
            }
        }
        .padding(.leading, 84).padding(.trailing, 22).padding(.top, 16)
    }
}

struct ControlBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var clock: PlaybackClock

    init(model: PlayerModel) {
        self.model = model
        self.clock = model.clock
    }
    /// Click on the total length switches it to the remaining time (countdown) and back.
    @AppStorage("showRemainingTime") private var showRemaining = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(verbatim: PlayerModel.time(model.currentTime)).font(Theme.mono(11)).monospacedDigit()
                SeekBar(model: model)
                Button { showRemaining.toggle() } label: {
                    Text(verbatim: showRemaining ? "−" + PlayerModel.time(max(model.duration - model.currentTime, 0))
                                                 : PlayerModel.time(model.duration))
                        .font(Theme.mono(11)).monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(showRemaining ? Text("Show total length") : Text("Show remaining time"))
            }
            .foregroundStyle(Theme.ink)

            HStack(spacing: 4) {
                ChromeButton("backward.end.fill", help: "Previous") { model.previous() }
                ChromeButton("gobackward.10", help: "Jump back 10 seconds") { model.jump(by: -10) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.acid))
                        .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                        .background(Circle().fill(Theme.ink).offset(x: 3, y: 3))
                }
                .buttonStyle(PressStyle())
                .padding(.horizontal, 6)
                .help(Text("Play/Pause (Space)"))
                ChromeButton("goforward.10", help: "Jump forward 10 seconds") { model.jump(by: 10) }
                ChromeButton("forward.end.fill", help: "Next") { model.next() }
                if !model.chapters.isEmpty { ChapterControls(model: model) }

                Spacer(minLength: 12)

                Menu {
                    ForEach(PlayerModel.rates, id: \.self) { r in
                        Toggle(isOn: Binding(get: { model.rate == r }, set: { _ in model.rate = r })) {
                            Text(verbatim: PlayerModel.rateLabel(r))
                        }
                    }
                } label: {
                    Text(verbatim: PlayerModel.rateLabel(model.rate)).font(Theme.mono(12, .semibold)).monospacedDigit()
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text("Playback speed"))

                TrackMenus(model: model)

                ChromeButton(model.isMuted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", help: "Mute") {
                    model.isMuted.toggle()
                }
                VolumeBar(volume: $model.volume).frame(width: 84)

                ChromeButton("list.bullet", help: "Playlist (⌘L)", active: model.showPlaylist) { model.showPlaylist.toggle() }
                if model.canPictureInPicture {
                    ChromeButton(model.isPictureInPicture ? "pip.exit" : "pip.enter", help: "Picture in Picture",
                                 active: model.isPictureInPicture) { model.togglePictureInPicture() }
                }
                RoutePicker(player: model.player)
                    .frame(width: 30, height: 28)
                    .help(Text("AirPlay – choose your TV"))
                ChromeButton("arrow.up.left.and.arrow.down.right", help: "Full Screen (⌘F)") { model.toggleFullScreen() }
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .brutal(Theme.paper, offset: 5)
        .overlayPreferenceValue(SeekTooltip.Key.self, SeekTooltip.overlay)
        .frame(maxWidth: 1000)
        .tint(Theme.ink)
    }
}

/// Previous / next chapter and the chapter list; only shown when the file has chapters.
struct ChapterControls: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var clock: PlaybackClock

    init(model: PlayerModel) {
        self.model = model
        self.clock = model.clock
    }

    var body: some View {
        HStack(spacing: 2) {
            Rectangle().fill(Theme.ink).frame(width: 1.5, height: 24).padding(.horizontal, 8)
            ChromeButton("chevron.left.2", help: "Previous Chapter (⇧P)") { model.previousChapter() }
            Menu {
                ForEach(Array(model.chapters.enumerated()), id: \.offset) { i, chapter in
                    Toggle(isOn: Binding(get: { model.currentChapter == i }, set: { _ in model.goTo(chapter: chapter) })) {
                        Text(verbatim: "\(PlayerModel.time(chapter.start))   \(chapter.title)")
                    }
                }
            } label: {
                Text(verbatim: model.currentChapter.map { String(format: "%02d/%02d", $0 + 1, model.chapters.count) } ?? "–")
                    .font(Theme.mono(11, .semibold)).monospacedDigit()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(Text("Chapters"))
            ChromeButton("chevron.right.2", help: "Next Chapter (⇧N)") { model.nextChapter() }
        }
    }
}

struct TrackMenus: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Menu {
            if model.audioTracks.isEmpty { Text("No audio tracks") }
            ForEach(Array(model.audioTracks.enumerated()), id: \.offset) { i, name in
                Toggle(isOn: Binding(get: { model.selectedAudio == i }, set: { _ in model.selectAudio(i) })) { Text(verbatim: name) }
            }
        } label: {
            Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 5)
        .help(Text("Audio track"))

        Menu {
            Toggle(isOn: Binding(get: { model.selectedSubtitle == nil }, set: { _ in model.selectSubtitle(nil) })) { Text("Off") }
            ForEach(Array(model.subtitleTracks.enumerated()), id: \.offset) { i, name in
                Toggle(isOn: Binding(get: { model.selectedSubtitle == i }, set: { _ in model.selectSubtitle(i) })) { Text(verbatim: name) }
            }
            Divider()
            Button("Add Subtitle File…") { model.addSubtitleFile() }
            Button("Subtitles Earlier (G)") { model.changeSubtitleDelay(by: -0.05) }
            Button("Subtitles Later (H)") { model.changeSubtitleDelay(by: 0.05) }
            if model.subtitleDelay != 0 { Button("Reset Subtitle Delay") { model.setSubtitleDelay(0) } }
        } label: {
            Image(systemName: "captions.bubble").font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 5)
        .help(Text("Subtitles"))
    }
}

struct ChromeButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var active = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemName: String, help: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active || hovering ? Theme.onAccent : Theme.ink)
                .frame(width: 32, height: 30)
                .background(active ? Theme.lavender : hovering ? Theme.acid : .clear)
                .overlay(Rectangle().stroke(Theme.ink, lineWidth: active || hovering ? 1.5 : 0))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(Text(help))
    }
}

/// The timeline: lavender = played, light lavender = seekable so far (remux), ink ticks = chapters,
/// acid = A–B loop, and a time / chapter label under the mouse.
struct SeekBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var clock: PlaybackClock

    init(model: PlayerModel) {
        self.model = model
        self.clock = model.clock
    }
    @State private var dragTime: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = max(model.duration, 0.001)
            let shown = dragTime ?? model.currentTime
            let x = { (t: Double) in CGFloat(min(max(t / duration, 0), 1)) * width }

            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.cream).frame(height: 10)
                Rectangle().fill(Theme.lavenderLight).frame(width: x(model.seekableEnd), height: 10)
                if let a = model.loopA {
                    Rectangle().fill(Theme.acid)
                        .frame(width: max(x(model.loopB ?? model.currentTime) - x(a), 2), height: 10)
                        .offset(x: x(a))
                }
                Rectangle().fill(Theme.lavender).frame(width: x(shown), height: 10)
                Rectangle().stroke(Theme.ink, lineWidth: 1.5).frame(height: 10)
                ForEach(model.chapters, id: \.self) { chapter in
                    Rectangle().fill(Theme.ink).frame(width: 1.5, height: 10).offset(x: x(chapter.start) - 0.75)
                }
                Rectangle().fill(Theme.acid).frame(width: 12, height: 18)
                    .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1.5))
                    .background(Rectangle().fill(Theme.ink).offset(x: 2, y: 2))
                    .offset(x: x(shown) - 6)
            }
            .frame(height: 22)
            // The hover time is drawn by the control bar (SeekTooltip.overlay), above its border: drawn here, the
            // bar's outline would run through the text.
            .anchorPreference(key: SeekTooltip.Key.self, value: .point(CGPoint(x: hoverX ?? 0, y: 0))) { anchor in
                hoverX.map { SeekTooltip(text: tooltip(at: Double($0 / width) * duration), anchor: anchor) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragTime = Double(min(max($0.location.x / width, 0), 1)) * duration }
                .onEnded { _ in
                    if let dragTime { model.seek(to: dragTime) }
                    dragTime = nil
                })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = min(max(p.x, 0), width) } else { hoverX = nil }
            }
        }
        .frame(height: 22)
    }

    private func tooltip(at t: Double) -> String {
        let chapter = model.chapters.last { $0.start <= t }
        return [PlayerModel.time(t), chapter?.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The time under the mouse on the seek bar, shown above the control bar's outline.
struct SeekTooltip {
    let text: String
    let anchor: Anchor<CGPoint>

    struct Key: PreferenceKey {
        static var defaultValue: SeekTooltip? { nil }
        static func reduce(value: inout SeekTooltip?, nextValue: () -> SeekTooltip?) { value = value ?? nextValue() }
    }

    static func overlay(_ tooltip: SeekTooltip?) -> some View {
        GeometryReader { geo in
            if let tooltip {
                let point = geo[tooltip.anchor]
                Text(verbatim: tooltip.text)
                    .font(Theme.mono(10, .semibold)).monospacedDigit().foregroundStyle(Theme.paper)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.ink)
                    .fixedSize()
                    .position(x: min(max(point.x, 36), geo.size.width - 36), y: point.y - 13)
            }
        }
        .allowsHitTesting(false)
    }
}

struct VolumeBar: View {
    @Binding var volume: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.cream)
                Rectangle().fill(Theme.ink).frame(width: geo.size.width * CGFloat(volume))
                Rectangle().stroke(Theme.ink, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                volume = Float(min(max($0.location.x / geo.size.width, 0), 1))
            })
        }
        .frame(height: 8)
    }
}

// MARK: - Button styles

struct BrutalButtonStyle: ButtonStyle {
    enum Kind { case dark, paper, acid }
    var kind: Kind
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let fill: Color = kind == .dark ? Theme.ink : kind == .acid ? Theme.acid : Theme.paper
        let shadow: Color = kind == .dark ? Theme.lavender : Theme.ink
        let offset: CGFloat = pressed ? 1 : (small ? 3 : 4)
        return configuration.label
            .lineLimit(1).fixedSize()
            .font(Theme.sans(small ? 12 : 14, .medium))
            .labelStyle(TrailingIconLabelStyle())
            .foregroundStyle(kind == .dark ? Theme.paper : kind == .acid ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, small ? 12 : 17).padding(.vertical, small ? 7 : 11)
            .brutal(fill, shadow: shadow, offset: offset)
            .offset(x: pressed ? 3 : 0, y: pressed ? 3 : 0)
            .rotationEffect(.degrees(kind == .dark ? -2 : 0))
    }
}

/// Text first, icon after it, like the site's "Beszéljünk ↗" button.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .bold))
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.offset(x: configuration.isPressed ? 1.5 : 0, y: configuration.isPressed ? 1.5 : 0)
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Theme.onAccent : Theme.ink)
                .padding(.horizontal, 6)
                .background(hovering ? Theme.acid : .clear)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - AppKit wrappers

/// The video, drawn by our own AVPlayerLayer: AVPlayerView has no public way to start Picture in Picture,
/// AVPictureInPictureController on a player layer does.
struct PlayerView: NSViewRepresentable {
    let model: PlayerModel
    let gravity: AVLayerVideoGravity

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = gravity
        model.attachPictureInPicture(to: view.playerLayer)
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== model.player { view.playerLayer.player = model.player }
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
}

/// Transparent area that moves the window when dragged (the title bar is hidden) and handles double clicks.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
            } else {
                window?.performDrag(with: event)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }
}

/// The system AirPlay menu; bound to our player so the video (not just the sound) goes to the TV.
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.dynamic(light: 0x25221F, dark: 0xF5F0E7), for: .normal)
        view.setRoutePickerButtonColor(NSColor(Theme.violet), for: .active)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
