# AgentOpsBar (Windows Edition)

轻量级 Windows 桌面置顶监控悬浮窗（Python 3.12 + `tkinter`，零第三方依赖，严格只读）。

## 四个面板

| 面板 | 内容 |
| --- | --- |
| **Colab** | `colab-pool status --json` 付费 CU 余额与本次打开消耗差值、燃烧速率、节点与槽位占用、空闲自动回收倒计时（未安装时自动隐藏并切至 `Agents`） |
| **Agents** | 基于 `Win32_Process` 的本机 Coding Agent 会话（Codex / DSH / Claude / HA / Node / Python 任务）、内存占用、工作区与 `task_*` 标识、超 60 分钟告警，以及 `ha daemon status` / `ha runtime instance list` |
| **CI / 交付** | `gh` 开放 PR 与 CheckRun 状态（60 秒缓存，点 `↻` 强制实时刷新，点击 PR 卡片在浏览器打开）及 `ha task list` 待审/阻塞队列 |
| **宿主** | Windows CPU 负载、空闲内存百分比、磁盘剩余空间预警（使用率 ≥90% 或剩余 <80G 高亮）、活跃仓库 `.worktrees` / 未推送提交 / 脏文件统计（点击仓库行在资源管理器中定位） |

## 环境要求与可选 CLI

- **必需**：Python 3.12+（自带 `tkinter` 与标准库，无需 `pip install`）
- **可选**：`colab-pool`、`gh`（GitHub CLI）、`ha`（Harness Anything CLI）、`git`

### 环境变量

| 变量 | 说明 |
| --- | --- |
| `AGENT_OPS_REPOS` | 分号 `;` 分隔的固定巡检仓库路径（未设置时自动扫描 `ha daemon` 挂载仓库、`D:\project\*`、`~/Projects/*` 与 `~/Brain`） |
| `COLAB_POOL_BIN` | 自定义 `colab-pool` 可执行文件路径 |
| `HARNESS_HA_BIN` | 自定义 `ha` 可执行文件路径 |
| `AGENT_OPS_BAR_CACHE_DIR` | 自定义 CI 缓存目录（默认为 `%LOCALAPPDATA%\agent-ops-bar`） |

## 启动方式

- **无黑框静默启动（推荐）**：双击或运行 `start-agentopsbar.vbs`
- **调试启动（显示控制台输出）**：运行 `start-agentopsbar-debug.bat`
- **命令行仅输出 JSON 快照**：`python probe.py snapshot --fast`

## 严格只读边界

- 不读取任何私钥或凭据文件
- 不修改任何业务仓库
- 绝不自动启停或重启任何后台守护进程
- 仅在 `%LOCALAPPDATA%\agent-ops-bar\ops_ci_cache.json` 写入 60 秒只读缓存
