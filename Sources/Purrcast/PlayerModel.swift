import PurrcastCore
import AppKit
import AVFoundation
import AVKit
import MediaPlayer
import UniformTypeIdentifiers

@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    @Published fileprivate(set) var isPlaying = false
    @Published fileprivate(set) var converted: Double = 0
}

@MainActor
final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    enum Phase: Equatable {
        case idle
        case preparing
        case playing
        case failed(String)
    }

    let player = AVPlayer()
    let playlist = Playlist()

    // Playback state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var title = ""
    @Published private(set) var summary: [String] = []
    @Published private(set) var info: MediaInfo?
    /// Position, play state and conversion progress change several times a second; they live in `clock` so that
    /// only the views showing them re-render (the menu bar observes this model, and re-building it 4× a second
    /// made open menus flicker).
    let clock = PlaybackClock()
    var currentTime: Double {
        get { clock.currentTime }
        set { if clock.currentTime != newValue { clock.currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { clock.isPlaying }
        set { if clock.isPlaying != newValue { clock.isPlaying = newValue } }
    }
    var converted: Double {
        get { clock.converted }
        set { if clock.converted != newValue { clock.converted = newValue } }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var isAirPlaying = false
    /// Seeking works anywhere (on-demand stream or finished remux); otherwise only up to `converted`.
    @Published private(set) var isOnDemand = false
    @Published private(set) var conversionDone = false
    @Published private(set) var conversionError: String?
    @Published private(set) var notice: String?
    @Published private(set) var resumedFrom: Double?

    // Tracks
    @Published private(set) var audioTracks: [String] = []
    @Published private(set) var selectedAudio: Int?
    @Published private(set) var subtitleTracks: [String] = []
    @Published private(set) var selectedSubtitle: Int?
    @Published private(set) var subtitleDelay: Double = 0

    // Settings
    @Published var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }
    @Published var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published var videoGravity: AVLayerVideoGravity = .resizeAspect
    @Published private(set) var isPictureInPicture = false
    @Published private(set) var canPictureInPicture = false
    @Published var floatOnTop = false { didSet { mainWindow?.level = floatOnTop ? .floating : .normal } }
    @Published var showPlaylist = UserDefaults.standard.bool(forKey: "showPlaylist") {
        didSet { UserDefaults.standard.set(showPlaylist, forKey: "showPlaylist") }
    }
    @Published var showOpenURL = false
    @Published var showGoTo = false
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?
    @Published private(set) var recentURLs: [URL] = (UserDefaults.standard.stringArray(forKey: "recent") ?? []).compactMap(URL.init(string:))
    /// Keep HEVC / HDR / surround sound. Off by default: the compatible stream plays on every receiver.
    @Published var originalQuality = UserDefaults.standard.bool(forKey: "originalQuality") {
        didSet {
            UserDefaults.standard.set(originalQuality, forKey: "originalQuality")
            if let current = playlist.current, phase != .idle { play(current) }
        }
    }

    private var currentURL: URL?
    private var session: StreamSession?
    private var streamURL: URL?
    private var plan: StreamPlan?
    private var loadTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var reloadCount = 0
    private var observers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var ticks = 0
    private var delayReload: Task<Void, Never>?
    /// Settings tried in order until playback works: each step is more conservative than the previous one.
    private var attempts: [StreamPlan.Options] = []
    private var attempt = 0

    static let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]

    private init() {
        player.allowsExternalPlayback = true
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        setupRemoteCommands()
    }

    static let videoTypes: [UTType] = [.movie, .video, .audiovisualContent, .folder] +
        (Playlist.videoExtensions.union(Playlist.playlistExtensions)).compactMap { UTType(filenameExtension: $0) }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow
    }

    // MARK: - Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// Adds files / folders / playlists / URLs to the playlist and plays the first of them.
    func open(_ urls: [URL]) {
        let added = playlist.add(urls)
        if let first = added.first { play(first) }
    }

    func openURLString(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        open([url])
    }

    func play(_ item: PlaylistItem) {
        saveResumePosition()
        stop()
        playlist.setCurrent(item)
        let url = item.url
        currentURL = url
        title = item.title
        summary = []
        info = nil
        converted = 0
        duration = 0
        currentTime = 0
        conversionDone = false
        conversionError = nil
        notice = nil
        resumedFrom = nil
        loopA = nil
        loopB = nil
        subtitleDelay = 0
        audioTracks = []
        subtitleTracks = []
        attempt = 0
        attempts = (originalQuality ? [StreamPlan.Options(mode: .original)] : []) + [
            StreamPlan.Options(mode: .compatible),
            StreamPlan.Options(mode: .compatible, forceVideoTranscode: true),
            StreamPlan.Options(mode: .compatible, forceVideoTranscode: true, softwareDecode: true),
        ]
        phase = .preparing
        addRecent(url)
        loadTask = Task { [weak self] in await self?.load(url, resume: self?.resumePosition(for: url)) }
    }

    func shutdown() {
        saveResumePosition()
        stop(waitUntilDone: true)
    }

    /// Stop button: back to the start screen, the playlist stays.
    func stopPlayback() {
        saveResumePosition()
        stop()
        phase = .idle
        title = ""
    }

    private func stop(waitUntilDone: Bool = false) {
        stopStream(waitUntilDone: waitUntilDone)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func stopStream(waitUntilDone: Bool = false) {
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        session?.stop(waitUntilDone: waitUntilDone)
        session = nil
        streamURL = nil
        plan = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Something went wrong (ffmpeg, the player or the TV): restart with the next, safer settings.
    private func fallBack(_ reason: String) {
        guard let url = currentURL else { return }
        Log.write("attempt \(attempt) failed: \(reason)")
        guard let info else {
            stop()
            phase = .failed(loc("Couldn't start playback:\n\(reason)\n\nDetails: ~/Library/Logs/Purrcast.log"))
            return
        }
        let position = currentTime
        let previous = plan.map { $0.ffmpegArguments(input: url, dir: StreamSession.root) }
        while attempt + 1 < attempts.count {
            attempt += 1
            // Skip settings that would produce exactly the same stream again.
            if StreamPlan(info: info, input: url, options: attempts[attempt]).ffmpegArguments(input: url, dir: StreamSession.root) != previous {
                stopStream()
                phase = .preparing
                notice = loc("Didn't start with the previous settings, retrying in a safer mode…")
                loadTask = Task { [weak self] in await self?.load(url, resume: position > 5 ? position : nil) }
                return
            }
        }
        stop()
        phase = .failed(loc("Couldn't start playback:\n\(reason)\n\nDetails: ~/Library/Logs/Purrcast.log"))
    }

    private func load(_ url: URL, resume: Double?) async {
        // Remote HLS is already what AVPlayer and AirPlay play natively (and converting it would mean downloading
        // every quality variant at once): hand it over directly.
        if !url.isFileURL, ["m3u8", "m3u"].contains(url.pathExtension.lowercased()), attempt == 0 {
            await playDirectly(url, resume: resume)
            return
        }
        do {
            let info: MediaInfo
            if let known = self.info {
                info = known
            } else {
                info = try await MediaInfo.probe(url)
                self.info = info
            }
            try Task.checkCancellation()
            let plan = StreamPlan(info: info, input: url, options: attempts[attempt])
            self.plan = plan
            summary = plan.summary
            duration = info.duration
            if let id = playlist.currentID, info.duration > 0 { playlist.setDuration(info.duration, for: id) }
            isOnDemand = plan.isOnDemand

            let session = StreamSession(input: url, plan: plan)
            session.onProgress = { [weak self] seconds in
                Task { @MainActor in self?.converted = seconds }
            }
            session.onFinished = { [weak self, weak session] error in
                Task { @MainActor in self?.conversionFinished(session, error) }
            }
            session.onSubtitlesChanged = { [weak self, weak session] in
                Task { @MainActor in self?.reload(for: session) }
            }
            self.session = session
            // The Mac must stay awake while the TV streams from it, even when nothing happens on screen.
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled], reason: "Purrcast stream")
            }

            let start = plan.isOnDemand ? (resume ?? 0) : 0
            let streamURL = try await session.start(at: start)
            try Task.checkCancellation()
            self.streamURL = streamURL
            conversionDone = !session.remuxPending && !plan.isOnDemand
            let item = AVPlayerItem(url: streamURL)
            watch(item)
            player.replaceCurrentItem(with: item)
            if let resume, plan.isOnDemand || !session.remuxPending {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                resumedFrom = resume
                flash(loc("Resumed at \(MediaInfo.formatTime(resume))"))
            }
            phase = .playing
            updateNowPlaying()
            player.play()
            await applySelection(to: item, audio: plan.audio.first(where: { $0.isDefault })?.name,
                                 subtitle: plan.subtitles.first(where: { $0.isDefault })?.name)
            await loadTracks(of: item)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if case PlayerError.ffmpegFailed = error {
                fallBack(error.localizedDescription)
            } else {
                stop()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func playDirectly(_ url: URL, resume: Double?) async {
        Log.write("open \(url.absoluteString) directly (HLS)")
        isOnDemand = true
        conversionDone = true
        summary = [loc("Network HLS stream – played directly, without conversion")]
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Purrcast stream")
        }
        let item = AVPlayerItem(url: url)
        watch(item)
        player.replaceCurrentItem(with: item)
        if let d = try? await item.asset.load(.duration), d.seconds.isFinite { duration = d.seconds }
        if let resume { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        phase = .playing
        updateNowPlaying()
        player.play()
        await loadTracks(of: item)
    }

    /// Logs playback state and errors to ~/Library/Logs/Purrcast.log; failures trigger the fallback.
    private func watch(_ item: AVPlayerItem) {
        observers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error.map { ($0 as NSError).description } ?? ""
            Log.write("player status \(status.rawValue) \(error)")
            guard status == .failed else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.fallBack(loc("player error: \(error)"))
            }
        })
        NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: nil) { note in
            guard let event = (note.object as? AVPlayerItem)?.errorLog()?.events.last else { return }
            Log.write("player errorLog \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "") \(event.uri ?? "")")
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded() }
        }
        // Watchdog: a stream the TV (or AVPlayer) silently refuses never starts moving.
        let startTime = resumedFrom ?? 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.player.currentItem === item else { return }
            let t = self.player.currentTime().seconds
            Log.write("player after 20s: t=\(t) status=\(self.player.timeControlStatus.rawValue) external=\(self.player.isExternalPlaybackActive)")
            if t < startTime + 1, self.player.timeControlStatus != .paused {
                self.fallBack(loc("playback didn't start within 20 seconds"))
            } else if self.notice == loc("Didn't start with the previous settings, retrying in a safer mode…") {
                self.notice = nil
            }
        }
    }

    private func itemEnded() {
        clearResumePosition()
        if let next = playlist.next(automatic: true) {
            if next.id == playlist.currentID {
                seek(to: 0)
                player.play()
            } else {
                play(next)
            }
        } else {
            stopPlayback()
        }
    }

    private func conversionFinished(_ finished: StreamSession?, _ error: Error?) {
        guard let finished, finished === session else { return }
        conversionDone = error == nil
        conversionError = error?.localizedDescription
        // The player still has the half-done EVENT playlist: reload so it sees the whole movie and can seek anywhere.
        if error == nil, finished.remuxPending { reload(for: finished) }
    }

    /// Reloads the stream (new master playlist / subtitle files) at the current position, keeping the selections.
    private func reload(for changed: StreamSession?) {
        guard let changed, changed === session, let streamURL, let old = player.currentItem else { return }
        Task {
            let audio = await selectedName(in: old, .audible)
            let subtitle = await selectedName(in: old, .legible)
            let time = player.currentTime()
            let wasPlaying = player.rate > 0
            reloadCount += 1
            var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "r", value: "\(reloadCount)")]
            let item = AVPlayerItem(url: components.url!)
            watch(item)
            player.replaceCurrentItem(with: item)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            await applySelection(to: item, audio: audio, subtitle: subtitle)
            await loadTracks(of: item)
        }
    }

    // MARK: - Periodic update

    private func tick(_ time: CMTime) {
        if time.seconds.isFinite { currentTime = time.seconds }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying { isPlaying = playing; updateNowPlaying() }
        let external = player.isExternalPlaybackActive
        if external != isAirPlaying {
            Log.write("external playback (AirPlay) active: \(external)")
            isAirPlaying = external
        }
        if let a = loopA, let b = loopB, currentTime >= b { seek(to: a) }
        ticks += 1
        if ticks % 20 == 0 { saveResumePosition(); updateNowPlaying() }   // every 5 s
    }

    // MARK: - Transport

    func togglePlay() {
        if phase == .idle || (phase != .playing && phase != .preparing) {
            if let item = playlist.current ?? playlist.items.first { play(item) }
            return
        }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func next() {
        if let item = playlist.next(automatic: false) { play(item) }
    }

    func previous() {
        // Like VLC: a few seconds in, "previous" restarts the current item.
        if currentTime > 5 || playlist.previous() == nil { seek(to: 0); return }
        if let item = playlist.previous() { play(item) }
    }

    /// Seconds the player can seek to right now.
    var seekableEnd: Double {
        if isOnDemand || conversionDone || duration == 0 { return duration }
        return min(converted, duration)
    }

    func seek(to seconds: Double) {
        let t = max(0, min(seconds, max(seekableEnd - 1, 0)))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func jump(by seconds: Double) { seek(to: currentTime + seconds) }

    func nextFrame() {
        player.pause()
        player.currentItem?.step(byCount: 1)
    }

    func changeRate(faster: Bool) {
        let rates = Self.rates
        let i = rates.firstIndex { $0 >= rate } ?? rates.count - 1
        rate = rates[faster ? min(i + 1, rates.count - 1) : max(i - 1, 0)]
        flash(loc("Speed: \(Self.rateLabel(rate))"))
    }

    static func rateLabel(_ rate: Float) -> String {
        (rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%g", rate)) + "×"
    }

    func changeVolume(by delta: Float) {
        volume = max(0, min(1, volume + delta))
        isMuted = false
        flash(loc("Volume: \(String(Int((volume * 100).rounded())) + "%")"))
    }

    func toggleLoop() {
        if loopA == nil {
            loopA = currentTime
            flash(loc("Loop start: \(MediaInfo.formatTime(currentTime))"))
        } else if loopB == nil, let a = loopA {
            loopB = max(currentTime, a + 1)
            seek(to: a)
            flash(loc("Looping \(MediaInfo.formatTime(a)) – \(MediaInfo.formatTime(loopB!))"))
        } else {
            loopA = nil
            loopB = nil
            flash(loc("Loop off"))
        }
    }

    func toggleFullScreen() { mainWindow?.toggleFullScreen(nil) }

    func goTo(chapter: MediaInfo.Chapter) {
        seek(to: chapter.start)
        flash(loc("Chapter: \(chapter.title)"))
    }

    var chapters: [MediaInfo.Chapter] { info?.chapters ?? [] }

    /// Index of the chapter playing now.
    var currentChapter: Int? {
        chapters.lastIndex { $0.start <= currentTime + 0.5 }
    }

    func nextChapter() {
        let next = (currentChapter ?? -1) + 1
        if chapters.indices.contains(next) { goTo(chapter: chapters[next]) }
    }

    /// Like VLC: a few seconds into a chapter, "previous" restarts it; at its start it goes to the one before.
    func previousChapter() {
        guard let i = currentChapter else { return }
        let target = currentTime - chapters[i].start > 3 || i == 0 ? i : i - 1
        goTo(chapter: chapters[target])
    }

    func startOver() {
        resumedFrom = nil
        seek(to: 0)
    }

    // MARK: - Picture in Picture

    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private lazy var pipDelegate = PictureInPictureDelegate(model: self)

    /// Called by the player view when it creates its layer (again after every phase change).
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              pipController?.playerLayer !== layer,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        controller.delegate = pipDelegate
        pipController = controller
        pipObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.canPictureInPicture = possible }
        }
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    fileprivate func pictureInPictureChanged(_ active: Bool) {
        isPictureInPicture = active
        if !active {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Snapshot

    func takeSnapshot() {
        guard let url = currentURL, let info else { return }
        let time = currentTime
        Task {
            do {
                let file = try await Snapshot.save(input: url, info: info, at: time)
                flash(loc("Snapshot saved: \(file.lastPathComponent)"))
            } catch {
                flash(loc("Couldn't save the snapshot."))
            }
        }
    }

    // MARK: - Audio and subtitle tracks

    private var audioGroup: AVMediaSelectionGroup?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var subtitleGroup: AVMediaSelectionGroup?
    private var subtitleOptions: [AVMediaSelectionOption] = []

    private func loadTracks(of item: AVPlayerItem) async {
        audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        audioOptions = audioGroup?.options ?? []
        subtitleOptions = subtitleGroup?.options ?? []
        var names: [String] = []
        for o in audioOptions { names.append(await Self.name(of: o)) }
        audioTracks = names
        names = []
        for o in subtitleOptions { names.append(await Self.name(of: o)) }
        subtitleTracks = names
        updateSelectedTracks()
    }

    private func updateSelectedTracks() {
        guard let item = player.currentItem else { return }
        if let g = audioGroup, let o = item.currentMediaSelection.selectedMediaOption(in: g) { selectedAudio = audioOptions.firstIndex(of: o) }
        if let g = subtitleGroup {
            selectedSubtitle = item.currentMediaSelection.selectedMediaOption(in: g).flatMap { subtitleOptions.firstIndex(of: $0) }
        }
    }

    func selectAudio(_ index: Int) {
        guard let item = player.currentItem, let group = audioGroup, audioOptions.indices.contains(index) else { return }
        item.select(audioOptions[index], in: group)
        selectedAudio = index
    }

    /// nil turns subtitles off.
    func selectSubtitle(_ index: Int?) {
        guard let item = player.currentItem, let group = subtitleGroup else { return }
        if let index, subtitleOptions.indices.contains(index) {
            item.select(subtitleOptions[index], in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedSubtitle = index
    }

    func cycleSubtitle() {
        guard !subtitleTracks.isEmpty else { return }
        let next: Int? = selectedSubtitle.map { $0 + 1 < subtitleTracks.count ? $0 + 1 : nil } ?? 0
        selectSubtitle(next)
        flash(next.map { loc("Subtitle: \(subtitleTracks[$0])") } ?? loc("Subtitles off"))
    }

    func addSubtitleFile() {
        guard let session else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { session.addSubtitle(url) }
        flash(loc("Adding subtitles…"))
    }

    /// VLC's G / H: moves the subtitles in 50 ms steps. The stream is reloaded once the key presses stop.
    func changeSubtitleDelay(by delta: Double) {
        setSubtitleDelay(subtitleDelay + delta)
    }

    func setSubtitleDelay(_ value: Double) {
        subtitleDelay = (value * 1000).rounded() / 1000
        session?.subtitleDelay = subtitleDelay
        flash(loc("Subtitle delay: \(String(Int((subtitleDelay * 1000).rounded()))) ms"))
        delayReload?.cancel()
        delayReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reload(for: self.session)
        }
    }

    private func selectedName(in item: AVPlayerItem, _ characteristic: AVMediaCharacteristic) async -> String? {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic),
              let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return await Self.name(of: option)
    }

    /// The HLS NAME attribute ends up as the option's title; displayName is just the language.
    private static func name(of option: AVMediaSelectionOption) async -> String {
        let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
        return (try? await titles.first?.load(.stringValue)) ?? option.displayName
    }

    private func applySelection(to item: AVPlayerItem, audio: String?, subtitle: String?) async {
        for (characteristic, name) in [(AVMediaCharacteristic.audible, audio), (.legible, subtitle)] {
            guard let name, let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            for option in group.options where await Self.name(of: option) == name {
                item.select(option, in: group)
                break
            }
        }
    }

    // MARK: - Playlist files

    func savePlaylist() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText]
        panel.nameFieldStringValue = "Playlist.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? playlist.m3u().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Recent files and resume positions

    private func addRecent(_ url: URL) {
        var list = recentURLs.filter { $0 != url }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(15))
        UserDefaults.standard.set(recentURLs.map(\.absoluteString), forKey: "recent")
        if url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    func removeRecent(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        UserDefaults.standard.set(recentURLs.map(\.absoluteString), forKey: "recent")
    }

    func clearRecent() {
        recentURLs = []
        UserDefaults.standard.removeObject(forKey: "recent")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func resumePosition(for url: URL) -> Double? {
        (UserDefaults.standard.dictionary(forKey: "resume") as? [String: Double])?[url.absoluteString]
    }

    private func saveResumePosition() {
        guard let url = currentURL, phase == .playing, duration > 120 else { return }
        var all = UserDefaults.standard.dictionary(forKey: "resume") as? [String: Double] ?? [:]
        if currentTime > 30, currentTime < duration - 60 {
            all[url.absoluteString] = currentTime
        } else {
            all[url.absoluteString] = nil
        }
        UserDefaults.standard.set(all, forKey: "resume")
    }

    private func clearResumePosition() {
        guard let url = currentURL else { return }
        var all = UserDefaults.standard.dictionary(forKey: "resume") as? [String: Double] ?? [:]
        all[url.absoluteString] = nil
        UserDefaults.standard.set(all, forKey: "resume")
    }

    // MARK: - Media keys

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        center.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    /// Title, position and state for the system's Now Playing info (and AirPlay): the file name, not whatever
    /// title tag the file carries.
    private func updateNowPlaying() {
        guard phase == .playing || phase == .preparing, !title.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Status

    /// Short message shown over the video for a few seconds (OSD).
    func flash(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.notice == text { self?.notice = nil }
        }
    }

    var status: String {
        switch phase {
        case .idle: return ""
        case .preparing: return loc("Preparing…")
        case .failed: return loc("Error")
        case .playing:
            var parts: [String] = []
            if let i = currentChapter { parts.append(chapters[i].title) }
            if isAirPlaying { parts.append(loc("Playing via AirPlay")) }
            if let conversionError {
                parts.append(loc("Conversion stopped: \(String(conversionError.prefix(80)))"))
            } else if !isOnDemand, !conversionDone, duration > 0 {
                parts.append(loc("Prepared: \(Self.time(converted)) / \(Self.time(duration))"))
            }
            return parts.joined(separator: " · ")
        }
    }

    static func time(_ seconds: Double) -> String { MediaInfo.formatTime(seconds) }
}

private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var model: PlayerModel?

    init(model: PlayerModel) { self.model = model }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.model?.pictureInPictureChanged(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.model?.pictureInPictureChanged(false) }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.model?.mainWindow?.makeKeyAndOrderFront(nil)
            completion(true)
        }
    }
}
