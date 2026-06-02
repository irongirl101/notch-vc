import Cocoa
import SwiftUI
import CoreImage
import CoreAudio
import IOKit.hid
import ApplicationServices
import Foundation
import AVFoundation
import IOKit.ps
import Darwin

func debugLog(_ message: String) {
    print(message)
    fflush(stdout)
}

extension NSImage {
    func withMinimalistColors() -> NSImage {
        guard let tiffData = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let ciImage = CIImage(bitmapImageRep: bitmapImage) else {
            return self
        }
        
        guard let filter = CIFilter(name: "CIColorControls") else { return self }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.4, forKey: kCIInputSaturationKey) // Muted saturation for a minimalist look
        filter.setValue(0.1, forKey: kCIInputBrightnessKey) // Slight brightness boost
        filter.setValue(1.1, forKey: kCIInputContrastKey)   // Slight contrast boost to keep it crisp
        
        guard let outputCIImage = filter.outputImage else { return self }
        
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) {
            return NSImage(cgImage: cgImage, size: self.size)
        }
        return self
    }
}

final class NowPlayingManager: ObservableObject {
    @Published var isPlaying: Bool = false {
        didSet { updateProgressTimer() }
    }
    @Published var nowPlayingAppIcon: NSImage?
    @Published var nowPlayingAppIconSmall: NSImage?
    @Published var nowPlayingArtwork: NSImage?
    @Published var trackTitle: String?
    @Published var trackArtist: String?
    @Published var trackAlbum: String?
    @Published var trackReleaseYear: String?
    @Published var trackQuality: String?
    @Published var trackElapsed: Double = 0
    @Published var trackDuration: Double = 0
    @Published var nowPlayingAppName: String?
    @Published var lastTrackUpdateAt: Date = .distantPast
    @Published var fallbackTrackTitle: String?
    @Published var fallbackTrackArtist: String?
    @Published var fallbackTrackAlbum: String?
    @Published var fallbackAppName: String?
    @Published var fallbackAppIcon: NSImage?
    @Published var fallbackArtwork: NSImage?
    @Published var fallbackIsPlaying: Bool = false {
        didSet { updateProgressTimer() }
    }
    @Published var fallbackPlaybackState: String = "" {
        didSet { updateProgressTimer() }
    }
    @Published var fallbackLastUpdateAt: Date = .distantPast
    @Published var lastKnownTrackTitle: String?
    @Published var lastKnownTrackArtist: String?
    @Published var lastKnownTrackAlbum: String?
    @Published var lastKnownArtwork: NSImage?
    @Published var isBrowserJSEnabled: Bool = true

    private let bundle: CFBundle?
    private let queue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var progressTimer: Timer?
    private var fallbackPollInterval: TimeInterval = 12.0
    private var lastFallbackRefreshAt: Date = .distantPast
    private var isRefreshingFallback: Bool = false
    private var frontmostBundleID: String?
    private var frontmostAppName: String?
    private var lastFallbackArtworkURL: String?
    private var lastDirectFallbackArtworkURL: String?

