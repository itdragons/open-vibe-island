# Signal Light Python Tools (红绿灯纯脚本运行套件)

这是一个专为 `open-vibe-island` 硬件红绿灯设备（ESP32-C3 核心板）设计的 **纯 Python 脚本管理与运行套件**。

通过这些脚本，你**不需要编译或运行 Swift macOS 客户端**，就可以在终端以纯脚本化的形式运行后台服务、拦截审批、烧录固件及校准接线。

---

## 🚦 目录指南
- **`signal-light-bridge.py`**：状态监控与权限审批桥接服务器。接收 Agent 的 Hook 并驱动硬件灯效。
- **`calibrate.py`**：硬件 LED 引脚接线校准工具。通电测试引脚并将结果永久保存到板子的闪存 (NVS) 中。
- **`flash_ota.py`**：固件无线 (OTA) 升级工具。通过蓝牙将编译好的 `.bin` 固件刷入硬件中。
- **`test_ble.py`**：低级蓝牙指令调试工具。

---

## 📦 环境准备与依赖安装

在运行脚本前，请确保在你的 Python 虚拟环境（如 `.venv`）中安装了 `bleak` 蓝牙库：

```bash
# 1. 激活你的虚拟环境
source .venv/bin/activate

# 2. 安装 bleak
pip install bleak
```

---

## 📡 1. 状态桥接服务 (`signal-light-bridge.py`)

运行此脚本会启动一个 Unix Domain Socket 服务，接收 AI 终端工具的运行状态（如正在运行、等待审批等）并驱动红绿灯。

### 运行指令：
```bash
# 仅灯效模式（默认，推荐）：只驱动灯光，权限审批仍走 Claude Code 自己的确认界面。
# 有审批待处理时红黄灯闪烁，提醒你回到对应终端确认。
python3 signal-light/signal-light-bridge.py

# 终端交互式审批模式（Agent 需要安全确认时会在终端挂起并询问你 y/n）
python3 signal-light/signal-light-bridge.py --interactive

# ⚠️ 危险：自动批准模式。所有权限请求（包括删除文件、外发网络等敏感操作）
# 一律无提示放行，等于完全关闭 Claude Code 的权限确认。仅限完全可信的环境。
python3 signal-light/signal-light-bridge.py --auto-approve

# 强行清除本地已记住的设备，重新扫描并选择红绿灯
python3 signal-light/signal-light-bridge.py --select
```

### 命令参数：
* `--socket`：Unix Socket 监听路径，默认值为 `/tmp/open-island.sock`。
* `--interactive`：开启终端交互式权限审批拦截（在运行 bridge 的终端里输 y/n）。
* `--auto-approve`：**危险**，自动放行所有 Claude 权限请求，与 `--interactive` 互斥。
* `--device`：通过名称或地址模糊过滤蓝牙设备直接连接。
* `--select`：忽略已记住的设备，重新进入扫描及编号选择界面。

---

## 🛠️ 2. 接线校准向导 (`calibrate.py`)

用于匹配 ESP32-C3 主板上的 GPIO 引脚与具体的 LED 灯颜色，无需修改代码或重新烧录，校准结果将永久写入板子的非易失闪存中。

### 运行指令：
```bash
# 启动接线校准
python3 signal-light/calibrate.py
```

### 校准步骤：
1. 脚本会安全测试每一个 GPIO 口（令其通电）。
2. 当有灯亮起时，在终端输入看到的颜色（`r` 代表红，`y` 代表黄，`g` 代表绿，`n` 代表未亮起）。
3. 收集完三个颜色的引脚后，终端会提示你是否将新映射烧录进板子的闪存中。选择 `y` 即可永久生效。

---

## 🚀 3. 无线固件升级 (`flash_ota.py`)

支持通过 BLE (蓝牙低功耗) 协议无线升级板子的固件，内置数据流控，防止 ESP32 溢出或变砖。

### 运行指令：
```bash
# 自动寻找并刷写内置默认的最新的固件 binary
python3 signal-light/flash_ota.py

# 刷写指定的固件 .bin 文件
python3 signal-light/flash_ota.py --file signal-light/firmware/signal-light.bin
```

---

## 💡 Claude Code Hooks 配置指南

如果要让 **Claude Code** 的状态实时反映在红绿灯上，请按以下步骤配置：

1. 用文本编辑器打开 Claude 配置文件：
   👉 `~/.claude/settings.json`

2. 将以下 JSON 段落合并或复制到你的 `"hooks"` 字段下（**请确保命令中的脚本路径指向你的实际绝对路径**）。桥接脚本启动时也会打印一份路径已填好的配置，直接复制即可：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude",
            "timeout": 86400
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "OPEN_ISLAND_SOCKET_PATH=/tmp/open-island.sock python3 /path/to/open-vibe-island/scripts/open-island-hooks.py --source claude"
          }
        ]
      }
    ]
  }
}
```

> **说明**：
> * `PermissionRequest` 上的 `"timeout": 86400` 不能省略——Claude Code 对 hook 有默认超时（约 60 秒），不加的话 `--interactive` 模式下审批超时会被静默跳过。
> * 如果你已经用 **Open Island macOS 应用**安装过托管 hooks，请不要再重复添加以上配置：两套 hooks 会同时触发、互相干扰，二者选其一即可。

---

## 🚦 灯光效果说明

桥接脚本会根据活跃的 Agent 状态，自动向红绿灯发送以下蓝牙指令：

* 🟢 **绿灯常亮** (`SUCCESS`)：当前无会话，或所有的 Agent 已退出、处于空闲状态 (`idle`)。
* 🔄 **炫彩轮转** (`THINKING`)：Agent 正在跑任务、推理中、或正在执行工具指令 (`running`)。
* ⚠️ **黄绿慢吸** (`EFFECT:BREATHE:YG:1200`)：Agent 通过 `AskUserQuestion` 工具等待你回答问题 (`needsAnswer`)。
* 🚨 **红黄交替闪烁** (`ALARM`)：Agent 正在等待权限审批 (`needsApproval`)。默认（仅灯效）模式下请回到 Claude Code 所在终端确认；`--interactive` 模式下在 bridge 终端输 y/n。
