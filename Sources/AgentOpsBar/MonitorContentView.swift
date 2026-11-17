import AppKit
import SwiftUI

enum MonitorSurfaceMode {
    case popover
    case floating
}

enum MonitorPalette {
    static let bg = Color(red: 0x14 / 255.0, green: 0x16 / 255.0, blue: 0x1B / 255.0)
    static let card = Color(red: 0x1C / 255.0, green: 0x20 / 255.0, blue: 0x28 / 255.0)
    static let border = Color(red: 0x2C / 255.0, green: 0x32 / 255.0, blue: 0x3F / 255.0)
    static let text = Color(red: 0xE6 / 255.0, green: 0xEA / 255.0, blue: 0xF2 / 255.0)
    static let muted = Color(red: 0x8B / 255.0, green: 0x93 / 255.0, blue: 0xA7 / 255.0)
    static let accent = Color(red: 0x5B / 255.0, green: 0x9C / 255.0, blue: 0xF6 / 255.0)
    static let cyan = Color(red: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0)
    static let green = Color(red: 0x4A / 255.0, green: 0xDE / 255.0, blue: 0x80 / 255.0)
    static let amber = Color(red: 0xFB / 255.0, green: 0xBF / 255.0, blue: 0x24 / 255.0)
    static let red = Color(red: 0xF8 / 255.0, green: 0x71 / 255.0, blue: 0x71 / 255.0)
}

struct MonitorContentView: View {
    @ObservedObject var store: StatusStore
    let mode: MonitorSurfaceMode
    var onDismissPopover: (() -> Void)?