    private func updateProgressTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.effectiveIsPlaying {
                if self.progressTimer == nil {
                    self.startProgressTimer()
                }
            } else {
                self.stopProgressTimer()
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.effectiveIsPlaying {
                DispatchQueue.main.async {
                    if self.trackElapsed < self.trackDuration {
                        self.trackElapsed += 1.0
                    }
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    private var lastFallbackWasSpotify: Bool = false
    private var hasOptimisticSpotifyToggleState: Bool = false

    private typealias MRRegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias MRGetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias MRGetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRSendCommandFn = @convention(c) (Int32, Any?) -> Bool

    private let mrRegister: MRRegisterFn?
    private let mrGetPID: MRGetPIDFn?
    private let mrGetIsPlaying: MRGetIsPlayingFn?
    private let mrGetNowPlayingInfo: MRGetNowPlayingInfoFn?
    private let mrSendCommand: MRSendCommandFn?

    init() {
        debugLog("[DEBUG] NowPlayingManager: Loading MediaRemote framework...")
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let b = CFBundleCreate(kCFAllocatorDefault, url)
        bundle = b

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let b else { return nil }
            guard let ptr = CFBundleGetFunctionPointerForName(b, name as CFString) else {
                debugLog("[DEBUG] NowPlayingManager: Failed to load function \(name)")
                return nil
            }
            return unsafeBitCast(ptr, to: type)
        }

        mrRegister = load("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterFn.self)
        mrGetPID = load("MRMediaRemoteGetNowPlayingApplicationPID", as: MRGetPIDFn.self)
        mrGetIsPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: MRGetIsPlayingFn.self)
        mrGetNowPlayingInfo = load("MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfoFn.self)
        mrSendCommand = load("MRMediaRemoteSendCommand", as: MRSendCommandFn.self)

        debugLog("[DEBUG] NowPlayingManager: mrRegister=\(mrRegister != nil), mrGetPID=\(mrGetPID != nil), mrGetIsPlaying=\(mrGetIsPlaying != nil), mrGetNowPlayingInfo=\(mrGetNowPlayingInfo != nil), mrSendCommand=\(mrSendCommand != nil)")

        if mrRegister != nil {
            mrRegister?(queue)
            let names = [
                "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            ]
            for n in names {
                debugLog("[DEBUG] NowPlayingManager: Registering observer for \(n)")
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSNotification.Name(rawValue: n),
                        object: nil, queue: .main
                    ) { [weak self] notification in 
                        debugLog("[DEBUG] NowPlayingManager: Received notification \(notification.name.rawValue)")
                        self?.refresh() 
                    }
                )
            }
        }
        refresh()
        DispatchQueue.main.async { [weak self] in
            self?.refreshBrowserFallback(force: true)
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func refresh() {
        debugLog("[DEBUG] NowPlayingManager: refresh() called")
        guard let mrGetIsPlaying = mrGetIsPlaying,
              let mrGetPID = mrGetPID,
              let mrGetNowPlayingInfo = mrGetNowPlayingInfo else { 
            debugLog("[DEBUG] NowPlayingManager: missing core functions, aborting refresh")
            return 
        }

        mrGetIsPlaying(queue) { [weak self] playing in
            guard let self = self else { return }
            debugLog("[DEBUG] NowPlayingManager: mrGetIsPlaying callback: playing=\(playing)")
            self.isPlaying = playing
            
            mrGetPID(self.queue) { pid in
                DispatchQueue.main.async {
                    debugLog("[DEBUG] NowPlayingManager: mrGetPID callback: pid=\(pid)")
                    if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                        self.nowPlayingAppName = app.localizedName
                        self.nowPlayingAppIcon = app.icon
                    } else {
                        self.nowPlayingAppName = nil
                        self.nowPlayingAppIcon = nil
                    }
                }
            }

            mrGetNowPlayingInfo(self.queue) { info in
                DispatchQueue.main.async {
                    let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                    let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                    let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                    debugLog("[DEBUG] NowPlayingManager: mrGetNowPlayingInfo callback: title=\(String(describing: title)), artist=\(String(describing: artist)), album=\(String(describing: album))")
                    
                    self.trackTitle = title
                    self.trackArtist = artist
                    self.trackAlbum = album
                    if let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
                        self.trackElapsed = elapsed
                    }
                    if let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double {
                        self.trackDuration = duration
                    }
                    
                    if let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                        self.nowPlayingArtwork = NSImage(data: artworkData)
                        self.lastKnownArtwork = self.nowPlayingArtwork
                    } else {
                        self.nowPlayingArtwork = nil
                    }
                    if let t = self.trackTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastKnownTrackTitle = t
                    }
                    if let a = self.trackArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastKnownTrackArtist = a
                    }
                    if let al = self.trackAlbum, !al.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.lastKnownTrackAlbum = al
                    }
                    self.lastTrackUpdateAt = Date()
                }
            }
        }
    }

    func sendCommand(_ command: Int32) {
        _ = mrSendCommand?(command, nil)
    }

    func seekToPosition(_ seconds: Double) {
        let options: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": seconds]
        _ = mrSendCommand?(10, options)
    }

    func noteSpotifyPlayPauseToggle() {
        DispatchQueue.main.async {
            let nextIsPlaying: Bool
            if !self.fallbackPlaybackState.isEmpty {
                nextIsPlaying = self.fallbackPlaybackState.lowercased() != "playing"
            } else {
                nextIsPlaying = !self.fallbackIsPlaying
            }
            self.fallbackIsPlaying = nextIsPlaying
            self.fallbackPlaybackState = nextIsPlaying ? "playing" : "paused"
            self.isPlaying = nextIsPlaying
            self.fallbackLastUpdateAt = Date()
            self.lastFallbackWasSpotify = true
            self.hasOptimisticSpotifyToggleState = true
        }
    }

    var hasMediaRemoteData: Bool {
        if let t = trackTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let a = trackArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let al = trackAlbum, !al.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if nowPlayingArtwork != nil { return true }
        return isPlaying
    }

    var effectiveTrackTitle: String? {
        if let t = trackTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        if let t = fallbackTrackTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return lastKnownTrackTitle
    }

    var effectiveTrackArtist: String? {
        if let a = trackArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        if let a = fallbackTrackArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        return lastKnownTrackArtist
    }

    var effectiveTrackAlbum: String? {
        if let a = trackAlbum, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        if let a = fallbackTrackAlbum, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        return lastKnownTrackAlbum
    }

    var effectiveAppName: String? {
        if let n = nowPlayingAppName, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return n }
        return fallbackAppName
    }

    var effectiveIsPlaying: Bool {
        if prefersSpotifyControls {
            if !fallbackPlaybackState.isEmpty {
                let normalized = fallbackPlaybackState.lowercased()
                if normalized == "playing" { return true }
                if normalized == "paused" {
                    // Spotify web metadata can occasionally mis-read page-level Play buttons.
                    // If system now-playing reports active playback, prefer that signal.
                    if hasMediaRemoteData && isPlaying { return true }
                    return false
                }
            }
            if hasOptimisticSpotifyToggleState {
                return fallbackIsPlaying
            }
            if hasMediaRemoteData {
                return isPlaying
            }
            return fallbackIsPlaying
        }
        if prefersSpotifyState {
            if !fallbackPlaybackState.isEmpty {
                return fallbackPlaybackState.lowercased() == "playing"
            }
            return fallbackIsPlaying
        }
        if hasMediaRemoteData { return isPlaying }
        if !fallbackPlaybackState.isEmpty {
            return fallbackPlaybackState.lowercased() == "playing"
        }
        return fallbackIsPlaying
    }

    var effectiveArtwork: NSImage? {
        if let a = nowPlayingArtwork { return a }
        if let a = fallbackArtwork { return a }
        return lastKnownArtwork
    }

    var effectiveAppIcon: NSImage? {
        if let icon = nowPlayingAppIconSmall ?? nowPlayingAppIcon { return icon }
        return fallbackAppIcon
    }

    func setFrontmostApp(bundleID: String?, name: String?) {
        frontmostBundleID = bundleID
        frontmostAppName = name
    }

    func startFallbackPolling(interval: TimeInterval = 12.0) {
        let normalizedInterval = max(8.0, interval)
        if let timer = fallbackTimer {
            if abs(fallbackPollInterval - normalizedInterval) < 0.01 {
                // Polling interval is the same, but still trigger a refresh immediately (forced) to capture updates
                refreshBrowserFallback(force: true)
                return
            }
            timer.invalidate()
            fallbackTimer = nil
        }
        fallbackPollInterval = normalizedInterval
        refreshBrowserFallback(force: true) // Force immediate update when starting or changing polling
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: normalizedInterval, repeats: true) { [weak self] _ in
            self?.refreshBrowserFallback()
        }
    }

    func stopFallbackPolling() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func refreshBrowserFallback(force: Bool = false) {
        debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback() called (force=\(force))")
        if isRefreshingFallback { 
            debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - already refreshing, aborting")
            return 
        }
        let now = Date()
        let minGap = force ? 1.0 : max(4.0, fallbackPollInterval * 0.75)
        if now.timeIntervalSince(lastFallbackRefreshAt) < minGap { 
            debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - throttled, gap is \(now.timeIntervalSince(lastFallbackRefreshAt))s (min \(minGap)s)")
            return 
        }
        isRefreshingFallback = true
        lastFallbackRefreshAt = now
        defer { isRefreshingFallback = false }

        let useBrowser = shouldUseBrowserFallback()
        debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - shouldUseBrowserFallback=\(useBrowser)")
        guard useBrowser else {
            // Keep recent data visible when switching away from the browser.
            if hasRecentFallback() { 
                debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - keeping recent fallback data")
                return 
            }
            debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - clearing fallback")
            clearFallback()
            return
        }

        debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - attempting browserSpotifyTabMetadataScript")
        if let meta = runAppleScript(browserSpotifyTabMetadataScript(), isJavaScript: true) {
            debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - meta raw: \(meta)")
            let parts = meta.components(separatedBy: "|||")
            if parts.count >= 8 {
                let title = parts[0]
                let artist = parts[1]
                let album = parts[2]
                let artworkURL = parts[3]
                let playbackState = parts[4]
                let elapsedSeconds = Double(parts[5]) ?? 0
                let durationSeconds = Double(parts[6]) ?? 0
                let url = parts[7]
                if url.contains("spotify.com") {
                    lastFallbackWasSpotify = true
                    let parsed = parseSpotifyTitle(title)
                    let newTitle = parsed.title ?? (title.isEmpty ? nil : title)
                    let newArtist = parsed.artist ?? (artist.isEmpty ? nil : artist)
                    let isTrackURL = url.contains("/track/")
                    let hasMediaSession = !playbackState.isEmpty || !artworkURL.isEmpty
                    let isPlayingFlag = playbackState.lowercased() == "playing"
                    let generic = isGenericSpotifyTitle(newTitle)
                    let shouldUpdateText = (newTitle != nil &&
                        (newArtist != nil || isTrackURL || hasMediaSession || isPlayingFlag) &&
                        !(generic))
                    let hasUsableMeta = shouldUpdateText || !artworkURL.isEmpty || !playbackState.isEmpty || isTrackURL
                    debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - meta parsed, shouldUpdateText=\(shouldUpdateText), hasUsableMeta=\(hasUsableMeta)")
                    if !hasUsableMeta {
                        // Keep scanning for a better Spotify tab signal.
                        // Some tabs return generic page titles with no track metadata.
                    } else {
                    DispatchQueue.main.async {
                        if shouldUpdateText {
                            self.fallbackTrackTitle = newTitle
                            self.fallbackTrackArtist = newArtist
                            if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.fallbackTrackAlbum = album
                                self.lastKnownTrackAlbum = album
                            }
                            if let t = newTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.lastKnownTrackTitle = t
                            }
                            if let a = newArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.lastKnownTrackArtist = a
                            }
                        }
                        self.fallbackAppName = "Spotify (Brave)"
                        self.fallbackAppIcon = self.braveIcon()
                        self.trackElapsed = elapsedSeconds
                        self.trackDuration = durationSeconds
                        if !playbackState.isEmpty {
                            let braveIsPlaying = playbackState.lowercased() == "playing"
                            self.fallbackIsPlaying = braveIsPlaying
                            self.fallbackPlaybackState = playbackState
                            self.isPlaying = braveIsPlaying
                            self.hasOptimisticSpotifyToggleState = false
                        }
                        self.fallbackLastUpdateAt = Date()
                        debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - updated fallback values: Title=\(String(describing: self.fallbackTrackTitle)), Artist=\(String(describing: self.fallbackTrackArtist)), PlayState=\(self.fallbackPlaybackState), Elapsed=\(self.trackElapsed), Duration=\(self.trackDuration)")
                    }
                    fetchDirectFallbackArtworkIfNeeded(artworkURLString: artworkURL)
                    fetchFallbackArtworkIfNeeded(pageURLString: url)
                    return
                    }
                }
            }
        }

        debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - browserSpotifyTabMetadataScript returned no data, trying browserFindSpotifyTabScript")
        if let found = runAppleScript(browserFindSpotifyTabScript()) {
            debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - found raw: \(found)")
            let parts = found.components(separatedBy: "|||")
            if parts.count >= 2 {
                let title = parts[0]
                let url = parts[1]
                if url.contains("spotify.com") {
                    lastFallbackWasSpotify = true
                    let parsed = parseSpotifyTitle(title)
                    let newTitle = parsed.title ?? (title.isEmpty ? nil : title)
                    let newArtist = parsed.artist
                    debugLog("[DEBUG] NowPlayingManager: refreshBrowserFallback - found tab parsed, Title=\(String(describing: newTitle)), Artist=\(String(describing: newArtist))")
                    DispatchQueue.main.async {
                        if let t = newTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.fallbackTrackTitle = t
                            self.lastKnownTrackTitle = t
                        }
                        if let a = newArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.fallbackTrackArtist = a
                            self.lastKnownTrackArtist = a
                        }
                        self.fallbackAppName = "Spotify (Brave)"
                        self.fallbackAppIcon = self.braveIcon()
                        self.fallbackLastUpdateAt = Date()
                    }
                    fetchFallbackArtworkIfNeeded(pageURLString: url)
                    return
                }
            }
        }

        lastFallbackWasSpotify = false
        if isBraveRunning() { return }
        clearFallback()
    }

    private func shouldUseBrowserFallback() -> Bool {
        return isBraveRunning()
    }

    private func hasRecentFallback() -> Bool {
        if fallbackIsPlaying { return true }
        if lastFallbackWasSpotify && isBraveRunning() { return true }
        return Date().timeIntervalSince(fallbackLastUpdateAt) < 10.0
    }

    private func isBraveRunning() -> Bool {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser").isEmpty == false
    }

    var prefersSpotifyControls: Bool {
        return isBraveRunning()
    }

    private var prefersSpotifyState: Bool {
        if lastFallbackWasSpotify { return true }
        if fallbackTrackTitle != nil && isBraveRunning() { return true }
        if !fallbackPlaybackState.isEmpty && isBraveRunning() { return true }
        return false
    }

    private func isGenericSpotifyTitle(_ title: String?) -> Bool {
        guard let t = title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return true }
        return t.contains("spotify") || t.contains("stats for") || t.contains("view ") || t.contains("home") || t.contains("search")
    }

    private func clearFallback() {
        DispatchQueue.main.async {
            self.fallbackTrackTitle = nil
            self.fallbackTrackArtist = nil
            self.fallbackTrackAlbum = nil
            self.fallbackAppName = nil
            self.fallbackAppIcon = nil
            self.fallbackArtwork = nil
            self.fallbackIsPlaying = false
            self.fallbackPlaybackState = ""
            self.hasOptimisticSpotifyToggleState = false
        }
        lastDirectFallbackArtworkURL = nil
    }

    private func browserSpotifyTabMetadataScript() -> String {
        let js = """
        (function(){
          const ms = (navigator.mediaSession && navigator.mediaSession.metadata) ? navigator.mediaSession.metadata : null;
          let title = (ms && ms.title) ? ms.title : '';
          let artist = (ms && ms.artist) ? ms.artist : '';
          let album = (ms && ms.album) ? ms.album : '';
          let artwork = '';
          if (ms && ms.artwork && ms.artwork.length) {
            const last = ms.artwork[ms.artwork.length - 1];
            artwork = last && last.src ? last.src : '';
          }

          // Fallback: scrape Spotify's now-playing footer/widget when Media Session is empty.
          const root = document.querySelector('[data-testid="now-playing-widget"]') ||
                       document.querySelector('footer');
          if (root) {
            if (!title) {
              const titleEl = root.querySelector('[data-testid="nowplaying-track-link"]') ||
                              root.querySelector('[data-testid="context-item-link"]') ||
                              root.querySelector('a[href*="/track/"]');
              title = titleEl ? (titleEl.textContent || '').trim() : '';
            }
            if (!artist) {
              const artistNodes = Array.from(
                root.querySelectorAll('[data-testid="context-item-info-artist"] a, a[href*="/artist/"]')
              ).filter((n) => {
                const rect = n.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              });
              if (artistNodes.length > 0) {
                artist = artistNodes.map((n) => (n.textContent || '').trim()).filter(Boolean).join(', ');
              }
            }
            if (!album) {
              const albumEl = root.querySelector('a[href*="/album/"]');
              album = albumEl ? (albumEl.textContent || '').trim() : '';
            }
            if (!artwork) {
              const artEl = root.querySelector('img[src*="i.scdn.co/image"], img');
              artwork = artEl ? (artEl.getAttribute('src') || '') : '';
            }
          }

          let rawPlayback = (navigator.mediaSession && navigator.mediaSession.playbackState) ? navigator.mediaSession.playbackState : '';
          let normalized = (rawPlayback || '').toLowerCase();
          let hasUsablePlayback = normalized === 'playing' || normalized === 'paused';
          var playback = hasUsablePlayback ? normalized : '';
          if (!playback) {
            const audios = Array.from(document.querySelectorAll('audio'));
            if (audios.length > 0) {
              const anyPlaying = audios.some((a) => {
                try { return !!a && !a.paused && !a.ended; } catch (_) { return false; }
              });
              // Only trust <audio> to positively confirm playing.
              // Spotify can keep paused/auxiliary audio elements in the DOM.
              if (anyPlaying) playback = 'playing';
            }
          }
          if (!playback) {
            const controls = document.querySelector('[data-testid="playback-controls"]') ||
                             document.querySelector('footer') ||
                             document;
            const isVisible = (el) => {
              if (!el) return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            const pauseBtn = controls.querySelector('[data-testid="control-button-pause"]');
            const playBtn = controls.querySelector('[data-testid="control-button-play"]');
            if (isVisible(pauseBtn)) playback = 'playing';
            else if (isVisible(playBtn)) playback = 'paused';
            else {
              const playPauseBtn = controls.querySelector('[data-testid="control-button-playpause"]') ||
                                   controls.querySelector('button[aria-label="Pause"]') ||
                                   controls.querySelector('button[aria-label="Play"]') ||
                                   controls.querySelector('button[aria-label*="Pause"]') ||
                                   controls.querySelector('button[aria-label*="Play"]');
              const label = playPauseBtn ? ((playPauseBtn.getAttribute('aria-label') || '').toLowerCase()) : '';
              if (label.includes('pause')) playback = 'playing';
              if (label.includes('play')) playback = 'paused';
            }
          }

          const parseTime = (str) => {
            if (!str) return 0;
            const p = str.trim().split(':').map(Number);
            if (p.length === 2) return p[0] * 60 + p[1];
            if (p.length === 3) return p[0] * 3600 + p[1] * 60 + p[2];
            return 0;
          };
          const elapsedEl = document.querySelector('[data-testid="playback-position"]');
          const durationEl = document.querySelector('[data-testid="playback-duration"]');
          const elapsed = elapsedEl ? parseTime(elapsedEl.textContent) : 0;
          const duration = durationEl ? parseTime(durationEl.textContent) : 0;

          return [title, artist, album, artwork, playback, elapsed, duration].join('|||');
        })();
        """
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            -- Prefer active Spotify tab in front window first.
            try
                set frontIndex to active tab index of front window
                set frontTab to tab frontIndex of front window
                set frontURL to URL of frontTab
                if frontURL contains "spotify.com" then
                    tell frontTab to set result to execute javascript "\(escaped)"
                    return result & "|||" & frontURL
                end if
            end try
            -- Prefer track tabs first
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "open.spotify.com/track/" then
                            tell t to set result to execute javascript "\(escaped)"
                            return result & "|||" & theURL
                        end if
                    end try
                end repeat
            end repeat
            -- Fall back to any Spotify tab
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "spotify.com" then
                            tell t to set result to execute javascript "\(escaped)"
                            return result & "|||" & theURL
                        end if
                    end try
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    private func browserFindSpotifyTabScript() -> String {
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            -- Prefer active Spotify tab in front window first.
            try
                set frontIndex to active tab index of front window
                set frontTab to tab frontIndex of front window
                set frontURL to URL of frontTab
                if frontURL contains "spotify.com" then
                    set frontTitle to title of frontTab
                    return frontTitle & "|||" & frontURL
                end if
            end try
            -- First pass: prefer direct track URLs
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "open.spotify.com/track/" then
                            set theTitle to title of t
                            return theTitle & "|||" & theURL
                        end if
                    end try
                end repeat
            end repeat
            -- Second pass: any Spotify tab
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "spotify.com" then
                            set theTitle to title of t
                            return theTitle & "|||" & theURL
                        end if
                    end try
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    private func runAppleScript(_ source: String, isJavaScript: Bool = false) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if let error = error {
            debugLog("[DEBUG] NowPlayingManager: AppleScript error: \(error)")
            let errStr = "\(error)"
            if isJavaScript && errStr.contains("-1723") {
                DispatchQueue.main.async {
                    self.isBrowserJSEnabled = false
                }
            }
            return nil
        }
        if isJavaScript {
            DispatchQueue.main.async {
                self.isBrowserJSEnabled = true
            }
        }
        return output.stringValue
    }

    private func fetchFallbackArtworkIfNeeded(pageURLString: String) {
        guard lastFallbackArtworkURL != pageURLString else { return }
        lastFallbackArtworkURL = pageURLString

        Task { [weak self] in
            guard let self else { return }
            guard let img = await self.spotifyOEmbedArtwork(pageURLString: pageURLString) else { return }
            await MainActor.run {
                self.fallbackArtwork = img
                self.fallbackLastUpdateAt = Date()
            }
        }
    }

    private func fetchDirectFallbackArtworkIfNeeded(artworkURLString: String) {
        guard !artworkURLString.isEmpty else { return }
        guard lastDirectFallbackArtworkURL != artworkURLString else { return }
        lastDirectFallbackArtworkURL = artworkURLString
        guard let artworkURL = URL(string: artworkURLString) else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let img = await self.downloadImage(from: artworkURL) else { return }
            await MainActor.run {
                self.fallbackArtwork = img
                self.lastKnownArtwork = img
                self.fallbackLastUpdateAt = Date()
            }
        }
    }

    private func spotifyOEmbedArtwork(pageURLString: String) async -> NSImage? {
        guard let encoded = pageURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://open.spotify.com/oembed?url=\(encoded)") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let thumb = json["thumbnail_url"] as? String,
               let thumbURL = URL(string: thumb) {
                return await downloadImage(from: thumbURL)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func downloadImage(from url: URL) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func parseSpotifyTitle(_ title: String) -> (title: String?, artist: String?) {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: " - Spotify", with: "")
        cleaned = cleaned.replacingOccurrences(of: " – Spotify", with: "")
        cleaned = cleaned.replacingOccurrences(of: " | Spotify", with: "")

        if cleaned.contains(" • ") {
            let parts = cleaned.components(separatedBy: " • ")
            if parts.count == 2 {
                return (title: parts[0], artist: parts[1])
            }
        }
        if cleaned.contains(" - ") {
            let parts = cleaned.components(separatedBy: " - ")
            if parts.count == 2 {
                return (title: parts[0], artist: parts[1])
            }
        }
        return (title: cleaned.isEmpty ? nil : cleaned, artist: nil)
    }

    private func braveIcon() -> NSImage? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser").first else {
            return nil
        }
        return app.icon
    }
}

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class PassThroughView<Content: View>: NSHostingView<Content> {
    var allowsHitTesting: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // We never want to actually absorb clicks, so if the user clicks, just pass it through 
        // to whatever app is underneath the notch (like the Menu Bar).
        // Returning nil here drops the click entirely, while tracking areas (like .onHover) continue to function.
        return allowsHitTesting ? super.hitTest(point) : nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // Since the user already has a physical MacBook notch, our software notch needs to be wider 
        // to extend past it and show the battery text on the side. 
        let notchWidth: CGFloat = 370
        let notchHeight: CGFloat = 33
        
        let baseExpandedWidth = max(480, (screenRect.width * 0.25) + 50)
        let expandedWidth = baseExpandedWidth + 5
        let expandedHeight: CGFloat = 172
        
        // The *window* needs to be large enough to contain the *expanded* notch, even when it's small.
        // Otherwise, the notch will clip when it animates open.
        // We position this invisible bounding box at the top center, shifted 5px to the left
        // to accommodate the extra width on the left side of the notch when hovered.
        let windowRect = NSRect(
            x: (screenRect.width - baseExpandedWidth) / 2.0 - 5,
            y: screenRect.height - expandedHeight + 1, // Still push it up +1 to hide the top edge
            width: expandedWidth,
            height: expandedHeight
        )
        
        // NotchView needs to know how big the window is so it can align itself 
        // to the absolute top-center of the Invisible Box.
        var hostingView: PassThroughView<NotchView>!
        let notchView = NotchView(
            baseWidth: notchWidth,
            baseHeight: notchHeight,
            expandedWidth: expandedWidth,
            expandedHeight: expandedHeight
        ) { hovering in
            hostingView?.allowsHitTesting = hovering
        }
        hostingView = PassThroughView(rootView: notchView)
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)

        notchWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        notchWindow.isOpaque = false
        notchWindow.backgroundColor = .clear
        notchWindow.level = .statusBar // Place above the menu bar
        notchWindow.hasShadow = false
        // DO NOT set ignoresMouseEvents = true. We need tracking areas for hover!
        notchWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle] // Appear on all spaces
        
        // Set standard tracking areas so SwiftUI .onHover works
        notchWindow.acceptsMouseMovedEvents = true
        
        notchWindow.contentView = hostingView
        notchWindow.makeKeyAndOrderFront(nil)
    }
}

