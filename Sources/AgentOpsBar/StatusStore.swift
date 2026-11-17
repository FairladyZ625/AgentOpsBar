import AppKit
import Foundation
import ServiceManagement

enum MonitorHealthState: Equatable {
    case loading
    case error
    case zeroBurn
    case activeWork
    case idleWasting
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var snapshot: PoolStatusSnapshot?
    @Published private(set) var agentsSnapshot: AgentsStatusSnapshot?
    @Published private(set) var opsSnapshot: OpsStatusSnapshot?
    @Published private(set) var colabErrorMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastUpdatedText: String = "--:--:--"
    @Published private(set) var nowTimestamp: Double = Date().timeIntervalSince1970
    @Published var activeTab: String = "colab"
    @Published var ciSubTab: String = "prs"
    @Published var isFloatingCollapsed: Bool = false
    @Published var showMenuBarRate: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarRate, forKey: Self.menuBarRateKey)
            onPresentationChange?()
        }
    }
    @Published var isFloatingPinned: Bool {
        didSet {
            UserDefaults.standard.set(isFloatingPinned, forKey: Self.floatingPinnedKey)
            onFloatingToggle?(isFloatingPinned)
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var launchAtLoginError: String?

    var onPresentationChange: (() -> Void)?
    var onFloatingToggle: ((Bool) -> Void)?

    private static let menuBarRateKey = "agentOpsBar.showMenuBarRate"
    private static let floatingPinnedKey = "agentOpsBar.isFloatingPinned"
    private static let pollIntervalSeconds: TimeInterval = 15.0
    private static let subprocessTimeoutSeconds: TimeInterval = 25.0

    private var initialBalanceCu: Double?
    private var didAutoSelectTab = false
    private var lastRawJson: String = ""
    private var pollTimer: Timer?
    private var secondTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.menuBarRateKey) == nil {
            defaults.set(true, forKey: Self.menuBarRateKey)
        }
        self.showMenuBarRate = defaults.bool(forKey: Self.menuBarRateKey)
        self.isFloatingPinned = defaults.bool(forKey: Self.floatingPinnedKey)
        syncLaunchAtLoginStatus()
    }

    func start() {
        refresh(forceLive: false)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(forceLive: false)
            }
        }
        secondTimer?.invalidate()
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let hasNodes = !(self.snapshot?.nodeItems.isEmpty ?? true)
                let hasWorkers = !(self.agentsSnapshot?.workers.isEmpty ?? true)
                if hasNodes || hasWorkers {
                    self.nowTimestamp = Date().timeIntervalSince1970
                }
            }
        }
    }

    var balanceDeltaCu: Double {
        guard let snap = snapshot, snap.isInstalled, let base = initialBalanceCu else { return 0.0 }
        return snap.balanceCu - base
    }

    var healthState: MonitorHealthState {
        if errorMessage != nil && snapshot == nil && agentsSnapshot == nil {
            return .error
        }
        guard let agents = agentsSnapshot else {
            return .loading
        }
        if let colabErr = colabErrorMessage, !colabErr.isEmpty {
            return .error
        }
        if (agents.haInstalled ?? false) && !agents.daemon.online {
            return .idleWasting
        }
        if let snap = snapshot, snap.isInstalled && snap.isIdleWasting {
            return .idleWasting
        }
        if (snapshot?.slotCount ?? 0) > 0 || agents.activeWorkers > 0 {
            return .activeWork
        }
        return .zeroBurn
    }

    var menuBarSummaryText: String {
        guard showMenuBarRate else { return "" }
        if errorMessage != nil && snapshot == nil && agentsSnapshot == nil {
            return "异常"
        }
        guard let agents = agentsSnapshot else {
            return "…"
        }
        let taskAgents = agents.taskWorkers
        let failPrs = opsSnapshot?.ci.failingPrs ?? 0
        let prSuffix = failPrs > 0 ? " · \(failPrs)PR✗" : ""

        if let snap = snapshot, snap.isInstalled {
            let agentSuffix = taskAgents > 0 ? " · \(taskAgents)A" : ""
            if snap.nodeCount == 0 && snap.cloudActiveVmsCount == 0 {
                return "0 CU/h\(agentSuffix)\(prSuffix)"
            }
            if snap.slotCount > 0 {
                return String(format: "%.2f CU/h · %d槽%@%@", snap.burnRateHourly, snap.slotCount, agentSuffix, prSuffix)
            }
            return String(format: "%.2f CU/h · 空载%@%@", snap.burnRateHourly, agentSuffix, prSuffix)
        }

        if agents.activeWorkers > 0 {
            return "\(agents.activeWorkers)A\(prSuffix)"
        }
        return failPrs > 0 ? "\(failPrs)PR✗" : "空闲"
    }

    func refresh(forceLive: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        onPresentationChange?()

        let fastMode = !forceLive
        let timeout = Self.subprocessTimeoutSeconds
        Task.detached(priority: .utility) {
            let result = Self.invokeUnifiedProbe(fast: fastMode, timeout: timeout)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.nowTimestamp = Date().timeIntervalSince1970
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                self.lastUpdatedText = formatter.string(from: Date())

                switch result {
                case let .success((payload, raw)):
                    self.colabErrorMessage = payload.colab.error
                    if payload.colab.error == nil || self.snapshot == nil {
                        self.snapshot = payload.colab
                    }
                    self.agentsSnapshot = payload.agents
                    self.opsSnapshot = payload.ops
                    self.lastRawJson = raw
                    self.errorMessage = nil
                    if payload.colab.isInstalled && self.initialBalanceCu == nil && payload.colab.configured {
                        self.initialBalanceCu = payload.colab.balanceCu
                    }
                    if !self.didAutoSelectTab {
                        self.didAutoSelectTab = true
                        if !payload.colab.isInstalled {
                            self.activeTab = "agents"
                        }
                    }
                case let .failure(err):
                    self.errorMessage = err.localizedDescription
                }

                self.onPresentationChange?()
            }
        }
    }

    func copyRawJsonToPasteboard() {
        guard !lastRawJson.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastRawJson, forType: .string)
    }

    func openExternalUrl(_ raw: String) {
        guard let url = URL(string: raw), !raw.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    func revealPathInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func syncLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = (status == .enabled)
    }

    func toggleLaunchAtLogin() {
        launchAtLoginError = nil
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            syncLaunchAtLoginStatus()
        } catch {
            syncLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
        }
    }

    private struct CLIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class LockedDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    nonisolated private static func resolveProbeScriptPath() -> String? {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["AGENT_OPS_PROBE"],
           !custom.isEmpty,
           fm.isReadableFile(atPath: custom) {
            return custom
        }
        if let bundled = Bundle.main.path(forResource: "agent_ops_probe", ofType: "py"),
           fm.isReadableFile(atPath: bundled) {
            return bundled
        }
        let cwdCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Resources/agent_ops_probe.py")
            .path
        if fm.isReadableFile(atPath: cwdCandidate) {
            return cwdCandidate
        }
        return nil
    }

    nonisolated private static func invokeUnifiedProbe(
        fast: Bool,
        timeout: TimeInterval
    ) -> Result<(UnifiedProbePayload, String), Error> {
        guard let scriptPath = resolveProbeScriptPath() else {
            return .failure(CLIError(message: "未找到内置采集脚本 agent_ops_probe.py"))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = fast ? [scriptPath, "snapshot", "--fast"] : [scriptPath, "snapshot"]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existingPath]).filter { !$0.isEmpty }.joined(separator: ":")
        env["HOME"] = home
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBuf = LockedDataBuffer()
        let errBuf = LockedDataBuffer()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            outBuf.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            errBuf.append(handle.availableData)
        }

        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            sema.signal()
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(CLIError(message: "无法启动 python3: \(error.localizedDescription)"))
        }

        let waitResult = sema.wait(timeout: .now() + timeout)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if waitResult == .timedOut {
            proc.terminate()
            return .failure(CLIError(message: "采集超时 (\(Int(timeout))s)"))
        }

        outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        let finalOut = outBuf.snapshot()
        let finalErr = errBuf.snapshot()

        let stdoutStr = String(data: finalOut, encoding: .utf8) ?? ""
        let stderrStr = String(data: finalErr, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            let combined = (stderrStr.isEmpty ? stdoutStr : stderrStr).trimmingCharacters(in: .whitespacesAndNewlines)
            let lastLine = combined.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(proc.terminationStatus)"
            return .failure(CLIError(message: lastLine))
        }

        do {
            let decoded = try JSONDecoder().decode(UnifiedProbePayload.self, from: Data(stdoutStr.utf8))
            return .success((decoded, stdoutStr))
        } catch {
            return .failure(CLIError(message: "JSON 解析失败: \(error.localizedDescription)"))
        }
    }
}
