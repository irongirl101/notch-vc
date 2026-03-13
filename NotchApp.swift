import Cocoa
import SwiftUI
import CoreImage

extension NSImage {
    func grayscaled() -> NSImage {
        guard let tiffData = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let ciImage = CIImage(bitmapImageRep: bitmapImage) else {
            return self
        }
        
        guard let filter = CIFilter(name: "CIColorControls") else { return self }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey) // Zero saturation = B&W
        filter.setValue(0.3, forKey: kCIInputBrightnessKey) // Increase brightness
        filter.setValue(1.3, forKey: kCIInputContrastKey)   // Increase contrast to prevent washing out
        
        guard let outputCIImage = filter.outputImage else { return self }
        
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) {
            return NSImage(cgImage: cgImage, size: self.size)
        }
        return self
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var notchWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // Since the user already has a physical MacBook notch, our software notch needs to be wider 
        // to extend past it and show the battery text on the side. 
        // A physical 14"/16" notch is ~200-220pt wide. Let's make ours ~290pt wide.
        let notchWidth: CGFloat = 290
        let notchHeight: CGFloat = 34
        
        // Position at the top center of the screen
        // We add +1 to screenRect.height to nudge the software notch up higher so it overlaps tightly 
        // with the physical hardware bezel and doesn't visually "hang down" too far.
        let notchRect = NSRect(
            x: (screenRect.width - notchWidth) / 2.0,
            y: screenRect.height - notchHeight + 1,
            width: notchWidth,
            height: notchHeight
        )
        
        let notchView = NotchView()
        let hostingView = NSHostingView(rootView: notchView)
        hostingView.frame = NSRect(origin: .zero, size: notchRect.size)

        notchWindow = NSWindow(
            contentRect: notchRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        notchWindow.isOpaque = false
        notchWindow.backgroundColor = .clear
        notchWindow.level = .statusBar // Place above the menu bar
        notchWindow.ignoresMouseEvents = true // Disable interactions so the user can use the menu underneath
        notchWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle] // Appear on all spaces
        
        notchWindow.contentView = hostingView
        notchWindow.makeKeyAndOrderFront(nil)
        
        // Native AppKit active app icon overlay to bypass SwiftUI cycles
        let iconView = NSImageView(frame: NSRect(x: notchWidth - 32, y: 7, width: 20, height: 20))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let contentView = notchWindow.contentView {
            contentView.addSubview(iconView)
        }
        
        // Initial setup
        if let app = NSWorkspace.shared.frontmostApplication {
            iconView.image = app.icon?.grayscaled()
        }
        
        // Observe changes
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            if let app = NSWorkspace.shared.frontmostApplication {
                iconView.image = app.icon?.grayscaled()
            }
        }
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
        updateBattery()
        
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
    @StateObject private var batteryManager = BatteryManager()
    
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
        NotchShape()
            .fill(Color.black)
            .ignoresSafeArea()
            .frame(width: 290, height: 34)
            .overlay(
                // Left Side: Battery
                ZStack(alignment: .center) {
                    Image(systemName: batteryIconName(level: batteryManager.batteryLevel, isCharging: batteryManager.isCharging))
                        .font(.system(size: 24, weight: .light)) // Make battery outline larger
                        .foregroundColor(batteryColor(level: batteryManager.batteryLevel, 
                                                      isCharging: batteryManager.isCharging, 
                                                      isLowPower: batteryManager.isLowPowerMode))
                    
                    // Drop the '%' sign to properly fit inside the SF Symbol boundary
                    Text("\(batteryManager.batteryLevel)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(batteryManager.batteryLevel <= 20 && !batteryManager.isCharging ? .white : .black)
                        // Nudge it slightly left to avoid bumping the battery terminal nub
                        .padding(.trailing, 2)
                }
                .position(x: 28, y: 15) // Absolute positioning
            )
            .offset(y: 1)
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
