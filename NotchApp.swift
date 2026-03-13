import Cocoa
import SwiftUI
import CoreImage
import CoreAudio
import Foundation
import AVFoundation

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
    @Published var nowPlayingArtwork: NSImage?

    private let bundle: CFBundle?
    private let queue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastBraveTabURL: String?
    private var lastBraveFetchAt: Date = .distantPast
    private var lastVoxTrackURL: String?
    private var lastVoxFetchAt: Date = .distantPast
    private var lastVoxFallbackKey: String?

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
                    self.nowPlayingArtwork = nil
                    self.updateFromCoreAudio()
                    return
                }

                // Pull artwork (album art) if present.
                mrGetNowPlayingInfo(self.queue) { [weak self] info in
                    guard let self else { return }
                    if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                       let image = NSImage(data: data) {
                        self.nowPlayingArtwork = image
                    } else {
                        self.nowPlayingArtwork = nil
                    }
                }

                // Also track the app that owns the now-playing session.
                mrGetPID(self.queue) { [weak self] pid in
                    guard let self else { return }
                    guard pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                        self.updateFromCoreAudio()
                        return
                    }
                    self.nowPlayingAppIcon = app.icon?.withMinimalistColors()
                }
            }
            return
        }

        // 2) Fallback: CoreAudio process list
        updateFromCoreAudio()
    }

    private func updateFromCoreAudio() {
        if let pid = Self.currentlyRunningOutputPID(),
           let app = NSRunningApplication(processIdentifier: pid) {
            self.isPlaying = true
            self.nowPlayingAppIcon = app.icon?.withMinimalistColors()
            self.nowPlayingArtwork = nil

            // If the audio source is Brave, try to resolve artwork from the active tab URL
            // (Spotify/YouTube web players commonly run in Brave).
            if let bundleID = app.bundleIdentifier, bundleID.contains("brave") {
                self.maybeUpdateArtworkFromBraveActiveTab()
            }

            // VOX local files: ask VOX for the track URL and extract embedded artwork.
            if app.localizedName == "Vox" || app.localizedName == "VOX" || (app.bundleIdentifier?.contains("Vox") == true) {
                self.maybeUpdateArtworkFromVox()
            }
        } else {
            self.isPlaying = false
            self.nowPlayingAppIcon = nil
            self.nowPlayingArtwork = nil
        }
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
        let trackURLString = info.trackURL
        guard !trackURLString.isEmpty else { return }
        guard trackURLString != lastVoxTrackURL else { return }
        lastVoxTrackURL = trackURLString

        guard let trackURL = Self.parseTrackURL(trackURLString) else { return }

        Task { [weak self] in
            guard let self else { return }
            if let artwork = await Self.embeddedArtwork(for: trackURL) {
                await MainActor.run {
                    self.nowPlayingArtwork = artwork
                }
                return
            }

            // If no embedded artwork, fall back to a web lookup using VOX's metadata.
            let key = "\(info.artist)|\(info.album)|\(info.track)"
            if self.lastVoxFallbackKey == key { return }
            self.lastVoxFallbackKey = key

            if let artwork = await Self.lookupArtwork(artist: info.artist, album: info.album, track: info.track) {
                await MainActor.run {
                    self.nowPlayingArtwork = artwork
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

    private struct VoxInfo {
        let track: String
        let artist: String
        let album: String
        let trackURL: String
        let playerState: Int
    }

    private static func voxNowPlayingInfo() -> VoxInfo? {
        // Use JXA like voxctl's `vox.trackurl()` plus metadata.
        let script = """
        const vox = Application("Vox");
        try {
          const state = vox.playerState();
          const info = {
            track: vox.track(),
            artist: vox.artist(),
            album: vox.album(),
            trackurl: vox.trackurl(),
            state: state
          };
          JSON.stringify(info);
        } catch (e) {
          "";
        }
        """

        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-l", "JavaScript", "-e", script]
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

        return VoxInfo(
            track: (obj["track"] as? String) ?? "",
            artist: (obj["artist"] as? String) ?? "",
            album: (obj["album"] as? String) ?? "",
            trackURL: (obj["trackurl"] as? String) ?? "",
            playerState: (obj["state"] as? Int) ?? 0
        )
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

    private static func artworkForWebMedia(pageURL: URL) async -> NSImage? {
        // Spotify oEmbed (no auth) -> thumbnail_url
        if pageURL.host?.contains("open.spotify.com") == true {
            if let imageURL = await oEmbedThumbnailURL(provider: "spotify", pageURL: pageURL),
               let img = await downloadImage(imageURL) {
                return img
            }
        }

        // YouTube oEmbed -> thumbnail_url
        if (pageURL.host?.contains("youtube.com") == true) || (pageURL.host?.contains("youtu.be") == true) {
            if let imageURL = await oEmbedThumbnailURL(provider: "youtube", pageURL: pageURL),
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        // We never want to actually absorb clicks, so if the user clicks, just pass it through 
        // to whatever app is underneath the notch (like the Menu Bar).
        // Returning nil here drops the click entirely, while tracking areas (like .onHover) continue to function.
        return nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // Since the user already has a physical MacBook notch, our software notch needs to be wider 
        // to extend past it and show the battery text on the side. 
        let notchWidth: CGFloat = 290
        let notchHeight: CGFloat = 34
        
        let expandedWidth: CGFloat = 320
        let expandedHeight: CGFloat = 90
        
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
        let notchView = NotchView(baseWidth: notchWidth, baseHeight: notchHeight, expandedWidth: expandedWidth, expandedHeight: expandedHeight)
        let hostingView = PassThroughView(rootView: notchView)
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
        
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
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
            if let range = output.range(of: "\\d+%", options: .regularExpression) {
                let foundPercentage = String(output[range])
                let intVal = Int(foundPercentage.dropLast()) ?? 0
                let charging = output.contains("charging") && !output.contains("discharging")
                DispatchQueue.main.async {
                    self.percentage = foundPercentage
                    self.batteryLevel = intVal
                    self.isCharging = charging
                    self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
            }
        }
    }
}

struct NotchView: View {
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    
    @StateObject private var batteryManager = BatteryManager()
    @StateObject private var nowPlayingManager = NowPlayingManager()
    @State private var activeAppIcon: NSImage?
    @State private var isHovered = false
    @State private var appActivationObserver: NSObjectProtocol?
    
    private func updateActiveAppIcon() {
        let icon = NSWorkspace.shared.frontmostApplication?.icon?.withMinimalistColors()
        // Defer to next runloop to avoid AttributeGraph cycles during layout/updates.
        DispatchQueue.main.async {
            self.activeAppIcon = icon
        }
    }
    
    private func batteryIconName(level: Int, isCharging: Bool) -> String {
        let suffix = isCharging ? ".bolt" : ""
        switch level {
        case 0...15: return "battery.0\(suffix)"
        case 16...35: return "battery.25\(suffix)"
        case 36...65: return "battery.50\(suffix)"
        case 66...85: return "battery.75\(suffix)"
        default: return "battery.100\(suffix)"
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
                                // If any app is actively playing audio, prefer that app's icon.
                                if let image = nowPlayingManager.nowPlayingArtwork ?? nowPlayingManager.nowPlayingAppIcon ?? activeAppIcon {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                }
                            }
                            .frame(width: 20, height: 20, alignment: .center)
                            .padding(.top, 6)
                            
                            Spacer(minLength: 0)
                            
                            // Right: Battery
                            ZStack(alignment: .center) {
                                Image(systemName: batteryIconName(level: batteryManager.batteryLevel, isCharging: batteryManager.isCharging))
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundColor(batteryColor(level: batteryManager.batteryLevel,
                                                                  isCharging: batteryManager.isCharging,
                                                                  isLowPower: batteryManager.isLowPowerMode))
                                
                                Text("\(batteryManager.batteryLevel)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(batteryManager.batteryLevel <= 20 && !batteryManager.isCharging ? .white : .black)
                                    .padding(.trailing, 2)
                            }
                            .frame(width: 28, height: 28, alignment: .center)
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
