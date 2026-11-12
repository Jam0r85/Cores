import SwiftUI

/// The dropdown shown when the menu bar item is clicked: a card for each part of the Mac, two
/// to a row, then every core.
/// Its height never changes while open: the menu bar window doesn't reliably shrink back
/// when content gets shorter, which left blank space around a collapsed section.
struct PanelView: View {
    let monitor: SystemMonitor
    let updater: Updater
    var tracksVisibility = true // off for snapshots, which can't draw the AppKit view that does it
    @State private var showingSettings: Bool

    static let width: CGFloat = 600
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12

    init(monitor: SystemMonitor, updater: Updater, tracksVisibility: Bool = true, startInSettings: Bool = false) {
        self.monitor = monitor
        self.updater = updater
        self.tracksVisibility = tracksVisibility
        _showingSettings = State(initialValue: startInSettings)
    }

    var body: some View {
        // Settings are laid over the (hidden) stats so the dropdown never changes size.
        ZStack(alignment: .top) {
            stats
                .opacity(showingSettings ? 0 : 1)
                .allowsHitTesting(!showingSettings)
                .accessibilityHidden(showingSettings)
            if showingSettings {
                SettingsView(monitor: monitor, updater: updater) { withAnimation(.easeOut(duration: 0.15)) { showingSettings = false } }
                    .frame(width: 380) // one narrow column reads better than rows stretched across the panel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if tracksVisibility { PanelVisibilityReader { monitor.setPanelVisible($0) } }
        }
        .onChange(of: monitor.panelOpens) { showingSettings = false } // each open starts on the stats
    }

    private enum Card: Hashable { case cpu, gpu, memory, disk, battery, fans }

    /// Fixed for the life of the app (a Mac doesn't gain a battery or fans), so the height never changes.
    /// Paired into rows; an odd one out at the end takes the whole row.
    private var rows: [[Card]] {
        var cards: [Card] = [.cpu, .gpu, .memory, .disk]
        if monitor.hasBattery { cards.append(.battery) }
        if !monitor.panel.sensors.fans.isEmpty { cards.append(.fans) }
        return stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HeaderView(monitor: monitor)
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row, id: \.self) { card($0) }
                }
                .fixedSize(horizontal: false, vertical: true) // both cards in a row as tall as the taller
            }
            CoresCard(clusters: monitor.panel.clusters, width: Self.width - Self.padding * 2)
            FooterView(showsBadge: updater.needsAttention) {
                withAnimation(.easeOut(duration: 0.15)) { showingSettings = true }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private func card(_ card: Card) -> some View {
        let data = monitor.panel
        switch card {
        case .cpu: CPUCard(data: data)
        case .gpu: GPUCard(data: data, coreCount: monitor.gpuCoreCount, memoryLimit: monitor.gpuMemoryLimit)
        case .memory: MemoryCard(data: data)
        case .disk: DiskCard(data: data)
        case .battery: BatteryCard(data: data)
        case .fans: FansCard(data: data)
        }
    }
}


