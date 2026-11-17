# AgentOpsBar

常驻 macOS 菜单栏的多智能体研发驾驶舱（原生 Swift / AppKit + 零第三方依赖只读探针），同时支持弹出无焦点抢占的桌面置顶悬浮窗（HUD）。

多路 Coding Agent 并行跑任务时，最常盲飞的四件事——远端测试算力池在不在空转烧钱、哪个 Worker 卡在哪个 worktree 超过 1 小时、哪个 PR 门禁红了或卡在待审队列、本机 SSD 是不是快被几百个 `.worktrees` 撑爆——都在右上角一眼看清。

## 四个面板显示什么

菜单栏常驻圆点与实时摘要（如 `1.56 CU/h · 13槽 · 6A · 1PR✗`），左键展开面板，点击右上角 `📌` 可固定为跨桌面空间的置顶小组件（`nonactivatingPanel`，点击与拖拽不抢占 IDE 或终端焦点）：

| 面板 | 内容 |
| --- | --- |
| **Colab** | `colab-pool` 付费 CU 总余额与本次打开以来的消耗差值、燃烧速率（零消耗 / 使用中 / 空载预警）、主力号与溢出号 VM 分布、单节点槽位占用项目名与空闲自动回收倒计时（未安装 `colab-pool` 时自动隐藏告警并默认切至 `Agents`） |
| **Agents** | 本机活跃 Coding Agent 会话（`Codex` / `DeepSeek Harness` / `Claude Code` / `AGY Pool`）、模型名、内存占用、工作区与 `task_*` 派工标识；单任务运行超 60 分钟自动琥珀色高亮；底部汇总 `Ha Daemon`、`Codex Cloud`、`Hermes`、`Rex` 桥接在线状态与实例冻结告警 |
| **CI / 交付** | 自动聚合当前 GitHub 登录账号及本地活跃仓库的开放 PR 与 CheckRun 进度（通过 / 运行中 / 失败 / 冲突，点击卡片直接在浏览器打开 PR）；支持一键切换查看各仓库 Harness `阻塞 / 待审 / 已提交` 任务队列 |
| **宿主** | 本机 CPU 负载、空闲内存百分比、磁盘剩余空间预警（使用率 ≥90% 或剩余 <80G 自动高亮）、活跃仓库 `.worktrees` 膨胀总数、分支未推送提交数与未提交改动数（点击仓库行直接在访达定位） |

## 数据来源与安全边界

AgentOpsBar **严格只读**：不读取任何私钥或凭据文件，不修改业务仓库，绝不自动启停或重启任何后台守护进程。

| 来源 | 覆盖范围 |
| --- | --- |
| `ps` / `lsof` / `memory_pressure` / `git status` | 本机智能体进程、工作区 CWD、CPU/内存/磁盘与 `.worktrees` 统计（开箱即用） |
| `gh`（GitHub CLI，可选） | 开放 PR 与 GitHub Actions 门禁实时状态（默认 60 秒缓存，手动点 `↻` 强制刷新） |
| `ha`（Harness Anything CLI，可选） | `ha daemon status`、`ha runtime instance list` 与 `ha task list` 待审/阻塞队列 |
| `colab-pool`（可选） | 共享 Google Colab 8 核测试池余额、节点与槽位租约 |

可通过环境变量 `AGENT_OPS_REPOS="/path/to/repoA:/path/to/repoB"` 指定固定巡检仓库列表；未设置时自动发现 `~/Projects` 与已挂载仓库。

## 构建、签名与安装

需要 macOS 13 或更高版本、Swift 5.9+（Xcode 或 Command Line Tools 均可）与系统自带 `python3`。

```bash
git clone https://github.com/FairladyZ625/AgentOpsBar.git
cd AgentOpsBar

# 自动检测钥匙串中的 Developer ID / Apple Development 证书签名（无证书自动回退 ad-hoc 签名），安装到 /Applications 并启动
./scripts/build-app.sh --install --open

# 仅构建到 ./dist/AgentOpsBar.app（使用 ad-hoc 签名）
./scripts/build-app.sh --adhoc
```

在菜单栏图标上右键（或点面板右上角 `⋯`）可随时开启**开机自动启动**、切换桌面置顶悬浮窗或复制当前完整 JSON 快照。

## License

MIT
