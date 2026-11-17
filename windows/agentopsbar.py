"""Lightweight Windows desktop HUD widget for AgentOpsBar.

Strictly read-only multi-panel monitor (Colab, Agents, CI / 交付, 宿主) using
Python 3.12 standard library + tkinter with zero external dependencies.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import tkinter as tk
import webbrowser
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from probe import collect_unified_snapshot  # noqa: E402

REFRESH_INTERVAL_MS = 15_000
TICK_INTERVAL_MS = 1_000

BG = "#14161b"
CARD_BG = "#1c2028"
SUBCARD_BG = "#181b22"
BORDER = "#2c323f"
TEXT = "#e6eaf2"
MUTED = "#8b93a7"
ACCENT = "#5b9cf6"
GREEN = "#4ade80"
AMBER = "#fbbf24"
RED = "#f87171"

FONT_UI = ("Microsoft YaHei UI", 9)
FONT_UI_SM = ("Microsoft YaHei UI", 8)
FONT_UI_BOLD = ("Microsoft YaHei UI", 9, "bold")
FONT_MONO = ("Consolas", 9)
FONT_MONO_SM = ("Consolas", 8)
FONT_MONO_LG = ("Consolas", 13, "bold")


def format_duration(seconds: float) -> str:
    sec = max(0, int(seconds))
    mins, rem = divmod(sec, 60)
    hours, mins = divmod(mins, 60)
    if hours > 0:
        return f"{hours}h{mins:02d}m"
    return f"{mins}m{rem:02d}s"


def truncate_text(text: str, limit: int = 44) -> str:
    clean = " ".join(text.split())
    return clean if len(clean) <= limit else clean[: limit - 1] + "…"


class AgentOpsBarWindow:
    """Frameless, draggable, always-on-top-capable Windows desktop HUD."""

    def __init__(self, *, headless_smoke: bool = False) -> None:
        self.root = tk.Tk()
        self.root.title("AgentOpsBar")
        self.root.overrideredirect(True)
        self.root.configure(bg=BORDER)
        self.root.attributes("-alpha", 0.95)

        self.topmost = True
        self.root.attributes("-topmost", self.topmost)

        self.collapsed = False
        self.active_tab = "colab"
        self.ci_sub_tab = "prs"
        self.refreshing = False
        self._did_auto_select = False
        self._initial_balance: float | None = None
        self._snapshot: dict[str, Any] | None = None
        self._last_error: str | None = None
        self._last_height: int | None = None
        self._live_updaters: list[Any] = []
        self._drag_x = 0
        self._drag_y = 0

        sw = self.root.winfo_screenwidth()
        self.width = 404
        self.root.geometry(f"{self.width}x280+{max(16, sw - self.width - 24)}+28")

        self.outer = tk.Frame(self.root, bg=BG, padx=12, pady=10)
        self.outer.pack(fill="both", expand=True, padx=1, pady=1)

        self._build_header()
        self._build_tabs()
        self.body = tk.Frame(self.outer, bg=BG)
        self.body.pack(fill="both", expand=True, pady=(6, 0))

        self._bind_drag(self.outer)
        self._render_active_panel()

        if not headless_smoke:
            self.refresh_async(fast=True)
            self.root.after(REFRESH_INTERVAL_MS, self._schedule_refresh)
            self.root.after(TICK_INTERVAL_MS, self._schedule_tick)

    # ------------------------------------------------------------------
    # Window Chrome & Navigation
    # ------------------------------------------------------------------

    def _build_header(self) -> None:
        header = tk.Frame(self.outer, bg=BG)
        header.pack(fill="x")
        self._bind_drag(header)

        self.title_dot = tk.Label(header, text="●", fg=MUTED, bg=BG, font=("Segoe UI", 10))
        self.title_dot.pack(side="left")
        self.title_lbl = tk.Label(
            header, text=" AgentOpsBar", fg=TEXT, bg=BG, font=("Microsoft YaHei UI", 10, "bold")
        )
        self.title_lbl.pack(side="left")
        self._bind_drag(self.title_lbl)

        self.header_meta_lbl = tk.Label(header, text="--:--:--", fg=MUTED, bg=BG, font=FONT_MONO_SM)
        self.header_meta_lbl.pack(side="left", padx=(8, 0))
        self._bind_drag(self.header_meta_lbl)

        btn_cfg: dict[str, Any] = {
            "bg": BG,
            "fg": MUTED,
            "bd": 0,
            "activebackground": CARD_BG,
            "activeforeground": TEXT,
            "cursor": "hand2",
            "font": ("Segoe UI", 9),
        }
        tk.Button(header, text="✕", command=self.root.destroy, **btn_cfg).pack(side="right", padx=(2, 0))
        self.collapse_btn = tk.Button(header, text="▾", command=self._toggle_collapse, **btn_cfg)
        self.collapse_btn.pack(side="right", padx=2)
        self.pin_btn = tk.Button(header, text="📌", command=self._toggle_topmost, **{**btn_cfg, "fg": ACCENT})
        self.pin_btn.pack(side="right", padx=2)
        self.copy_btn = tk.Button(header, text="{}", command=self._copy_snapshot_json, **btn_cfg)
        self.copy_btn.pack(side="right", padx=2)
        self.refresh_btn = tk.Button(
            header, text="↻", command=lambda: self.refresh_async(fast=False), **btn_cfg
        )
        self.refresh_btn.pack(side="right", padx=2)

    def _build_tabs(self) -> None:
        self.tab_bar = tk.Frame(self.outer, bg=BG)
        self.tab_bar.pack(fill="x", pady=(6, 0))
        self.tab_buttons: dict[str, tk.Button] = {}
        self._tab_labels = {
            "colab": "Colab",
            "agents": "Agents",
            "ci": "CI / 交付",
            "host": "宿主",
        }
        for key, label in self._tab_labels.items():
            btn = tk.Button(
                self.tab_bar,
                text=label,
                command=lambda k=key: self._select_tab(k),
                bd=0,
                padx=8,
                pady=3,
                cursor="hand2",
                font=FONT_UI_SM,
            )
            btn.pack(side="left", padx=(0, 4))
            self.tab_buttons[key] = btn

    def _select_tab(self, key: str) -> None:
        self.active_tab = key
        self._update_tab_styles()
        self._render_active_panel()

    def _update_tab_styles(self) -> None:
        snap = self._snapshot
        badges: dict[str, str] = {}
        if snap:
            colab = snap.get("colab") or {}
            agents = snap.get("agents") or {}
            ops = snap.get("ops") or {}
            ci = ops.get("ci") or {}
            host = ops.get("host") or {}
            if colab.get("installed", True):
                badges["colab"] = f" {colab.get('activeNodes', 0)}"
            badges["agents"] = f" {agents.get('activeWorkers', 0)}"
            badges["ci"] = f" {ci.get('openPrs', 0)}"
            if host.get("diskWarning"):
                badges["host"] = " !"

        for key, btn in self.tab_buttons.items():
            text = self._tab_labels[key] + badges.get(key, "")
            if key == self.active_tab:
                btn.configure(text=text, bg=CARD_BG, fg=TEXT, font=("Microsoft YaHei UI", 8, "bold"))
            else:
                btn.configure(text=text, bg=BG, fg=MUTED, font=FONT_UI_SM)

    def _toggle_topmost(self) -> None:
        self.topmost = not self.topmost
        self.root.attributes("-topmost", self.topmost)
        self.pin_btn.configure(fg=ACCENT if self.topmost else MUTED)

    def _toggle_collapse(self) -> None:
        self.collapsed = not self.collapsed
        if self.collapsed:
            self.tab_bar.pack_forget()
            self.body.pack_forget()
            self.collapse_btn.configure(text="▸")
        else:
            self.tab_bar.pack(fill="x", pady=(6, 0))
            self.body.pack(fill="both", expand=True, pady=(6, 0))
            self.collapse_btn.configure(text="▾")
        self._update_header_chrome()
        self._fit_height()

    def _copy_snapshot_json(self) -> None:
        if not self._snapshot:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(json.dumps(self._snapshot, ensure_ascii=False, indent=2))
        self.copy_btn.configure(fg=GREEN)
        self.root.after(1200, lambda: self.copy_btn.configure(fg=MUTED))

    def _fit_height(self) -> None:
        self.root.update_idletasks()
        h = self.outer.winfo_reqheight() + 2
        if h == self._last_height:
            return
        self._last_height = h
        x, y = self.root.winfo_x(), self.root.winfo_y()
        self.root.geometry(f"{self.width}x{h}+{x}+{y}")

    def _bind_drag(self, widget: tk.Misc) -> None:
        widget.bind("<ButtonPress-1>", self._on_drag_start)
        widget.bind("<B1-Motion>", self._on_drag_motion)

    def _on_drag_start(self, event: tk.Event) -> None:
        self._drag_x = event.x_root - self.root.winfo_x()
        self._drag_y = event.y_root - self.root.winfo_y()

    def _on_drag_motion(self, event: tk.Event) -> None:
        x = event.x_root - self._drag_x
        y = event.y_root - self._drag_y
        self.root.geometry(f"+{x}+{y}")

    # ------------------------------------------------------------------
    # Data Polling & Live Tick
    # ------------------------------------------------------------------

    def _schedule_refresh(self) -> None:
        self.refresh_async(fast=True)
        self.root.after(REFRESH_INTERVAL_MS, self._schedule_refresh)

    def _schedule_tick(self) -> None:
        if not self.collapsed and self._snapshot and self.active_tab in ("colab", "agents"):
            for updater in self._live_updaters:
                updater()
        self.root.after(TICK_INTERVAL_MS, self._schedule_tick)

    def refresh_async(self, *, fast: bool = True) -> None:
        if self.refreshing:
            return
        self.refreshing = True
        self.refresh_btn.configure(fg=ACCENT)

        def worker() -> None:
            try:
                snap = collect_unified_snapshot(fast=fast)
                self.root.after(0, lambda s=snap: self._apply_snapshot(s, None))
            except Exception as exc:
                msg = str(exc)
                self.root.after(0, lambda m=msg: self._apply_snapshot(None, m))

        threading.Thread(target=worker, daemon=True).start()

    def _apply_snapshot(self, snap: dict[str, Any] | None, error: str | None) -> None:
        self.refreshing = False
        self.refresh_btn.configure(fg=MUTED)
        if error or snap is None:
            self._last_error = error or "探针执行失败"
        else:
            self._last_error = None
            self._snapshot = snap
            colab = snap.get("colab") or {}
            if colab.get("installed", True) and colab.get("configured") and self._initial_balance is None:
                self._initial_balance = float(colab.get("totalPaidBalanceCu", 0.0) or 0.0)
            if not self._did_auto_select:
                self._did_auto_select = True
                if not colab.get("installed", True):
                    self.active_tab = "agents"

        self._update_header_chrome()
        self._update_tab_styles()
        if not self.collapsed:
            self._render_active_panel()
        else:
            self._fit_height()

    def _summary_text(self) -> str:
        snap = self._snapshot
        if not snap:
            return "采集中…" if not self._last_error else "异常"
        colab = snap.get("colab") or {}
        agents = snap.get("agents") or {}
        ci = (snap.get("ops") or {}).get("ci") or {}

        task_a = int(agents.get("taskWorkers", 0) or 0)
        fail_prs = int(ci.get("failingPrs", 0) or 0)
        pr_suffix = f" · {fail_prs}PR✗" if fail_prs > 0 else ""

        if colab.get("installed", True) and colab.get("configured"):
            nodes = int(colab.get("activeNodes", 0) or 0)
            slots = int(colab.get("activeSlots", 0) or 0)
            burn = float(colab.get("totalBurnRateHourly", 0.0) or 0.0)
            a_suffix = f" · {task_a}A" if task_a > 0 else ""
            if nodes == 0:
                return f"0 CU/h{a_suffix}{pr_suffix}"
            if slots > 0:
                return f"{burn:.2f} CU/h · {slots}槽{a_suffix}{pr_suffix}"
            return f"{burn:.2f} CU/h · 空载{a_suffix}{pr_suffix}"

        active_w = int(agents.get("activeWorkers", 0) or 0)
        if active_w > 0:
            return f"{active_w}A{pr_suffix}"
        return f"{fail_prs}PR✗" if fail_prs > 0 else "空闲"

    def _update_header_chrome(self) -> None:
        snap = self._snapshot
        if self._last_error and not snap:
            dot = RED
        elif not snap:
            dot = MUTED
        else:
            colab = snap.get("colab") or {}
            agents = snap.get("agents") or {}
            ha_off = bool(agents.get("haInstalled")) and not bool((agents.get("daemon") or {}).get("online"))
            idle_waste = bool(colab.get("installed", True)) and (
                int(colab.get("activeNodes", 0) or 0) > 0 and int(colab.get("activeSlots", 0) or 0) == 0
            )
            if colab.get("error"):
                dot = RED
            elif ha_off or idle_waste:
                dot = AMBER
            elif int(colab.get("activeSlots", 0) or 0) > 0 or int(agents.get("activeWorkers", 0) or 0) > 0:
                dot = ACCENT
            else:
                dot = GREEN
        self.title_dot.configure(fg=dot)
        meta = self._summary_text() if self.collapsed else time.strftime("%H:%M:%S")
        self.header_meta_lbl.configure(text=meta)

    # ------------------------------------------------------------------
    # Panel Rendering Helpers
    # ------------------------------------------------------------------

    def _clear_body(self) -> None:
        self._live_updaters.clear()
        for child in self.body.winfo_children():
            child.destroy()

    def _render_active_panel(self) -> None:
        self._clear_body()
        if self._last_error:
            self._banner(self._last_error, RED)
        if self._snapshot is None:
            self._empty_card("正在采集本机与远端运行态…", MUTED)
            self._fit_height()
            return

        if self.active_tab == "colab":
            self._render_colab(self._snapshot.get("colab") or {})
        elif self.active_tab == "agents":
            self._render_agents(self._snapshot.get("agents") or {})
        elif self.active_tab == "ci":
            self._render_ci((self._snapshot.get("ops") or {}).get("ci") or {})
        else:
            self._render_host((self._snapshot.get("ops") or {}).get("host") or {})
        self._fit_height()

    def _banner(self, text: str, color: str) -> None:
        lbl = tk.Label(
            self.body,
            text=f"⚠ {truncate_text(text, 64)}",
            fg=color,
            bg=CARD_BG,
            padx=10,
            pady=6,
            anchor="w",
            font=FONT_UI_SM,
        )
        lbl.pack(fill="x", pady=(0, 6))

    def _empty_card(self, text: str, color: str = MUTED) -> None:
        tk.Label(
            self.body,
            text=text,
            fg=color,
            bg=CARD_BG,
            padx=10,
            pady=12,
            anchor="w",
            font=FONT_UI_SM,
        ).pack(fill="x")

    def _stat_chip(self, parent: tk.Misc, title: str, value: str, color: str = TEXT) -> None:
        box = tk.Frame(parent, bg=CARD_BG)
        box.pack(side="left", padx=(0, 12))
        tk.Label(box, text=title, fg=MUTED, bg=CARD_BG, font=("Microsoft YaHei UI", 7)).pack(anchor="w")
        tk.Label(box, text=value, fg=color, bg=CARD_BG, font=("Consolas", 10, "bold")).pack(anchor="w")

    # ------------------------------------------------------------------
    # Panel 1: Colab
    # ------------------------------------------------------------------

    def _render_colab(self, colab: dict[str, Any]) -> None:
        if colab.get("error"):
            self._banner(str(colab["error"]), RED)
        if not colab.get("installed", True):
            self._empty_card("未安装 colab-pool CLI · Agents / CI / 宿主面板正常可用")
            return

        balance = float(colab.get("totalPaidBalanceCu", 0.0) or 0.0)
        burn = float(colab.get("totalBurnRateHourly", 0.0) or 0.0)
        nodes = colab.get("nodes") or []
        active_nodes = int(colab.get("activeNodes", 0) or 0)
        max_nodes = int(colab.get("maxNodes", 0) or 0)
        active_slots = int(colab.get("activeSlots", 0) or 0)
        max_slots = int(colab.get("maxSlots", 0) or 0)
        idle_timeout = float(colab.get("idleTimeoutSeconds", 600.0) or 600.0)
        idle_wasting = active_nodes > 0 and active_slots == 0

        card = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=8)
        card.pack(fill="x", pady=(0, 6))

        top = tk.Frame(card, bg=CARD_BG)
        top.pack(fill="x")
        delta_txt = ""
        if self._initial_balance is not None:
            delta = balance - self._initial_balance
            if abs(delta) >= 0.01:
                delta_txt = f" ({delta:+.2f})"
        tk.Label(top, text=f"{balance:.2f} CU{delta_txt}", fg=TEXT, bg=CARD_BG, font=FONT_MONO_LG).pack(side="left")

        if active_nodes == 0:
            burn_txt, burn_fg = "0.00 CU/h · 零消耗", GREEN
        elif active_slots > 0:
            burn_txt, burn_fg = f"{burn:.2f} CU/h · 使用中", ACCENT
        else:
            burn_txt, burn_fg = f"{burn:.2f} CU/h · 空载", AMBER
        tk.Label(top, text=burn_txt, fg=burn_fg, bg=CARD_BG, font=FONT_UI_BOLD).pack(side="right", pady=(2, 0))

        state_hint = "空载待机中" if idle_wasting else ("无活跃 VM" if active_nodes == 0 else "任务运行中")
        tk.Label(
            card,
            text=f"节点 {active_nodes}/{max_nodes} · 槽位 {active_slots}/{max_slots} · {state_hint}",
            fg=AMBER if idle_wasting else MUTED,
            bg=CARD_BG,
            font=FONT_UI_SM,
            anchor="w",
        ).pack(fill="x", pady=(4, 0))

        if not nodes:
            self._empty_card("当前没有活跃 Colab VM（零空耗）", GREEN)
        else:
            now = time.time()
            for node in sorted(nodes, key=lambda n: str(n.get("node_id", "")))[:5]:
                nc = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=6)
                nc.pack(fill="x", pady=(0, 4))
                nid = str(node.get("node_id", "unknown"))
                status = str(node.get("status", "?"))
                account = str(node.get("account", "-"))
                n_slots = int(node.get("active_slots", 0) or 0)
                projects = [str(p) for p in (node.get("active_projects") or []) if p]

                nrow = tk.Frame(nc, bg=CARD_BG)
                nrow.pack(fill="x")
                tk.Label(nrow, text=nid, fg=TEXT, bg=CARD_BG, font=("Consolas", 9, "bold")).pack(side="left")
                tk.Label(nrow, text=f"{status} · {account}", fg=ACCENT, bg=CARD_BG, font=FONT_MONO_SM).pack(side="right")

                if n_slots > 0:
                    proj_str = ", ".join(projects) if projects else f"{n_slots} 槽占用中"
                    sub_txt, sub_fg = f"运行中: {truncate_text(proj_str, 42)}", ACCENT
                    tk.Label(nc, text=sub_txt, fg=sub_fg, bg=CARD_BG, font=FONT_UI_SM, anchor="w").pack(fill="x")
                else:
                    anchor = float(node.get("last_used_at") or node.get("created_at") or now)
                    remain = max(0.0, idle_timeout - max(0.0, now - anchor))
                    sub_txt = f"空闲 {format_duration(remain)} 后自动回收" if remain > 0 else "已达空闲阈值 · 等待回收"
                    sub_fg = MUTED if remain > 0 else AMBER
                    sub_lbl = tk.Label(nc, text=sub_txt, fg=sub_fg, bg=CARD_BG, font=FONT_UI_SM, anchor="w")
                    sub_lbl.pack(fill="x")

                    def _update_idle(lbl: tk.Label = sub_lbl, anc: float = anchor, tout: float = idle_timeout) -> None:
                        rem = max(0.0, tout - max(0.0, time.time() - anc))
                        lbl.configure(
                            text=f"空闲 {format_duration(rem)} 后自动回收" if rem > 0 else "已达空闲阈值 · 等待回收",
                            fg=MUTED if rem > 0 else AMBER,
                        )

                    self._live_updaters.append(_update_idle)

        accounts = colab.get("accounts") or []
        if accounts:
            primary = colab.get("primaryAccount")
            strip = tk.Frame(self.body, bg=SUBCARD_BG, padx=10, pady=6)
            strip.pack(fill="x", pady=(2, 0))
            for acc in accounts[:4]:
                alias = str(acc.get("alias", "-"))
                bal = float(acc.get("paid_balance", 0.0) or 0.0)
                vms = int(acc.get("active_vms_count", 0) or 0)
                ok = acc.get("ok", True)
                row = tk.Frame(strip, bg=SUBCARD_BG)
                row.pack(fill="x", pady=1)
                dot_c = RED if not ok else (ACCENT if vms > 0 else MUTED)
                pri_tag = " [主力]" if primary and alias == primary else ""
                tk.Label(row, text="●", fg=dot_c, bg=SUBCARD_BG, font=("Segoe UI", 7)).pack(side="left")
                tk.Label(row, text=f" {alias}{pri_tag}", fg=TEXT, bg=SUBCARD_BG, font=FONT_MONO_SM).pack(side="left")
                tk.Label(
                    row, text=f"{bal:.1f} CU · {vms} VM", fg=ACCENT if vms > 0 else MUTED, bg=SUBCARD_BG, font=FONT_MONO_SM
                ).pack(side="right")

    # ------------------------------------------------------------------
    # Panel 2: Agents
    # ------------------------------------------------------------------

    def _render_agents(self, agents: dict[str, Any]) -> None:
        active_w = int(agents.get("activeWorkers", 0) or 0)
        task_w = int(agents.get("taskWorkers", 0) or 0)
        long_warn = int(agents.get("longRunningWarnings", 0) or 0)
        mem_mb = float(agents.get("totalWorkerMemoryMb", 0.0) or 0.0)
        daemon = agents.get("daemon") or {}
        instances = agents.get("instances") or {}

        card = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=8)
        card.pack(fill="x", pady=(0, 6))

        top = tk.Frame(card, bg=CARD_BG)
        top.pack(fill="x")
        tk.Label(top, text=f"{active_w} 活跃会话", fg=TEXT, bg=CARD_BG, font=FONT_MONO_LG).pack(side="left")

        if agents.get("haInstalled") and not daemon.get("online"):
            pill_t, pill_c = "Ha Daemon 离线", RED
        elif instances.get("frozenIds"):
            pill_t, pill_c = f"实例冻结: {len(instances['frozenIds'])}", AMBER
        elif long_warn > 0:
            pill_t, pill_c = f"{long_warn} 个超 60m", AMBER
        elif daemon.get("online"):
            pill_t, pill_c = f"Ha 在线 · {daemon.get('attachedRepos', 0)}仓", GREEN
        else:
            pill_t, pill_c = "本机进程监控", GREEN
        tk.Label(top, text=pill_t, fg=pill_c, bg=CARD_BG, font=FONT_UI_BOLD).pack(side="right", pady=(2, 0))

        chips = tk.Frame(card, bg=CARD_BG)
        chips.pack(fill="x", pady=(6, 0))
        self._stat_chip(chips, "派工", str(task_w))
        if int(instances.get("total", 0) or 0) > 0:
            self._stat_chip(chips, "实例", f"{instances.get('healthy', 0)}/{instances.get('total', 0)}")
        if int(agents.get("agyPoolStandby", 0) or 0) > 0:
            self._stat_chip(chips, "AGY池", str(agents["agyPoolStandby"]))
        mem_str = f"{mem_mb / 1024.0:.1f}G" if mem_mb >= 1024.0 else f"{mem_mb:.0f}M"
        self._stat_chip(chips, "内存", mem_str)

        workers = agents.get("workers") or []
        if not workers:
            self._empty_card("当前没有活跃 Coding Agent 会话", GREEN)
        else:
            checked_at = float(agents.get("checkedAt", time.time()) or time.time())
            now = time.time()
            for w in workers[:6]:
                wc = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=6)
                wc.pack(fill="x", pady=(0, 4))
                is_warn = bool(w.get("longRunningWarning"))
                elapsed = float(w.get("elapsedSeconds", 0) or 0) + max(0.0, now - checked_at)
                tag = w.get("taskLabel") or w.get("scope", "-")

                r1 = tk.Frame(wc, bg=CARD_BG)
                r1.pack(fill="x")
                tk.Label(
                    r1,
                    text=f"{w.get('kind', '?')} · {w.get('model', '-')}",
                    fg=AMBER if is_warn else TEXT,
                    bg=CARD_BG,
                    font=("Consolas", 9, "bold"),
                ).pack(side="left")
                tk.Label(
                    r1,
                    text=f"{'⚠ ' if is_warn else ''}{format_duration(elapsed)}",
                    fg=AMBER if is_warn else MUTED,
                    bg=CARD_BG,
                    font=FONT_MONO_SM,
                ).pack(side="right")

                r2 = tk.Frame(wc, bg=CARD_BG)
                r2.pack(fill="x", pady=(2, 0))
                tk.Label(
                    r2,
                    text=f"{w.get('workspace', '-')} · {tag}",
                    fg=MUTED,
                    bg=CARD_BG,
                    font=FONT_MONO_SM,
                ).pack(side="left")
                tk.Label(
                    r2,
                    text=f"{float(w.get('memoryMb', 0.0)):.0f}M",
                    fg=MUTED,
                    bg=CARD_BG,
                    font=FONT_MONO_SM,
                ).pack(side="right")

        bridges = agents.get("bridges") or []
        if bridges:
            strip = tk.Frame(self.body, bg=SUBCARD_BG, padx=10, pady=6)
            strip.pack(fill="x", pady=(2, 0))
            for b in bridges:
                online = bool(b.get("online"))
                warn = bool(b.get("warning"))
                c = MUTED if not online else (AMBER if warn else GREEN)
                item = tk.Frame(strip, bg=SUBCARD_BG)
                item.pack(side="left", padx=(0, 10))
                tk.Label(item, text="●", fg=c, bg=SUBCARD_BG, font=("Segoe UI", 7)).pack(side="left")
                tk.Label(
                    item, text=f" {b.get('label', '')}", fg=TEXT if online else MUTED, bg=SUBCARD_BG, font=FONT_UI_SM
                ).pack(side="left")

    # ------------------------------------------------------------------
    # Panel 3: CI / 交付
    # ------------------------------------------------------------------

    def _render_ci(self, ci: dict[str, Any]) -> None:
        open_prs = int(ci.get("openPrs", 0) or 0)
        passing = int(ci.get("passingPrs", 0) or 0)
        running = int(ci.get("runningPrs", 0) or 0)
        failing = int(ci.get("failingPrs", 0) or 0)
        queue = ci.get("reviewQueue") or {}
        in_rev = int(queue.get("inReview", 0) or 0)
        submitted = int(queue.get("submitted", 0) or 0)
        blocked = int(queue.get("blocked", 0) or 0)

        card = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=8)
        card.pack(fill="x", pady=(0, 6))

        top = tk.Frame(card, bg=CARD_BG)
        top.pack(fill="x")
        tk.Label(top, text=f"{open_prs} 开放 PR", fg=TEXT, bg=CARD_BG, font=FONT_MONO_LG).pack(side="left")

        if failing > 0:
            pill_t, pill_c = f"{failing} 个门禁失败", RED
        elif running > 0:
            pill_t, pill_c = f"{running} 个门禁运行中", ACCENT
        elif open_prs > 0:
            pill_t, pill_c = "门禁全部通过", GREEN
        else:
            pill_t, pill_c = "无开放 PR", GREEN
        tk.Label(top, text=pill_t, fg=pill_c, bg=CARD_BG, font=FONT_UI_BOLD).pack(side="right", pady=(2, 0))

        chips = tk.Frame(card, bg=CARD_BG)
        chips.pack(fill="x", pady=(6, 0))
        self._stat_chip(chips, "通过", str(passing), GREEN)
        self._stat_chip(chips, "运行", str(running), ACCENT)
        self._stat_chip(chips, "失败", str(failing), RED if failing > 0 else TEXT)
        self._stat_chip(chips, "待审", str(in_rev + submitted))
        self._stat_chip(chips, "阻塞", str(blocked), AMBER if blocked > 0 else TEXT)

        sub_bar = tk.Frame(self.body, bg=BG)
        sub_bar.pack(fill="x", pady=(0, 6))
        for sk, stitle in (("prs", f"GitHub PR · {open_prs}"), ("tasks", f"待审与阻塞 · {queue.get('total', 0)}")):
            active = self.ci_sub_tab == sk
            tk.Button(
                sub_bar,
                text=stitle,
                command=lambda k=sk: self._set_ci_subtab(k),
                bd=0,
                padx=8,
                pady=2,
                cursor="hand2",
                bg=CARD_BG if active else BG,
                fg=TEXT if active else MUTED,
                font=FONT_MONO_SM,
            ).pack(side="left", padx=(0, 6))

        if self.ci_sub_tab == "prs":
            prs = ci.get("prs") or []
            if not prs:
                msg = "当前没有开放的 GitHub PR" if ci.get("ghAvailable") else "未检测到 gh CLI"
                self._empty_card(msg, GREEN if ci.get("ghAvailable") else MUTED)
                return
            for pr in prs[:5]:
                pc = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=6, cursor="hand2")
                pc.pack(fill="x", pady=(0, 4))
                url = str(pr.get("url", ""))
                if url:
                    pc.bind("<Button-1>", lambda _e, u=url: webbrowser.open(u))

                ci_state = pr.get("ciState", "none")
                if pr.get("mergeState") == "DIRTY":
                    st_txt, st_col = "冲突", RED
                elif ci_state == "failing":
                    st_txt, st_col = f"{pr.get('checksFailed', 0)}/{pr.get('checksTotal', 0)} ✗", RED
                elif ci_state == "running":
                    st_txt, st_col = f"{pr.get('checksPassed', 0)}/{pr.get('checksTotal', 0)} ⟳", ACCENT
                elif ci_state == "passing":
                    st_txt, st_col = f"{pr.get('checksPassed', 0)}/{pr.get('checksTotal', 0)} ✓", GREEN
                else:
                    st_txt, st_col = ("草稿" if pr.get("isDraft") else "无门禁"), MUTED

                r1 = tk.Frame(pc, bg=CARD_BG)
                r1.pack(fill="x")
                tk.Label(
                    r1, text=f"#{pr.get('number')} {pr.get('repo', '')}", fg=TEXT, bg=CARD_BG, font=("Consolas", 9, "bold")
                ).pack(side="left")
                tk.Label(r1, text=st_txt, fg=st_col, bg=CARD_BG, font=FONT_MONO_SM).pack(side="right")

                title_lbl = tk.Label(
                    pc,
                    text=truncate_text(str(pr.get("title", "")), 48),
                    fg=MUTED,
                    bg=CARD_BG,
                    font=FONT_UI_SM,
                    anchor="w",
                )
                title_lbl.pack(fill="x")
                if url:
                    title_lbl.bind("<Button-1>", lambda _e, u=url: webbrowser.open(u))
        else:
            items = queue.get("items") or []
            if not items:
                self._empty_card("没有阻塞或待审的 Harness 任务", GREEN)
                return
            for item in items[:6]:
                tc = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=6)
                tc.pack(fill="x", pady=(0, 4))
                st = str(item.get("status", ""))
                st_c = RED if st == "blocked" else (AMBER if st == "in_review" else ACCENT)
                r1 = tk.Frame(tc, bg=CARD_BG)
                r1.pack(fill="x")
                tk.Label(
                    r1, text=f"{item.get('repo', '')} · {item.get('taskId', '')}", fg=TEXT, bg=CARD_BG, font=FONT_MONO_SM
                ).pack(side="left")
                tk.Label(r1, text=st, fg=st_c, bg=CARD_BG, font=FONT_MONO_SM).pack(side="right")
                tk.Label(
                    tc,
                    text=truncate_text(str(item.get("title", "")), 48),
                    fg=MUTED,
                    bg=CARD_BG,
                    font=FONT_UI_SM,
                    anchor="w",
                ).pack(fill="x")

    def _set_ci_subtab(self, key: str) -> None:
        self.ci_sub_tab = key
        self._render_active_panel()

    # ------------------------------------------------------------------
    # Panel 4: 宿主
    # ------------------------------------------------------------------

    def _render_host(self, host: dict[str, Any]) -> None:
        cpu_pct = int(host.get("cpuLoadPercent", 0) or 0)
        mem_free = int(host.get("memoryFreePercent", 50) or 50)
        disk_free = float(host.get("diskFreeGiB", 0.0) or 0.0)
        disk_used = float(host.get("diskUsedPercent", 0.0) or 0.0)
        disk_warn = bool(host.get("diskWarning"))

        card = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=8)
        card.pack(fill="x", pady=(0, 6))

        top = tk.Frame(card, bg=CARD_BG)
        top.pack(fill="x")
        tk.Label(
            top,
            text=f"磁盘剩余 {disk_free:.1f}G",
            fg=AMBER if disk_warn else TEXT,
            bg=CARD_BG,
            font=FONT_MONO_LG,
        ).pack(side="left")
        tk.Label(
            top,
            text=f"已用 {disk_used:.0f}% · {'空间预警' if disk_warn else '正常'}",
            fg=AMBER if disk_warn else GREEN,
            bg=CARD_BG,
            font=FONT_UI_BOLD,
        ).pack(side="right", pady=(2, 0))

        chips = tk.Frame(card, bg=CARD_BG)
        chips.pack(fill="x", pady=(6, 0))
        self._stat_chip(chips, "CPU", f"{cpu_pct}%")
        self._stat_chip(chips, "空闲内存", f"{mem_free}%")
        self._stat_chip(chips, "工作树", str(host.get("totalWorktrees", 0)))
        unpushed = int(host.get("totalUnpushed", 0) or 0)
        self._stat_chip(chips, "未推送", str(unpushed), AMBER if unpushed > 0 else TEXT)
        dirty_repos = int(host.get("dirtyRepos", 0) or 0)
        self._stat_chip(chips, "脏仓库", str(dirty_repos), AMBER if dirty_repos > 0 else TEXT)

        repos = host.get("repos") or []
        if not repos:
            self._empty_card("未发现活跃 Git 仓库（可设置 AGENT_OPS_REPOS）")
            return
        for r in repos[:6]:
            rc = tk.Frame(self.body, bg=CARD_BG, padx=10, pady=6, cursor="hand2")
            rc.pack(fill="x", pady=(0, 4))
            rpath = str(r.get("path", ""))
            if rpath:
                rc.bind("<Button-1>", lambda _e, p=rpath: self._open_folder(p))

            wt = int(r.get("worktreeCount", 0) or 0)
            up = int(r.get("unpushedCount", 0) or 0)
            dt = int(r.get("dirtyCount", 0) or 0)

            r1 = tk.Frame(rc, bg=CARD_BG)
            r1.pack(fill="x")
            tk.Label(
                r1, text=f"{r.get('name', '?')} ({r.get('branch', '-')})", fg=TEXT, bg=CARD_BG, font=FONT_MONO_SM
            ).pack(side="left")
            badges = f"{wt}wt · {up}↑ · {dt}✎"
            b_col = AMBER if (up > 0 or wt >= 10) else MUTED
            tk.Label(r1, text=badges, fg=b_col, bg=CARD_BG, font=FONT_MONO_SM).pack(side="right")

    @staticmethod
    def _open_folder(path: str) -> None:
        try:
            os.startfile(path)  # type: ignore[attr-defined]
        except Exception:
            pass

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    AgentOpsBarWindow().run()
