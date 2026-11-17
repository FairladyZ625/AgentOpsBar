import Foundation

public struct PanelSpec: Identifiable, Equatable {
    public let key: String
    public let label: String
    public let enabled: Bool

    public var id: String { key }

    public static let all: [PanelSpec] = [
        PanelSpec(key: "colab", label: "Colab", enabled: true),
        PanelSpec(key: "agents", label: "Agents", enabled: true),
        PanelSpec(key: "ci", label: "CI / 交付", enabled: true),
        PanelSpec(key: "host", label: "宿主", enabled: true),
    ]
}

public struct UnifiedProbePayload: Decodable, Equatable {
    public let checkedAt: Double
    public let colab: PoolStatusSnapshot
    public let agents: AgentsStatusSnapshot
    public let ops: OpsStatusSnapshot
}

public struct PoolStatusSnapshot: Decodable, Equatable {
    public let installed: Bool?
    public let configured: Bool
    public let error: String?
    public let primaryAccount: String?
    public let networkBlocked: Bool?
    public let healthyAccounts: Int?
    public let totalPaidBalanceCu: Double?
    public let totalBurnRateHourly: Double?
    public let activeNodes: Int?
    public let drainingNodes: Int?
    public let maxNodes: Int?
    public let slotsPerNode: Int?
    public let maxSlots: Int?
    public let activeSlots: Int?
    public let availableSlots: Int?
    public let availableCpu: Int?
    public let availableMemoryGiB: Int?
    public let idleTimeoutSeconds: Double?
    public let nodes: [NodeRecord]?
    public let accounts: [AccountRecord]?

    public var isInstalled: Bool {
        installed ?? true
    }

    public var balanceCu: Double { totalPaidBalanceCu ?? 0.0 }
    public var burnRateHourly: Double { totalBurnRateHourly ?? 0.0 }
    public var nodeCount: Int { activeNodes ?? 0 }
    public var maxNodeCount: Int { maxNodes ?? 0 }
    public var slotCount: Int { activeSlots ?? 0 }
    public var maxSlotCount: Int { maxSlots ?? 0 }
    public var perNodeSlots: Int { slotsPerNode ?? 2 }
    public var idleTimeout: Double { idleTimeoutSeconds ?? 600.0 }
    public var nodeItems: [NodeRecord] { (nodes ?? []).sorted { $0.nodeId < $1.nodeId } }
    public var accountItems: [AccountRecord] { accounts ?? [] }

    public var effectivePrimaryAccount: String? {
        if let p = primaryAccount, !p.isEmpty {
            return p
        }
        return accountItems.max(by: { ($0.paidBalance ?? 0) < ($1.paidBalance ?? 0) })?.alias
    }

    public var isIdleWasting: Bool {
        (nodeCount > 0 && slotCount == 0) || (cloudActiveVmsCount > 0 && nodeCount == 0)
    }

    public var cloudActiveVmsCount: Int {
        accountItems.reduce(0) { $0 + ($1.activeVmsCount ?? 0) }
    }

    public var prioritizedAccounts: [AccountRecord] {
        let primary = effectivePrimaryAccount
        return accountItems.sorted { lhs, rhs in
            let lPri = (primary != nil && lhs.alias == primary) ? 0 : 1
            let rPri = (primary != nil && rhs.alias == primary) ? 0 : 1
            if lPri != rPri { return lPri < rPri }
            let lBal = lhs.paidBalance ?? 0.0
            let rBal = rhs.paidBalance ?? 0.0
            if abs(lBal - rBal) > 0.001 { return lBal > rBal }
            return lhs.alias < rhs.alias
        }
    }
}

public struct NodeRecord: Decodable, Identifiable, Equatable {
    public let nodeId: String
    public let status: String
    public let account: String?
    public let endpoint: String?
    public let createdAt: Double?
    public let lastUsedAt: Double?
    public let slotsPerNode: Int?
    public let activeSlots: Int?
    public let activeProjects: [String]?

    public var id: String { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case status
        case account
        case endpoint
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case slotsPerNode = "slots_per_node"
        case activeSlots = "active_slots"
        case activeProjects = "active_projects"
    }

    public func idleRemainingSeconds(now: Double, idleTimeout: Double) -> Double {
        let anchor = lastUsedAt ?? createdAt ?? now
        return max(0, idleTimeout - max(0, now - anchor))
    }
}

public struct AccountRecord: Decodable, Identifiable, Equatable {
    public let alias: String
    public let ok: Bool?
    public let paidBalance: Double?
    public let burnRateHourly: Double?
    public let activeVmsCount: Int?