class BatteryManager: ObservableObject {
    @Published var percentage: String = "--%"
    @Published var isCharging: Bool = false
    @Published var batteryLevel: Int = 0
    @Published var isLowPowerMode: Bool = false
    private var timer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    init() {
        self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        // Defer the first read to avoid SwiftUI/AttributeGraph update cycles during view creation.
        DispatchQueue.main.async { [weak self] in
            self?.updateBattery()
        }
        
        // Instantly catch when the user shifts in and out of Low Power Mode
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        
        // Instant updates when power source changes.
        let src = IOPSNotificationCreateRunLoopSource({ context in
            let unmanaged = Unmanaged<BatteryManager>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async {
                unmanaged.updateBattery()
            }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        if let src {
            let source = src.takeRetainedValue()
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Keep a periodic poll as a fallback.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
    }

    deinit {
        if let src = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        timer?.invalidate()
    }

    func updateBattery() {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g", "batt"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            // Find percentage using simple string parsing or regex
            let percentRange = output.range(of: "\\d+%", options: .regularExpression)
            let foundPercentage = percentRange.map { String(output[$0]) }
            let intVal = foundPercentage.flatMap { Int($0.dropLast()) } ?? 0

            // Parse status from the battery line (charging/charged/discharging).
            let batteryLine = output.split(separator: "\n").first { $0.contains("%") } ?? ""
            let line = batteryLine.lowercased()
            let isDischarging = line.contains("discharging")
            let isCharging = line.contains("charging") || line.contains("charged") || line.contains("finishing charge")
            let charging = isCharging && !isDischarging

            DispatchQueue.main.async {
                if let foundPercentage {
                    self.percentage = foundPercentage
                    self.batteryLevel = intVal
                }
                self.isCharging = charging
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
}

class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = []
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    
    init() {
        startPolling()
    }
    
    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
    
    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if items.first?.text == text { return }
            
            DispatchQueue.main.async {
                let newItem = ClipboardItem(id: UUID(), text: text, timestamp: Date())
                self.items.insert(newItem, at: 0)
                if self.items.count > 5 {
                    self.items.removeLast()
                }
            }
        }
    }
    
    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }
}

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var ramUsage: Double = 0.0
    @Published var downloadSpeed: Double = 0.0
    @Published var uploadSpeed: Double = 0.0
    