    private var collapsed: Bool {
        mode == .floating && store.isFloatingCollapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            if !collapsed {
                tabBar

                switch store.activeTab {
                case "colab":
                    colabPanel
                case "agents":
                    agentsPanel
                case "ci":
                    ciPanel
                default:
                    hostPanel
                }
            }
        }
        .padding(12)
        .frame(width: 386)
        .background(MonitorPalette.bg)
        .overlay(
            RoundedRectangle(cornerRadius: mode == .floating ? 12 : 0)
                .stroke(MonitorPalette.border, lineWidth: mode == .floating ? 1 : 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: mode == .floating ? 12 : 0))
    }

    private var dotColor: Color {
        switch store.healthState {
        case .loading:
            return MonitorPalette.muted
        case .error:
            return MonitorPalette.red
        case .zeroBurn:
            return MonitorPalette.green
        case .activeWork:
            return MonitorPalette.accent
        case .idleWasting:
            return MonitorPalette.amber
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text("AgentOpsBar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MonitorPalette.text)

            if collapsed {
                Text(store.menuBarSummaryText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MonitorPalette.muted)
                    .lineLimit(1)
            } else {
                Text(store.lastUpdatedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MonitorPalette.muted)
            }

            Spacer(minLength: 4)

            Button {
                store.refresh(forceLive: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.isRefreshing ? MonitorPalette.accent : MonitorPalette.muted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("立即刷新全部实时状态")
            .accessibilityLabel("立即刷新状态")

            Button {
                let nextPinned = !store.isFloatingPinned
                store.isFloatingPinned = nextPinned
                if nextPinned && mode == .popover {
                    onDismissPopover?()
                }
            } label: {
                Image(systemName: store.isFloatingPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.isFloatingPinned ? MonitorPalette.accent : MonitorPalette.muted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(store.isFloatingPinned ? "关闭桌面置顶悬浮窗" : "固定为桌面置顶悬浮窗")
            .accessibilityLabel(store.isFloatingPinned ? "关闭桌面置顶悬浮窗" : "固定为桌面置顶悬浮窗")

            if mode == .floating {
                Button {
                    store.isFloatingCollapsed.toggle()
                } label: {
                    Image(systemName: store.isFloatingCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorPalette.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(store.isFloatingCollapsed ? "展开悬浮窗" : "折叠悬浮窗")
                .accessibilityLabel(store.isFloatingCollapsed ? "展开悬浮窗" : "折叠悬浮窗")

                Button {
                    store.isFloatingPinned = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MonitorPalette.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("关闭桌面悬浮窗（保留菜单栏图标）")
                .accessibilityLabel("关闭桌面悬浮窗")
            } else {
                settingsMenu
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                store.showMenuBarRate.toggle()
            } label: {
                Label(
                    store.showMenuBarRate ? "隐藏菜单栏文字摘要" : "显示菜单栏文字摘要",
                    systemImage: store.showMenuBarRate ? "eye.slash" : "eye"
                )
            }

            Button {
                store.toggleLaunchAtLogin()
            } label: {
                Label(
                    store.launchAtLoginEnabled ? "已开启开机自启" : "开启开机自启",
                    systemImage: store.launchAtLoginEnabled ? "checkmark.circle.fill" : "circle"
                )
            }

            Button {
                store.copyRawJsonToPasteboard()
            } label: {
                Label("复制完整快照 JSON", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 AgentOpsBar", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MonitorPalette.muted)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("偏好设置与退出")
        .accessibilityLabel("偏好设置菜单")
    }

    private func tabBadge(for key: String) -> (String, Color)? {
        switch key {
        case "colab":
            guard let snap = store.snapshot, snap.isInstalled else { return nil }
            let col = snap.isIdleWasting ? MonitorPalette.amber : MonitorPalette.accent
            return ("\(snap.nodeCount)", col)
        case "agents":
            guard let agents = store.agentsSnapshot else { return nil }
            let col = agents.longRunningWarnings > 0 ? MonitorPalette.amber : MonitorPalette.accent
            return ("\(agents.activeWorkers)", col)
        case "ci":
            guard let ci = store.opsSnapshot?.ci else { return nil }
            let col: Color = ci.failingPrs > 0
                ? MonitorPalette.red
                : (ci.reviewQueue.blocked > 0 ? MonitorPalette.amber : MonitorPalette.accent)
            return ("\(ci.openPrs)", col)
        case "host":
            guard let host = store.opsSnapshot?.host else { return nil }
            return host.diskWarning ? ("!", MonitorPalette.amber) : nil
        default:
            return nil
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelSpec.all) { spec in
                let isSelected = store.activeTab == spec.key
                Button {
                    store.activeTab = spec.key
                } label: {
                    HStack(spacing: 4) {
                        Text(spec.label)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? MonitorPalette.text : MonitorPalette.muted)

                        if let (badge, badgeColor) = tabBadge(for: spec.key) {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? badgeColor : badgeColor.opacity(0.85))
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? MonitorPalette.card : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(spec.label) 面板")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Phase 1: Colab Panel

    private var colabPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.errorMessage {
                errorBanner(err)
            }

            if let colabErr = store.colabErrorMessage, !colabErr.isEmpty {
                errorBanner(colabErr)
            }

            if let err = store.launchAtLoginError {
                errorBanner("开机自启设置失败: \(err)")
            }

            if let snap = store.snapshot, !snap.isInstalled {
                emptyRow(
                    icon: "cloud",
                    text: "未安装 colab-pool CLI · Agents / CI / 宿主面板正常可用",
                    color: MonitorPalette.muted
                )
            } else {
                metricCard
                nodesSection
                if let snap = store.snapshot, !snap.accountItems.isEmpty {
                    accountsStrip(snap.prioritizedAccounts, primaryAlias: snap.effectivePrimaryAccount)
                }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(MonitorPalette.red)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(MonitorPalette.red)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MonitorPalette.red.opacity(0.12))
        )
    }

    private var metricCard: some View {
        let snap = store.snapshot
        let balanceText: String = {
            guard let snap else { return "-- CU" }
            let delta = store.balanceDeltaCu
            if abs(delta) >= 0.01 {
                return String(format: "%.2f CU (%+.2f)", snap.balanceCu, delta)
            }
            return String(format: "%.2f CU", snap.balanceCu)
        }()

        let (burnText, burnColor): (String, Color) = {
            guard let snap else { return ("-- CU/h", MonitorPalette.muted) }
            if snap.nodeCount == 0 && snap.cloudActiveVmsCount == 0 {
                return ("0.00 CU/h · 零消耗", MonitorPalette.green)
            }
            if snap.slotCount > 0 {
                return (String(format: "%.2f CU/h · 使用中", snap.burnRateHourly), MonitorPalette.accent)
            }
            return (String(format: "%.2f CU/h · 空载", snap.burnRateHourly), MonitorPalette.amber)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(balanceText)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MonitorPalette.text)

                Spacer()

                pillBadge(text: burnText, color: burnColor)
            }

            if let snap {
                HStack(spacing: 10) {
                    statChip(title: "节点", value: "\(snap.nodeCount)/\(snap.maxNodeCount)")
                    statChip(title: "槽位", value: "\(snap.slotCount)/\(snap.maxSlotCount)")
                    if let availCpu = snap.availableCpu {
                        statChip(title: "空闲核", value: "\(availCpu)C")
                    }
                    if snap.cloudActiveVmsCount != snap.nodeCount && snap.cloudActiveVmsCount > 0 {
                        Spacer(minLength: 0)
                        Text("云端 \(snap.cloudActiveVmsCount) VM")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MonitorPalette.amber)
                            .help("账号实开 VM 数与本地池记录不一致")
                    }
                }
            } else {
                Text("正在获取状态…")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(MonitorPalette.card)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MonitorPalette.border, lineWidth: 1)
            )
    }

    private func pillBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
    }

    private func statChip(title: String, value: String, valueColor: Color = MonitorPalette.text) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(MonitorPalette.muted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }

    @ViewBuilder
    private var nodesSection: some View {
        if let snap = store.snapshot {
            let items = snap.nodeItems
            if items.isEmpty {
                emptyRow(
                    icon: "checkmark.seal.fill",
                    text: snap.cloudActiveVmsCount == 0 ? "无活跃 VM · 零空耗" : "本地池无活跃节点（云端仍有 \(snap.cloudActiveVmsCount) 台 VM）",
                    color: snap.cloudActiveVmsCount == 0 ? MonitorPalette.green : MonitorPalette.amber
                )
            } else if items.count <= 4 {
                VStack(spacing: 6) {
                    ForEach(items) { node in
                        nodeCard(node, snapshot: snap)
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 6) {
                        ForEach(items) { node in
                            nodeCard(node, snapshot: snap)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(height: 232)
            }
        }
    }

    private func emptyRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MonitorPalette.card)
        )
    }

    private func nodeCard(_ node: NodeRecord, snapshot: PoolStatusSnapshot) -> some View {
        let slotsCap = node.slotsPerNode ?? snapshot.perNodeSlots
        let usedSlots = node.activeSlots ?? (snapshot.slotCount > 0 ? 1 : 0)
        let projects = node.activeProjects ?? []
        let remain = node.idleRemainingSeconds(now: store.nowTimestamp, idleTimeout: snapshot.idleTimeout)

        let statusColor: Color = {
            switch node.status {
            case "ready":
                return usedSlots > 0 ? MonitorPalette.accent : MonitorPalette.green
            case "booting", "draining":
                return MonitorPalette.amber
            default:
                return MonitorPalette.muted
            }
        }()

        let detailLine: (String, Color) = {
            if node.status == "booting" {
                let projText = projects.isEmpty ? "" : " · \(projects.joined(separator: ", "))"
                return ("启动分配中 · 预占 \(usedSlots)/\(slotsCap) 槽\(projText)", MonitorPalette.amber)
            }
            if usedSlots > 0 {
                let projText = projects.isEmpty ? "执行任务中" : projects.joined(separator: ", ")
                return ("占用 \(usedSlots)/\(slotsCap) 槽 · \(projText)", MonitorPalette.text.opacity(0.88))
            }
            if remain > 0 {
                return ("空闲 \(DurationFormatter.compact(remain)) 后自动回收", MonitorPalette.muted)
            }
            return ("已达空闲阈值 · 等待回收", MonitorPalette.amber)
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(node.nodeId)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MonitorPalette.text)

                smallTag(text: node.status, color: statusColor)

                Spacer()

                Text(node.account ?? "-")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(node.account == snapshot.effectivePrimaryAccount ? MonitorPalette.accent : MonitorPalette.muted)
            }

            Text(detailLine.0)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(detailLine.1)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(MonitorPalette.card)
        )
    }

    private func smallTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }

    private func accountsStrip(_ accounts: [AccountRecord], primaryAlias: String?) -> some View {
        VStack(spacing: 4) {
            ForEach(accounts) { acc in
                let vms = acc.activeVmsCount ?? 0
                let bal = acc.paidBalance ?? 0.0
                let ok = acc.ok ?? true
                let isPrimary = (primaryAlias != nil && acc.alias == primaryAlias)
                HStack(spacing: 6) {
                    Circle()
                        .fill(!ok ? MonitorPalette.red : (vms > 0 ? MonitorPalette.accent : MonitorPalette.muted.opacity(0.5)))
                        .frame(width: 6, height: 6)

                    Text(acc.alias)
                        .font(.system(size: 11, weight: isPrimary ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(MonitorPalette.text)

                    if isPrimary {
                        Text("主力")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MonitorPalette.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(MonitorPalette.accent.opacity(0.16))
                            )
                    }

                    Spacer()

                    Text(String(format: "%.1f CU", bal))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(MonitorPalette.muted)

                    Text("\(vms) VM")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(vms > 0 ? MonitorPalette.accent : MonitorPalette.muted)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(MonitorPalette.card.opacity(0.65))
        )
    }

    // MARK: - Phase 2: Agents Panel

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.errorMessage {
                errorBanner(err)
            }

            agentsSummaryCard

            if let agents = store.agentsSnapshot {
                agentsWorkersSection(agents)
                bridgesStrip(agents.bridges)
            }
        }
    }

    private var agentsSummaryCard: some View {
        let agents = store.agentsSnapshot
        let headline = agents.map { "\($0.activeWorkers) 活跃会话" } ?? "-- Agents"

        let (pillText, pillColor): (String, Color) = {
            guard let agents else { return ("采集中…", MonitorPalette.muted) }
            if (agents.haInstalled ?? false) && !agents.daemon.online {
                return ("Ha Daemon 离线", MonitorPalette.red)
            }
            if !agents.instances.frozenIds.isEmpty {
                return ("实例冻结: \(agents.instances.frozenIds.count)", MonitorPalette.amber)
            }
            if agents.longRunningWarnings > 0 {
                return ("\(agents.longRunningWarnings) 个超 60m", MonitorPalette.amber)
            }
            if agents.daemon.online {
                return ("Ha 在线 · \(agents.daemon.attachedRepos)仓", MonitorPalette.green)
            }
            return ("本机进程监控", MonitorPalette.green)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MonitorPalette.text)

                Spacer()

                pillBadge(text: pillText, color: pillColor)
            }

            if let agents {
                HStack(spacing: 10) {
                    statChip(title: "派工", value: "\(agents.taskWorkers)")
                    if agents.instances.total > 0 {
                        statChip(title: "实例", value: "\(agents.instances.healthy)/\(agents.instances.total)")
                    }
                    if agents.agyPoolStandby > 0 {
                        statChip(title: "AGY池", value: "\(agents.agyPoolStandby)")
                    }
                    let memGb = agents.totalWorkerMemoryMb / 1024.0
                    statChip(
                        title: "内存",
                        value: memGb >= 1.0
                            ? String(format: "%.1fG", memGb)
                            : String(format: "%.0fM", agents.totalWorkerMemoryMb)
                    )
                }
            } else {
                Text("正在扫描本地与远端智能体…")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    @ViewBuilder
    private func agentsWorkersSection(_ agents: AgentsStatusSnapshot) -> some View {
        if agents.workers.isEmpty {
            emptyRow(icon: "zzz", text: "当前无活跃派工或交互智能体", color: MonitorPalette.green)
        } else if agents.workers.count <= 4 {
            VStack(spacing: 6) {
                ForEach(agents.workers) { worker in
                    workerCard(worker, checkedAt: agents.checkedAt)
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(agents.workers) { worker in
                        workerCard(worker, checkedAt: agents.checkedAt)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: 232)
        }
    }

    private func workerCard(_ worker: AgentWorkerRecord, checkedAt: Double) -> some View {
        let kindColor: Color = {
            switch worker.kind {
            case "Codex":
                return MonitorPalette.accent
            case "DSH":
                return MonitorPalette.cyan
            case "Claude":
                return MonitorPalette.amber
            case "AGY":
                return MonitorPalette.green
            default:
                return MonitorPalette.muted
            }
        }()

        let elapsed = worker.liveElapsedSeconds(now: store.nowTimestamp, checkedAt: checkedAt)
        let rightStat = String(format: "%@ · %.0fM", DurationFormatter.compact(elapsed), worker.memoryMb)

        let targetLine: String = {
            if let task = worker.taskLabel, !task.isEmpty {
                return "\(worker.workspace) · \(task)"
            }
            return "\(worker.workspace) · \(worker.scope == "task" ? "任务执行" : "交互会话")"
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                smallTag(text: worker.kind, color: kindColor)

                Text(worker.model)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MonitorPalette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(rightStat)
                    .font(.system(size: 10.5, weight: worker.longRunningWarning ? .semibold : .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(worker.longRunningWarning ? MonitorPalette.amber : MonitorPalette.muted)
            }

            HStack(spacing: 6) {
                Text(targetLine)
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.text.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("PID \(worker.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MonitorPalette.muted.opacity(0.75))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(MonitorPalette.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(worker.longRunningWarning ? MonitorPalette.amber.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
    }

    private func bridgesStrip(_ bridges: [AgentBridgeStatus]) -> some View {
        HStack(spacing: 8) {
            ForEach(bridges) { b in
                let c: Color = !b.online ? MonitorPalette.muted.opacity(0.45) : (b.warning ? MonitorPalette.amber : MonitorPalette.green)
                HStack(spacing: 4) {
                    Circle()
                        .fill(c)
                        .frame(width: 6, height: 6)
                    Text(b.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(b.online ? MonitorPalette.text : MonitorPalette.muted)
                        .lineLimit(1)
                }
                .help("\(b.label): \(b.detail)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(MonitorPalette.card.opacity(0.65))
        )
    }

    // MARK: - Phase 3: CI / Delivery Pipeline Panel

    private var ciPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.errorMessage {
                errorBanner(err)
            }

            ciSummaryCard

            if let ci = store.opsSnapshot?.ci {
                ciSubSelector(ci)

                if store.ciSubTab == "prs" {
                    prsListSection(ci)
                } else {
                    reviewQueueSection(ci.reviewQueue)
                }
            }
        }
    }

    private var ciSummaryCard: some View {
        let ci = store.opsSnapshot?.ci
        let headline = ci.map { "\($0.openPrs) 开放 PR" } ?? "-- PR"

        let (pillText, pillColor): (String, Color) = {
            guard let ci else { return ("同步中…", MonitorPalette.muted) }
            if ci.failingPrs > 0 {
                return ("\(ci.failingPrs) 个门禁失败", MonitorPalette.red)
            }
            if ci.runningPrs > 0 {
                return ("\(ci.runningPrs) 个门禁运行中", MonitorPalette.accent)
            }
            if ci.openPrs > 0 {
                return ("门禁全部通过", MonitorPalette.green)
            }
            return ("无开放 PR", MonitorPalette.green)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MonitorPalette.text)

                Spacer()

                pillBadge(text: pillText, color: pillColor)
            }

            if let ci {
                HStack(spacing: 10) {
                    statChip(title: "通过", value: "\(ci.passingPrs)", valueColor: MonitorPalette.green)
                    statChip(title: "运行", value: "\(ci.runningPrs)", valueColor: MonitorPalette.accent)
                    statChip(
                        title: "失败",
                        value: "\(ci.failingPrs)",
                        valueColor: ci.failingPrs > 0 ? MonitorPalette.red : MonitorPalette.text
                    )
                    statChip(
                        title: "待审",
                        value: "\(ci.reviewQueue.inReview + ci.reviewQueue.submitted)"
                    )
                    statChip(
                        title: "阻塞",
                        value: "\(ci.reviewQueue.blocked)",
                        valueColor: ci.reviewQueue.blocked > 0 ? MonitorPalette.amber : MonitorPalette.text
                    )
                }
            } else {
                Text("正在查询 GitHub PR 与待审任务…")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func ciSubSelector(_ ci: CiPipelineSnapshot) -> some View {
        HStack(spacing: 6) {
            subSwitchButton(
                key: "prs",
                title: "GitHub PR · \(ci.openPrs)",
                active: store.ciSubTab == "prs"
            )
            subSwitchButton(
                key: "tasks",
                title: "待审与阻塞 · \(ci.reviewQueue.total)",
                active: store.ciSubTab == "tasks"
            )
            Spacer()
        }
    }

    private func subSwitchButton(key: String, title: String, active: Bool) -> some View {
        Button {
            store.ciSubTab = key
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(active ? MonitorPalette.text : MonitorPalette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? MonitorPalette.card : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(active ? MonitorPalette.border : Color.clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func prsListSection(_ ci: CiPipelineSnapshot) -> some View {
        if ci.prs.isEmpty {
            emptyRow(
                icon: ci.ghAvailable ? "checkmark.circle.fill" : "terminal",
                text: ci.ghAvailable ? "当前没有开放的 GitHub PR" : "未检测到 gh CLI 登录态",
                color: ci.ghAvailable ? MonitorPalette.green : MonitorPalette.muted
            )
        } else if ci.prs.count <= 4 {
            VStack(spacing: 6) {
                ForEach(ci.prs) { pr in
                    prCard(pr)
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(ci.prs) { pr in
                        prCard(pr)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: 232)
        }
    }

    private func prCard(_ pr: PullRequestRecord) -> some View {
        let (stateText, stateColor): (String, Color) = {
            if pr.mergeState == "DIRTY" {
                return ("代码冲突", MonitorPalette.red)
            }
            switch pr.ciState {
            case "failing":
                return ("\(pr.checksFailed) 失败 / \(pr.checksTotal)", MonitorPalette.red)
            case "running":
                return ("\(pr.checksPassed)/\(pr.checksTotal) 运行中", MonitorPalette.accent)
            case "passing":
                return ("\(pr.checksPassed)/\(pr.checksTotal) 通过", MonitorPalette.green)
            default:
                return (pr.isDraft ? "草稿" : "无门禁", MonitorPalette.muted)
            }
        }()

        return Button {
            store.openExternalUrl(pr.url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(pr.number)")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(MonitorPalette.text)

                    Text(pr.repo)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(MonitorPalette.muted)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    smallTag(text: stateText, color: stateColor)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MonitorPalette.muted)
                }

                Text(pr.title)
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.text.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(MonitorPalette.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(pr.ciState == "failing" ? MonitorPalette.red.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("在浏览器打开 \(pr.fullRepo)#\(pr.number)（分支 \(pr.branch)）")
        .accessibilityLabel("打开 PR \(pr.number) \(pr.title)")
    }

    @ViewBuilder
    private func reviewQueueSection(_ queue: HarnessReviewQueue) -> some View {
        if queue.items.isEmpty {
            emptyRow(icon: "tray", text: "无待审或阻塞的 Harness 任务", color: MonitorPalette.green)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(queue.items) { item in
                        queueTaskCard(item)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: min(232, CGFloat(max(1, queue.items.count)) * 54))
        }
    }

    private func queueTaskCard(_ item: HarnessQueueItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.status {
            case "blocked":
                return ("阻塞", MonitorPalette.red)
            case "in_review":
                return ("待审", MonitorPalette.amber)
            default:
                return ("已提交", MonitorPalette.cyan)
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                smallTag(text: label, color: color)

                Text(item.repo)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MonitorPalette.text)

                Spacer()

                Text(item.taskId)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(MonitorPalette.muted)
            }

            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(MonitorPalette.text.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(MonitorPalette.card)
        )
    }

    // MARK: - Phase 4: Mac Host & Worktree Radar Panel

    private var hostPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.errorMessage {
                errorBanner(err)
            }

            hostSummaryCard

            if let host = store.opsSnapshot?.host {
                reposRadarSection(host.repos)
            }
        }
    }

    private var hostSummaryCard: some View {
        let host = store.opsSnapshot?.host
        let headline = host.map { "CPU \($0.cpuLoadPercent)% · 内存余 \($0.memoryFreePercent)%" } ?? "-- Host"

        let (diskText, diskColor): (String, Color) = {
            guard let host else { return ("检测中…", MonitorPalette.muted) }
            let txt = String(format: "余 %.0fG (%.0f%%)", host.diskFreeGiB, host.diskUsedPercent)
            if host.diskFreeGiB < 40.0 {
                return (txt, MonitorPalette.red)
            }
            if host.diskWarning {
                return (txt, MonitorPalette.amber)
            }
            return (txt, MonitorPalette.green)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.system(size: 16.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(MonitorPalette.text)

                Spacer()

                pillBadge(text: diskText, color: diskColor)
            }

            if let host {
                HStack(spacing: 10) {
                    statChip(title: "负载", value: String(format: "%.1f/%dC", host.loadAvg1m, host.cpuCores))
                    statChip(
                        title: "Worktree",
                        value: "\(host.totalWorktrees)",
                        valueColor: host.totalWorktrees >= 40 ? MonitorPalette.amber : MonitorPalette.text
                    )
                    statChip(
                        title: "未推送",
                        value: "\(host.totalUnpushed)",
                        valueColor: host.totalUnpushed > 0 ? MonitorPalette.accent : MonitorPalette.text
                    )
                    statChip(title: "脏仓", value: "\(host.dirtyRepos)")
                }
            } else {
                Text("正在检测本机负载与工作树状态…")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func reposRadarSection(_ repos: [RepoRadarRecord]) -> some View {
        VStack(spacing: 6) {
            ForEach(repos) { repo in
                Button {
                    store.revealPathInFinder(repo.path)
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(MonitorPalette.text)
                                .lineLimit(1)

                            Text(repo.branch)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(MonitorPalette.muted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if repo.unpushedCount > 0 {
                            smallTag(text: "↑\(repo.unpushedCount) 未推", color: MonitorPalette.accent)
                        }

                        if repo.worktreeCount > 0 {
                            smallTag(
                                text: "\(repo.worktreeCount) wt",
                                color: repo.worktreeCount >= 30 ? MonitorPalette.amber : MonitorPalette.cyan
                            )
                        }

                        Text(repo.dirtyCount > 0 ? "\(repo.dirtyCount) 改动" : "干净")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(repo.dirtyCount > 0 ? MonitorPalette.muted : MonitorPalette.green)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(MonitorPalette.card)
                    )
                }
                .buttonStyle(.plain)
                .help("在访达中打开 \(repo.path)")
                .accessibilityLabel("在访达中打开仓库 \(repo.name)")
            }
        }
    }
}
