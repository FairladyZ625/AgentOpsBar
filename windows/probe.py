#!/usr/bin/env python3
"""Standalone read-only telemetry probe for AgentOpsBar (Windows).

Uses Python 3.12 standard library only. Never reads credentials, never mutates
files outside its own short-TTL cache (`%LOCALAPPDATA%/agent-ops-bar`), and
never starts, stops, or restarts any daemon or agent process.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import configparser
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Callable

LONG_RUNNING_TASK_THRESHOLD_S = 3600
OPS_REMOTE_CACHE_TTL_S = 60.0
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

_MODEL_FLAG_RE = re.compile(r"(?:--model(?:=|\s+)|-m\s+)([A-Za-z0-9._:/-]+)")
_TASK_ID_RE = re.compile(r"(task_[a-z0-9]{8,40})")
_GITHUB_REMOTE_RE = re.compile(r"github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?$")
_WORKTREE_PATH_RE = re.compile(r"([A-Za-z]:[\\/][^\"'\s]+?[\\/]\.worktrees[\\/][^\"'\s]+)")
_PROJECT_PATH_RE = re.compile(r"([A-Za-z]:[\\/][^\"'\s]+)")

_PASS_CONCLUSIONS = frozenset({"SUCCESS", "NEUTRAL", "SKIPPED"})
_FAIL_CONCLUSIONS = frozenset(
    {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"}
)


def operator_home() -> Path:
    return Path.home()


def default_cache_dir() -> Path:
    override = os.environ.get("AGENT_OPS_BAR_CACHE_DIR")
    if override:
        return Path(os.path.expandvars(os.path.expanduser(override)))
    local_app = os.environ.get("LOCALAPPDATA")
    if local_app:
        return Path(local_app) / "agent-ops-bar"
    return operator_home() / ".cache" / "agent-ops-bar"


def resolve_bin(name: str, env_var: str | None = None) -> str | None:
    if env_var:
        override = os.environ.get(env_var)
        if override and Path(override).is_file():
            return override
    found = shutil.which(name)
    if found:
        return found
    home = operator_home()
    for base in (home / ".local" / "bin", Path(sys.executable).parent / "Scripts"):
        for ext in ("", ".exe", ".cmd", ".bat"):
            cand = base / f"{name}{ext}"
            if cand.is_file():
                return str(cand)
    return None


def _run_quiet(
    args: list[str],
    *,
    timeout: float = 5.0,
    cwd: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


# ---------------------------------------------------------------------------
# 1. Colab Pool Status (optional CLI integration)
# ---------------------------------------------------------------------------


def collect_colab_status(*, fast: bool = True, timeout_s: float = 20.0) -> dict[str, Any]:
    colab_bin = resolve_bin("colab-pool", "COLAB_POOL_BIN")
    if not colab_bin:
        return {
            "installed": False,
            "configured": False,
            "primaryAccount": None,
            "healthyAccounts": 0,
            "totalPaidBalanceCu": 0.0,
            "totalBurnRateHourly": 0.0,
            "activeNodes": 0,
            "drainingNodes": 0,
            "maxNodes": 0,
            "slotsPerNode": 2,
            "maxSlots": 0,
            "activeSlots": 0,
            "availableSlots": 0,
            "availableCpu": 0,
            "availableMemoryGiB": 0,
            "idleTimeoutSeconds": 600.0,
            "nodes": [],
            "accounts": [],
        }

    args = [colab_bin, "status", "--fast", "--json"] if fast else [colab_bin, "status", "--json"]
    try:
        proc = _run_quiet(args, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"installed": True, "configured": False, "error": f"colab-pool status timeout ({int(timeout_s)}s)"}
    except Exception as exc:
        return {"installed": True, "configured": False, "error": str(exc)}

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
        last_line = err.splitlines()[-1] if err else "colab-pool failed"
        return {"installed": True, "configured": False, "error": last_line}

    try:
        data = json.loads(proc.stdout)
        data["installed"] = True
        return data
    except Exception as exc:
        return {"installed": True, "configured": False, "error": f"invalid JSON: {exc}"}


# ---------------------------------------------------------------------------
# 2. Local & Remote Agents Telemetry (Windows CIM / PowerShell)
# ---------------------------------------------------------------------------


def summarize_cmdline_workspace(cmd: str) -> tuple[str, str | None]:
    """Extract workspace name and optional task_id from a Windows command line."""
    norm_cmd = cmd.replace("\\", "/")
    is_review = "/.review/" in norm_cmd or norm_cmd.endswith("/.review")
    task_match = _TASK_ID_RE.search(norm_cmd)
    short_task: str | None = None
    if task_match:
        raw_tid = task_match.group(1)
        short_tid = raw_tid[:13] if len(raw_tid) > 13 else raw_tid
        short_task = f"review/{short_tid}" if is_review else short_tid

    wt_match = _WORKTREE_PATH_RE.search(cmd)
    if wt_match:
        wt_norm = wt_match.group(1).replace("\\", "/")
        repo_prefix = wt_norm.split("/.worktrees/", 1)[0]
        repo_name = Path(repo_prefix).name or repo_prefix
        return (repo_name, short_task)

    for p_match in _PROJECT_PATH_RE.finditer(cmd):
        cand = p_match.group(1).replace("\\", "/")
        low = cand.lower()
        if any(skip in low for skip in ("/windows/", "/program files", "/python", "/node-js/", "/appdata/")):
            continue
        parts = [p for p in cand.split("/") if p]
        if len(parts) >= 2:
            # Prefer repo folder under d:/project/<repo> or ~/Projects/<repo>
            for idx, seg in enumerate(parts):
                if seg.lower() in ("project", "projects") and idx + 1 < len(parts):
                    return (parts[idx + 1], short_task)
            return (parts[-1], short_task)

    return ("-", short_task)


def _default_win_processes_fn() -> list[dict[str, Any]]:
    """Query active processes via PowerShell Get-CimInstance Win32_Process (no console window)."""
    ps_script = (
        "$now = Get-Date; "
        "Get-CimInstance Win32_Process | ForEach-Object { "
        "$el = if ($_.CreationDate) { [int][Math]::Max(0, ($now - $_.CreationDate).TotalSeconds) } else { 0 }; "
        "[PSCustomObject]@{ "
        "pid = [int]$_.ProcessId; "
        "ppid = [int]$_.ParentProcessId; "
        "name = [string]$_.Name; "
        "cmd = [string]$_.CommandLine; "
        "wsBytes = [int64]$_.WorkingSetSize; "
        "elapsedSeconds = $el "
        "} } | ConvertTo-Json -Compress"
    )
    try:
        proc = _run_quiet(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script],
            timeout=8.0,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return []
        parsed = json.loads(proc.stdout)
        return parsed if isinstance(parsed, list) else ([parsed] if isinstance(parsed, dict) else [])
    except Exception:
        return []


def _default_ha_json_fn(subargs: list[str]) -> dict[str, Any] | None:
    ha_bin = resolve_bin("ha", "HARNESS_HA_BIN")
    if not ha_bin:
        return None
    try:
        proc = _run_quiet([ha_bin, *subargs, "--json"], timeout=5.0)
    except Exception:
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    for line in reversed(proc.stdout.splitlines()):
        stripped = line.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            try:
                return json.loads(stripped)
            except Exception:
                continue
    try:
        return json.loads(proc.stdout)
    except Exception:
        return None


def _extract_model(cmd: str, default: str) -> str:
    match = _MODEL_FLAG_RE.search(cmd)
    return match.group(1) if match else default


def collect_agents_status(
    *,
    processes_fn: Callable[[], list[dict[str, Any]]] = _default_win_processes_fn,
    ha_json_fn: Callable[[list[str]], dict[str, Any] | None] = _default_ha_json_fn,
    daemon_doc_preloaded: dict[str, Any] | None = None,
    self_pid: int | None = None,
) -> dict[str, Any]:
    own_pid = os.getpid() if self_pid is None else self_pid

    with ThreadPoolExecutor(max_workers=3) as pool:
        f_procs = pool.submit(processes_fn)
        f_daemon = None if daemon_doc_preloaded is not None else pool.submit(ha_json_fn, ["daemon", "status"])
        f_instances = pool.submit(ha_json_fn, ["runtime", "instance", "list"])
        proc_rows = f_procs.result()
        daemon_doc = daemon_doc_preloaded if f_daemon is None else f_daemon.result()
        instances_doc = f_instances.result()

    workers: list[dict[str, Any]] = []
    agy_standby_count = 0
    codex_cloud_online = False
    hermes_online = False
    rex_online = False

    for row in proc_rows:
        try:
            pid = int(row.get("pid") or 0)
            ppid = int(row.get("ppid") or 0)
            ws_bytes = int(row.get("wsBytes") or 0)
            elapsed_s = int(row.get("elapsedSeconds") or 0)
        except (TypeError, ValueError):
            continue
        if pid <= 0 or pid == own_pid:
            continue

        name = str(row.get("name") or "")
        cmd = str(row.get("cmd") or "").strip()
        if not cmd:
            continue
        low = cmd.lower()
        name_low = name.lower()

        if "crashpad" in low or "conhost.exe" in name_low:
            continue
        if "agentopsbar" in low or "agent_ops_probe" in low:
            continue

        if "codex" in low and "exec-server" in low and "--remote" in low:
            codex_cloud_online = True
            continue
        if "hermes" in low and ("process_supervisor" in low or "hermes.exe" in name_low):
            hermes_online = True
            continue
        if "rex server" in low or "rex-server" in low:
            rex_online = True
            continue

        rss_mb = round(ws_bytes / (1024.0 * 1024.0), 1)
        kind: str | None = None
        scope = "interactive"
        default_model = "unknown"

        if "codex" in low and (" exec" in low or "codex.exe" in name_low):
            kind = "Codex"
            scope = "task" if "exec" in low else "interactive"
            default_model = "codex"
        elif "dsh-desktop-host" in low:
            kind = "DSH"
            scope = "task"
            default_model = "dsh-acp"
        elif ("claude-code" in low or name_low == "claude.exe" or "claude " in low) and "--chrome-native-host" not in low:
            kind = "Claude"
            scope = "interactive"
            default_model = "claude"
        elif "agy" in low and "acp --worker" in low:
            agy_standby_count += 1
            continue
        elif ("harness-anything" in low or "ha.cmd" in low or "ha-daemon" in low) and (
            "agent run" in low or "runtime run" in low
        ):
            kind = "HA"
            scope = "task"
            default_model = "harness"
        elif name_low in ("node.exe", "python.exe", "python3.exe") and _TASK_ID_RE.search(low):
            kind = "Python" if "python" in name_low else "Node"
            scope = "task"
            default_model = name_low.removesuffix(".exe")

        if not kind:
            continue

        workspace, task_label = summarize_cmdline_workspace(cmd)
        final_scope = "task" if (scope == "task" or task_label is not None) else scope
        long_warn = final_scope == "task" and elapsed_s >= LONG_RUNNING_TASK_THRESHOLD_S

        workers.append(
            {
                "pid": pid,
                "ppid": ppid,
                "kind": kind,
                "scope": final_scope,
                "model": _extract_model(cmd, default_model),
                "cpuPercent": 0.0,
                "memoryMb": rss_mb,
                "elapsedSeconds": elapsed_s,
                "workspace": workspace,
                "taskLabel": task_label,
                "longRunningWarning": long_warn,
            }
        )

    workers.sort(
        key=lambda w: (
            0 if w["scope"] == "task" else 1,
            -int(bool(w["longRunningWarning"])),
            -w["elapsedSeconds"],
            w["pid"],
        )
    )

    ha_installed = resolve_bin("ha", "HARNESS_HA_BIN") is not None
    daemon_online = bool(daemon_doc and daemon_doc.get("ok") is True)
    daemon_repos = (daemon_doc or {}).get("repos") or []
    attached_repos = sum(1 for r in daemon_repos if r.get("state") == "attached")
    unhealthy_repos = sum(
        1
        for r in daemon_repos
        if r.get("state") == "attached" and (r.get("lastError") is not None or not r.get("projectionReadable", True))
    )
    build_drifted = bool(((daemon_doc or {}).get("build") or {}).get("drifted", False))

    raw_instances = [i for i in ((instances_doc or {}).get("instances") or []) if i.get("enabled", True)]
    frozen_ids: list[str] = []
    cooldown_ids: list[str] = []
    for inst in raw_instances:
        iid = str(inst.get("instanceId", ""))
        phealth = inst.get("providerHealth") or {}
        if phealth.get("frozen", False):
            frozen_ids.append(iid)
        elif phealth.get("cooldownUntil") is not None:
            cooldown_ids.append(iid)

    task_workers_count = sum(1 for w in workers if w["scope"] == "task")
    long_running_count = sum(1 for w in workers if w["longRunningWarning"])
    total_worker_mem_mb = round(sum(float(w["memoryMb"]) for w in workers), 1)

    by_kind: dict[str, int] = {}
    for w in workers:
        by_kind[w["kind"]] = by_kind.get(w["kind"], 0) + 1

    bridges: list[dict[str, Any]] = []
    if ha_installed or daemon_online:
        bridges.append(
            {
                "key": "harness-daemon",
                "label": "Ha Daemon",
                "online": daemon_online,
                "warning": build_drifted or unhealthy_repos > 0,
                "detail": f"{attached_repos}仓" if daemon_online else "离线",
            }
        )
    bridges.extend(
        [
            {
                "key": "codex-cloud",
                "label": "Codex Cloud",
                "online": codex_cloud_online,
                "warning": False,
                "detail": "远端在线" if codex_cloud_online else "未启动",
            },
            {
                "key": "hermes",
                "label": "Hermes",
                "online": hermes_online,
                "warning": False,
                "detail": "在线" if hermes_online else "未启动",
            },
            {
                "key": "rex",
                "label": "Rex",
                "online": rex_online,
                "warning": False,
                "detail": "远控在线" if rex_online else "未启动",
            },
        ]
    )

    return {
        "checkedAt": time.time(),
        "haInstalled": ha_installed,
        "activeWorkers": len(workers),
        "taskWorkers": task_workers_count,
        "agyPoolStandby": agy_standby_count,
        "longRunningWarnings": long_running_count,
        "totalWorkerMemoryMb": total_worker_mem_mb,
        "byKind": by_kind,
        "daemon": {
            "online": daemon_online,
            "pid": (daemon_doc or {}).get("pid"),
            "drifted": build_drifted,
            "attachedRepos": attached_repos,
            "unhealthyRepos": unhealthy_repos,
        },
        "instances": {
            "total": len(raw_instances),
            "healthy": len(raw_instances) - len(frozen_ids) - len(cooldown_ids),
            "frozenIds": frozen_ids,
            "cooldownIds": cooldown_ids,
        },
        "bridges": bridges,
        "workers": workers,
    }


# ---------------------------------------------------------------------------
# 3. CI / PR Pipeline & Host / Worktree Radar
# ---------------------------------------------------------------------------


def extract_github_slug(remote_url: str | None) -> str | None:
    if not remote_url:
        return None
    match = _GITHUB_REMOTE_RE.search(remote_url.strip())
    return match.group(1) if match else None


def _read_git_origin_url(repo_dir: Path) -> str | None:
    git_cfg = repo_dir / ".git" / "config"
    if not git_cfg.is_file():
        return None
    parser = configparser.ConfigParser(strict=False)
    try:
        parser.read(git_cfg, encoding="utf-8")
        if parser.has_section('remote "origin"'):
            return parser.get('remote "origin"', "url", fallback=None)
    except Exception:
        return None
    return None


def summarize_check_rollup(rollup: list[dict[str, Any]] | None) -> dict[str, Any]:
    items = rollup or []
    passed = 0
    failed = 0
    pending = 0
    for item in items:
        typename = item.get("__typename", "")
        if typename == "StatusContext" or ("state" in item and "status" not in item):
            st = str(item.get("state", "")).upper()
            if st == "SUCCESS":
                passed += 1
            elif st in ("FAILURE", "ERROR"):
                failed += 1
            else:
                pending += 1
        else:
            status = str(item.get("status", "")).upper()
            conclusion = str(item.get("conclusion", "")).upper()
            if status != "COMPLETED":
                pending += 1
            elif conclusion in _PASS_CONCLUSIONS:
                passed += 1
            elif conclusion in _FAIL_CONCLUSIONS:
                failed += 1
            else:
                pending += 1

    total = passed + failed + pending
    if failed > 0:
        ci_state = "failing"
    elif pending > 0:
        ci_state = "running"
    elif total > 0:
        ci_state = "passing"
    else:
        ci_state = "none"

    return {
        "ciState": ci_state,
        "checksPassed": passed,
        "checksFailed": failed,
        "checksPending": pending,
        "checksTotal": total,
    }


def parse_ha_task_evidence(raw_stdout: str) -> tuple[list[dict[str, Any]], int]:
    if not raw_stdout.strip():
        return ([], 0)
    doc: dict[str, Any] | None = None
    for line in reversed(raw_stdout.splitlines()):
        stripped = line.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            try:
                doc = json.loads(stripped)
                break
            except Exception:
                continue
    if doc is None:
        try:
            doc = json.loads(raw_stdout)
        except Exception:
            return ([], 0)

    ev = doc.get("evidence")
    if isinstance(ev, str):
        try:
            ev = json.loads(ev)
        except Exception:
            ev = {}
    if not isinstance(ev, dict):
        ev = doc
    rows = ev.get("rows") or ev.get("tasks") or []
    count = int(ev.get("count", len(rows)) or len(rows))
    return (rows if isinstance(rows, list) else [], count)


def _count_worktrees(repo_dir: Path) -> int:
    wt_root = repo_dir / ".worktrees"
    if not wt_root.is_dir():
        return 0
    total = 0
    try:
        for child in wt_root.iterdir():
            if not child.is_dir():
                continue
            if child.name == ".review":
                total += sum(1 for r in child.iterdir() if r.is_dir() and not r.name.startswith("."))
            elif not child.name.startswith("."):
                total += 1
    except OSError:
        pass
    return total


def discover_active_repos(daemon_doc: dict[str, Any] | None = None, limit: int = 6) -> list[Path]:
    """Dynamically discover active git repositories on Windows."""
    explicit = os.environ.get("AGENT_OPS_REPOS", "").strip()
    if explicit:
        sep = ";" if ";" in explicit else os.pathsep
        custom = [Path(os.path.expandvars(os.path.expanduser(p.strip()))) for p in explicit.split(sep) if p.strip()]
        return [p for p in custom if (p / ".git").exists()][:limit]

    seen: set[Path] = set()
    candidates: list[Path] = []

    def _add(p: Path) -> None:
        try:
            resolved = p.resolve()
        except OSError:
            return
        if resolved in seen or not (resolved / ".git").exists():
            return
        seen.add(resolved)
        candidates.append(resolved)

    home = operator_home()
    if (home / "Brain" / ".git").exists():
        _add(home / "Brain")

    for r in (daemon_doc or {}).get("repos") or []:
        if r.get("state") == "attached" and r.get("rootDir"):
            _add(Path(str(r["rootDir"])))

    search_roots = [
        Path("D:/project"),
        Path("D:/projects"),
        home / "Projects",
        home / "project",
    ]
    for root in search_roots:
        if not root.is_dir():
            continue
        try:
            for child in sorted(root.iterdir()):
                if not child.is_dir() or child.name.startswith(".") or child.name.startswith("_"):
                    continue
                if (child / ".git").exists():
                    _add(child)
        except OSError:
            pass

    def _priority(p: Path) -> tuple[int, float, str]:
        wt = _count_worktrees(p)
        try:
            mtime = (p / ".git").stat().st_mtime
        except OSError:
            mtime = 0.0
        return (-wt, -mtime, p.name)

    candidates.sort(key=_priority)
    return candidates[:limit]


def _inspect_single_repo(repo_dir: Path) -> dict[str, Any]:
    branch = "HEAD"
    dirty = 0
    unpushed = 0
    try:
        b_proc = _run_quiet(["git", "-C", str(repo_dir), "rev-parse", "--abbrev-ref", "HEAD"], timeout=2.5)
        if b_proc.returncode == 0 and b_proc.stdout.strip():
            branch = b_proc.stdout.strip()
    except Exception:
        pass

    try:
        s_proc = _run_quiet(["git", "-C", str(repo_dir), "status", "--porcelain"], timeout=3.0)
        if s_proc.returncode == 0:
            dirty = sum(1 for ln in s_proc.stdout.splitlines() if ln.strip())
    except Exception:
        pass

    try:
        u_proc = _run_quiet(["git", "-C", str(repo_dir), "rev-list", "--count", "@{u}..HEAD"], timeout=2.5)
        if u_proc.returncode == 0 and u_proc.stdout.strip().isdigit():
            unpushed = int(u_proc.stdout.strip())
    except Exception:
        pass

    return {
        "name": repo_dir.name,
        "path": str(repo_dir),
        "branch": branch,
        "dirtyCount": dirty,
        "unpushedCount": unpushed,
        "worktreeCount": _count_worktrees(repo_dir),
    }


def _query_win_cpu_mem() -> tuple[int, int]:
    """Return (cpu_load_percent, memory_free_percent) via Windows CIM."""
    ps_script = (
        "$os = Get-CimInstance Win32_OperatingSystem; "
        "$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; "
        "$freePct = if ($os.TotalVisibleMemorySize -gt 0) { "
        "[int][Math]::Round(($os.FreePhysicalMemory * 100.0) / $os.TotalVisibleMemorySize) } else { 50 }; "
        "[PSCustomObject]@{ cpuPct = [int][Math]::Round($cpu); memFreePct = $freePct } | ConvertTo-Json -Compress"
    )
    try:
        proc = _run_quiet(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script], timeout=5.0)
        if proc.returncode == 0 and proc.stdout.strip():
            doc = json.loads(proc.stdout)
            cpu_pct = max(0, min(100, int(doc.get("cpuPct", 0) or 0)))
            mem_free = max(0, min(100, int(doc.get("memFreePct", 50) or 50)))
            return (cpu_pct, mem_free)
    except Exception:
        pass
    return (0, 50)


def collect_host_vitals(repo_dirs: list[Path]) -> dict[str, Any]:
    cpus = max(1, os.cpu_count() or 1)
    cpu_pct, mem_free_pct = _query_win_cpu_mem()

    # Check disk usage for the primary project drive if available, else system drive
    disk_anchor = str(repo_dirs[0]) if repo_dirs else os.environ.get("SystemDrive", "C:") + "\\"
    du = shutil.disk_usage(disk_anchor)
    disk_free_gib = round(du.free / (1024**3), 1)
    disk_total_gib = round(du.total / (1024**3), 1)
    disk_used_pct = round(du.used * 100.0 / max(1, du.total), 1)

    if repo_dirs:
        with ThreadPoolExecutor(max_workers=min(6, len(repo_dirs))) as pool:
            repo_items = list(pool.map(_inspect_single_repo, repo_dirs))
    else:
        repo_items = []

    repo_items.sort(
        key=lambda r: (
            -int(r["unpushedCount"] > 0),
            -int(r["worktreeCount"]),
            -int(r["dirtyCount"]),
            r["name"],
        )
    )

    return {
        "cpuCores": cpus,
        "loadAvg1m": 0.0,
        "loadAvg5m": 0.0,
        "cpuLoadPercent": cpu_pct,
        "memoryFreePercent": mem_free_pct,
        "memoryUsedPercent": max(0, 100 - mem_free_pct),
        "diskFreeGiB": disk_free_gib,
        "diskTotalGiB": disk_total_gib,
        "diskUsedPercent": disk_used_pct,
        "diskWarning": disk_used_pct >= 90.0 or disk_free_gib < 80.0,
        "totalWorktrees": sum(int(r["worktreeCount"]) for r in repo_items),
        "totalUnpushed": sum(int(r["unpushedCount"]) for r in repo_items),
        "dirtyRepos": sum(1 for r in repo_items if int(r["dirtyCount"]) > 0),
        "repos": repo_items,
    }


def collect_remote_ci(repo_dirs: list[Path]) -> dict[str, Any]:
    gh_bin = resolve_bin("gh")
    ha_bin = resolve_bin("ha", "HARNESS_HA_BIN")

    gh_slugs: list[str] = []
    for rdir in repo_dirs:
        slug = extract_github_slug(_read_git_origin_url(rdir))
        if slug and slug not in gh_slugs:
            gh_slugs.append(slug)

    if gh_bin:
        try:
            s_proc = _run_quiet(
                [gh_bin, "search", "prs", "--state=open", "--involves=@me", "--limit", "12", "--json", "repository"],
                timeout=6.0,
            )
            if s_proc.returncode == 0 and s_proc.stdout.strip():
                for row in json.loads(s_proc.stdout):
                    slug = ((row.get("repository") or {}).get("nameWithOwner") or "").strip()
                    if slug and slug not in gh_slugs:
                        gh_slugs.append(slug)
        except Exception:
            pass

    def _fetch_repo_prs(slug: str) -> list[dict[str, Any]]:
        if not gh_bin:
            return []
        try:
            proc = _run_quiet(
                [
                    gh_bin,
                    "pr",
                    "list",
                    "--repo",
                    slug,
                    "--limit",
                    "8",
                    "--json",
                    "number,title,headRefName,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,updatedAt,url,author",
                ],
                timeout=7.0,
            )
            if proc.returncode != 0 or not proc.stdout.strip():
                return []
            raw_prs = json.loads(proc.stdout)
        except Exception:
            return []

        short_repo = slug.split("/")[-1]
        parsed: list[dict[str, Any]] = []
        for pr in raw_prs:
            rollup_summary = summarize_check_rollup(pr.get("statusCheckRollup"))
            author_login = ((pr.get("author") or {}).get("login") or "").strip()
            parsed.append(
                {
                    "id": f"{slug}#{pr.get('number')}",
                    "repo": short_repo,
                    "fullRepo": slug,
                    "number": int(pr.get("number", 0)),
                    "title": str(pr.get("title", "")),
                    "branch": str(pr.get("headRefName", "")),
                    "author": author_login,
                    "isDraft": bool(pr.get("isDraft", False)),
                    "mergeState": str(pr.get("mergeStateStatus", "")),
                    "reviewDecision": str(pr.get("reviewDecision", "")),
                    "updatedAt": str(pr.get("updatedAt", "")),
                    "url": str(pr.get("url", "")),
                    **rollup_summary,
                }
            )
        return parsed

    harness_repos = [r for r in repo_dirs if (r / "harness" / "harness.yaml").is_file() or (r / ".worktrees").is_dir()]

    def _fetch_repo_tasks(rdir: Path) -> tuple[int, int, int, list[dict[str, Any]]]:
        if not ha_bin:
            return (0, 0, 0, [])
        counts = {"in_review": 0, "submitted": 0, "blocked": 0}
        collected: list[dict[str, Any]] = []
        for st in ("blocked", "in_review", "submitted"):
            try:
                proc = _run_quiet(
                    [ha_bin, "task", "list", "--status", st, "--limit", "5", "--json"],
                    cwd=str(rdir),
                    timeout=4.5,
                )
                if proc.returncode != 0:
                    continue
                rows, total_cnt = parse_ha_task_evidence(proc.stdout)
                counts[st] = total_cnt
                for row in rows:
                    if row.get("taskClass") == "milestone":
                        continue
                    tid = str(row.get("taskId") or row.get("id") or "")
                    short_tid = tid[:13] if len(tid) > 13 else tid
                    collected.append(
                        {
                            "id": f"{rdir.name}:{tid}",
                            "repo": rdir.name,
                            "taskId": short_tid,
                            "status": st,
                            "title": str(row.get("title", "")),
                            "updatedAt": str(row.get("updatedAt", "")),
                        }
                    )
            except Exception:
                continue
        return (counts["in_review"], counts["submitted"], counts["blocked"], collected)

    all_prs: list[dict[str, Any]] = []
    in_review_total = 0
    submitted_total = 0
    blocked_total = 0
    queue_items: list[dict[str, Any]] = []

    with ThreadPoolExecutor(max_workers=6) as pool:
        pr_futures = [pool.submit(_fetch_repo_prs, s) for s in gh_slugs[:4]]
        task_futures = [pool.submit(_fetch_repo_tasks, r) for r in harness_repos[:4]]
        for f in pr_futures:
            all_prs.extend(f.result())
        for f in task_futures:
            ir, sub, blk, items = f.result()
            in_review_total += ir
            submitted_total += sub
            blocked_total += blk
            queue_items.extend(items)

    state_rank = {"failing": 0, "running": 1, "passing": 2, "none": 3}
    all_prs.sort(key=lambda p: (state_rank.get(p["ciState"], 9), -p["number"]))

    task_rank = {"blocked": 0, "in_review": 1, "submitted": 2}
    queue_items.sort(key=lambda t: (task_rank.get(t["status"], 9), t["repo"], t["taskId"]))

    return {
        "ghAvailable": bool(gh_bin),
        "openPrs": len(all_prs),
        "passingPrs": sum(1 for p in all_prs if p["ciState"] == "passing"),
        "runningPrs": sum(1 for p in all_prs if p["ciState"] == "running"),
        "failingPrs": sum(1 for p in all_prs if p["ciState"] == "failing"),
        "conflictPrs": sum(1 for p in all_prs if p["mergeState"] == "DIRTY"),
        "prs": all_prs[:10],
        "reviewQueue": {
            "inReview": in_review_total,
            "submitted": submitted_total,
            "blocked": blocked_total,
            "total": in_review_total + submitted_total + blocked_total,
            "items": queue_items[:12],
        },
    }


def collect_unified_snapshot(*, fast: bool = True, cache_dir: Path | None = None) -> dict[str, Any]:
    ts = time.time()
    cdir = cache_dir or default_cache_dir()
    cdir.mkdir(parents=True, exist_ok=True)
    ci_cache_file = cdir / "ops_ci_cache.json"

    daemon_doc = _default_ha_json_fn(["daemon", "status"])
    active_repos = discover_active_repos(daemon_doc, limit=6)

    cached_ci: dict[str, Any] | None = None
    if fast and ci_cache_file.is_file():
        try:
            doc = json.loads(ci_cache_file.read_text(encoding="utf-8"))
            if 0.0 <= (ts - float(doc.get("cachedAt", 0.0))) <= OPS_REMOTE_CACHE_TTL_S and isinstance(
                doc.get("ci"), dict
            ):
                cached_ci = doc["ci"]
        except Exception:
            cached_ci = None

    with ThreadPoolExecutor(max_workers=4) as pool:
        f_colab = pool.submit(collect_colab_status, fast=fast)
        f_agents = pool.submit(collect_agents_status, daemon_doc_preloaded=daemon_doc)
        f_host = pool.submit(collect_host_vitals, active_repos)
        f_ci = None if cached_ci is not None else pool.submit(collect_remote_ci, active_repos)

        colab_data = f_colab.result()
        agents_data = f_agents.result()
        host_data = f_host.result()
        ci_data = cached_ci if f_ci is None else f_ci.result()

    if cached_ci is None:
        try:
            tmp = ci_cache_file.with_suffix(".json.tmp")
            tmp.write_text(json.dumps({"cachedAt": ts, "ci": ci_data}, ensure_ascii=False) + "\n", encoding="utf-8")
            os.replace(tmp, ci_cache_file)
        except OSError:
            pass

    return {
        "checkedAt": ts,
        "colab": colab_data,
        "agents": agents_data,
        "ops": {
            "checkedAt": ts,
            "ci": ci_data,
            "host": host_data,
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent-ops-probe-win", description="Read-only telemetry collector for AgentOpsBar (Windows).")
    sub = parser.add_subparsers(dest="command", required=True)
    p_snap = sub.add_parser("snapshot", help="Emit unified JSON telemetry snapshot.")
    p_snap.add_argument("--fast", action="store_true", help="Use short-TTL caches for remote Colab/GitHub queries.")
    args = parser.parse_args(argv)

    if args.command == "snapshot":
        doc = collect_unified_snapshot(fast=args.fast)
        print(json.dumps(doc, ensure_ascii=False))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