/// Reports when the menu bar panel opens and closes, so the monitor can sample less while it's closed.
private struct PanelVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    /// Watches the window being shown and hidden, and gaining and losing focus (the menu bar
    /// panel takes focus when it opens and closes when it loses it).
    final class ObserverView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var visibility: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            visibility = nil
            guard let window else { return report() }
            visibility = window.observe(\.isVisible) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.report() } }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.report()
                        // The window may still be animating closed when it loses focus; look again shortly.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self?.report() } }
                    }
                })
            }
            report()
        }

        private func report() {
            onChange?(window?.isVisible ?? false)
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    let monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(monitor.chipName)
                .font(.system(size: 13, weight: .semibold))
            Text(([ "\(monitor.coreCount)-core CPU", monitor.gpuCoreCount.map { "\($0)-core GPU" },
                    Format.wholeGigabytes(ProcessInfo.processInfo.physicalMemory) ] as [String?])
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cards

private struct CPUCard: View {
    let data: SystemMonitor.PanelData

    var body: some View {
        MetricCard(title: "CPU", symbol: "cpu", tint: .blue,
                   caption: "Load now",
                   value: Format.percent(data.totalLoad), unit: "%",
                   stats: data.clusters.prefix(2).map { .init(label: $0.name, value: Format.percent($0.average) + "%") }
                       + [.temperature(data.sensors.cpu)],
                   history: data.loadHistory)
    }
}

private struct GPUCard: View {
    let data: SystemMonitor.PanelData
    let coreCount: Int?
    let memoryLimit: UInt64?

    var body: some View {
        let peak = data.gpuHistory.map(\.value).max()
        MetricCard(title: "GPU", symbol: "square.stack.3d.up", tint: .pink,
                   caption: coreCount.map { "\($0)-core GPU" } ?? "Load now",
                   value: data.gpu?.utilization.map(Format.percent) ?? "–", unit: "%",
                   stats: [.init(label: "Memory", value: data.gpu.map { Format.gigabytes($0.memoryInUse) } ?? "–"),
                           .temperature(data.sensors.gpu),
                           .init(label: "Peak", value: peak.map { "\(Int($0.rounded()))%" } ?? "–")],
                   history: data.gpuHistory)
            .help(helpText)
    }

    private var helpText: String {
        var text = "Apple silicon has one pool of memory shared by the CPU and GPU. Memory is the GPU's share that it's actively using"
        if let gpu = data.gpu { text += "; it has \(Format.gigabytes(gpu.memoryAllocated)) set aside in all" }
        if let memoryLimit { text += ", and can use up to \(Format.gigabytes(memoryLimit))" }
        return text + ". Peak is the busiest it's been in the last minute."
    }
}

private struct MemoryCard: View {
    let data: SystemMonitor.PanelData

    var body: some View {
        let memory = data.memory
        MetricCard(title: "Memory", symbol: "memorychip", tint: .indigo,
                   caption: memory.map { "In use of \(Format.wholeGigabytes($0.total))" } ?? "In use",
                   value: memory.map { String(format: "%.1f", Double($0.used) / Format.gibibyte) } ?? "–", unit: "GB",
                   badge: memory?.pressure.map(Self.badge),
                   stats: [.init(label: "App", value: memory.map { Format.gigabytes($0.app) } ?? "–"),
                           .init(label: "Wired", value: memory.map { Format.gigabytes($0.wired) } ?? "–"),
                           .init(label: "Compressed", value: memory.map { Format.gigabytes($0.compressed) } ?? "–")],
                   history: data.memoryHistory)
            .help("Counted like Activity Monitor's Memory Used: app memory, plus wired memory macOS can't move, "
                  + "plus what's been compressed to make room. The badge is macOS's own memory pressure.")
    }

    private static func badge(_ pressure: MemoryReading.Pressure) -> MetricCard.Badge {
        switch pressure {
        case .normal: .init(text: "Normal", symbol: "checkmark", tint: .green)
        case .warning: .init(text: "Warning", symbol: "exclamationmark", tint: .orange)
        case .critical: .init(text: "Critical", symbol: "exclamationmark", tint: .red)
        }
    }
}

private struct DiskCard: View {
    let data: SystemMonitor.PanelData

    var body: some View {
        let disk = data.disk
        let free = disk?.free.map(Format.diskSize)
        MetricCard(title: "Disk", symbol: "internaldrive", tint: .orange,
                   caption: disk?.total.map { "Free of \(Format.diskSize($0).joined(separator: " "))" } ?? "Free",
                   value: free?[0] ?? "–", unit: free?[1] ?? "GB",
                   stats: [.init(label: "Reading", value: Format.rate(disk?.readRate)),
                           .init(label: "Writing", value: Format.rate(disk?.writeRate)),
                           .temperature(data.sensors.ssd)],
                   history: data.diskHistory, domain: nil, minimumScale: 1_000_000)
            .help("Free space on the startup disk, counted like Finder's Available. Reading and writing add up every disk.")
    }
}

private struct BatteryCard: View {
    let data: SystemMonitor.PanelData

    var body: some View {
        let battery = data.battery
        MetricCard(title: "Battery", symbol: symbol, tint: .green,
                   caption: battery.map(Format.batteryStatus) ?? "–",
                   value: battery.map { "\($0.charge)" } ?? "–", unit: "%", valueTint: chargeTint,
                   stats: [.init(label: battery?.state == .charging ? "Charging at" : "Power draw",
                                 value: battery?.power.map { String(format: "%.1f W", $0) } ?? "–"),
                           .init(label: "Cycles", value: battery?.cycles.map { $0.formatted() } ?? "–"),
                           .temperature(data.sensors.battery)],
                   history: data.batteryHistory)
            .help("Not charging while plugged in usually means macOS is holding the charge to look after the battery "
                  + "(Optimized Battery Charging, or a charge limit in Battery settings). A cycle is a full charge's "
                  + "worth of use, whether in one go or spread over several charges.")
    }

    private var symbol: String {
        guard let battery = data.battery else { return "battery.100percent" }
        if battery.state == .charging { return "battery.100percent.bolt" }
        return switch battery.charge {
        case 88...: "battery.100percent"
        case 63...: "battery.75percent"
        case 38...: "battery.50percent"
        case 13...: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private var chargeTint: Color {
        guard let battery = data.battery, battery.state == .onBattery else { return .primary }
        return battery.charge <= 10 ? .red : battery.charge <= 20 ? .orange : .primary
    }
}

private struct FansCard: View {
    let data: SystemMonitor.PanelData

    var body: some View {
        let fans = data.sensors.fans
        let average = fans.isEmpty ? 0 : fans.map(\.rpm).reduce(0, +) / Double(fans.count)
        let fastest = fans.compactMap(\.maxRPM).max()
        var stats: [MetricCard.Stat] = fans.count > 1
            ? fans.prefix(2).map { .init(label: "Fan \($0.id + 1)", value: Format.rpm($0.rpm)) }
            : [.init(label: "Of top speed", value: fastest.map { "\(Int((average / $0 * 100).rounded()))%" } ?? "–")]
        stats.append(.init(label: "Top speed", value: fastest.map(Format.rpm) ?? "–"))
        return MetricCard(title: "Fans", symbol: "fan", tint: .teal,
                          caption: fans.count == 1 ? "1 fan" : "\(fans.count) fans",
                          value: average < 1 ? "Off" : Int(average).formatted(), unit: average < 1 ? "" : "rpm",
                          stats: stats,
                          history: data.fanHistory, domain: fastest.map { 0...$0 }, minimumScale: 1000)
    }
}

private struct CoresCard: View {
    let clusters: [SystemMonitor.ClusterLoad]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Cores", symbol: "square.grid.3x3", tint: .blue)
            CoreBarsView(clusters: clusters, width: width - MetricCard.padding * 2)
        }
        .padding(MetricCard.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

// MARK: - Card parts

/// A card for one part of the Mac: a headline reading, up to three smaller ones, and the last minute as bars.
private struct MetricCard: View {
    struct Stat {
        let label: String
        let value: String
        var tint: Color = .primary

        static func temperature(_ reading: TempReading?) -> Stat {
            Stat(label: "Temp", value: reading.map { "\(Int($0.average.rounded()))°" } ?? "–",
                 tint: Palette.temperature(reading?.average))
        }
    }

    struct Badge {
        let text: String
        let symbol: String
        let tint: Color
    }

    static let padding: CGFloat = 12

    let title: String
    let symbol: String
    let tint: Color
    let caption: String
    let value: String
    let unit: String
    var valueTint: Color = .primary
    var badge: Badge?
    let stats: [Stat]
    let history: [SystemMonitor.Sample]
    var domain: ClosedRange<Double>? = 0...100 // nil scales to the data
    var minimumScale: Double = 0               // when scaling to the data, so idle noise stays small

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: title, symbol: symbol, tint: tint)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 10)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueTint)
                Text(unit)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let badge {
                    HStack(spacing: 3) {
                        Image(systemName: badge.symbol).font(.system(size: 9, weight: .bold))
                        Text(badge.text).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(badge.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(badge.tint.opacity(0.15)))
                }
            }
            .monospacedDigit()
            // Always three columns, so the stats line up across cards.
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        if index < stats.count {
                            Text(stats[index].label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Text(stats[index].value)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(stats[index].tint)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .monospacedDigit()
            .padding(.top, 6)
            HistoryBars(samples: history, tint: tint, domain: domain, minimumScale: minimumScale)
                .padding(.top, 10)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }
}

private struct CardHeader: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.15)))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// White in light mode (with a faint shadow so it still stands off a pale wallpaper showing through
/// the dropdown), a light wash in dark mode.
private struct CardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if colorScheme == .light {
            shape.fill(.white).shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
        } else {
            shape.fill(.primary.opacity(0.045))
        }
    }
}