    public var id: String { alias }

    enum CodingKeys: String, CodingKey {
        case alias
        case ok
        case paidBalance = "paid_balance"
        case burnRateHourly = "burn_rate_hourly"
        case activeVmsCount = "active_vms_count"
    }
}

public struct AgentsStatusSnapshot: Decodable, Equatable {
    public let checkedAt: Double
    public let haInstalled: Bool?
    public let activeWorkers: Int
    public let taskWorkers: Int
    public let agyPoolStandby: Int
    public let longRunningWarnings: Int
    public let totalWorkerMemoryMb: Double
    public let byKind: [String: Int]
    public let daemon: AgentDaemonStatus
    public let instances: AgentInstancesSummary
    public let bridges: [AgentBridgeStatus]
    public let workers: [AgentWorkerRecord]
}

public struct AgentDaemonStatus: Decodable, Equatable {
    public let online: Bool
    public let pid: Int?
    public let drifted: Bool
    public let attachedRepos: Int
    public let unhealthyRepos: Int
}

public struct AgentInstancesSummary: Decodable, Equatable {
    public let total: Int
    public let healthy: Int
    public let frozenIds: [String]
    public let cooldownIds: [String]
}

public struct AgentBridgeStatus: Decodable, Identifiable, Equatable {
    public let key: String
    public let label: String
    public let online: Bool
    public let warning: Bool
    public let detail: String

    public var id: String { key }
}

public struct AgentWorkerRecord: Decodable, Identifiable, Equatable {
    public let pid: Int
    public let ppid: Int
    public let kind: String
    public let scope: String
    public let model: String
    public let cpuPercent: Double
    public let memoryMb: Double
    public let elapsedSeconds: Int
    public let workspace: String
    public let taskLabel: String?
    public let longRunningWarning: Bool

    public var id: Int { pid }

    public func liveElapsedSeconds(now: Double, checkedAt: Double) -> Double {
        return Double(elapsedSeconds) + max(0, now - checkedAt)
    }
}

public struct OpsStatusSnapshot: Decodable, Equatable {
    public let checkedAt: Double
    public let ci: CiPipelineSnapshot
    public let host: HostVitalsSnapshot
}

public struct CiPipelineSnapshot: Decodable, Equatable {
    public let ghAvailable: Bool
    public let openPrs: Int
    public let passingPrs: Int
    public let runningPrs: Int
    public let failingPrs: Int
    public let conflictPrs: Int
    public let prs: [PullRequestRecord]
    public let reviewQueue: HarnessReviewQueue
}

public struct PullRequestRecord: Decodable, Identifiable, Equatable {
    public let id: String
    public let repo: String
    public let fullRepo: String
    public let number: Int
    public let title: String
    public let branch: String
    public let author: String
    public let isDraft: Bool
    public let mergeState: String
    public let reviewDecision: String
    public let updatedAt: String
    public let url: String
    public let ciState: String
    public let checksPassed: Int
    public let checksFailed: Int
    public let checksPending: Int
    public let checksTotal: Int
}

public struct HarnessReviewQueue: Decodable, Equatable {
    public let inReview: Int
    public let submitted: Int
    public let blocked: Int
    public let total: Int
    public let items: [HarnessQueueItem]
}

public struct HarnessQueueItem: Decodable, Identifiable, Equatable {
    public let id: String
    public let repo: String
    public let taskId: String
    public let status: String
    public let title: String
    public let updatedAt: String
}

public struct HostVitalsSnapshot: Decodable, Equatable {
    public let cpuCores: Int
    public let loadAvg1m: Double
    public let loadAvg5m: Double
    public let cpuLoadPercent: Int
    public let memoryFreePercent: Int
    public let memoryUsedPercent: Int
    public let diskFreeGiB: Double
    public let diskTotalGiB: Double
    public let diskUsedPercent: Double
    public let diskWarning: Bool
    public let totalWorktrees: Int
    public let totalUnpushed: Int
    public let dirtyRepos: Int
    public let repos: [RepoRadarRecord]
}

public struct RepoRadarRecord: Decodable, Identifiable, Equatable {
    public let name: String
    public let path: String
    public let branch: String
    public let dirtyCount: Int
    public let unpushedCount: Int
    public let worktreeCount: Int

    public var id: String { path }
}

public enum DurationFormatter {
    public static func compact(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        let hours = mins / 60
        let remMins = mins % 60
        if hours > 0 {
            return String(format: "%dh%02dm", hours, remMins)
        }
        return String(format: "%dm%02ds", mins, secs)
    }
}
