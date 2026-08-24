import AppKit
import AVFoundation
import CoreAudio
import Foundation
import MediaPlayer
import OSLog
import ServiceManagement

private let playbackLogger = Logger(subsystem: "com.zaksorel.audio", category: "playback")
private let lifecycleLogger = Logger(subsystem: "com.zaksorel.audio", category: "lifecycle")

private let musicDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Music", isDirectory: true)
private let playableAudioExtensions: Set<String> = [
    "aac", "aif", "aiff", "flac", "m4a", "mp3", "wav",
]

private func isPlayableAudioFile(_ url: URL) -> Bool {
    guard playableAudioExtensions.contains(url.pathExtension.lowercased()) else {
        return false
    }

    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
}

private func musicTracks() -> [URL] {
    guard
        let urls = try? FileManager.default.contentsOfDirectory(
            at: musicDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return []
    }

    return urls.filter { url in
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        else {
            return false
        }
        return values.isRegularFile == true
            && playableAudioExtensions.contains(url.pathExtension.lowercased())
    }.sorted { left, right in
        left.path.localizedStandardCompare(right.path) == .orderedAscending
    }
}

final class DefaultOutputDeviceMonitor {
    private let queue = DispatchQueue(label: "com.zaksorel.audio.output-device")
    private var listener: AudioObjectPropertyListenerBlock?
    private var outputDeviceID: AudioDeviceID?

    var onOutputDeviceChanged: (() -> Void)?

    func start() -> Bool {
        guard listener == nil, let initialDeviceID = currentOutputDeviceID() else {
            return false
        }

        outputDeviceID = initialDeviceID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChange()
        }
        listener = block

        var address = outputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        if status != noErr {
            listener = nil
            outputDeviceID = nil
            return false
        }
        return true
    }

    func stop() {
        guard let listener else { return }

        var address = outputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        self.listener = nil
        outputDeviceID = nil
    }

    private var outputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func currentOutputDeviceID() -> AudioDeviceID? {
        var address = outputDeviceAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private func handleOutputDeviceChange() {
        guard
            let newDeviceID = currentOutputDeviceID(),
            newDeviceID != outputDeviceID
        else {
            return
        }

        outputDeviceID = newDeviceID
        playbackLogger.notice("default output device changed")
        DispatchQueue.main.async { [weak self] in
            self?.onOutputDeviceChanged?()
        }
    }
}

final class MusicLaunchBlocker {
    private let bundleIdentifier = "com.apple.Music"
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
        ] {
            observers.append(
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    self?.blockMusic(from: notification)
                }
            )
        }

        for application in NSWorkspace.shared.runningApplications {
            blockMusic(application)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func blockMusic(from notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else {
            return
        }
        blockMusic(application)
    }

    private func blockMusic(_ application: NSRunningApplication) {
        guard application.bundleIdentifier == bundleIdentifier else { return }
        application.forceTerminate()
        lifecycleLogger.notice("blocked Apple Music")
    }
}

final class PlayerController {
    private enum PlaybackState {
        case stopped
        case playing
        case paused
    }

    private let player = AVPlayer()
    private var playbackState = PlaybackState.stopped
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var shuffled = true
    private var currentTrackLoop = false
    private var shuffleBag = ShuffleBag()
    private var playbackHistory: [URL] = []
    private var historyIndex: Int?

    var onTrackEnded: (() -> Void)?

    var hasTrack: Bool {
        currentTrackURL != nil && player.currentItem != nil
    }

    var isPlaying: Bool {
        playbackState == .playing
    }

    private var currentTrackURL: URL? {
        guard let historyIndex, playbackHistory.indices.contains(historyIndex) else {
            return nil
        }
        return playbackHistory[historyIndex]
    }

    init() {
        player.actionAtItemEnd = .pause
        configureRemoteCommands()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let item = notification.object as? AVPlayerItem,
                item === self.player.currentItem
            else {
                return
            }
            self.handleTrackEnded()
        }

        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    @discardableResult
    func playRandomMusicTrack() -> Bool {
        selectRandomMusicTrack(autoplay: true)
    }

    @discardableResult
    func prepareRandomMusicTrack() -> Bool {
        selectRandomMusicTrack(autoplay: false)
    }

    private func selectRandomMusicTrack(autoplay: Bool) -> Bool {
        let available = musicTracks()
        let previousBag = shuffleBag
        guard let track = shuffleBag.draw(available: available, after: currentTrackURL) else {
            return false
        }

        guard playSelectedTrack(track, autoplay: autoplay) else {
            shuffleBag = previousBag
            return false
        }
        return true
    }

    @discardableResult
    func play(file url: URL) -> Bool {
        guard isPlayableAudioFile(url) else { return false }
        guard playSelectedTrack(url.standardizedFileURL) else {
            return false
        }

        if shuffled {
            shuffleBag.markPlayed(url, available: musicTracks())
        }
        return true
    }

    @discardableResult
    func pause() -> Bool {
        guard hasTrack else { return false }
        player.pause()
        playbackState = .paused
        playbackLogger.info("playback paused")
        updateNowPlayingInfo()
        return true
    }