/// The last minute as bars, one per 1.5 s. Samples come every second while the panel is open and
/// every 3 s while it's closed, so each bar shows the newest sample in its slot, or the one before.
private struct HistoryBars: View {
    let samples: [SystemMonitor.Sample]
    let tint: Color
    let domain: ClosedRange<Double>?
    let minimumScale: Double

    static let slots = 40

    var body: some View {
        let values = Self.slotValues(samples)
        let top = domain?.upperBound ?? max(values.compactMap { $0 }.max() ?? 0, minimumScale)
        Canvas { context, size in
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(Self.slots - 1)) / CGFloat(Self.slots)
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                let fraction = top > 0 ? min(max(value / top, 0), 1) : 0
                let height = max(1.5, size.height * fraction)
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1, width / 2)), with: .color(tint))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.1)))
        .accessibilityHidden(true)
    }

    static func slotValues(_ samples: [SystemMonitor.Sample]) -> [Double?] {
        var values = [Double?](repeating: nil, count: slots)
        guard let end = samples.last?.time else { return values }
        let slot = SystemMonitor.historySeconds / Double(slots)
        let start = end.addingTimeInterval(-SystemMonitor.historySeconds)
        for sample in samples {
            let index = min(Int(sample.time.timeIntervalSince(start) / slot), slots - 1)
            if index >= 0 { values[index] = sample.value }
        }
        var last: Double?
        for index in values.indices {
            if let value = values[index] { last = value } else { values[index] = last }
        }
        return values
    }
}

