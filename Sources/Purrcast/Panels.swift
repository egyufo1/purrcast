import PurrcastCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Playlist sidebar

struct PlaylistView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playlist: Playlist
    @ObservedObject private var clock: PlaybackClock

    init(model: PlayerModel, playlist: Playlist) {
        self.model = model
        self.playlist = playlist
        self.clock = model.clock
    }
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Playlist").font(Theme.sans(22, .heavy)).tracking(-1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(String(playlist.items.count)) items")
                    if playlist.totalDuration.seconds > 0 {
                        let total = playlist.totalDuration
                        Text(verbatim: (total.complete ? "" : "≥ ") + PlayerModel.time(total.seconds))
                            .fontWeight(.semibold).foregroundStyle(Theme.ink)
                    }
                }
                .font(Theme.mono(10)).textCase(.uppercase).foregroundStyle(Theme.muted)
                Spacer()
                Button { model.showPlaylist = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                        .brutal(Theme.paper, offset: 2, border: 1.5)
                }
                .buttonStyle(PressStyle()).help(Text("Close"))
            }
            .padding(.horizontal, 16).padding(.top, 38).padding(.bottom, 12)
            Rectangle().fill(Theme.ink).frame(height: 2)

            List(selection: $selection) {
                ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                    let isCurrent = item.id == playlist.currentID
                    HStack(spacing: 10) {
                        Text(verbatim: String(format: "%02d", index + 1)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        Text(verbatim: item.title)
                            .font(Theme.sans(13, isCurrent ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let duration = item.duration {
                            Text(verbatim: PlayerModel.time(duration)).font(Theme.mono(10)).monospacedDigit()
                                .foregroundStyle(Theme.muted)
                        }
                        if isCurrent {
                            Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onAccent).padding(4)
                                .brutal(Theme.acid, offset: 1.5, border: 1)
                        } else if !item.url.isFileURL {
                            Image(systemName: "network").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 4)
                    .tag(item.id)
                    .help(Text(verbatim: item.url.isFileURL ? item.url.path : item.url.absoluteString))
                    .listRowBackground(isCurrent ? Theme.lavenderLight : Color.clear)
                }
                .onMove { playlist.move(from: $0, to: $1) }
            }
            .scrollContentBackground(.hidden)
            .tint(Theme.lavender)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Play") { play(ids) }
                if ids.count == 1, let item = playlist.items.first(where: { ids.contains($0.id) }), item.url.isFileURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                Divider()
                Button("Remove from Playlist") { playlist.remove(ids) }
            } primaryAction: { ids in
                play(ids)
            }
            .onDeleteCommand { playlist.remove(selection) }
            .dropDestination(for: URL.self) { urls, _ in
                playlist.add(urls)
                return !urls.isEmpty
            }
            .overlay {
                if playlist.items.isEmpty {
                    Text("Drop videos or folders here").sticker(Theme.lavenderLight, angle: -1.5)
                        .allowsHitTesting(false)
                }
            }

            Rectangle().fill(Theme.ink).frame(height: 2)
            HStack(spacing: 8) {
                SquareButton("plus", help: "Add files or folders…") { addFiles() }
                SquareButton("minus", help: "Remove from Playlist") { playlist.remove(selection) }
                    .disabled(selection.isEmpty).opacity(selection.isEmpty ? 0.4 : 1)
                Spacer()
                SquareButton("shuffle", help: "Shuffle", active: playlist.shuffle) { playlist.shuffle.toggle() }
                SquareButton(playlist.repeatMode == .one ? "repeat.1" : "repeat", helpText: repeatHelp,
                             active: playlist.repeatMode != .off) { cycleRepeat() }
                Menu {
                    Button("Save Playlist…") { model.savePlaylist() }
                    Button("Clear Playlist") { playlist.clear() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 26).brutal(Theme.paper, offset: 2, border: 1.5)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .foregroundStyle(Theme.ink)
        .background(PaperBackground())
        .overlay(alignment: .leading) { Rectangle().fill(Theme.ink).frame(width: 2) }
    }

    private var repeatHelp: Text {
        switch playlist.repeatMode {
        case .off: return Text("Repeat: off")
        case .all: return Text("Repeat: all")
        case .one: return Text("Repeat: one")
        }
    }

    private func cycleRepeat() {
        let all = Playlist.RepeatMode.allCases
        playlist.repeatMode = all[(all.firstIndex(of: playlist.repeatMode)! + 1) % all.count]
    }

    private func play(_ ids: Set<UUID>) {
        if let item = playlist.items.first(where: { ids.contains($0.id) }) { model.play(item) }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PlayerModel.videoTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { playlist.add(panel.urls) }
    }
}

/// Small square button with an ink outline and hard shadow (playlist footer).
struct SquareButton: View {
    let systemName: String
    let help: Text
    var active = false
    let action: () -> Void

    init(_ systemName: String, help: LocalizedStringKey, active: Bool = false, action: @escaping () -> Void) {
        self.init(systemName, helpText: Text(help), active: active, action: action)
    }

    init(_ systemName: String, helpText: Text, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = helpText
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? Theme.onAccent : Theme.ink)
                .frame(width: 28, height: 26)
                .brutal(active ? Theme.acid : Theme.paper, offset: 2, border: 1.5)
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

// MARK: - Media information window

struct InfoView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Group {
            if let info = model.info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(verbatim: model.title).font(.title2.weight(.semibold))
                        if !model.summary.isEmpty {
                            GroupBox(label: Text("Streaming")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.summary, id: \.self) { Text(verbatim: $0) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !info.chapters.isEmpty {
                            GroupBox(label: Text("Chapters")) {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                    ForEach(info.chapters, id: \.self) { c in
                                        GridRow {
                                            Text(verbatim: PlayerModel.time(c.start)).monospacedDigit().foregroundStyle(.secondary)
                                            Button(c.title) { model.goTo(chapter: c) }.buttonStyle(.link)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(info.sections) { section in
                            GroupBox(label: Text(verbatim: section.title)) {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                        GridRow {
                                            Text(verbatim: row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                            Text(verbatim: row.1).textSelection(.enabled)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                Text("Nothing is playing.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

// MARK: - Sheets

struct OpenURLSheet: View {
    @ObservedObject var model: PlayerModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Network Stream").font(.headline)
            Text("HTTP, HTTPS, HLS, RTSP, RTMP, UDP… – anything ffmpeg can open.").font(.callout).foregroundStyle(.secondary)
            TextField(text: $text, prompt: Text(verbatim: "https://")) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
                .onSubmit(open)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(URL(string: text)?.scheme == nil)
            }
        }
        .padding(20)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), s.contains("://") { text = s }
        }
    }

    private func open() {
        dismiss()
        model.openURLString(text)
    }
}

struct GoToSheet: View {
    @ObservedObject var model: PlayerModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to Time").font(.headline)
            TextField(text: $text, prompt: Text(verbatim: "1:23:45")) { EmptyView() }
                .textFieldStyle(.roundedBorder).monospacedDigit()
                .frame(width: 220)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Jump", action: go).keyboardShortcut(.defaultAction).disabled(Self.parse(text) == nil)
            }
        }
        .padding(20)
        .onAppear { text = PlayerModel.time(model.currentTime) }
    }

    private func go() {
        guard let t = Self.parse(text) else { return }
        dismiss()
        model.seek(to: t)
    }

    /// "1:23:45", "83:45", "45" → seconds.
    static func parse(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}
