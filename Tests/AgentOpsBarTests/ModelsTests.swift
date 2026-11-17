import XCTest
@testable import AgentOpsBar

final class ModelsTests: XCTestCase {
    func testDurationFormatterCompact() {
        XCTAssertEqual(DurationFormatter.compact(45), "0m45s")
        XCTAssertEqual(DurationFormatter.compact(512), "8m32s")
        XCTAssertEqual(DurationFormatter.compact(3905), "1h05m")
    }

    func testUnifiedPayloadDecodingAndAccountPriority() throws {
        let raw = """
        {
          "checkedAt": 1700000000.0,
          "colab": {
            "installed": true,
            "configured": true,
            "primaryAccount": "primary-acc",
            "totalPaidBalanceCu": 1200.5,
            "totalBurnRateHourly": 0.52,
            "activeNodes": 2,
            "maxNodes": 10,
            "activeSlots": 3,
            "maxSlots": 20,
            "idleTimeoutSeconds": 600.0,
            "nodes": [
              {
                "node_id": "pool-02",
                "status": "ready",
                "account": "primary-acc",
                "active_slots": 2,
                "active_projects": ["demo-repo"]
              }
            ],
            "accounts": [
              {"alias": "spillover-acc", "ok": true, "paid_balance": 150.0, "active_vms_count": 0},
              {"alias": "primary-acc", "ok": true, "paid_balance": 1050.5, "active_vms_count": 2}
            ]
          },
          "agents": {
            "checkedAt": 1700000000.0,
            "haInstalled": true,
            "activeWorkers": 1,
            "taskWorkers": 1,
            "agyPoolStandby": 2,
            "longRunningWarnings": 0,
            "totalWorkerMemoryMb": 210.0,
            "byKind": {"Codex": 1},
            "daemon": {"online": true, "pid": 1234, "drifted": false, "attachedRepos": 3, "unhealthyRepos": 0},
            "instances": {"total": 2, "healthy": 2, "frozenIds": [], "cooldownIds": []},
            "bridges": [],
            "workers": [
              {
                "pid": 4321,
                "ppid": 1234,
                "kind": "Codex",
                "scope": "task",
                "model": "gpt-5",
                "cpuPercent": 1.2,
                "memoryMb": 210.0,
                "elapsedSeconds": 180,
                "workspace": "demo-repo",
                "taskLabel": "task_12345678",
                "longRunningWarning": false
              }
            ]
          },
          "ops": {
            "checkedAt": 1700000000.0,
            "ci": {
              "ghAvailable": true,
              "openPrs": 1,
              "passingPrs": 1,
              "runningPrs": 0,
              "failingPrs": 0,
              "conflictPrs": 0,
              "prs": [],
              "reviewQueue": {"inReview": 1, "submitted": 0, "blocked": 0, "total": 1, "items": []}
            },
            "host": {
              "cpuCores": 12,
              "loadAvg1m": 3.0,
              "loadAvg5m": 2.5,
              "cpuLoadPercent": 25,
              "memoryFreePercent": 60,
              "memoryUsedPercent": 40,
              "diskFreeGiB": 250.0,
              "diskTotalGiB": 1000.0,
              "diskUsedPercent": 75.0,
              "diskWarning": false,
              "totalWorktrees": 8,
              "totalUnpushed": 0,
              "dirtyRepos": 1,
              "repos": []
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(UnifiedProbePayload.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.colab.prioritizedAccounts.first?.alias, "primary-acc")
        XCTAssertEqual(decoded.agents.taskWorkers, 1)
        XCTAssertEqual(decoded.ops.host.totalWorktrees, 8)
    }
}