// MARK: - Per-core bars

private struct CoreBarsView: View {
    let clusters: [SystemMonitor.ClusterLoad]
    let width: CGFloat

    private let barSpacing: CGFloat = 3
    private let groupSpacing: CGFloat = 14

    /// Every bar gets the same width, so the groups are sized by how many cores they have.
    private var barWidth: CGFloat {
        let bars = clusters.reduce(0) { $0 + $1.cores.count }
        let gaps = CGFloat(max(bars - clusters.count, 0)) * barSpacing + CGFloat(max(clusters.count - 1, 0)) * groupSpacing
        return bars > 0 ? (width - gaps) / CGFloat(bars) : 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: groupSpacing) {
            ForEach(clusters) { cluster in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(cluster.name.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text("\(Int((cluster.average * 100).rounded()))%")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: barSpacing) {
                        ForEach(Array(cluster.cores.enumerated()), id: \.offset) { offset, load in
                            CoreBar(load: load)
                                .frame(width: barWidth)
                                .help("Core \(cluster.firstCPU + offset + 1) · \(Int((load * 100).rounded()))%")
                        }
                    }
                }
                .frame(width: CGFloat(cluster.cores.count) * barWidth + CGFloat(max(cluster.cores.count - 1, 0)) * barSpacing)
            }
        }
    }
}

private struct CoreBar: View {
    let load: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Palette.load(load).gradient)
                    .frame(height: max(3, geo.size.height * min(max(load, 0), 1)))
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.4), value: load)
    }
}

// MARK: - Footer

private struct FooterView: View {
    let showsBadge: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: openSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            if showsBadge {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                            }
                        }
                    Text("Settings")
                }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .buttonStyle(QuietButtonStyle())
        .padding(.top, 2)
    }
}

/// Text-only button that brightens on hover. Pure SwiftUI so snapshots render it too.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.5 : hovering ? 1 : 0.8)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Colors

enum Palette {
    static func load(_ load: Double) -> Color {
        switch load {
        case 0.9...: .red
        case 0.7...: .orange
        default: .accentColor
        }
    }

    static func temperature(_ celsius: Double?) -> Color {
        guard let celsius else { return .primary }
        switch celsius {
        case 95...: return .red
        case 82...: return .orange
        default: return .primary
        }
    }
}

// MARK: - Formatting

enum Format {
    static let gibibyte = 1_073_741_824.0

    /// Memory, in the binary gigabytes Activity Monitor uses.
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / gibibyte)
    }

    static func wholeGigabytes(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / gibibyte).rounded())) GB"
    }

    /// Disk space, in the decimal gigabytes Finder uses: number and unit.
    static func diskSize(_ bytes: UInt64) -> [String] {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1000 { return [String(format: "%.2f", gigabytes / 1000), "TB"] }
        return [String(format: gigabytes >= 100 ? "%.0f" : "%.1f", gigabytes), "GB"]
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        return switch bytesPerSecond {
        case ..<1_000_000: "\(Int(bytesPerSecond / 1000)) kB/s"
        case ..<1_000_000_000: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        default: String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))"
    }

    static func rpm(_ rpm: Double) -> String {
        rpm < 1 ? "Off" : "\(Int(rpm).formatted()) rpm"
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func batteryStatus(_ battery: BatteryReading) -> String {
        let time = battery.minutesRemaining.map(duration)
        return switch battery.state {
        case .onBattery: ["On battery", time.map { "\($0) left" }].compactMap { $0 }.joined(separator: " · ")
        case .charging: ["Charging", time.map { "\($0) until full" }].compactMap { $0 }.joined(separator: " · ")
        case .charged: "Plugged in · fully charged"
        case .notCharging: "Plugged in · not charging"
        }
    }
}
