import AppKit
import Foundation
import Observation
import os
import Security

/// Keeps Cores up to date from the latest GitHub release.
///
/// It downloads the release's Cores.zip and accepts the app inside only if it is signed with the
/// Steve Morris & Son LLP Developer ID certificate. Then it swaps it in for the running copy and
/// restarts. Automatic updates wait until the dropdown is closed so they never interrupt you.
@MainActor @Observable
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case installing(version: String)
        case restarting(version: String)
        case waitingToRestart(version: String)          // installed; restarts when the dropdown closes
        case manualUpdateNeeded(version: String, page: URL) // can't replace the app where it is
        case failed(String)
    }

    static let releasesAPI = URL(string: "https://api.github.com/repos/Jam0r85/Cores/releases/latest")!
    nonisolated static let teamID = "BAZ32PFTJS" // Steve Morris & Son LLP
    static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let automaticKey = "automaticallyChecksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"

    let currentVersion: String
    private(set) var status: Status = .idle
    private(set) var lastCheck: Date?
    var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: Self.automaticKey)
            scheduleAutomaticCheck()
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing, .restarting, .waitingToRestart: true
        default: false
        }
    }

    /// Worth a dot on the settings button: there's something to see.
    var needsAttention: Bool {
        switch status {
        case .manualUpdateNeeded, .waitingToRestart: true
        default: false
        }
    }

    @ObservationIgnored private let feed: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var pendingRestart: URL?
    @ObservationIgnored private let log = Logger(subsystem: "dev.local.Cores", category: "updater")

    init(startChecking: Bool = true) {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
        automaticallyChecks = UserDefaults.standard.bool(forKey: Self.automaticKey)
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        // For testing an update without publishing one, CORES_UPDATE_FEED can point at another release feed.
        feed = ProcessInfo.processInfo.environment["CORES_UPDATE_FEED"].flatMap(URL.init(string:)) ?? Self.releasesAPI

        guard startChecking else { return }
        scheduleAutomaticCheck()
        if CommandLine.arguments.contains("--update-now") { checkNow() }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func panelVisibilityChanged(_ open: Bool) {
        panelOpen = open
        if !open, let app = pendingRestart, case .waitingToRestart(let version) = status {
            pendingRestart = nil
            restart(into: app, version: version)
        }
    }

    // MARK: - Scheduling

    /// Shortly after launch if the last check was over 6 hours ago, otherwise when it's due.
    private func scheduleAutomaticCheck(after delay: TimeInterval? = nil) {
        timer?.invalidate()
        timer = nil
        guard automaticallyChecks else { return }
        let sinceLast = lastCheck.map { Date().timeIntervalSince($0) } ?? .infinity
        let wait = delay ?? (sinceLast >= Self.checkInterval ? 20 : Self.checkInterval - sinceLast)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheckDue() }
        }
        timer.tolerance = min(wait * 0.1, 300)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func automaticCheckDue() {
        Task {
            await check(userInitiated: false)
            if case .failed = status {
                scheduleAutomaticCheck(after: 60 * 60) // probably offline: try again in an hour
            } else {
                scheduleAutomaticCheck()
            }
        }
    }

    // MARK: - Checking and installing

    private struct Release {
        let version: String
        let zip: URL?
        let page: URL
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            guard Self.version(release.version, isNewerThan: currentVersion) else {
                status = .upToDate
                return
            }
            log.notice("Version \(release.version, privacy: .public) is available (running \(self.currentVersion, privacy: .public))")
            try await install(release, userInitiated: userInitiated)
        } catch {
            log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub replied with error \(http.statusCode)")
        }
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let zip = payload.assets.first { $0.name == "Cores.zip" }?.browser_download_url
        return Release(version: version, zip: zip, page: payload.html_url)
    }

    private func install(_ release: Release, userInitiated: Bool) async throws {
        let target = Bundle.main.bundleURL
        guard let zipURL = release.zip, Self.canReplace(target) else {
            // Running from the disk image, a read-only place, or a folder this user can't write to.
            log.notice("Can't replace \(target.path, privacy: .public); offering the download instead")
            status = .manualUpdateNeeded(version: release.version, page: release.page)
            return
        }

        status = .downloading(version: release.version)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("Cores-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
        let zip = workDir.appendingPathComponent("Cores.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        status = .installing(version: release.version)
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let newApp = try await Task.detached(priority: .userInitiated) {
            try Self.unpackAndVerify(zip: zip, into: workDir, identifier: identifier, version: release.version)
        }.value
        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp) // atomic swap
        log.notice("Installed version \(release.version, privacy: .public)")

        if userInitiated || !panelOpen {
            restart(into: target, version: release.version)
        } else {
            pendingRestart = target
            status = .waitingToRestart(version: release.version)
        }
    }

    private func restart(into app: URL, version: String) {
        status = .restarting(version: version)
        // A tiny helper waits for this copy to quit, then opens the new one.
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                                "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        do {
            try relauncher.run()
        } catch {
            status = .failed("Installed \(version). Quit and reopen Cores to finish.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApplication.shared.terminate(nil) }
    }

    // MARK: - Helpers

    private static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else { return false }
        let files = FileManager.default
        return files.isWritableFile(atPath: app.deletingLastPathComponent().path) && files.isWritableFile(atPath: path)
    }

    nonisolated private static func unpackAndVerify(zip: URL, into dir: URL, identifier: String, version: String) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("couldn't unpack the download") }

        let app = dir.appendingPathComponent("Cores.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("the download isn't the expected version of Cores") }

        try verifySignature(of: app, identifier: identifier)
        return app
    }

    /// Accepts only an app signed with this team's Developer ID certificate (Apple's Developer ID
    /// requirement plus our Team ID), with every file in the bundle checked against the signature.
    nonisolated private static func verifySignature(of app: URL, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("couldn't read the download's signature")
        }
        let rule = """
        identifier "\(identifier)" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("couldn't check the download's signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else {
            throw UpdateError("the download isn't signed by Steve Morris & Son LLP")
        }
    }

    /// Compares dotted versions numerically, so 1.10 is newer than 1.9.
    nonisolated static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

extension Updater {
    /// One line for the settings screen.
    var statusText: String {
        switch status {
        case .idle:
            lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        case .checking: "Checking for updates…"
        case .upToDate: "Cores is up to date"
        case .downloading(let version): "Downloading \(version)…"
        case .installing(let version): "Installing \(version)…"
        case .restarting(let version): "Restarting into \(version)…"
        case .waitingToRestart(let version): "\(version) installed. It restarts when you close this."
        case .manualUpdateNeeded(let version, _): "\(version) is available to download"
        case .failed(let message): message
        }
    }
}
