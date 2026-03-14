import Cocoa
import SwiftUI
import CoreImage
import CoreAudio
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
    @Published var nowPlayingAppName: String?
    @Published var isEligibleSource: Bool = false
    @Published var isBrowserSource: Bool = false
    @Published var cachedTrackTitle: String?
    @Published var cachedTrackArtist: String?
    @Published var cachedTrackAlbum: String?
    @Published var cachedArtwork: NSImage?
    @Published var lastControllableSource: String?

    private let bundle: CFBundle?
    private let queue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastBraveTabURL: String?
    private var lastBraveFetchAt: Date = .distantPast
    private var lastVoxTrackURL: String?
    private var lastVoxFetchAt: Date = .distantPast
    private var lastVoxFallbackKey: String?
    private var lastVoxArtworkUpdateAt: Date = .distantPast
    private var lastVoxTrackKey: String?
    private var lastVoxPlayerState: Int = -1
    private var lastVoxInfoAt: Date = .distantPast
    private var lastVoxActiveAt: Date = .distantPast
    private var lastSourceBundleID: String?
    private var lastAudioSeenAt: Date = .distantPast
    @Published var lastTrackUpdateAt: Date = .distantPast
    @Published var lastArtworkUpdateAt: Date = .distantPast
    private var lastSpotifyWebEligibleAt: Date = .distantPast
    @Published var lastPermissionRequestAt: Date = .distantPast
    private var lastBraveMetaFetchAt: Date = .distantPast
    private var lastBraveMetaKey: String?
    private let didRequestBrowserPermissionKey = "NotchDidRequestBrowserPermission"

    private typealias MRRegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias MRGetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias MRGetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

    private let mrRegister: MRRegisterFn?
    private let mrGetPID: MRGetPIDFn?
    private let mrGetIsPlaying: MRGetIsPlayingFn?
    private let mrGetNowPlayingInfo: MRGetNowPlayingInfoFn?

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

        // If MediaRemote isn't available, keep a no-op manager.
        let mediaRemoteAvailable = (mrRegister != nil && mrGetPID != nil && mrGetIsPlaying != nil)

        if mediaRemoteAvailable {
            mrRegister?(queue)

            // Refresh on any now-playing or playback-state changes.
            let names = [
                "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            ]
            for n in names {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSNotification.Name(rawValue: n),
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        self?.refresh()
                    }
                )
            }
        }

        // Tahoe can restrict MediaRemote without entitlements; poll CoreAudio as a fallback.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
        }
        timer?.invalidate()
    }

    private func refresh() {
        // 1) Try MediaRemote first (best signal when available)
        if let mrGetIsPlaying, let mrGetPID, let mrGetNowPlayingInfo {
            mrGetIsPlaying(queue) { [weak self] playing in
                guard let self else { return }
                self.isPlaying = playing

                guard playing else {
                    // Fall through to CoreAudio below (some systems report playing=false even when audio is active).
                    if self.shouldPreserveVoxArtwork() {
                        // Keep Vox metadata visible even when paused.
                        self.isPlaying = (self.lastVoxPlayerState == 1)
                        // Still poll Vox so metadata can update while paused.
                        self.maybeUpdateArtworkFromVox()
                        return
                    } else {
                        self.nowPlayingArtwork = nil
                        self.cachedArtwork = nil
                        self.trackTitle = nil
                        self.trackArtist = nil
                        self.trackAlbum = nil
                        self.isEligibleSource = false
                        self.updateFromCoreAudio()
                    }
                    return
                }

                // Pull artwork (album art) if present.
                mrGetNowPlayingInfo(self.queue) { [weak self] info in
                    guard let self else { return }
                    if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                       let image = NSImage(data: data) {
                        self.nowPlayingArtwork = image
                        self.cachedArtwork = image
                        self.lastArtworkUpdateAt = Date()
                    } else {
                        // Avoid wiping VOX artwork if MediaRemote has no art payload.
                        let isVox = self.isVoxSource(bundleID: self.lastSourceBundleID, name: self.nowPlayingAppName)
                        if !isVox {
                            self.nowPlayingArtwork = nil
                        }
                    }

                    let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                    let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                    let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
                    let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)

                    if let t = trimmedTitle, !t.isEmpty {
                        self.trackTitle = t
                        self.cachedTrackTitle = t
                        self.lastTrackUpdateAt = Date()
                    }
                    if let a = trimmedArtist, !a.isEmpty {
                        self.trackArtist = a
                        self.cachedTrackArtist = a
                        self.lastTrackUpdateAt = Date()
                    }
                    if let a = trimmedAlbum, !a.isEmpty {
                        self.trackAlbum = a
                        self.cachedTrackAlbum = a
                        self.lastTrackUpdateAt = Date()
                    }
                }

                // Also track the app that owns the now-playing session.
                mrGetPID(self.queue) { [weak self] pid in
                    guard let self else { return }
                    guard pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                        self.updateFromCoreAudio()
                        return
                    }
                    let sourceChanged = app.bundleIdentifier != self.lastSourceBundleID
                    if sourceChanged || self.nowPlayingAppIcon == nil {
                        if let icon = app.icon?.withMinimalistColors() {
                            self.nowPlayingAppIcon = icon
                            self.nowPlayingAppIconSmall = Self.scaledImage(icon, size: CGSize(width: 20, height: 20))
                        }
                    }
                    if sourceChanged || self.nowPlayingAppName == nil {
                        self.nowPlayingAppName = app.localizedName
                    }
                    self.lastSourceBundleID = app.bundleIdentifier
                    self.isEligibleSource = Self.isEligibleSource(bundleID: app.bundleIdentifier, name: app.localizedName)
                    self.isBrowserSource = Self.isBrowser(bundleID: app.bundleIdentifier, name: app.localizedName)
                    if self.isEligibleSource {
                        self.lastControllableSource = Self.sourceKey(bundleID: app.bundleIdentifier, name: app.localizedName)
                    }

                    // If this is a browser, refine eligibility by checking the active tab URL.
                    if Self.isBrowser(bundleID: app.bundleIdentifier, name: app.localizedName) {
                        self.maybeUpdateEligibilityFromBrave()
                    }

                    // VOX can be the active audio session without MediaRemote metadata.
                    if app.localizedName == "Vox" || app.localizedName == "VOX" || (app.bundleIdentifier?.contains("Vox") == true) {
                        self.maybeUpdateArtworkFromVox()
                    }
                }
            }
            return
        }

        // 2) Fallback: CoreAudio process list
        updateFromCoreAudio()
    }

    private func isVoxSource(bundleID: String?, name: String?) -> Bool {
        let n = name?.lowercased() ?? ""
        if n.contains("vox") { return true }
        if let id = bundleID, id.lowercased().contains("vox") { return true }
        return false
    }

    private func shouldPreserveVoxArtwork() -> Bool {
        let isVox = isVoxSource(bundleID: lastSourceBundleID, name: nowPlayingAppName)
        let fresh = Date().timeIntervalSince(lastVoxActiveAt) < 60.0
        return isVox && fresh
    }

    private func updateFromCoreAudio() {
        if let pid = Self.currentlyRunningOutputPID(),
           let app = NSRunningApplication(processIdentifier: pid) {
            lastAudioSeenAt = Date()
            let bundleID = app.bundleIdentifier
            let sourceChanged = (bundleID != lastSourceBundleID)
            lastSourceBundleID = bundleID

            if isVoxSource(bundleID: bundleID, name: app.localizedName) {
                self.isPlaying = (lastVoxPlayerState == 1)
            } else {
                self.isPlaying = true
            }
            if sourceChanged || self.nowPlayingAppIcon == nil {
                if let icon = app.icon?.withMinimalistColors() {
                    self.nowPlayingAppIcon = icon
                    self.nowPlayingAppIconSmall = Self.scaledImage(icon, size: CGSize(width: 20, height: 20))
                }
            }
            if sourceChanged || self.nowPlayingAppName == nil {
                self.nowPlayingAppName = app.localizedName
            }
            self.isEligibleSource = Self.isEligibleSource(bundleID: bundleID, name: app.localizedName)
            self.isBrowserSource = Self.isBrowser(bundleID: bundleID, name: app.localizedName)
            if self.isEligibleSource {
                self.lastControllableSource = Self.sourceKey(bundleID: bundleID, name: app.localizedName)
            }

            if sourceChanged {
                let isVox = isVoxSource(bundleID: bundleID, name: app.localizedName)
                if !isVox {
                    self.nowPlayingArtwork = nil
                    self.cachedArtwork = nil
                }
                self.trackTitle = nil
                self.trackArtist = nil
                self.trackAlbum = nil
                self.cachedTrackTitle = nil
                self.cachedTrackArtist = nil
                self.cachedTrackAlbum = nil
            }

            // If the audio source is Brave, try to resolve artwork from the active tab URL
            // (Spotify/YouTube web players commonly run in Brave).
            if let bundleID = app.bundleIdentifier, bundleID.contains("brave") {
                self.maybeUpdateEligibilityFromBrave()
                self.maybeUpdateArtworkFromBraveActiveTab()
                self.maybeUpdateNowPlayingFromBraveWeb()
            }

            // VOX local files: ask VOX for the track URL and extract embedded artwork.
            if app.localizedName == "Vox" || app.localizedName == "VOX" || (app.bundleIdentifier?.contains("Vox") == true) {
                self.maybeUpdateArtworkFromVox()
            } else {
                if sourceChanged {
                    self.trackTitle = nil
                    self.trackArtist = nil
                    self.trackAlbum = nil
                    self.cachedTrackTitle = nil
                    self.cachedTrackArtist = nil
                    self.cachedTrackAlbum = nil
                }
            }
        } else {
            let now = Date()
            let grace: TimeInterval = 1.5
            if now.timeIntervalSince(lastAudioSeenAt) < grace {
                return
            }
            if shouldPreserveVoxArtwork() {
                // Keep UI visible when Vox is paused.
                self.isPlaying = (lastVoxPlayerState == 1)
                return
            }
            self.isPlaying = false
            self.nowPlayingAppIcon = nil
            if !shouldPreserveVoxArtwork() {
                self.nowPlayingArtwork = nil
                self.cachedArtwork = nil
            }
            self.trackTitle = nil
            self.trackArtist = nil
            self.trackAlbum = nil
            self.cachedTrackTitle = nil
            self.cachedTrackArtist = nil
            self.cachedTrackAlbum = nil
            self.nowPlayingAppName = nil
            self.lastSourceBundleID = nil
            self.isEligibleSource = false
            self.isBrowserSource = false
            self.lastControllableSource = nil
        }
    }

    func requestBrowserPermissionIfNeeded() {
        let already = UserDefaults.standard.bool(forKey: didRequestBrowserPermissionKey)
        if already { return }
        UserDefaults.standard.set(true, forKey: didRequestBrowserPermissionKey)
        lastPermissionRequestAt = Date()
        _ = Self.braveActiveTabURLString()
    }

    private func maybeUpdateEligibilityFromBrave() {
        let now = Date()
        guard let tabURLString = Self.braveActiveTabURLString(),
              let url = URL(string: tabURLString) else {
            // If we can't read the tab (permissions), keep eligibility briefly to avoid flicker.
            self.isEligibleSource = now.timeIntervalSince(lastSpotifyWebEligibleAt) < 30.0
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("open.spotify.com") {
            self.isEligibleSource = true
            self.lastSpotifyWebEligibleAt = now
        } else {
            self.isEligibleSource = now.timeIntervalSince(lastSpotifyWebEligibleAt) < 30.0
        }
    }

    private struct BraveWebInfo {
        let title: String
        let artist: String
        let artworkURL: String
    }

    private func maybeUpdateNowPlayingFromBraveWeb() {
        let now = Date()
        guard now.timeIntervalSince(lastBraveMetaFetchAt) > 1.0 else { return }
        lastBraveMetaFetchAt = now

        guard let tabURLString = Self.braveActiveTabURLString(),
              let url = URL(string: tabURLString),
              (url.host?.lowercased().contains("open.spotify.com") == true) else {
            return
        }

        guard let info = Self.braveWebNowPlayingInfo() else { return }
        let key = "\(info.title)|\(info.artist)|\(info.artworkURL)"
        if key == lastBraveMetaKey { return }
        lastBraveMetaKey = key

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                self.trackTitle = t
                self.cachedTrackTitle = t
                self.lastTrackUpdateAt = Date()
            }
            if !a.isEmpty {
                self.trackArtist = a
                self.cachedTrackArtist = a
                self.lastTrackUpdateAt = Date()
            }
            if !t.isEmpty || !a.isEmpty {
                self.lastControllableSource = "brave-spotify"
                self.isEligibleSource = true
            }
        }

        if !info.artworkURL.isEmpty, let artURL = URL(string: info.artworkURL) {
            Task { [weak self] in
                guard let self else { return }
                if let img = await Self.downloadImage(artURL) {
                    await MainActor.run {
                        self.nowPlayingArtwork = img
                        self.cachedArtwork = img
                        self.lastArtworkUpdateAt = Date()
                    }
                }
            }
        }
    }

    private static func isBrowser(bundleID: String?, name: String?) -> Bool {
        let id = bundleID?.lowercased() ?? ""
        let n = name?.lowercased() ?? ""
        return id.contains("brave") || id.contains("chrome") || id.contains("edge") || id.contains("safari") || id.contains("arc") || n.contains("brave") || n.contains("chrome") || n.contains("edge") || n.contains("safari") || n.contains("arc")
    }

    private static func isEligibleSource(bundleID: String?, name: String?) -> Bool {
        let id = bundleID?.lowercased() ?? ""
        let n = name?.lowercased() ?? ""
        if id.contains("com.spotify.client") || n.contains("spotify") { return true }
        if id.contains("com.apple.music") || n == "music" { return true }
        if id.contains("vox") || n.contains("vox") { return true }
        return false
    }

    private static func sourceKey(bundleID: String?, name: String?) -> String? {
        let id = bundleID?.lowercased() ?? ""
        let n = name?.lowercased() ?? ""
        if id.contains("com.spotify.client") || n.contains("spotify") { return "spotify" }
        if id.contains("com.apple.music") || n == "music" { return "music" }
        if id.contains("vox") || n.contains("vox") { return "vox" }
        if id.contains("brave") || n.contains("brave") { return "brave-spotify" }
        return nil
    }

    private func maybeUpdateArtworkFromBraveActiveTab() {
        // Throttle: Brave tab URL polling + network fetch can be expensive.
        let now = Date()
        guard now.timeIntervalSince(lastBraveFetchAt) > 1.0 else { return }
        lastBraveFetchAt = now

        guard let tabURLString = Self.braveActiveTabURLString(),
              !tabURLString.isEmpty else {
            return
        }

        guard tabURLString != lastBraveTabURL else { return }
        lastBraveTabURL = tabURLString

        guard let pageURL = URL(string: tabURLString) else { return }

        Task { [weak self] in
            guard let self else { return }
            if let artwork = await Self.artworkForWebMedia(pageURL: pageURL) {
                await MainActor.run {
                    self.nowPlayingArtwork = artwork
                }
            }
        }
    }

    private func maybeUpdateArtworkFromVox() {
        let now = Date()
        guard now.timeIntervalSince(lastVoxFetchAt) > 1.0 else { return }
        lastVoxFetchAt = now

        guard let info = Self.voxNowPlayingInfo() else { return }
        lastVoxPlayerState = info.playerState
        lastVoxInfoAt = Date()
        lastVoxActiveAt = Date()
        let newVoxKey = [
            info.track.trimmingCharacters(in: .whitespacesAndNewlines),
            info.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            info.album.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
        if lastVoxTrackKey == nil || lastVoxTrackKey != newVoxKey {
            lastVoxTrackKey = newVoxKey
            // New track: allow artwork to refresh from Vox.
            lastVoxArtworkUpdateAt = .distantPast
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = info.track.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let al = info.album.trimmingCharacters(in: .whitespacesAndNewlines)

            self.isPlaying = (info.playerState == 1)
            if !t.isEmpty { self.trackTitle = t; self.cachedTrackTitle = t }
            if !a.isEmpty { self.trackArtist = a; self.cachedTrackArtist = a }
            if !al.isEmpty { self.trackAlbum = al; self.cachedTrackAlbum = al }
            if !t.isEmpty || !a.isEmpty || !al.isEmpty {
                self.lastTrackUpdateAt = Date()
            }
        }
        let artBase64 = info.artworkBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artBase64.isEmpty, let data = Data(base64Encoded: artBase64), let image = NSImage(data: data) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Pin Vox artwork for the current track.
                self.nowPlayingArtwork = image
                self.cachedArtwork = image
                self.lastArtworkUpdateAt = Date()
                self.lastVoxArtworkUpdateAt = Date()
            }
            return
        }
        let trackURLString = info.trackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let canTryEmbedded = !trackURLString.isEmpty && trackURLString != lastVoxTrackURL
        if canTryEmbedded {
            lastVoxTrackURL = trackURLString
        }

        Task { [weak self] in
            guard let self else { return }

            if canTryEmbedded, let trackURL = Self.parseTrackURL(trackURLString) {
                if let artwork = await Self.embeddedArtwork(for: trackURL) {
                    await MainActor.run {
                        self.nowPlayingArtwork = artwork
                        self.cachedArtwork = artwork
                        self.lastArtworkUpdateAt = Date()
                        self.lastVoxArtworkUpdateAt = Date()
                    }
                    return
                }
            }

            // Fallback: iTunes/Apple Music lookup using VOX metadata.
            let key = "\(info.artist)|\(info.album)|\(info.track)"
            if self.lastVoxFallbackKey == key { return }
            self.lastVoxFallbackKey = key

            if let artwork = await Self.lookupArtwork(artist: info.artist, album: info.album, track: info.track) {
                await MainActor.run {
                    self.nowPlayingArtwork = artwork
                    self.cachedArtwork = artwork
                    self.lastArtworkUpdateAt = Date()
                    self.lastVoxArtworkUpdateAt = Date()
                }
            }
        }
    }

    private static func parseTrackURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file:") {
            // VOX returns "file:/Users/..." (single slash) with percent escapes.
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed)
    }

    private static func scaledImage(_ image: NSImage, size: CGSize) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        out.unlockFocus()
        return out
    }

    private struct VoxInfo {
        let track: String
        let artist: String
        let album: String
        let trackURL: String
        let playerState: Int
        let artworkBase64: String
    }

    private static func voxAppPath() -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.coppertino.Vox") {
            return url.path
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.coppertino.Vox").first,
           let url = running.bundleURL {
            return url.path
        }
        let fallback = "/Applications/VOX.app"
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }
        return nil
    }

    private static func jxaStringLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    fileprivate static func voxJxaTarget() -> String {
        if let path = voxAppPath() {
            return "\"\(jxaStringLiteral(path))\""
        }
        return "\"Vox\""
    }

    private static func voxNowPlayingInfo() -> VoxInfo? {
        // Use JXA like voxctl's `vox.trackurl()` plus metadata.
        guard let appPath = voxAppPath() else { return nil }
        let appPathLiteral = jxaStringLiteral(appPath)
        let script = """
        ObjC.import('Foundation');
        const vox = Application("\(appPathLiteral)");
        try {
          const errors = [];
          function safeCall(label, fn) {
            try { return fn(); } catch (e) { errors.push(label + ":" + String(e)); return null; }
          }
          const state = safeCall("playerState", () => vox.playerState()) ?? 0;
          const track = safeCall("track", () => vox.track()) ?? "";
          const artist = safeCall("artist", () => vox.artist()) ?? "";
          const album = safeCall("album", () => vox.album()) ?? "";
          const trackurl = safeCall("trackUrl", () => vox.trackUrl()) ?? "";

          let art = "";
          const tiff = safeCall("tiffArtworkData", () => vox.tiffArtworkData());
          if (tiff) {
            try {
              art = tiff.base64EncodedStringWithOptions(0).js;
            } catch (e) {
              try {
                const data = ObjC.unwrap(tiff);
                if (data && data.base64EncodedStringWithOptions) {
                  art = data.base64EncodedStringWithOptions(0).js;
                } else {
                  errors.push("tiffArtworkData:unwrap:Unsupported type");
                }
              } catch (e2) {
                errors.push("tiffArtworkData:unwrap:" + String(e2));
              }
            }
          }
          if (!art) {
            const img = safeCall("artworkImage", () => vox.artworkImage());
            if (img) {
              try {
                const tiff2 = img.TIFFRepresentation();
                if (tiff2) {
                  art = tiff2.base64EncodedStringWithOptions(0).js;
                }
              } catch (e) { errors.push("artworkImage:TIFF:" + String(e)); }
            }
          }
          const info = {
            track: track,
            artist: artist,
            album: album,
            trackurl: trackurl,
            state: state,
            artwork: art,
            errors: errors
          };
          JSON.stringify(info);
        } catch (e) {
          JSON.stringify({ error: String(e) });
        }
        """

        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-l", "JavaScript", "-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationStatus != 0 {
            Self.appendDebugLog("VOX JXA exited with status \(proc.terminationStatus)")
        }
        if let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !err.isEmpty {
            Self.appendDebugLog("VOX JXA stderr (status \(proc.terminationStatus)): \(err.prefix(500))")
        }
        if trimmed.isEmpty {
            Self.appendDebugLog("VOX JXA returned empty output")
        } else {
            Self.appendDebugLog("VOX JXA output: \(trimmed.prefix(500))")
        }
        guard let jsonData = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            Self.appendDebugLog("VOX JXA output was not valid JSON")
            return nil
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            Self.appendDebugLog("VOX JXA error: \(err)")
            return nil
        }
        if let errors = obj["errors"] as? [String], !errors.isEmpty {
            Self.appendDebugLog("VOX JXA property errors: \(errors.joined(separator: " | "))")
        }

        return VoxInfo(
            track: (obj["track"] as? String) ?? "",
            artist: (obj["artist"] as? String) ?? "",
            album: (obj["album"] as? String) ?? "",
            trackURL: (obj["trackurl"] as? String) ?? "",
            playerState: (obj["state"] as? Int) ?? 0,
            artworkBase64: (obj["artwork"] as? String) ?? ""
        )
    }

    private static func appendDebugLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/notch-vox-debug.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func embeddedArtwork(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            // Prefer the standardized common identifier (works across formats).
            let common = try await asset.load(.commonMetadata)
            if let artItem = common.first(where: { $0.identifier == .commonIdentifierArtwork }) {
                if let data = try? await artItem.load(.dataValue), let img = NSImage(data: data) {
                    return img
                }
            }

            // Fallback: scan all metadata formats for artwork.
            let formats = try await asset.load(.availableMetadataFormats)
            for fmt in formats {
                let items = asset.metadata(forFormat: fmt)
                if let artItem = items.first(where: { $0.identifier == .commonIdentifierArtwork || $0.commonKey?.rawValue == "artwork" }) {
                    if let data = try? await artItem.load(.dataValue), let img = NSImage(data: data) {
                        return img
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func braveActiveTabURLString() -> String? {
        // Use AppleScript to get the active tab URL from Brave.
        // If Brave isn't frontmost, it still typically returns the last active window/tab.
        let script = """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            set theURL to URL of active tab of front window
            return theURL
        end tell
        """

        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func braveWebNowPlayingInfo() -> BraveWebInfo? {
        let js = """
        (function(){
          const titleEl = document.querySelector('[data-testid="nowplaying-track-link"]');
          const artistEl = document.querySelector('[data-testid="nowplaying-artist"] a') ||
                           document.querySelector('[data-testid="nowplaying-artist"]');
          const imgEl = document.querySelector('img[aria-label="Cover art"]') ||
                        document.querySelector('img[alt*="Cover"]') ||
                        document.querySelector('img[alt*="cover"]');

          const title = titleEl ? titleEl.textContent : "";
          const artist = artistEl ? artistEl.textContent : "";
          const artwork = imgEl ? imgEl.src : "";

          return JSON.stringify({ title: title, artist: artist, artwork: artwork });
        })();
        """

        let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let script = """
        tell application "Brave Browser"
            if (count of windows) = 0 then return ""
            set theTab to active tab of front window
            set result to execute javascript "\(escapedJS)" in theTab
            return result
        end tell
        """

        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        return BraveWebInfo(
            title: (obj["title"] as? String) ?? "",
            artist: (obj["artist"] as? String) ?? "",
            artworkURL: (obj["artwork"] as? String) ?? ""
        )
    }

    private static func artworkForWebMedia(pageURL: URL) async -> NSImage? {
        // Spotify oEmbed (no auth) -> thumbnail_url
        if pageURL.host?.contains("open.spotify.com") == true {
            if let imageURL = await oEmbedThumbnailURL(provider: "spotify", pageURL: pageURL),
               let img = await downloadImage(imageURL) {
                return img
            }
        }

        return nil
    }

    private static func oEmbedThumbnailURL(provider: String, pageURL: URL) async -> URL? {
        let endpoint: URL?
        switch provider {
        case "spotify":
            endpoint = URL(string: "https://open.spotify.com/oembed?url=\(pageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        case "youtube":
            endpoint = URL(string: "https://www.youtube.com/oembed?format=json&url=\(pageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        default:
            endpoint = nil
        }

        guard let endpoint else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: endpoint)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let thumb = obj["thumbnail_url"] as? String,
               let url = URL(string: thumb) {
                return url
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func downloadImage(_ url: URL) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private static func lookupArtwork(artist: String, album: String, track: String) async -> NSImage? {
        let query = [artist, album, track]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return nil }

        guard let term = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=song&limit=1&term=\(term)") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = obj["results"] as? [[String: Any]],
               let first = results.first,
               let artwork = first["artworkUrl100"] as? String {
                // Bump to a higher resolution when possible.
                let hiRes = artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                if let imageURL = URL(string: hiRes), let img = await downloadImage(imageURL) {
                    return img
                }
                if let imageURL = URL(string: artwork), let img = await downloadImage(imageURL) {
                    return img
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private static func currentlyRunningOutputPID() -> pid_t? {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &listAddr, 0, nil, &dataSize) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return nil }

        var processObjects = Array<AudioObjectID>(repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObjectID, &listAddr, 0, nil, &dataSize, &processObjects) == noErr else {
            return nil
        }

        // Prefer the first process we find that's actively running OUTPUT.
        // (This matches the user-visible expectation in the common case: one app is producing sound.)
        for processObject in processObjects {
            if isProcessRunningOutput(processObject),
               let pid = pidForProcessObject(processObject) {
                return pid
            }
        }

        return nil
    }

    private static func pidForProcessObject(_ processObject: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid > 0 ? pid : nil
    }

    private static func isProcessRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
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
        let notchWidth: CGFloat = 330
        let notchHeight: CGFloat = 34
        
        let expandedWidth: CGFloat = 520
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
    @State private var activeAppIcon: NSImage?
    @State private var activeAppName: String?
    @State private var activeAppBundleID: String?
    @State private var isHovered = false
    @State private var appActivationObserver: NSObjectProtocol?
    
    private func updateActiveAppIcon() {
        let app = NSWorkspace.shared.frontmostApplication
        let icon = app?.icon?.withMinimalistColors()
        // Defer to next runloop to avoid AttributeGraph cycles during layout/updates.
        DispatchQueue.main.async {
            self.activeAppIcon = icon
            self.activeAppName = app?.localizedName
            self.activeAppBundleID = app?.bundleIdentifier
        }
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
        let recent = Date().timeIntervalSince(nowPlayingManager.lastTrackUpdateAt) < 5.0
        if let title = nowPlayingManager.trackTitle,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if recent, let cached = nowPlayingManager.cachedTrackTitle,
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }
        if let appName = nowPlayingManager.nowPlayingAppName,
           !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }
        return nowPlayingManager.isPlaying ? "Now Playing" : "Nothing Playing"
    }

    private var miniPlayerAlbumName: String? {
        let recent = Date().timeIntervalSince(nowPlayingManager.lastTrackUpdateAt) < 5.0
        let album = nowPlayingManager.trackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            (recent ? nowPlayingManager.cachedTrackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        if let album, !album.isEmpty {
            return album
        }
        return nil
    }

    private var miniPlayerArtistName: String? {
        let recent = Date().timeIntervalSince(nowPlayingManager.lastTrackUpdateAt) < 5.0
        let artist = nowPlayingManager.trackArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            (recent ? nowPlayingManager.cachedTrackArtist?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        if let artist, !artist.isEmpty {
            return artist
        }
        return nil
    }

    private var miniPlayerArt: some View {
        Group {
            let recentArt = Date().timeIntervalSince(nowPlayingManager.lastArtworkUpdateAt) < 6.0
            let art = nowPlayingManager.nowPlayingArtwork ?? (recentArt ? nowPlayingManager.cachedArtwork : nil)
            if let image = art ?? nowPlayingManager.nowPlayingAppIcon ?? activeAppIcon {
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
        .frame(width: 80, height: 80)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func sendMediaKey(_ key: Int32) {
        // System-defined media key events (private but widely used).
        let flags = NSEvent.ModifierFlags(rawValue: 0xA00)
        let keyDown = Int((key << 16) | 0xA00)
        let keyUp = Int((key << 16) | 0xB00)

        let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: keyDown,
            data2: -1
        )
        let up = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: keyUp,
            data2: -1
        )

        down?.cgEvent?.post(tap: .cghidEventTap)
        up?.cgEvent?.post(tap: .cghidEventTap)
    }

    private enum PlaybackCommand {
        case playPause
        case next
        case previous
    }

    private func runAppleScript(_ script: String, language: String = "AppleScript") -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        if language == "JavaScript" {
            proc.arguments = ["-l", "JavaScript", "-e", script]
        } else {
            proc.arguments = ["-e", script]
        }
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func sendPlaybackCommand(_ command: PlaybackCommand) {
        let appName = nowPlayingManager.nowPlayingAppName?.lowercased() ?? ""
        let fallback = nowPlayingManager.lastControllableSource ?? ""
        var handled = false

        if appName.contains("spotify") {
            let script: String
            switch command {
            case .playPause: script = "tell application \"Spotify\" to playpause"
            case .next: script = "tell application \"Spotify\" to next track"
            case .previous: script = "tell application \"Spotify\" to previous track"
            }
            handled = runAppleScript(script)
        } else if appName == "music" {
            let script: String
            switch command {
            case .playPause: script = "tell application \"Music\" to playpause"
            case .next: script = "tell application \"Music\" to next track"
            case .previous: script = "tell application \"Music\" to previous track"
            }
            handled = runAppleScript(script)
        } else if appName.contains("vox") {
            let voxTarget = NowPlayingManager.voxJxaTarget()
            let script: String
            switch command {
            case .playPause:
                script = "const vox = Application(\(voxTarget)); try { vox.playpause(); } catch (e) {}"
            case .next:
                script = "const vox = Application(\(voxTarget)); try { vox.next(); } catch (e) {}"
            case .previous:
                script = "const vox = Application(\(voxTarget)); try { vox.previous(); } catch (e) {}"
            }
            handled = runAppleScript(script, language: "JavaScript")
        } else if appName.contains("brave") || fallback == "brave-spotify" {
            handled = runBraveSpotifyCommand(command)
        } else if fallback == "spotify" {
            let script: String
            switch command {
            case .playPause: script = "tell application \"Spotify\" to playpause"
            case .next: script = "tell application \"Spotify\" to next track"
            case .previous: script = "tell application \"Spotify\" to previous track"
            }
            handled = runAppleScript(script)
        } else if fallback == "music" {
            let script: String
            switch command {
            case .playPause: script = "tell application \"Music\" to playpause"
            case .next: script = "tell application \"Music\" to next track"
            case .previous: script = "tell application \"Music\" to previous track"
            }
            handled = runAppleScript(script)
        } else if fallback == "vox" {
            let voxTarget = NowPlayingManager.voxJxaTarget()
            let script: String
            switch command {
            case .playPause:
                script = "const vox = Application(\(voxTarget)); try { vox.playpause(); } catch (e) {}"
            case .next:
                script = "const vox = Application(\(voxTarget)); try { vox.next(); } catch (e) {}"
            case .previous:
                script = "const vox = Application(\(voxTarget)); try { vox.previous(); } catch (e) {}"
            }
            handled = runAppleScript(script, language: "JavaScript")
        }

        if handled {
            return
        }

        switch command {
        case .playPause:
            sendMediaKey(16) // NX_KEYTYPE_PLAY (toggle play/pause)
        case .next:
            sendMediaKey(17) // NX_KEYTYPE_NEXT
        case .previous:
            sendMediaKey(18) // NX_KEYTYPE_PREVIOUS
        }
    }

    private func runBraveSpotifyCommand(_ command: PlaybackCommand) -> Bool {
        let js: String
        switch command {
        case .playPause:
            js = """
            (function(){
              const play = document.querySelector('[data-testid="control-button-playpause"]') ||
                           document.querySelector('button[aria-label="Play"]') ||
                           document.querySelector('button[aria-label="Pause"]');
              if (play) { play.click(); return true; }
              return false;
            })();
            """
        case .next:
            js = """
            (function(){
              const next = document.querySelector('[data-testid="control-button-skip-forward"]') ||
                           document.querySelector('button[aria-label="Next"]') ||
                           document.querySelector('button[aria-label="Next track"]');
              if (next) { next.click(); return true; }
              return false;
            })();
            """
        case .previous:
            js = """
            (function(){
              const prev = document.querySelector('[data-testid="control-button-skip-back"]') ||
                           document.querySelector('button[aria-label="Previous"]') ||
                           document.querySelector('button[aria-label="Previous track"]');
              if (prev) { prev.click(); return true; }
              return false;
            })();
            """
        }

        let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        let script = """
        tell application "Brave Browser"
            if (count of windows) = 0 then return false
            set theTab to active tab of front window
            set result to execute javascript "\(escapedJS)" in theTab
        end tell
        """
        return runAppleScript(script)
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
                Image(systemName: nowPlayingManager.isPlaying ? "pause.fill" : "play.fill")
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
        VStack(alignment: .leading, spacing: 4) {
            miniPlayerArt

            if let albumName = miniPlayerAlbumName {
                Text(albumName)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Text(miniPlayerTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            if let artistName = miniPlayerArtistName {
                Text(artistName)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
            }

            miniPlayerControls
        }
        .offset(x: -10, y: -6)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 300, maxHeight: expandedHeight - 16, alignment: .topLeading)
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
                nowPlayingManager.requestBrowserPermissionIfNeeded()
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
            if let image = nowPlayingManager.nowPlayingAppIconSmall
                ?? nowPlayingManager.nowPlayingAppIcon
                ?? activeAppIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 20, height: 20, alignment: .center)
        .transaction { $0.animation = nil }
    }

    private var isFrontmostBrowser: Bool {
        let id = activeAppBundleID?.lowercased() ?? ""
        let n = activeAppName?.lowercased() ?? ""
        return id.contains("brave") || id.contains("chrome") || id.contains("edge") || id.contains("safari") || id.contains("arc")
            || n.contains("brave") || n.contains("chrome") || n.contains("edge") || n.contains("safari") || n.contains("arc")
    }
    
    var body: some View {
        // We place the expanding notch inside an invisible frame the exact size of the maximum window.
        // We align it to the top so it "drops down" strictly from the menu bar edge.
        ZStack(alignment: .top) {
            
            // The expanding black notch area
            Group {
                NotchShape()
                    .fill(Color.black)
                    .ignoresSafeArea()
                    .frame(
                        width: isHovered ? expandedWidth : baseWidth,
                        height: isHovered ? expandedHeight : baseHeight
                    )
                    .overlay(
                        // Use edge-aligned layout (avoids layout cycles from .position())
                        HStack(alignment: .top) {
                            // Left: Active app icon
                            Group {
                                if isHovered {
                                    VStack(alignment: .leading, spacing: 6) {
                                        appIconView
                                        miniPlayerPanel
                                        let recentlyRequested = Date().timeIntervalSince(nowPlayingManager.lastPermissionRequestAt) < 10.0
                                        if (nowPlayingManager.isBrowserSource || isFrontmostBrowser || recentlyRequested) && !nowPlayingManager.isEligibleSource {
                                            browserPermissionPanel
                                        }
                                    }
                                } else {
                                    appIconView
                                }
                            }
                            .padding(.top, 6)
                            
                            Spacer(minLength: 0)
                            
                            // Right: Battery
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Battery.prefPane"))
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
                            .frame(height: 28, alignment: .center)
                            .padding(.top, 2)
                        }
                        // These paddings are tuned to sit inside the notch "corner" area.
                        .padding(.top, 1)
                        .padding(.leading, isHovered ? 29 : 14)
                        .padding(.trailing, isHovered ? 29 : 14)
                        .frame(
                            width: isHovered ? expandedWidth : baseWidth,
                            height: isHovered ? expandedHeight : baseHeight,
                            alignment: .top
                        )
                    )
            }
            .offset(y: 1)
            // Trigger the animation whenever the mouse enters/leaves this specific shape
            .onHover { hovering in
                isHovered = hovering
                onHoverChange(hovering)
                if hovering && isFrontmostBrowser {
                    nowPlayingManager.requestBrowserPermissionIfNeeded()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isHovered)
            
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
        }
        .onDisappear {
            if let appActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
                self.appActivationObserver = nil
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
