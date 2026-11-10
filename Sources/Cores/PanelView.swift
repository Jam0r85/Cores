import Charts
import SwiftUI

/// The dropdown shown when the menu bar item is clicked.
/// Its height never changes while open: the menu bar window doesn't reliably shrink back
/// when content gets shorter, which left blank space around a collapsed section.
struct PanelView: View {
    let monitor: SystemMonitor
    let updater: Updater
    var tracksVisibility = true // off for snapshots, which can't draw the AppKit view that does it
    @State private var showingSettings: Bool

    static let width: CGFloat = 320
    static let padding: CGFloat = 16

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

    private var stats: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(monitor: monitor)
            StatsRow(monitor: monitor)
            CoreBarsView(clusters: monitor.panel.clusters, width: Self.width - Self.padding * 2)
            MemoryView(memory: monitor.panel.memory)
            HStack(spacing: 10) {
                HistoryCard(title: "Load", series: [.init(name: "CPU", samples: monitor.panel.loadHistory, color: .accentColor)],
                            domain: 0...100, filled: true)
                HistoryCard(title: "Temp", series: [
                    .init(name: "CPU", samples: monitor.panel.cpuTempHistory, color: .orange),
                    .init(name: "GPU", samples: monitor.panel.gpuTempHistory, color: .purple),
                ], domain: nil, filled: false)
            }
            SensorsSection(sensors: monitor.panel.sensors)
            FooterView(showsBadge: updater.needsAttention) {
                withAnimation(.easeOut(duration: 0.15)) { showingSettings = true }
            }
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.chipName)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(monitor.coreCount) cores")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Headline numbers

private struct StatsRow: View {
    let monitor: SystemMonitor

    var body: some View {
        HStack(alignment: .top) {
            Stat(value: Int((monitor.panel.totalLoad * 100).rounded()), unit: "%", label: "CPU load")
            Spacer()
            Stat(value: monitor.panel.sensors.cpu.map { Int($0.average.rounded()) }, unit: "°",
                 label: "CPU temp", tint: Palette.temperature(monitor.panel.sensors.cpu?.average))
            Spacer()
            Stat(value: monitor.panel.sensors.gpu.map { Int($0.average.rounded()) }, unit: "°",
                 label: "GPU temp", tint: Palette.temperature(monitor.panel.sensors.gpu?.average))
        }
    }
}

private struct Stat: View {
    let value: Int?
    let unit: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: unit == "°" ? 0 : 1) {
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                // The degree sign reads best at full size; % sits smaller as a unit.
                Text(unit)
                    .font(.system(size: unit == "°" ? 30 : 16, weight: unit == "°" ? .regular : .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
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
        .frame(height: 46)
        .animation(.easeOut(duration: 0.4), value: load)
    }
}

// MARK: - Memory

/// Unified memory: one pool shared by the CPU and GPU. The bar is total memory in use out of the
/// Mac's RAM, with the GPU's share drawn in purple from the left (solid for what it's actively
/// using, lighter for what it has set aside).
struct MemoryView: View {
    let memory: MemoryReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("MEMORY")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(memory.map { "\(Self.gigabytes($0.used)) of \(Self.wholeGigabytes($0.total)) used" } ?? "–")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.primary.opacity(0.07))
                    bar(for: memory?.used, width: geo.size.width)
                        .fill(Color.accentColor.opacity(0.45))
                    bar(for: memory?.gpu.map { min($0.allocated, memory?.used ?? 0) }, width: geo.size.width)
                        .fill(Color.purple.opacity(0.45))
                    bar(for: memory?.gpu?.inUse, width: geo.size.width)
                        .fill(Color.purple.gradient)
                }
            }
            .frame(height: 6)
            HStack(spacing: 5) {
                Circle().fill(Color.purple).frame(width: 5, height: 5)
                Text(memory?.gpu.map { "GPU \(Self.gigabytes($0.inUse)) in use · \(Self.gigabytes($0.allocated)) allocated" } ?? "GPU –")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .monospacedDigit()
        .help(helpText)
    }

    private var helpText: String {
        var text = "Apple silicon has one pool of memory shared by the CPU and GPU. The bar shows how much is in use "
            + "(counted like Activity Monitor's Memory Used), with the GPU's share in purple: solid for what it's "
            + "actively using, lighter for what it has set aside."
        if let limit = memory?.gpu?.limit { text += " The GPU can use up to \(Self.gigabytes(limit))." }
        return text
    }

    private func bar(for bytes: UInt64?, width: CGFloat) -> some Shape {
        let total = Double(memory?.total ?? 0)
        let fraction = total > 0 ? min(Double(bytes ?? 0) / total, 1) : 0
        let length = fraction > 0 ? max(4, width * fraction) : 0
        return RoundedRectangle(cornerRadius: 3, style: .continuous).size(width: length, height: 6)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func wholeGigabytes(_ bytes: UInt64) -> String {
        "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB"
    }
}