    private var lastCPULoad = host_cpu_load_info()
    private var hasLastCPULoad = false
    
    private var lastNetBytes: (ibytes: UInt64, obytes: UInt64)? = nil
    private var lastNetTime = Date()
    
    private var monitorTimer: Timer?
    
    func startMonitoring(interval: TimeInterval = 1.5) {
        debugLog("[DEBUG] SystemMonitor: startMonitoring called with interval \(interval)")
        stopMonitoring()
        _ = getHostCPUUsage()
        _ = getNetworkSpeeds()
        
        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }
    
    func stopMonitoring() {
        debugLog("[DEBUG] SystemMonitor: stopMonitoring called")
        monitorTimer?.invalidate()
        monitorTimer = nil
    }
    
    private func updateStats() {
        let cpu = getHostCPUUsage()
        let ram = getHostRAMUsage()
        let net = getNetworkSpeeds()
        debugLog("[DEBUG] SystemMonitor: updateStats - cpu=\(cpu), ram=\(ram), down=\(net.download), up=\(net.upload)")
        
        DispatchQueue.main.async {
            self.cpuUsage = cpu
            self.ramUsage = ram
            self.downloadSpeed = net.download
            self.uploadSpeed = net.upload
        }
    }
    
    private func getHostCPUUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var cpuLoad = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }
        
        if hasLastCPULoad {
            let userDiff = Double(cpuLoad.cpu_ticks.0 - lastCPULoad.cpu_ticks.0)
            let sysDiff = Double(cpuLoad.cpu_ticks.1 - lastCPULoad.cpu_ticks.1)
            let idleDiff = Double(cpuLoad.cpu_ticks.2 - lastCPULoad.cpu_ticks.2)
            let niceDiff = Double(cpuLoad.cpu_ticks.3 - lastCPULoad.cpu_ticks.3)
            
            let total = userDiff + sysDiff + idleDiff + niceDiff
            if total > 0 {
                let usage = (userDiff + sysDiff + niceDiff) / total * 100.0
                lastCPULoad = cpuLoad
                return usage
            }
        }
        
        lastCPULoad = cpuLoad
        hasLastCPULoad = true
        return 0.0
    }
    
    private func getHostRAMUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }
        
        var totalBytes: UInt64 = 0
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        let mibSize = mib.count
        var mibLength = MemoryLayout<UInt64>.size
        sysctl(&mib, UInt32(mibSize), &totalBytes, &mibLength, nil, 0)
        
        if totalBytes > 0 {
            let pageSize = vm_kernel_page_size
            let active = Double(vmStats.active_count) * Double(pageSize)
            let wire = Double(vmStats.wire_count) * Double(pageSize)
            let usedBytes = active + wire
            return (usedBytes / Double(totalBytes)) * 100.0
        }
        
        return 0.0
    }
    
    private func getNetworkSpeeds() -> (download: Double, upload: Double) {
        let currentBytes = getNetworkBytes()
        let currentTime = Date()
        
        if let last = lastNetBytes {
            let timeDiff = currentTime.timeIntervalSince(lastNetTime)
            if timeDiff > 0.1 {
                let downDiff = Double(currentBytes.ibytes &- last.ibytes)
                let upDiff = Double(currentBytes.obytes &- last.obytes)
                
                let downloadSpeed = downDiff / timeDiff
                let uploadSpeed = upDiff / timeDiff
                
                lastNetBytes = currentBytes
                lastNetTime = currentTime
                return (downloadSpeed, uploadSpeed)
            }
        }
        
        lastNetBytes = currentBytes
        lastNetTime = currentTime
        return (0.0, 0.0)
    }
    
    private func getNetworkBytes() -> (ibytes: UInt64, obytes: UInt64) {
        var ibytes: UInt64 = 0
        var obytes: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: interface.ifa_name)
                    if name.hasPrefix("lo") { continue }
                    if let data = interface.ifa_data {
                        let ifData = data.assumingMemoryBound(to: if_data.self)
                        ibytes += UInt64(ifData.pointee.ifi_ibytes)
                        obytes += UInt64(ifData.pointee.ifi_obytes)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return (ibytes, obytes)
    }
}