    @discardableResult
    func pauseForOutputDeviceChange() -> Bool {
        guard isPlaying else { return false }
        let paused = pause()
        if paused {
            playbackLogger.notice("paused after default output device changed")
        }
        return paused
    }

    @discardableResult
    func resume() -> Bool {
        guard hasTrack else {
            return playRandomMusicTrack()
        }

        player.play()
        playbackState = .playing
        playbackLogger.info("playback resumed")
        updateNowPlayingInfo()
        return true
    }

    @discardableResult
    func togglePause() -> Bool {
        isPlaying ? pause() : resume()
    }

    @discardableResult
    func next() -> Bool {
        if playForwardHistoryTrack() {
            return true
        }

        let available = musicTracks()
        let nextTrack: URL?

        if shuffled {
            let previousBag = shuffleBag
            nextTrack = shuffleBag.draw(available: available, after: currentTrackURL)

            guard let nextTrack, playSelectedTrack(nextTrack) else {
                shuffleBag = previousBag
                return false
            }
        } else {
            nextTrack = nextSequentialTrack(in: available, after: currentTrackURL)
            guard let nextTrack else { return false }
            guard playSelectedTrack(nextTrack) else { return false }
        }
        return true
    }

    @discardableResult
    func previous() -> Bool {
        guard let currentIndex = historyIndex, currentIndex > 0 else { return false }

        for candidateIndex in stride(from: currentIndex - 1, through: 0, by: -1) {
            let candidate = playbackHistory[candidateIndex]
            guard isPlayableAudioFile(candidate) else { continue }

            if loadTrack(candidate) {
                historyIndex = candidateIndex
                updateNowPlayingInfo()
                return true
            }
            return false
        }
        return false
    }

    func toggleShuffle() -> Bool {
        shuffled.toggle()
        if shuffled {
            shuffleBag.beginCycle(
                available: musicTracks(),
                currentTrack: currentTrackURL
            )
        }
        return shuffled
    }

    func toggleRepeat() -> Bool {
        currentTrackLoop.toggle()
        return currentTrackLoop
    }

