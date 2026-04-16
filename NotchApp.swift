import Cocoa
import SwiftUI
import CoreImage
import CoreAudio
import IOKit.hid
import ApplicationServices
import Foundation
import AVFoundation
import IOKit.ps

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
    @Published var isPlaying: Bool = false
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
    @Published var fallbackIsPlaying: Bool = false
    @Published var fallbackPlaybackState: String = ""
    @Published var fallbackLastUpdateAt: Date = .distantPast
    @Published var lastKnownTrackTitle: String?
    @Published var lastKnownTrackArtist: String?
    @Published var lastKnownTrackAlbum: String?
    @Published var lastKnownArtwork: NSImage?

    private let bundle: CFBundle?
    private let queue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var fallbackPollInterval: TimeInterval = 12.0
    private var frontmostBundleID: String?
    private var frontmostAppName: String?
    private var lastFallbackArtworkURL: String?
    private var lastDirectFallbackArtworkURL: String?
    private var lastFallbackWasSpotify: Bool = false

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
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let b = CFBundleCreate(kCFAllocatorDefault, url)
        bundle = b

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let b else { return nil }
            guard let ptr = CFBundleGetFunctionPointerForName(b, name as CFString) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }

        mrRegister = load("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterFn.self)
        mrGetPID = load("MRMediaRemoteGetNowPlayingApplicationPID", as: MRGetPIDFn.self)
        mrGetIsPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: MRGetIsPlayingFn.self)
        mrGetNowPlayingInfo = load("MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfoFn.self)
        mrSendCommand = load("MRMediaRemoteSendCommand", as: MRSendCommandFn.self)

        if mrRegister != nil {
            mrRegister?(queue)
            let names = [
                "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            ]
            for n in names {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSNotification.Name(rawValue: n),
                        object: nil, queue: .main
                    ) { [weak self] _ in self?.refresh() }
                )
            }
        }
        refresh()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func refresh() {
        guard let mrGetIsPlaying = mrGetIsPlaying,
              let mrGetPID = mrGetPID,
              let mrGetNowPlayingInfo = mrGetNowPlayingInfo else { return }

        mrGetIsPlaying(queue) { [weak self] playing in
            guard let self = self else { return }
            self.isPlaying = playing
            
            mrGetPID(self.queue) { pid in
                DispatchQueue.main.async {
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
                    self.trackTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                    self.trackArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                    self.trackAlbum = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
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
        let normalizedInterval = max(3.0, interval)
        if let timer = fallbackTimer {
            if abs(fallbackPollInterval - normalizedInterval) < 0.01 { return }
            timer.invalidate()
            fallbackTimer = nil
        }
        fallbackPollInterval = normalizedInterval
        refreshBrowserFallback()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: normalizedInterval, repeats: true) { [weak self] _ in
            self?.refreshBrowserFallback()
        }
    }

    func stopFallbackPolling() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func refreshBrowserFallback() {
        guard shouldUseBrowserFallback() else {
            // Keep recent data visible when switching away from the browser.
            if hasRecentFallback() { return }
            clearFallback()
            return
        }

        if let meta = runAppleScript(browserSpotifyTabMetadataScript()) {
            let parts = meta.components(separatedBy: "|||")
            if parts.count >= 6 {
                let title = parts[0]
                let artist = parts[1]
                let album = parts[2]
                let artworkURL = parts[3]
                let playbackState = parts[4]
                let url = parts[5]
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
                        if !playbackState.isEmpty {
                            self.fallbackIsPlaying = playbackState.lowercased() == "playing"
                            self.fallbackPlaybackState = playbackState
                        }
                        self.fallbackLastUpdateAt = Date()
                    }
                    fetchDirectFallbackArtworkIfNeeded(artworkURLString: artworkURL)
                    fetchFallbackArtworkIfNeeded(pageURLString: url)
                    return
                }
            }
        }

        var title = ""
        var artist = ""
        var artworkURL = ""
        var url = ""
        var playbackState = ""

        if let rich = runAppleScript(browserNowPlayingRichScript()) {
            let parts = rich.components(separatedBy: "|||")
            if parts.count >= 6 {
                title = parts[0]
                artist = parts[1]
                artworkURL = parts[3]
                playbackState = parts[4]
                url = parts[5]
            }
        }

        if url.isEmpty {
            guard let result = runAppleScript(browserNowPlayingScript()) else {
                clearFallback()
                return
            }

            let parts = result.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count < 3 {
                clearFallback()
                return
            }

            title = String(parts[0])
            url = String(parts[2])
        }

        if !url.contains("spotify.com") {
            // Try to find any Spotify tab in Brave and use that instead.
            if let found = runAppleScript(browserFindSpotifyTabScript()) {
                let parts = found.components(separatedBy: "|||")
                if parts.count >= 2 {
                    title = parts[0]
                    url = parts[1]
                }
            }
        }
        guard url.contains("spotify.com") else {
            lastFallbackWasSpotify = false
            // If Brave is still running, keep last known info rather than clearing.
            if isBraveRunning() { return }
            clearFallback()
            return
        }
        lastFallbackWasSpotify = true

        let parsed = parseSpotifyTitle(title)
        let newTitle = parsed.title ?? (title.isEmpty ? nil : title)
        let newArtist = parsed.artist ?? (artist.isEmpty ? nil : artist)
        let isTrackURL = url.contains("/track/")
        let hasMediaSession = !playbackState.isEmpty || !artworkURL.isEmpty
        let isPlayingFlag = playbackState.lowercased() == "playing"
        let generic = isGenericSpotifyTitle(newTitle)
        // Only accept updates when we have strong signals. Otherwise keep last known.
        let shouldUpdateText = (newTitle != nil &&
            (newArtist != nil || isTrackURL || hasMediaSession || isPlayingFlag) &&
            !(generic))
        DispatchQueue.main.async {
            if shouldUpdateText {
                self.fallbackTrackTitle = newTitle
                self.fallbackTrackArtist = newArtist
                if let t = newTitle, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.lastKnownTrackTitle = t
                }
                if let a = newArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.lastKnownTrackArtist = a
                }
            }
            self.fallbackAppName = "Spotify (Brave)"
            self.fallbackAppIcon = self.braveIcon()
            if !playbackState.isEmpty {
                self.fallbackIsPlaying = playbackState.lowercased() == "playing"
                self.fallbackPlaybackState = playbackState
            } else if shouldUpdateText {
                self.fallbackIsPlaying = !(title.isEmpty && artist.isEmpty && artworkURL.isEmpty)
            }
            self.fallbackLastUpdateAt = Date()
        }

        fetchDirectFallbackArtworkIfNeeded(artworkURLString: artworkURL)

        fetchFallbackArtworkIfNeeded(pageURLString: url)
    }

    private func shouldUseBrowserFallback() -> Bool {
        let id = frontmostBundleID?.lowercased() ?? ""
        let name = frontmostAppName?.lowercased() ?? ""
        return id.contains("brave") || name.contains("brave") || hasRecentFallback() || isBraveRunning()
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
        if lastFallbackWasSpotify { return true }
        if fallbackTrackTitle != nil && isBraveRunning() { return true }
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
        }
        lastDirectFallbackArtworkURL = nil
    }

    private func browserNowPlayingScript() -> String {
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            set theTab to active tab of front window
            set theTitle to title of theTab
            set theURL to URL of theTab
            return theTitle & "||" & theURL
        end tell
        """
    }

    private func browserNowPlayingRichScript() -> String {
        let js = """
        (function(){
          const ms = (navigator.mediaSession && navigator.mediaSession.metadata) ? navigator.mediaSession.metadata : null;
          const playback = (navigator.mediaSession && navigator.mediaSession.playbackState) ? navigator.mediaSession.playbackState : '';
          const title = (ms && ms.title) ? ms.title : '';
          const artist = (ms && ms.artist) ? ms.artist : '';
          const album = (ms && ms.album) ? ms.album : '';
          let artwork = '';
          if (ms && ms.artwork && ms.artwork.length) {
            const last = ms.artwork[ms.artwork.length - 1];
            artwork = last && last.src ? last.src : '';
          }
          return [title, artist, album, artwork, playback].join('|||');
        })();
        """
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            set theTab to active tab of front window
            set theURL to URL of theTab
            set result to execute javascript "\(escaped)" in theTab
            return result & "|||" & theURL
        end tell
        """
    }

    private func browserFindSpotifyTabScript() -> String {
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
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

    private func browserSpotifyTabMetadataScript() -> String {
        let js = """
        (function(){
          const ms = (navigator.mediaSession && navigator.mediaSession.metadata) ? navigator.mediaSession.metadata : null;
          const title = (ms && ms.title) ? ms.title : '';
          const artist = (ms && ms.artist) ? ms.artist : '';
          const album = (ms && ms.album) ? ms.album : '';
          let artwork = '';
          if (ms && ms.artwork && ms.artwork.length) {
            const last = ms.artwork[ms.artwork.length - 1];
            artwork = last && last.src ? last.src : '';
          }
          let playback = (navigator.mediaSession && navigator.mediaSession.playbackState) ? navigator.mediaSession.playbackState : '';
          if (!playback) {
            const btn = document.querySelector('[data-testid="control-button-playpause"]') ||
                        document.querySelector('button[aria-label="Play"]') ||
                        document.querySelector('button[aria-label="Pause"]');
            const label = btn ? (btn.getAttribute('aria-label') || '') : '';
            if (label.toLowerCase().includes('play')) playback = 'paused';
            if (label.toLowerCase().includes('pause')) playback = 'playing';
          }
          return [title, artist, album, artwork, playback].join('|||');
        })();
        """
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            -- Prefer track tabs first
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "open.spotify.com/track/" then
                            set result to execute javascript "\(escaped)" in t
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
                            set result to execute javascript "\(escaped)" in t
                            return result & "|||" & theURL
                        end if
                    end try
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
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
        
        let expandedWidth: CGFloat = (screenRect.width * 0.25) + 50
        let expandedHeight: CGFloat = 198
        
        // The *window* needs to be large enough to contain the *expanded* notch, even when it's small.
        // Otherwise, the notch will clip when it animates open.
        // We position this invisible bounding box at the top center.
        let windowRect = NSRect(
            x: (screenRect.width - expandedWidth) / 2.0,
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
    @State private var runningApps: [NSRunningApplication] = []
    @State private var appListTimer: Timer?
    @State private var appListObserverTokens: [NSObjectProtocol] = []
    @State private var appIconCache: [pid_t: NSImage] = [:]
    @State private var activeAppIcon: NSImage?
    @State private var activeAppName: String?
    @State private var activeAppBundleID: String?
    @State private var isHovered = false
    @State private var appActivationObserver: NSObjectProtocol?
    @AppStorage("batterySaverMode") private var batterySaverMode = true
    
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

    private func updateRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { $0.isTerminated == false }

        // De-dupe by bundle id, prefer active instance
        var seen: Set<String> = []
        var deduped: [NSRunningApplication] = []
        for app in apps {
            let id = app.bundleIdentifier ?? "\(app.processIdentifier)"
            if seen.contains(id) { continue }
            seen.insert(id)
            deduped.append(app)
        }

        let newIDs = deduped.map { $0.processIdentifier }
        let currentIDs = runningApps.map { $0.processIdentifier }
        if newIDs == currentIDs { return }
        DispatchQueue.main.async {
            self.runningApps = deduped
            var newCache: [pid_t: NSImage] = [:]
            for app in deduped {
                if let existing = self.appIconCache[app.processIdentifier] {
                    newCache[app.processIdentifier] = existing
                } else if let icon = app.icon {
                    newCache[app.processIdentifier] = icon
                }
            }
            self.appIconCache = newCache
        }
    }

    private var appCarouselView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    Button {
                        app.activate()
                    } label: {
                        if let icon = appIconCache[app.processIdentifier] ?? app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "app")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 120, height: 26)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .offset(y: 28)
        .transaction { $0.animation = nil }
    }
    
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

    private var miniPlayerArt: some View {
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
                    .padding(6)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: 60, height: 60)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private enum PlaybackCommand {
        case playPause
        case next
        case previous
    }

    private func runAppleScriptResult(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return output.stringValue
    }

    private func runBrowserSpotifyCommand(_ command: PlaybackCommand) -> Bool {
        let js: String
        switch command {
        case .playPause:
            js = """
            (function(){
              const btn = document.querySelector('[data-testid="control-button-playpause"]') ||
                          document.querySelector('button[aria-label="Play"]') ||
                          document.querySelector('button[aria-label="Pause"]');
              if (btn) { btn.click(); return true; }
              return false;
            })();
            """
        case .next:
            js = """
            (function(){
              const btn = document.querySelector('[data-testid="control-button-skip-forward"]') ||
                          document.querySelector('button[aria-label="Next"]');
              if (btn) { btn.click(); return true; }
              return false;
            })();
            """
        case .previous:
            js = """
            (function(){
              const btn = document.querySelector('[data-testid="control-button-skip-back"]') ||
                          document.querySelector('button[aria-label="Previous"]');
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
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set theURL to URL of t
                        if theURL contains "spotify.com" then
                            set result to execute javascript "\(escaped)" in t
                            return result
                        end if
                    end try
                end repeat
            end repeat
            return "false"
        end tell
        """
        let result = runAppleScriptResult(script) ?? "false"
        return result.lowercased().contains("true")
    }

    private func sendPlaybackCommand(_ command: PlaybackCommand) {
        if nowPlayingManager.prefersSpotifyControls {
            if runBrowserSpotifyCommand(command) {
                return
            }
        }
        let cmd: Int32
        switch command {
        case .playPause: cmd = 2 // kMRTogglePlayPause
        case .next: cmd = 4 // kMRNextTrack
        case .previous: cmd = 5 // kMRPreviousTrack
        }
        nowPlayingManager.sendCommand(cmd)
    }

    private var miniPlayerControls: some View {
        HStack(spacing: 12) {
            Button {
                sendPlaybackCommand(.previous)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 11, weight: .semibold))
            }

            Button {
                sendPlaybackCommand(.playPause)
            } label: {
                Image(systemName: nowPlayingManager.effectiveIsPlaying ? "pause.fill" : "play.fill")
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

    private var miniPlayerPanel: some View {
        let sidePadding: CGFloat = 20
        let rightReserve: CGFloat = 80
        let leftIconWidth: CGFloat = 20
        let calculatedWidth = max(180, expandedWidth - (sidePadding * 2) - rightReserve - leftIconWidth)
        let maxPanelWidth = min(expandedWidth / 3.0, calculatedWidth)
        let verticalPadding: CGFloat = 14
        let outputName = outputDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaying = nowPlayingManager.effectiveIsPlaying
        let stackSpacing: CGFloat = 6
        return VStack(alignment: .leading, spacing: stackSpacing) {
            HStack(alignment: .top, spacing: 10) {
                miniPlayerArt
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(miniPlayerTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    let albumName = miniPlayerAlbumName
                    if let albumName, !albumName.isEmpty {
                        Text(albumName)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    let artistName = miniPlayerArtistName
                    Text(artistName ?? " ")
                        .font(.system(size: artistName == nil ? 9 : 10, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .opacity(isPlaying ? (artistName == nil ? 0 : 1) : 0)

                    if let timeText = miniPlayerTimeText {
                        Text(timeText)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }

                    if let year = nowPlayingManager.trackReleaseYear, !year.isEmpty {
                        Text("Year \(year)")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        Text("Year —")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }

                    if let quality = nowPlayingManager.trackQuality, !quality.isEmpty {
                        Text("Quality \(quality)")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    } else {
                        Text("Quality —")
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
            }
            
            miniPlayerControls
                .padding(.top, 4)
                        
            if !outputName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(outputName)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 2)
            }
        }
        .offset(x: -6, y: -6)
        .padding(.top, 14)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: maxPanelWidth, maxHeight: expandedHeight - 4, alignment: .topLeading)
    }

    private var browserPermissionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enable Spotify in browser")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            Text("Allow Notch to read the active tab.")
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            Button {
            } label: {
                Text("Enable")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 230, alignment: .leading)
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
        return HStack(alignment: .bottom, spacing: 2) {
            VisualizerBar(delay: 0.0, min: 0.25, max: 0.95)
            VisualizerBar(delay: 0.12, min: 0.15, max: 0.85)
            VisualizerBar(delay: 0.24, min: 0.35, max: 1.0)
            VisualizerBar(delay: 0.36, min: 0.2, max: 0.9)
            VisualizerBar(delay: 0.48, min: 0.3, max: 0.8)
        }
        .frame(width: 20, height: 18, alignment: .bottom)
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
            nowPlayingManager.startFallbackPolling(interval: 5.0)
            return
        }
        if batterySaverMode {
            nowPlayingManager.stopFallbackPolling()
            return
        }
        if nowPlayingManager.effectiveIsPlaying {
            nowPlayingManager.startFallbackPolling(interval: 15.0)
        } else {
            nowPlayingManager.stopFallbackPolling()
        }
    }
    
    var body: some View {
        let shouldShowPlayer = isHovered
        // We place the expanding notch inside an invisible frame the exact size of the maximum window.
        // We align it to the top so it "drops down" strictly from the menu bar edge.
        ZStack(alignment: .top) {
            
            // The expanding black notch area
            Group {
                NotchShape()
                    .fill(Color.black)
                    .ignoresSafeArea()
                    .frame(
                        width: shouldShowPlayer ? expandedWidth : baseWidth,
                        height: shouldShowPlayer ? expandedHeight : baseHeight
                    )
                    .overlay(
                        // Use edge-aligned layout (avoids layout cycles from .position())
                        HStack(alignment: .top) {
                            // Left: Active app icon
                            Group {
                                if shouldShowPlayer {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if nowPlayingManager.effectiveIsPlaying {
                                            barsView
                                                .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? -1 : -4)
                                        } else {
                                            appIconView
                                                .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? 0 : -3)
                                        }
                                        miniPlayerPanel
                                        if false {
                                            browserPermissionPanel
                                        }
                                    }
                                } else {
                                    if nowPlayingManager.effectiveIsPlaying {
                                        compactPlayingIndicator
                                            .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? -1 : -4)
                                    } else {
                                        appIconView
                                            .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? 0 : -3)
                                    }
                                }
                            }
                            .padding(.top, 6)
                            
                            Spacer(minLength: 0)

                            // Middle: App carousel
                            if shouldShowPlayer {
                                appCarouselView
                            }
                            
                            // Right: Battery
                            HStack(spacing: 8) {
                                if shouldShowPlayer {
                                    Button {
                                        batterySaverMode.toggle()
                                        updateFallbackPollingForCurrentState()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: batterySaverMode ? "leaf.fill" : "leaf")
                                                .font(.system(size: 9, weight: .semibold))
                                            Text("Saver")
                                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        }
                                        .foregroundColor(batterySaverMode ? .green : .white.opacity(0.8))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                                        NSWorkspace.shared.open(url)
                                    }
                                } label: {
                                    HStack(alignment: .center, spacing: 4) {
                                        Text("\(batteryManager.batteryLevel)%")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundColor(.white)
                                            .padding(.top, 1) // slight baseline adjustment
                                        
                                        batteryIconView
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(height: 28, alignment: .center)
                            .padding(.top, 2)
                            .offset(y: shouldShowPlayer ? 0 : -3)
                        }
                        // These paddings are tuned to sit inside the notch "corner" area.
                        .padding(.top, 4)
                        .padding(.leading, shouldShowPlayer ? 20 : 18)
                        .padding(.trailing, shouldShowPlayer ? 29 : 18)
                        .frame(
                            width: shouldShowPlayer ? expandedWidth : baseWidth,
                            height: shouldShowPlayer ? expandedHeight : baseHeight,
                            alignment: .top
                        )
                    )
            }
            .offset(y: 1)
            // Trigger the animation whenever the mouse enters/leaves this specific shape
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
            if hovering {
                nowPlayingManager.startFallbackPolling(interval: 5.0)
                if appListTimer == nil {
                    updateRunningApps()
                    appListTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
                        updateRunningApps()
                    }
                }
                updateOutputDeviceName()
                if outputDeviceTimer == nil {
                    outputDeviceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                        updateOutputDeviceName()
                    }
                }
            } else {
                updateFallbackPollingForCurrentState()
                appListTimer?.invalidate()
                appListTimer = nil
                outputDeviceTimer?.invalidate()
                outputDeviceTimer = nil
            }
            if hovering && isFrontmostBrowser {
            }
        }
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: shouldShowPlayer)
            
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
        .onAppear {
            // Ensure we only register once for this view lifetime.
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
            updateRunningApps()
            let ws = NSWorkspace.shared.notificationCenter
            appListObserverTokens = [
                ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
                    if self.isHovered {
                        updateRunningApps()
                    }
                },
                ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
                    if self.isHovered {
                        updateRunningApps()
                    }
                }
            ]
        }
        .onChange(of: nowPlayingManager.effectiveIsPlaying) { _, playing in
            if playing {
                updateFallbackPollingForCurrentState()
            } else if !isHovered {
                nowPlayingManager.stopFallbackPolling()
            }
        }
        .onChange(of: batterySaverMode) { _, _ in
            updateFallbackPollingForCurrentState()
        }
        .onDisappear {
            if let appActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
                self.appActivationObserver = nil
            }
            outputDeviceTimer?.invalidate()
            outputDeviceTimer = nil
            appListTimer?.invalidate()
            appListTimer = nil
            for t in appListObserverTokens {
                NSWorkspace.shared.notificationCenter.removeObserver(t)
            }
            appListObserverTokens = []
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
    let min: CGFloat
    let max: CGFloat
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white.opacity(0.9))
            .frame(width: 1.5, height: 18)
            .scaleEffect(x: 1.0, y: animate ? max : min, anchor: .bottom)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.65)
                    .repeatForever(autoreverses: true)
                    .delay(delay)
                ) {
                    animate = true
                }
            }
    }
}

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let cornerRadius: CGFloat = 16
        
        // In macOS SwiftUI, the coordinate system (0,0) is at the bottom left by default,
        // BUT when drawn inside a Shape, (0,0) is often at the top-left depending on context.
        // If the corners appeared sharp, it means that the rounded parts were drawn outside the visible frame
        // or the path is drawn upside down. Let's explicitly draw it from the top-left (0,0).
        
        // Start at top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        
        // Line to top right
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        
        // Line to bottom right (before corner)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        
        // Bottom right rounded corner
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 0),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )
        
        // Line to bottom left (before corner)
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        
        // Bottom left rounded corner
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 180),
            clockwise: false
        )
        
        // Line back to top left
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        
        return path
    }
}