// MARK: - History charts

private struct HistoryCard: View {
    struct Series: Identifiable {
        var id: String { name }
        let name: String
        let samples: [SystemMonitor.Sample]
        let color: Color
    }

    let title: String
    let series: [Series]
    let domain: ClosedRange<Double>?
    let filled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if series.count > 1 {
                    ForEach(series) { s in
                        HStack(spacing: 3) {
                            Circle().fill(s.color).frame(width: 5, height: 5)
                            Text(s.name).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            // Plotted by time, because samples are 1 s apart while the panel is open and 3 s apart while closed.
            Chart {
                ForEach(series) { s in
                    ForEach(s.samples) { sample in
                        if filled {
                            AreaMark(x: .value("Time", sample.time), y: .value(s.name, sample.value))
                                .foregroundStyle(s.color.opacity(0.18).gradient)
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("Time", sample.time), y: .value(s.name, sample.value), series: .value("Series", s.name))
                            .foregroundStyle(s.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 44)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.045)))
    }

    /// The last 60 seconds, ending at the newest sample.
    private var xDomain: ClosedRange<Date> {
        let end = series.compactMap { $0.samples.last?.time }.max() ?? Date()
        return end.addingTimeInterval(-SystemMonitor.historySeconds)...end
    }

    /// Fixed for load; for temperature, a window around the data at least 12° tall.
    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        let values = series.flatMap { $0.samples.map(\.value) }
        guard let low = values.min(), let high = values.max() else { return 30...60 }
        let mid = (low + high) / 2
        let half = max((high - low) / 2 + 2, 6)
        return (mid - half)...(mid + half)
    }
}

// MARK: - Sensors list

private struct SensorsSection: View {
    let sensors: SensorSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SENSORS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                TempRow(name: "CPU", reading: sensors.cpu)
                TempRow(name: "GPU", reading: sensors.gpu)
                TempRow(name: "SSD", reading: sensors.ssd)
                TempRow(name: "Battery", reading: sensors.battery)
                ForEach(sensors.fans) { fan in
                    SensorRow(name: sensors.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan",
                              value: fan.rpm < 1 ? "Off" : "\(Int(fan.rpm).formatted()) rpm",
                              detail: fan.maxRPM.map { "max \(Int($0).formatted())" })
                }
            }
        }
    }
}

/// Always takes up a row (showing "–" if a reading drops out) so the panel height stays put.
private struct TempRow: View {
    let name: String
    let reading: TempReading?

    var body: some View {
        SensorRow(name: name,
                  value: reading.map { "\(Int($0.average.rounded()))°" } ?? "–",
                  detail: reading.flatMap { $0.peak - $0.average >= 1 ? "peak \(Int($0.peak.rounded()))°" : nil },
                  tint: Palette.temperature(reading?.average))
    }
}

private struct SensorRow: View {
    let name: String
    let value: String
    var detail: String?
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(tint)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
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