struct NotchView: View {
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let onHoverChange: (Bool) -> Void
    
    @StateObject private var batteryManager = BatteryManager()
    @StateObject private var nowPlayingManager = NowPlayingManager()
    @State private var outputDeviceName: String = ""
    @State private var outputDeviceTimer: Timer?
    @State private var activeAppIcon: NSImage?
    @State private var activeAppName: String?
    @State private var activeAppBundleID: String?
    @State private var isHovered = false
    @State private var appActivationObserver: NSObjectProtocol?
    @AppStorage("batterySaverMode") private var batterySaverMode = false
    
    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var clipboardManager = ClipboardManager()
    @State private var copiedFeedbackId: UUID? = nil
    
    private func copyClipboardItem(_ item: ClipboardItem) {
        clipboardManager.copyToPasteboard(item.text)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
            copiedFeedbackId = item.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedFeedbackId == item.id {
                withAnimation {
                    copiedFeedbackId = nil
                }
            }
        }
    }
    
    private func seekToPosition(_ seconds: Double) {
        if nowPlayingManager.prefersSpotifyControls {
            if seekBrowserSpotify(to: seconds) {
                return
            }
        }
        let appName = (nowPlayingManager.effectiveAppName ?? "").lowercased()
        let isSpotifyOnBrave = appName.contains("spotify (brave)")
        if isSpotifyOnBrave {
            if seekBrowserSpotify(to: seconds) {
                return
            }
        }
        nowPlayingManager.seekToPosition(seconds)
    }
    
    private func updateActiveAppIcon() {
        let app = NSWorkspace.shared.frontmostApplication
        let icon = app?.icon?.withMinimalistColors()
        // Defer to next runloop to avoid AttributeGraph cycles during layout/updates.
        DispatchQueue.main.async {
            self.activeAppIcon = icon
            self.activeAppName = app?.localizedName
            self.activeAppBundleID = app?.bundleIdentifier
            self.nowPlayingManager.setFrontmostApp(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        }
    }

    // App carousel removed
    
    private func batteryIconName(level: Int, isCharging: Bool) -> String {
        switch level {
        case 0...15: return "battery.0"
        case 16...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...85: return "battery.75"
        default: return "battery.100"
        }
    }
    
    private func batteryColor(level: Int, isCharging: Bool, isLowPower: Bool) -> Color {
        if isCharging {
            return .green
        } else if isLowPower {
            return .yellow
        } else if level <= 10 {
            return .red
        } else {
            return .white
        }
    }

    private var batteryIconView: some View {
        let level = min(max(batteryManager.batteryLevel, 0), 100)
        let fillRatio = CGFloat(level) / 100.0
        let stroke = batteryColor(level: level, isCharging: batteryManager.isCharging, isLowPower: batteryManager.isLowPowerMode)
        let bodySize = CGSize(width: 18, height: 9)
        let innerSize = CGSize(width: bodySize.width - 2, height: bodySize.height - 2)
        let fillWidth = max(1, innerSize.width * fillRatio)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(stroke, lineWidth: 1)
                .frame(width: bodySize.width, height: bodySize.height)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(stroke)
                .frame(width: fillWidth, height: innerSize.height)
                .padding(1)

            // Battery nub
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(stroke)
                .frame(width: 2, height: 5)
                .offset(x: bodySize.width + 1)

            if batteryManager.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
                    .frame(width: bodySize.width, height: bodySize.height, alignment: .center)
                    .offset(x: 0.5)
            }
        }
    }

    private var miniPlayerTitle: String {
        if let title = nowPlayingManager.effectiveTrackTitle,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let appName = nowPlayingManager.effectiveAppName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }
        return nowPlayingManager.hasMediaRemoteData ? "Now Playing" : "Nothing Playing"
    }

    private var miniPlayerAlbumName: String? {
        let album = nowPlayingManager.effectiveTrackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let album, !album.isEmpty {
            return album
        }
        return nil
    }

    private var miniPlayerArtistName: String? {
        let artist = nowPlayingManager.effectiveTrackArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artist, !artist.isEmpty {
            return artist
        }
        return nil
    }

    private func miniPlayerArt(size: CGFloat) -> some View {
        Group {
            let art = nowPlayingManager.effectiveArtwork
            if let image = art ?? nowPlayingManager.effectiveAppIcon ?? activeAppIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private enum PlaybackCommand {
        case playPause
        case next
        case previous
    }

    private func runAppleScriptResult(_ source: String, isJavaScript: Bool = false) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if let error = error {
            let errStr = "\(error)"
            if isJavaScript && errStr.contains("-1723") {
                DispatchQueue.main.async {
                    self.nowPlayingManager.isBrowserJSEnabled = false
                }
            }
            return nil
        }
        if isJavaScript {
            DispatchQueue.main.async {
                self.nowPlayingManager.isBrowserJSEnabled = true
            }
        }
        if let s = output.stringValue { return s }
        return output.description
    }

    private func runBrowserSpotifyCommand(_ command: PlaybackCommand) -> Bool {
        let js: String
        switch command {
        case .playPause:
            js = """
            (function(){
              const root = document.querySelector('[data-testid="playback-controls"]') ||
                           document.querySelector('footer') ||
                           document;
              const isVisible = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };
              const findVisible = (selectors) => {
                for (const sel of selectors) {
                  const nodes = Array.from(root.querySelectorAll(sel));
                  const n = nodes.find(isVisible);
                  if (n) return n;
                }
                return null;
              };
              const btn = findVisible([
                '[data-testid="control-button-playpause"]',
                'button[data-testid="control-button-playpause"]',
                '[data-testid="control-button-pause"]',
                '[data-testid="control-button-play"]',
                'button[aria-label="Pause"]',
                'button[aria-label="Play"]',
                'button[aria-label*="Pause"]',
                'button[aria-label*="Play"]'
              ]);
              if (btn) { btn.click(); return true; }
              return false;
            })();
            """
        case .next:
            js = """
            (function(){
              const root = document.querySelector('[data-testid="playback-controls"]') ||
                           document.querySelector('footer') ||
                           document;
              const isVisible = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };
              const btn = Array.from(root.querySelectorAll(
                '[data-testid="control-button-skip-forward"], button[data-testid="control-button-skip-forward"], [data-testid="next-button"], button[aria-label=\"Next\"], button[aria-label*=\"Next\"], button[title*=\"Next\"]'
              )).find(isVisible) || null;
              if (btn) { btn.click(); return true; }
              return false;
            })();
            """
        case .previous:
            js = """
            (function(){
              const root = document.querySelector('[data-testid="playback-controls"]') ||
                           document.querySelector('footer') ||
                           document;
              const isVisible = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };
              const btn = Array.from(root.querySelectorAll(
                '[data-testid="control-button-skip-back"], button[data-testid="control-button-skip-back"], [data-testid="prev-button"], button[aria-label=\"Previous\"], button[aria-label*=\"Previous\"], button[title*=\"Previous\"]'
              )).find(isVisible) || null;
              if (btn) { btn.click(); return true; }
              return false;
            })();
            """
        }
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        tell application "Brave Browser"
            if (count of windows) = 0 then return "false"
            -- Prefer active Spotify tab in the front window first.
            try
                set frontIndex to active tab index of front window
                set frontTab to tab frontIndex of front window
                set frontURL to URL of frontTab
                if frontURL contains "spotify.com" then
                    tell frontTab to set result to execute javascript "\(escaped)"
                    return (result as text)
                end if
            end try
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "spotify.com" then
                            set active tab index of w to (index of t)
                            tell t to set result to execute javascript "\(escaped)"
                            return (result as text)
                        end if
                    end try
                end repeat
            end repeat
            return "false"
        end tell
        """
        let result = runAppleScriptResult(script, isJavaScript: true) ?? "false"
        return result.lowercased().contains("true")
    }

    private func sendPlaybackCommand(_ command: PlaybackCommand) {
        if nowPlayingManager.prefersSpotifyControls {
            let handled = runBrowserSpotifyCommand(command)
            if handled {
                if command == .playPause {
                    nowPlayingManager.noteSpotifyPlayPauseToggle()
                }
                // Trigger immediate metadata refresh after a short delay (0.4s) to capture updates
                let manager = self.nowPlayingManager
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    manager.refreshBrowserFallback(force: true)
                }
                return
            }
        }
        
        let cmd: Int32
        switch command {
        case .playPause: cmd = 2
        case .next: cmd = 4
        case .previous: cmd = 5
        }
        nowPlayingManager.sendCommand(cmd)
    }

    private var miniPlayerControls: some View {
        let isPlayingForButton = playbackButtonIsPlaying
        return HStack(spacing: 12) {
            Button {
                sendPlaybackCommand(.previous)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 11, weight: .semibold))
            }

            Button {
                sendPlaybackCommand(.playPause)
            } label: {
                Image(systemName: isPlayingForButton ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }

            Button {
                sendPlaybackCommand(.next)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.9))
    }

    private var playbackButtonIsPlaying: Bool {
        return nowPlayingManager.effectiveIsPlaying
    }

    private var miniPlayerPanel: some View {
        let outputName = outputDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = nowPlayingManager.trackElapsed
        let duration = nowPlayingManager.trackDuration
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                miniPlayerArt(size: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(miniPlayerTitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    let artistName = miniPlayerArtistName
                    Text(artistName ?? "Unknown Artist")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            
            if nowPlayingManager.prefersSpotifyControls && !nowPlayingManager.isBrowserJSEnabled {
                browserPermissionPanel
                    .padding(.top, 2)
            } else {
                ScrubbableProgressBar(elapsed: elapsed, duration: duration) { newTime in
                    seekToPosition(newTime)
                }
                .padding(.vertical, 2)
                
                HStack {
                    Text(formatTime(elapsed))
                        .font(.system(size: 7, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    if duration > 0 {
                        Text(formatTime(duration))
                            .font(.system(size: 7, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .offset(y: -4)
                
                HStack {
                    miniPlayerControls
                    
                    Spacer()
                    
                    if !outputName.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 7))
                            Text(outputName.prefix(12) + (outputName.count > 12 ? ".." : ""))
                                .font(.system(size: 7, weight: .medium, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white.opacity(0.4))
                    }
                }
                .offset(y: -4)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 160, height: 140, alignment: .topLeading)
    }

    private var clipboardPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CLIPBOARD")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(1)
                Spacer()
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.3))
            }
            
            if clipboardManager.items.isEmpty {
                VStack {
                    Spacer()
                    Text("No items copied")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
                .frame(height: 105)
            } else {
                VStack(spacing: 4) {
                    ForEach(clipboardManager.items) { item in
                        Button {
                            copyClipboardItem(item)
                        } label: {
                            HStack {
                                Text(item.text.prefix(22) + (item.text.count > 22 ? "..." : ""))
                                    .font(.system(size: 9, weight: .regular, design: .rounded))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                if copiedFeedbackId == item.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundColor(.green)
                                        .transition(.scale.combined(with: .opacity))
                                } else {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 7))
                                        .foregroundColor(.white.opacity(0.2))
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(copiedFeedbackId == item.id ? 0.08 : 0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 105, alignment: .top)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 140, height: 140, alignment: .topLeading)
    }

    private var systemMonitorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SYSTEM")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("CPU")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f%%", systemMonitor.cpuUsage))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: CGFloat(min(max(systemMonitor.cpuUsage / 100.0, 0), 1)) * 120, height: 4)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("RAM")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f%%", systemMonitor.ramUsage))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: CGFloat(min(max(systemMonitor.ramUsage / 100.0, 0), 1)) * 120, height: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Text(formatSpeed(systemMonitor.downloadSpeed))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Text(formatSpeed(systemMonitor.uploadSpeed))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 140, height: 140, alignment: .topLeading)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        } else if bytesPerSecond >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    private func seekBrowserSpotify(to seconds: Double) -> Bool {
        let duration = nowPlayingManager.trackDuration
        guard duration > 0 else { return false }
        let ratio = seconds / duration
        
        let js = """
        (function(){
          const progressBar = document.querySelector('[data-testid="progress-bar"]');
          if (progressBar) {
            const rect = progressBar.getBoundingClientRect();
            const clickX = rect.left + (rect.width * \(ratio));
            const clickY = rect.top + (rect.height / 2);
            
            const options = { clientX: clickX, clientY: clickY, bubbles: true, pointerId: 1, pointerType: 'mouse', isPrimary: true };
            
            progressBar.dispatchEvent(new PointerEvent('pointerdown', options));
            progressBar.dispatchEvent(new MouseEvent('mousedown', options));
            progressBar.dispatchEvent(new PointerEvent('pointerup', options));
            progressBar.dispatchEvent(new MouseEvent('mouseup', options));
            progressBar.dispatchEvent(new MouseEvent('click', options));
            return true;
          }
          return false;
        })();
        """
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        tell application "Brave Browser"
            if (count of windows) = 0 then return "false"
            try
                set frontIndex to active tab index of front window
                set frontTab to tab frontIndex of front window
                set frontURL to URL of frontTab
                if frontURL contains "spotify.com" then
                    tell frontTab to set result to execute javascript "\(escaped)"
                    return (result as text)
                end if
            end try
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "spotify.com" then
                            tell t to set result to execute javascript "\(escaped)"
                            return (result as text)
                        end if
                    end try
                end repeat
            end repeat
            return "false"
        end tell
        """
        let result = runAppleScriptResult(script, isJavaScript: true) ?? "false"
        return result.lowercased().contains("true")
    }

    private var browserPermissionPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 10))
                Text("Brave Spotify Integration")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            
            Text("Enable 'Allow JavaScript from Apple Events' in Brave's 'View' > 'Developer' menu.")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(8)
        .frame(width: 140, alignment: .leading)
    }

    private var appIconView: some View {
        Group {
            let art = nowPlayingManager.nowPlayingArtwork
            if !isHovered, nowPlayingManager.isPlaying, let artwork = art {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFit()
            } else if let image = nowPlayingManager.nowPlayingAppIconSmall
                        ?? nowPlayingManager.nowPlayingAppIcon
                        ?? activeAppIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 20, height: 20, alignment: .center)
        .offset(y: -2)
        .transaction { $0.animation = nil }
    }

    private var pulseRingView: some View {
        ZStack {
            PulseRing(delay: 0.0)
            PulseRing(delay: 0.45)
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20, alignment: .center)
        .offset(y: -2)
    }

    private var barsView: some View {
        let isPlaying = nowPlayingManager.effectiveIsPlaying
        return HStack(alignment: .bottom, spacing: 2) {
            VisualizerBar(delay: 0.0, minVal: 0.25, maxVal: 0.95, isPlaying: isPlaying)
            VisualizerBar(delay: 0.12, minVal: 0.15, maxVal: 0.85, isPlaying: isPlaying)
            VisualizerBar(delay: 0.24, minVal: 0.35, maxVal: 1.0, isPlaying: isPlaying)
            VisualizerBar(delay: 0.36, minVal: 0.2, maxVal: 0.9, isPlaying: isPlaying)
            VisualizerBar(delay: 0.48, minVal: 0.3, maxVal: 0.8, isPlaying: isPlaying)
        }
        .frame(width: 20, height: 18, alignment: .bottom)
        .id(isPlaying)
    }

    private var compactPlayingIndicator: some View {
        Image(systemName: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .frame(width: 20, height: 20, alignment: .center)
            .offset(y: -2)
    }

    private var isFrontmostBrowser: Bool {
        let id = activeAppBundleID?.lowercased() ?? ""
        let n = activeAppName?.lowercased() ?? ""
        return id.contains("brave") || id.contains("chrome") || id.contains("edge") || id.contains("safari") || id.contains("arc")
            || n.contains("brave") || n.contains("chrome") || n.contains("edge") || n.contains("safari") || n.contains("arc")
    }

    private func updateFallbackPollingForCurrentState() {
        if isHovered {
            nowPlayingManager.startFallbackPolling(interval: batterySaverMode ? 30.0 : 12.0)
            return
        }
        if batterySaverMode {
            nowPlayingManager.stopFallbackPolling()
            return
        }
        if nowPlayingManager.effectiveIsPlaying {
            nowPlayingManager.startFallbackPolling(interval: 45.0)
        } else {
            nowPlayingManager.stopFallbackPolling()
        }
    }
    
    var body: some View {
        let shouldShowPlayer = isHovered
        ZStack(alignment: .top) {
            Group {
                NotchShape()
                    .fill(Color.black)
                    .ignoresSafeArea()
                    .frame(
                        width: shouldShowPlayer ? expandedWidth : baseWidth,
                        height: shouldShowPlayer ? expandedHeight : baseHeight
                    )
                    .overlay(
                        HStack(alignment: .top, spacing: 14) {
                            if shouldShowPlayer {
                                // Column 1: Media Player Panel
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        if nowPlayingManager.effectiveIsPlaying {
                                            barsView
                                        } else {
                                            appIconView
                                        }
                                        Text("PLAYER")
                                            .font(.system(size: 8, weight: .bold, design: .rounded))
                                            .foregroundColor(.white.opacity(0.4))
                                            .tracking(1)
                                    }
                                    .frame(height: 20)
                                    
                                    miniPlayerPanel
                                }
                                
                                // Column 2: Clipboard Panel
                                clipboardPanel
                                
                                // Column 3: System Stats Panel
                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Button {
                                            batterySaverMode.toggle()
                                        } label: {
                                            Image(systemName: batterySaverMode ? "leaf.fill" : "leaf")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(batterySaverMode ? .green : .white.opacity(0.8))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.white.opacity(0.08))
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Button {
                                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text("\(batteryManager.batteryLevel)%")
                                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                                    .foregroundColor(.white)
                                                batteryIconView
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .frame(height: 20)
                                    
                                    systemMonitorPanel
                                }
                            } else {
                                // Collapsed View
                                HStack(alignment: .center) {
                                    if nowPlayingManager.effectiveIsPlaying {
                                        compactPlayingIndicator
                                            .offset(y: -2)
                                    } else {
                                        appIconView
                                            .offset(y: -2)
                                    }
                                    
                                    Spacer(minLength: 0)
                                    
                                    HStack(spacing: 4) {
                                        Text("\(batteryManager.batteryLevel)%")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                            .offset(y: -1)
                                        
                                        batteryIconView
                                    }
                                    .offset(y: -2)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.leading, shouldShowPlayer ? 20 : 18)
                        .padding(.trailing, shouldShowPlayer ? 29 : 18)
                        .frame(
                            width: shouldShowPlayer ? (expandedWidth - 5) : baseWidth,
                            height: shouldShowPlayer ? expandedHeight : baseHeight,
                            alignment: .top
                        ),
                        alignment: shouldShowPlayer ? .topTrailing : .center
                    )
            }
            .offset(x: shouldShowPlayer ? 0 : 2.5, y: 1)
        .onHover { hovering in
            debugLog("[DEBUG] NotchView: onHover change: \(hovering), batterySaverMode=\(batterySaverMode)")
            isHovered = hovering
            onHoverChange(hovering)
            if hovering {
                nowPlayingManager.startFallbackPolling(interval: batterySaverMode ? 30.0 : 12.0)
                systemMonitor.startMonitoring(interval: batterySaverMode ? 5.0 : 1.5)
                updateOutputDeviceName()
                if outputDeviceTimer == nil {
                    outputDeviceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                        updateOutputDeviceName()
                    }
                }
            } else {
                updateFallbackPollingForCurrentState()
                systemMonitor.stopMonitoring()
                outputDeviceTimer?.invalidate()
                outputDeviceTimer = nil
            }
        }
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: shouldShowPlayer)
            
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
        .onAppear {
            if appActivationObserver == nil {
                updateActiveAppIcon()
                appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    updateActiveAppIcon()
                }
            }
            onHoverChange(isHovered)
            updateOutputDeviceName()
            updateFallbackPollingForCurrentState()
            if isHovered {
                systemMonitor.startMonitoring(interval: batterySaverMode ? 5.0 : 1.5)
            }
        }
        .onChange(of: nowPlayingManager.effectiveIsPlaying) { _, playing in
            if playing {
                updateFallbackPollingForCurrentState()
            } else if !isHovered {
                nowPlayingManager.stopFallbackPolling()
            }
        }
        .onChange(of: batterySaverMode) { _, saver in
            updateFallbackPollingForCurrentState()
            if isHovered {
                systemMonitor.startMonitoring(interval: saver ? 5.0 : 1.5)
            }
        }
        .onDisappear {
            if let appActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
                self.appActivationObserver = nil
            }
            outputDeviceTimer?.invalidate()
            outputDeviceTimer = nil
        }
    }

    private var miniPlayerProgress: some View {
        let duration = nowPlayingManager.trackDuration
        let elapsed = nowPlayingManager.trackElapsed
        let ratio = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.15))
                .frame(height: 2)
            Capsule()
                .fill(Color.white.opacity(0.7))
                .frame(width: CGFloat(ratio) * max(1, 120), height: 2)
        }
        .frame(height: 2)
    }

    private var miniPlayerTimeText: String? {
        let duration = nowPlayingManager.trackDuration
        if duration <= 0 { return nil }
        let elapsed = max(0, nowPlayingManager.trackElapsed)
        return "\(formatTime(elapsed)) / \(formatTime(duration))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    private func updateOutputDeviceName() {
        if let name = Self.defaultOutputDeviceName() {
            outputDeviceName = name
        }
    }

    private static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        if status != noErr { return nil }

        var name: Unmanaged<CFString>? = nil
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status2 = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &size,
            &name
        )
        if status2 != noErr { return nil }
        return name?.takeUnretainedValue() as String?
    }
}

