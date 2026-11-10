import ServiceManagement
import SwiftUI

/// Settings, shown in place of the stats inside the dropdown (the dropdown keeps its size).
struct SettingsView: View {
    let monitor: SystemMonitor
    let updater: Updater
    let close: () -> Void
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: close) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(.cancelAction)

            SettingsSection("General") {
                SwitchRow(title: "Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
            }

            SettingsSection("Menu bar") {
                // The last one left on can't be turned off, or Cores would vanish from the menu bar.
                let items = monitor.menuBarItems
                SwitchRow(title: "Core usage", isOn: menuBarItem(\.usage))
                    .disabled(items.usage && !items.temperature)
                SwitchRow(title: "CPU temperature", isOn: menuBarItem(\.temperature))
                    .disabled(items.temperature && !items.usage)
            }

            SettingsSection("Updates") {
                SwitchRow(title: "Check for updates automatically",
                          isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Divider()
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Version \(updater.currentVersion)")
                            .font(.system(size: 12))
                        Text(updater.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if case .manualUpdateNeeded(_, let page) = updater.status {
                        Button("Download") { NSWorkspace.shared.open(page) }
                            .buttonStyle(PillButtonStyle(prominent: true))
                    } else {
                        Button("Check now") { updater.checkNow() }
                            .buttonStyle(PillButtonStyle())
                            .disabled(updater.isBusy)
                    }
                }
                if updater.automaticallyChecks {
                    Text("New versions install themselves and Cores restarts, but only while this dropdown is closed.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Jam0r85/Cores")!) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .buttonStyle(QuietButtonStyle())
            .padding(.top, 2)
        }
    }

    private var statusColor: Color {
        switch updater.status {
        case .failed: .orange
        case .manualUpdateNeeded, .waitingToRestart: .accentColor
        default: .secondary
        }
    }

    private func menuBarItem(_ item: WritableKeyPath<SystemMonitor.MenuBarItems, Bool>) -> Binding<Bool> {
        Binding(get: { monitor.menuBarItems[keyPath: item] }, set: { on in
            var items = monitor.menuBarItems
            items[keyPath: item] = on
            monitor.setMenuBarItems(items)
        })
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Cores: couldn't change the login item: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.045)))
        }
    }
}

/// A label with a small switch. Drawn in SwiftUI so it matches the panel and renders in snapshots.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(2)
                }
                .frame(width: 30, height: 18)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.snappy(duration: 0.2), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

/// A small rounded button for actions inside a settings card.
private struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.08)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
