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
    let tiers: [Double]
    let load: Int
    let temp: Int?
    let showsUsage: Bool
    let showsTemp: Bool

    init(tiers: [Double], load: Int, temp: Int?, showsUsage: Bool = true, showsTemp: Bool = true) {
        self.tiers = tiers
        self.load = load
        self.temp = temp
        self.showsUsage = showsUsage
        self.showsTemp = showsTemp
    }

    init(_ state: SystemMonitor.MenuBarState) {
        self.init(tiers: state.tierFractions, load: state.load, temp: state.temp,
                  showsUsage: state.items.usage, showsTemp: state.items.temperature)
    }

    var body: some View {
        // With both readings on, the core bars sit in front; a reading on its own is just its number,
        // centred so it doesn't sit off to one side of its space.
        let both = showsUsage && showsTemp
        HStack(spacing: 5) {
            if both {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(tiers.enumerated()), id: \.offset) { _, value in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1).opacity(0.3)
                            RoundedRectangle(cornerRadius: 1)
                                .frame(height: max(1.5, 13 * min(max(value, 0), 1)))
                        }
                        .frame(width: 3.5, height: 13)
                    }
                }
            }
            if showsUsage {
                Self.number("\(load)%", widest: "100%", alignment: both ? .trailing : .center)
            }
            if showsTemp {
                Self.number(temp.map { "\($0)°" } ?? "–°", widest: "100°", alignment: both ? .trailing : .center)
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