    func quit() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackState = .stopped
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nil
        nowPlayingCenter.playbackState = .stopped
    }

    private func playSelectedTrack(_ track: URL, autoplay: Bool = true) -> Bool {
        guard loadTrack(track, autoplay: autoplay) else { return false }

        if
            let historyIndex,
            historyIndex < playbackHistory.count - 1
        {
            playbackHistory.removeSubrange((historyIndex + 1)...)
        }

        playbackHistory.append(track.standardizedFileURL)
        historyIndex = playbackHistory.count - 1
        updateNowPlayingInfo()
        return true
    }

    private func playForwardHistoryTrack() -> Bool {
        guard let currentIndex = historyIndex else { return false }
        var candidateIndex = currentIndex + 1

        while playbackHistory.indices.contains(candidateIndex) {
            let candidate = playbackHistory[candidateIndex]

            if isPlayableAudioFile(candidate) {
                guard loadTrack(candidate) else { return false }
                historyIndex = candidateIndex
                updateNowPlayingInfo()
                return true
            }

            candidateIndex += 1
        }

        return false
    }

    private func nextSequentialTrack(in available: [URL], after currentTrack: URL?) -> URL? {
        guard !available.isEmpty else { return nil }
        guard let current = currentTrack?.standardizedFileURL else {
            return available[0]
        }

        if let currentIndex = available.firstIndex(of: current) {
            return available[(currentIndex + 1) % available.count]
        }

        return available.first {
            $0.path.localizedStandardCompare(current.path) == .orderedDescending
        } ?? available[0]
    }

    private func loadTrack(_ track: URL, autoplay: Bool = true) -> Bool {
        guard isPlayableAudioFile(track) else { return false }

        let item = AVPlayerItem(url: track)
        player.replaceCurrentItem(with: item)
        if autoplay {
            player.play()
            playbackState = .playing
        } else {
            player.pause()
            playbackState = .paused
        }
        return true
    }

    private func handleTrackEnded() {
        if currentTrackLoop {
            player.seek(to: .zero)
            player.play()
            playbackState = .playing
            updateNowPlayingInfo()
            return
        }

        playbackState = .stopped
        onTrackEnded?()
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            self?.resume() == true ? .success : .noActionableNowPlayingItem
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.pause() == true ? .success : .noActionableNowPlayingItem
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePause() == true ? .success : .noActionableNowPlayingItem
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.next() == true ? .success : .noActionableNowPlayingItem
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous() == true ? .success : .noActionableNowPlayingItem
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrackURL else { return }

        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = info
        switch playbackState {
        case .playing:
            nowPlayingCenter.playbackState = .playing
        case .paused:
            nowPlayingCenter.playbackState = .paused
        case .stopped:
            nowPlayingCenter.playbackState = .stopped
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let player = PlayerController()
    private let outputDeviceMonitor = DefaultOutputDeviceMonitor()
    private let musicLaunchBlocker = MusicLaunchBlocker()
    private var statusItem: NSStatusItem?
    private var shuffleMenuItem: NSMenuItem?
    private var repeatMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var receivedOpenRequest = false
    private let launchAtLoginEnabledKey = "launchAtLoginEnabled"

    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        synchronizeLaunchAtLogin()
        musicLaunchBlocker.start()

        player.onTrackEnded = { [weak self] in
            _ = self?.player.next()
        }
        outputDeviceMonitor.onOutputDeviceChanged = { [weak self] in
            _ = self?.player.pauseForOutputDeviceChange()
        }
        guard outputDeviceMonitor.start() else {
            quit()
            return
        }
        prepareRandomTrackIfOpenedDirectly()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        receivedOpenRequest = true
        return player.play(file: URL(fileURLWithPath: filename))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        receivedOpenRequest = true

        guard url.isFileURL else {
            handle(command: url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            return
        }

        _ = player.play(file: url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        musicLaunchBlocker.stop()
        outputDeviceMonitor.stop()
        player.quit()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "audio"
        )

        let menu = NSMenu()

        let playPauseItem = NSMenuItem(
            title: "Play/Pause",
            action: #selector(togglePlayback),
            keyEquivalent: ""
        )
        playPauseItem.image = NSImage(
            systemSymbolName: "playpause",
            accessibilityDescription: "play or pause"
        )
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(title: "Next", action: #selector(nextTrack), keyEquivalent: "")
        nextItem.image = NSImage(systemSymbolName: "forward.end", accessibilityDescription: "next")
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(
            title: "Previous",
            action: #selector(previousTrack),
            keyEquivalent: ""
        )
        previousItem.image = NSImage(
            systemSymbolName: "backward.end",
            accessibilityDescription: "previous"
        )
        menu.addItem(previousItem)

        menu.addItem(.separator())

        shuffleMenuItem = NSMenuItem(title: "Shuffle", action: #selector(toggleShuffle), keyEquivalent: "")
        shuffleMenuItem?.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "shuffle")
        shuffleMenuItem?.state = .on
        menu.addItem(shuffleMenuItem!)

        repeatMenuItem = NSMenuItem(title: "Repeat Track", action: #selector(toggleRepeat), keyEquivalent: "")
        repeatMenuItem?.image = NSImage(systemSymbolName: "repeat.1", accessibilityDescription: "repeat track")
        menu.addItem(repeatMenuItem!)

        menu.addItem(.separator())

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem?.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: "launch at login"
        )
        menu.addItem(launchAtLoginMenuItem!)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: ""))

        for item in menu.items {
            item.target = self
        }

        item.menu = menu
        statusItem = item
    }

    private func synchronizeLaunchAtLogin() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: launchAtLoginEnabledKey) == nil {
            defaults.set(true, forKey: launchAtLoginEnabledKey)
        }

        do {
            if defaults.bool(forKey: launchAtLoginEnabledKey) {
                if SMAppService.mainApp.status == .notRegistered
                    || SMAppService.mainApp.status == .notFound
                {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval
            {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lifecycleLogger.error(
                "failed to register launch at login: \(error.localizedDescription, privacy: .public)"
            )
        }
        updateLaunchAtLoginMenuItem()
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginMenuItem?.state = switch SMAppService.mainApp.status {
        case .enabled:
            .on
        case .requiresApproval:
            .mixed
        case .notRegistered, .notFound:
            .off
        @unknown default:
            .off
        }
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func prepareRandomTrackIfOpenedDirectly() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard !self.receivedOpenRequest, !self.player.hasTrack else { return }
            _ = self.player.prepareRandomMusicTrack()
        }
    }

    @objc private func handleURLEvent(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard
            let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: rawURL)
        else {
            return
        }

        receivedOpenRequest = true
        handle(command: url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func handle(command: String) {
        playbackLogger.notice("received command: \(command, privacy: .public)")
        switch command {
        case "pause":
            _ = player.pause()
        case "play":
            _ = player.resume()
        case "toggle":
            _ = player.togglePause()
        case "next":
            _ = player.next()
        case "previous":
            _ = player.previous()
        case "shuffle":
            shuffleMenuItem?.state = player.toggleShuffle() ? .on : .off
        case "repeat":
            repeatMenuItem?.state = player.toggleRepeat() ? .on : .off
        case "quit":
            quit()
        default:
            break
        }
    }

    @objc private func toggleShuffle() {
        handle(command: "shuffle")
    }

    @objc private func toggleRepeat() {
        handle(command: "repeat")
    }

    @objc private func togglePlayback() {
        handle(command: "toggle")
    }

    @objc private func nextTrack() {
        handle(command: "next")
    }

    @objc private func previousTrack() {
        handle(command: "previous")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: launchAtLoginEnabledKey)
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: launchAtLoginEnabledKey)
            @unknown default:
                return
            }
        } catch {
            lifecycleLogger.error(
                "failed to update launch at login: \(error.localizedDescription, privacy: .public)"
            )
        }
        updateLaunchAtLoginMenuItem()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
private struct AudioApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
