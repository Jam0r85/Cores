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

/// The live readout in the menu bar: one mini bar per core tier, then load and CPU temperature.
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    /// Reads only `menuBar`, which changes only when the drawing would, so SwiftUI re-renders
    /// the image (and macOS redraws the menu bar) only then.
    var body: some View {
        let state = monitor.menuBar
        Image(nsImage: Self.render(MenuBarReadout(tiers: state.tierFractions, load: state.load, temp: state.temp)))
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

    var body: some View {
        HStack(spacing: 5) {
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
            Text("\(load)%")
                .frame(width: 30, alignment: .trailing)
            Text(temp.map { "\($0)°" } ?? "–°")
                .frame(width: 27, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        .frame(height: 18)
        .padding(.horizontal, 1)
    }
}
