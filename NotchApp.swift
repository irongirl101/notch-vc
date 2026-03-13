import Cocoa
import SwiftUI
import CoreImage

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
                            // Left: Battery
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
                            
                            Spacer(minLength: 0)
                            
                            // Right: Active app icon
                            Group {
                                if let icon = activeAppIcon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .scaledToFit()
                                }
                            }
                            .frame(width: 20, height: 20, alignment: .center)
                            .padding(.top, 6)
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
