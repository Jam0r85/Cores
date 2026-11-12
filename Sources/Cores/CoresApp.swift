import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            Tools.dump()
        } else if let flag = args.firstIndex(of: "--snapshot"), args.count > flag + 1 {
            Tools.snapshot(to: args[flag + 1])
        } else if let flag = args.firstIndex(of: "--selftest"), args.count > flag + 1 {
            Tools.selfTest(outputDirectory: args[flag + 1])
        } else if let flag = args.firstIndex(of: "--render-icon"), args.count > flag + 1 {
            Tools.renderIcon(to: args[flag + 1])
        } else {
            CoresApp.main()
        }
    }
}

struct CoresApp: App {
    @State private var monitor: SystemMonitor
    @State private var updater: Updater

    init() {
        let monitor = SystemMonitor()
        let updater = Updater()
        monitor.onPanelVisibilityChange = { updater.panelVisibilityChanged($0) }
        _monitor = State(initialValue: monitor)
        _updater = State(initialValue: updater)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor, updater: updater)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The live readout in the menu bar: one mini bar per core tier, then load and CPU temperature
/// (or just one of the two, as chosen in Settings).
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    /// Reads only `menuBar`, which changes only when the drawing would, so SwiftUI re-renders
    /// the image (and macOS redraws the menu bar) only then.
    var body: some View {
        Image(nsImage: Self.render(MenuBarReadout(monitor.menuBar)))
    }

    /// Rendered to a template image so it looks exactly like this and adapts to the menu bar's colors.
    @MainActor static func render(_ readout: MenuBarReadout) -> NSImage {
        let renderer = ImageRenderer(content: readout)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return NSImage() }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale,
                                                           height: CGFloat(cgImage.height) / scale))
        image.isTemplate = true
        return image
    }
}

struct MenuBarReadout: View {
    let state: SystemMonitor.MenuBarState

    init(_ state: SystemMonitor.MenuBarState) {
        self.state = state
    }

    var body: some View {
        // With usage and temperature both on, the core bars sit in front; a reading on its own is just
        // its number, centred so it doesn't sit off to one side of its space. The battery's number
        // always hugs its icon.
        let items = state.items
        let alignment: Alignment = items.count == 1 ? .center : .trailing
        HStack(spacing: 5) {
            if items.usage && items.temperature {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(state.tierFractions.enumerated()), id: \.offset) { _, value in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1).opacity(0.3)
                            RoundedRectangle(cornerRadius: 1)
                                .frame(height: max(1.5, 13 * min(max(value, 0), 1)))
                        }
                        .frame(width: 3.5, height: 13)
                    }
                }
            }
            if items.usage {
                Self.number("\(state.load)%", widest: "100%", alignment: alignment)
            }
            if items.temperature {
                Self.number(state.temp.map { "\($0)°" } ?? "–°", widest: "100°", alignment: alignment)
            }
            if items.battery {
                HStack(spacing: 3) {
                    Self.number(state.batteryCharge.map { "\($0)%" } ?? "–%", widest: "100%", alignment: .trailing)
                    MenuBarBatteryIcon(charge: state.batteryCharge, state: state.batteryState)
                }
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        .frame(height: 18)
        .padding(.horizontal, 1)
    }

    /// Always as wide as the widest value it can show, so the item doesn't change width (and nudge
    /// its neighbours) as the number changes, and a three-digit reading is never cut off.
    private static func number(_ text: String, widest: String, alignment: Alignment) -> some View {
        Text(widest).hidden().overlay(alignment: alignment) { Text(text) }
    }
}

/// A battery filled to its charge, with a bolt while charging or a plug while plugged in but not
/// charging, like the system's own. The glyph has a cut-out outline so it stands out over the fill.
struct MenuBarBatteryIcon: View {
    let charge: Int?
    let state: BatteryReading.State?

    private static let size = CGSize(width: 22, height: 11)
    private static let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(lineWidth: 1)
                    .opacity(0.4)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .frame(width: (Self.size.width - Self.inset * 2) * min(max(Double(charge ?? 0) / 100, 0), 1))
                    .padding(Self.inset)
                if let glyph {
                    glyph.stroke(lineWidth: 2).blendMode(.destinationOut)
                    glyph.fill()
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .compositingGroup()
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1, topTrailingRadius: 1)
                .frame(width: 1.5, height: 4)
                .opacity(0.4)
        }
    }

    private var glyph: Path? {
        switch state {
        case .charging: Self.bolt
        case .charged, .notCharging: Self.plug
        case .onBattery, nil: nil
        }
    }

    /// 6 × 9 pt, centred in the battery.
    private static let bolt: Path = {
        var path = Path()
        path.addLines([CGPoint(x: 3.8, y: 0), CGPoint(x: 0, y: 5.1), CGPoint(x: 2.6, y: 5.1),
                       CGPoint(x: 2.2, y: 9), CGPoint(x: 6, y: 3.9), CGPoint(x: 3.4, y: 3.9)])
        path.closeSubpath()
        return path.offsetBy(dx: (size.width - 6) / 2, dy: (size.height - 9) / 2)
    }()

    /// 10 × 6 pt, pointing right, centred in the battery.
    private static let plug: Path = {
        var path = Path()
        path.addRect(CGRect(x: 0, y: 2.5, width: 2.5, height: 1))                                       // cord
        path.addRoundedRect(in: CGRect(x: 2.5, y: 0, width: 4, height: 6), cornerSize: CGSize(width: 1.2, height: 1.2)) // body
        path.addRect(CGRect(x: 6.5, y: 1, width: 3, height: 1))                                         // prongs
        path.addRect(CGRect(x: 6.5, y: 4, width: 3, height: 1))
        return path.offsetBy(dx: (size.width - 10) / 2, dy: (size.height - 6) / 2)
    }()
}