struct PulseRing: View {
    let delay: Double
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            .scaleEffect(animate ? 1.0 : 0.4)
            .opacity(animate ? 0.0 : 0.7)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.2)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    animate = true
                }
            }
    }
}

struct VisualizerBar: View {
    let delay: Double
    let minVal: CGFloat
    let maxVal: CGFloat
    let isPlaying: Bool
    
    @State private var currentScale: CGFloat = 0.2
    
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white.opacity(0.9))
            .frame(width: 1.5, height: 18)
            .scaleEffect(x: 1.0, y: isPlaying ? currentScale : minVal, anchor: .bottom)
            .onAppear {
                currentScale = minVal
                if isPlaying {
                    triggerAnimation()
                }
            }
            .onChange(of: isPlaying) { _, playing in
                if playing {
                    triggerAnimation()
                }
            }
    }
    
    private func triggerAnimation() {
        withAnimation(
            .easeInOut(duration: Double.random(in: 0.4...0.8))
            .repeatForever(autoreverses: true)
            .delay(delay)
        ) {
            currentScale = maxVal
        }
    }
}

struct ScrubbableProgressBar: View {
    let elapsed: Double
    let duration: Double
    let onScrub: (Double) -> Void

    @State private var dragProgress: Double? = nil

    var body: some View {
        let displayProgress = dragProgress ?? (duration > 0 ? elapsed / duration : 0)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 3)

                Capsule()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: CGFloat(displayProgress) * geo.size.width, height: 3)

                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .offset(x: CGFloat(displayProgress) * geo.size.width - 4)
                    .shadow(color: Color.black.opacity(0.5), radius: 1)
            }
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let locationX = value.location.x
                        let pct = min(max(0, locationX / geo.size.width), 1)
                        dragProgress = Double(pct)
                    }
                    .onEnded { value in
                        if let progress = dragProgress {
                            onScrub(progress * duration)
                        }
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 8)
    }
}

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let cornerRadius: CGFloat = 16
        
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 0),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )
        
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 180),
            clockwise: false
        )
        
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        
        return path
    }
}
