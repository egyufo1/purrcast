import PurrcastCore
import Foundation

struct PlaylistItem: Identifiable, Codable, Hashable {
    var id = UUID()
    let url: URL
    /// Length in seconds, filled in the background by ffprobe; nil until known (or for live streams).
    var duration: Double?

    var title: String { StreamPlan.displayTitle(url) }
}

@MainActor
final class Playlist: ObservableObject {
    enum RepeatMode: String, Codable, CaseIterable {
        case off, all, one
    }

    @Published private(set) var items: [PlaylistItem] = []
    @Published private(set) var currentID: UUID?
    @Published var repeatMode: RepeatMode = .off { didSet { save() } }
    @Published var shuffle = false { didSet { shuffledIDs = items.map(\.id).shuffled(); save() } }

    private var shuffledIDs: [UUID] = []

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "asf", "flv", "f4v", "webm", "ts", "m2ts", "mts", "mpg", "mpeg",
        "vob", "ogv", "ogm", "3gp", "3g2", "divx", "xvid", "rm", "rmvb", "dv", "mxf", "y4m",
    ]
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    init() { load() }

    var current: PlaylistItem? { items.first { $0.id == currentID } }

    /// Sum of the known lengths, and whether some are still unknown.
    var totalDuration: (seconds: Double, complete: Bool) {
        (items.reduce(0) { $0 + ($1.duration ?? 0) }, items.allSatisfy { $0.duration != nil })
    }

    private var durationTask: Task<Void, Never>?
    private var failedDurations = Set<UUID>()

    /// Probes the lengths of the items that don't have one yet, one after the other.
    private func fillDurations() {
        guard durationTask == nil else { return }
        durationTask = Task { [weak self] in
            while let self, let item = self.items.first(where: { $0.duration == nil && !self.failedDurations.contains($0.id) }) {
                let seconds = await MediaInfo.quickDuration(item.url)
                if let seconds { self.setDuration(seconds, for: item.id) } else { self.failedDurations.insert(item.id) }
            }
            self?.durationTask = nil
        }
    }

    /// Also used by the player, which knows the exact length of what it plays.
    func setDuration(_ seconds: Double, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].duration != seconds else { return }
        items[i].duration = seconds
        save()
    }

    // MARK: - Editing

    /// Adds files, folders (recursively, video files only) and .m3u playlists; returns the added items.
    @discardableResult
    func add(_ urls: [URL], at index: Int? = nil) -> [PlaylistItem] {
        let new = urls.flatMap(Self.expand).map { PlaylistItem(url: $0) }
        items.insert(contentsOf: new, at: min(index ?? items.count, items.count))
        shuffledIDs += new.map(\.id).shuffled()
        save()
        fillDurations()
        return new
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        shuffledIDs.removeAll { ids.contains($0) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func clear() {
        items = []
        shuffledIDs = []
        currentID = nil
        save()
    }

    func setCurrent(_ item: PlaylistItem?) {
        currentID = item?.id
        save()
    }

    // MARK: - Navigation

    private var order: [UUID] { shuffle ? shuffledIDs.filter { id in items.contains { $0.id == id } } : items.map(\.id) }

    /// The item after the current one. `automatic` = the current one finished playing (repeat one replays it).
    func next(automatic: Bool) -> PlaylistItem? {
        if automatic, repeatMode == .one { return current }
        let order = order
        guard !order.isEmpty else { return nil }
        guard let id = currentID, let i = order.firstIndex(of: id) else { return items.first { $0.id == order[0] } }
        if i + 1 < order.count { return items.first { $0.id == order[i + 1] } }
        guard repeatMode == .all || !automatic else { return nil }
        if shuffle { shuffledIDs = items.map(\.id).shuffled() }
        return items.first { $0.id == self.order.first }
    }

    func previous() -> PlaylistItem? {
        let order = order
        guard let id = currentID, let i = order.firstIndex(of: id) else { return nil }
        if i > 0 { return items.first { $0.id == order[i - 1] } }
        return repeatMode == .all ? items.first { $0.id == order.last } : nil
    }

    // MARK: - Files

    static func expand(_ url: URL) -> [URL] {
        guard url.isFileURL else { return [url] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL }
                .filter { videoExtensions.contains($0.pathExtension.lowercased()) } ?? []
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        if playlistExtensions.contains(url.pathExtension.lowercased()), let entries = readM3U(url) {
            return entries
        }
        return [url]
    }

    /// Entries of a local .m3u playlist; nil for HLS playlists (those are media and get played as such).
    static func readM3U(_ url: URL) -> [URL]? {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
              !text.contains("#EXT-X-") else { return nil }
        let base = url.deletingLastPathComponent()
        return text.split(whereSeparator: \.isNewline).compactMap { raw -> URL? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.contains("://") { return URL(string: line) }
            let path = (line as NSString).expandingTildeInPath
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        }
    }

    func m3u() -> String {
        (["#EXTM3U"] + items.flatMap { ["#EXTINF:-1,\($0.title)", $0.url.isFileURL ? $0.url.path : $0.url.absoluteString] })
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var items: [PlaylistItem]
        var currentID: UUID?
        var repeatMode: RepeatMode
        var shuffle: Bool
    }

    private func save() {
        let stored = Stored(items: items, currentID: currentID, repeatMode: repeatMode, shuffle: shuffle)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: "playlist") }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "playlist"),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        items = stored.items
        currentID = stored.currentID
        repeatMode = stored.repeatMode
        shuffle = stored.shuffle
        shuffledIDs = items.map(\.id).shuffled()
        fillDurations()
    }
}
