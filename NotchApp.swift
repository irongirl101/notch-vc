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
    @Published var nowPlayingAppName: String?
    @Published var lastTrackUpdateAt: Date = .distantPast
    @Published var fallbackTrackTitle: String?
    @Published var fallbackTrackArtist: String?
    @Published var fallbackAppName: String?
    @Published var fallbackAppIcon: NSImage?
    @Published var fallbackArtwork: NSImage?
    @Published var fallbackIsPlaying: Bool = false
    @Published var fallbackLastUpdateAt: Date = .distantPast

    private let bundle: CFBundle?
    private let queue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var frontmostBundleID: String?
    private var frontmostAppName: String?
    private var lastFallbackArtworkURL: String?
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
                    
                    if let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                        self.nowPlayingArtwork = NSImage(data: artworkData)
                    } else {
                        self.nowPlayingArtwork = nil
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
        return fallbackTrackTitle
    }

    var effectiveTrackArtist: String? {
        if let a = trackArtist, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a }
        return fallbackTrackArtist
    }

    var effectiveAppName: String? {
        if let n = nowPlayingAppName, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return n }
        return fallbackAppName
    }

    var effectiveIsPlaying: Bool {
        if hasMediaRemoteData { return isPlaying }
        return fallbackIsPlaying
    }

    var effectiveArtwork: NSImage? {
        if let a = nowPlayingArtwork { return a }
        return fallbackArtwork
    }

    var effectiveAppIcon: NSImage? {
        if let icon = nowPlayingAppIconSmall ?? nowPlayingAppIcon { return icon }
        return fallbackAppIcon
    }

    func setFrontmostApp(bundleID: String?, name: String?) {
        frontmostBundleID = bundleID
        frontmostAppName = name
    }

    func startFallbackPolling() {
        if fallbackTimer != nil { return }
        refreshBrowserFallback()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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

        guard url.contains("spotify.com") else {
            lastFallbackWasSpotify = false
            clearFallback()
            return
        }
        lastFallbackWasSpotify = true

        let parsed = parseSpotifyTitle(title)
        DispatchQueue.main.async {
            self.fallbackTrackTitle = parsed.title ?? (title.isEmpty ? nil : title)
            self.fallbackTrackArtist = parsed.artist ?? (artist.isEmpty ? nil : artist)
            self.fallbackAppName = "Spotify (Brave)"
            self.fallbackAppIcon = self.braveIcon()
            if !playbackState.isEmpty {
                self.fallbackIsPlaying = playbackState.lowercased() == "playing"
            } else {
                self.fallbackIsPlaying = !(title.isEmpty && artist.isEmpty && artworkURL.isEmpty)
            }
            self.fallbackLastUpdateAt = Date()
        }

        if !artworkURL.isEmpty, let artwork = URL(string: artworkURL) {
            Task { [weak self] in
                guard let self else { return }
                if let img = await self.downloadImage(from: artwork) {
                    await MainActor.run {
                        self.fallbackArtwork = img
                        self.fallbackLastUpdateAt = Date()
                    }
                }
            }
        }

        fetchFallbackArtworkIfNeeded(pageURLString: url)
    }

    private func shouldUseBrowserFallback() -> Bool {
        let id = frontmostBundleID?.lowercased() ?? ""
        let name = frontmostAppName?.lowercased() ?? ""
        return id.contains("brave") || name.contains("brave") || hasRecentFallback()
    }

    private func hasRecentFallback() -> Bool {
        if fallbackIsPlaying { return true }
        if lastFallbackWasSpotify && isBraveRunning() { return true }
        return Date().timeIntervalSince(fallbackLastUpdateAt) < 10.0
    }

    private func isBraveRunning() -> Bool {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser").isEmpty == false
    }

    private func clearFallback() {
        DispatchQueue.main.async {
            self.fallbackTrackTitle = nil
            self.fallbackTrackArtist = nil
            self.fallbackAppName = nil
            self.fallbackAppIcon = nil
            self.fallbackArtwork = nil
            self.fallbackIsPlaying = false
        }
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
            self.nowPlayingManager.setFrontmostApp(bundleID: app?.bundleIdentifier, name: app?.localizedName)
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
        let album = nowPlayingManager.trackAlbum?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func sendPlaybackCommand(_ command: PlaybackCommand) {
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
        let maxPanelWidth = max(180, expandedWidth - (sidePadding * 2) - rightReserve - leftIconWidth)
        return VStack(alignment: .leading, spacing: 4) {
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
        .offset(x: -6, y: 4)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
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

    private var isFrontmostBrowser: Bool {
        let id = activeAppBundleID?.lowercased() ?? ""
        let n = activeAppName?.lowercased() ?? ""
        return id.contains("brave") || id.contains("chrome") || id.contains("edge") || id.contains("safari") || id.contains("arc")
            || n.contains("brave") || n.contains("chrome") || n.contains("edge") || n.contains("safari") || n.contains("arc")
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
                                        barsView
                                            .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? -1 : -4)
                                    } else {
                                        appIconView
                                            .offset(x: shouldShowPlayer ? 0 : -2, y: shouldShowPlayer ? 0 : -3)
                                    }
                                }
                            }
                            .padding(.top, 6)
                            
                            Spacer(minLength: 0)
                            
                            // Right: Battery
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
                    nowPlayingManager.startFallbackPolling()
                } else {
                    if !nowPlayingManager.effectiveIsPlaying {
                        nowPlayingManager.stopFallbackPolling()
                    }
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
        }
        .onChange(of: nowPlayingManager.effectiveIsPlaying) { _, playing in
            if playing {
                nowPlayingManager.startFallbackPolling()
            } else if !isHovered {
                nowPlayingManager.stopFallbackPolling()
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
