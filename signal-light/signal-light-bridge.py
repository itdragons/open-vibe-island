#!/usr/bin/env python3
import asyncio
import json
import os
import socket
import sys
import argparse
from bleak import BleakScanner, BleakClient

# ESP32-C3 BLE Service and Characteristic UUIDs from config.h
SERVICE_UUID = "77697364-6f6d-6761-7264-656e00000001"
CMD_CHAR_UUID = "77697364-6f6d-6761-7264-656e00000002"

# Config file to store selected device details
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, ".selected_device")

# Map aggregate state to BLE light command
STATE_EFFECTS = {
    "needsApproval": "ALARM",  # Red/Yellow alternating flashing
    "needsAnswer": "EFFECT:BREATHE:YG:1200",  # Yellow/Green breathing
    "running": "THINKING",  # Cycling Red/Yellow/Green (thinking mode)
    "idle": "SUCCESS",  # Green solid (success/done)
}


class SessionTracker:
    def __init__(self):
        # Map session_id -> current phase ("idle", "running", "waitingForApproval", "waitingForAnswer")
        self.sessions = {}

    def handle_hook(self, source, event_name, session_id, payload):
        phase = "idle"

        # Claude / Kimi / Qwen / Qoder / Factory / Droid / Codebuddy
        if source in (
            "claude",
            "qoder",
            "qwen",
            "factory",
            "codebuddy",
            "kimi",
            "droid",
        ):
            if event_name in ("SessionStart", "Stop", "StopFailure", "SessionEnd"):
                phase = "idle"
            elif (
                event_name == "PreToolUse"
                and (payload or {}).get("tool_name") == "AskUserQuestion"
            ):
                # 与 Swift 端一致：AskUserQuestion 表示 Agent 停下等待用户回答
                phase = "waitingForAnswer"
            elif event_name in (
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PostToolUseFailure",
                "PermissionDenied",
            ):
                phase = "running"
            elif event_name == "PermissionRequest":
                phase = "waitingForApproval"
            elif event_name == "Notification":
                # Do not change phase on notification
                phase = self.sessions.get(session_id, "idle")
            else:
                phase = self.sessions.get(session_id, "idle")

        # Gemini CLI
        elif source == "gemini":
            if event_name in ("SessionStart", "SessionEnd", "AfterAgent"):
                phase = "idle"
            elif event_name == "BeforeAgent":
                phase = "running"
            else:
                phase = self.sessions.get(session_id, "idle")

        # Cursor
        elif source == "cursor":
            if event_name in (
                "beforeSubmitPrompt",
                "beforeShellExecution",
                "beforeMCPExecution",
                "beforeReadFile",
            ):
                phase = "running"
            elif event_name in ("stop", "afterFileEdit"):
                phase = "idle"
            else:
                phase = self.sessions.get(session_id, "idle")

        # Codex CLI
        else:
            if event_name in ("SessionStart", "Stop"):
                phase = "idle"
            elif event_name in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
                phase = "running"
            elif event_name == "PermissionRequest":
                phase = "waitingForApproval"
            else:
                phase = self.sessions.get(session_id, "idle")

        if event_name in ("SessionEnd", "Stop"):
            self.sessions.pop(session_id, None)
            print(f"🧹 会话已结束并清理: {session_id[:8]}")
        else:
            self.sessions[session_id] = phase
            print(f"🔄 会话 [{source}] {session_id[:8]} 状态更新为: {phase}")

    def get_aggregate_state(self):
        if not self.sessions:
            return "idle"
        phases = list(self.sessions.values())
        if "waitingForApproval" in phases:
            return "needsApproval"
        if "waitingForAnswer" in phases:
            return "needsAnswer"
        if "running" in phases:
            return "running"
        return "idle"


# Global variables
ble_client = None
session_tracker = SessionTracker()
current_effect = None
args = None
selected_address = None
# 串行化交互式审批提问，避免多个会话同时抢占 stdin
approval_lock = asyncio.Lock()


def read_saved_device():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get("name"), data.get("address")
        except:
            pass
    return None, None


def save_device(name, address):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump({"name": name, "address": address}, f, ensure_ascii=False)
        print(f"💾 已在本地记住设备: {name} ({address})")
    except Exception as e:
        print(f"⚠️ 保存设备配置失败: {e}")


CLAUDE_HOOK_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
    "SessionEnd",
]


def build_claude_hooks_config(socket_path, hook_script_path):
    command = (
        f"OPEN_ISLAND_SOCKET_PATH={socket_path} "
        f"python3 {hook_script_path} --source claude"
    )
    hooks = {}
    for event in CLAUDE_HOOK_EVENTS:
        entry = {"type": "command", "command": command}
        if event == "PermissionRequest":
            # 审批可能等待很久，必须覆盖 Claude Code 默认的 hook 超时（约 60 秒），
            # 否则交互式审批超时后会被静默跳过。与 Swift 安装器保持一致。
            entry["timeout"] = 86400
        hooks[event] = [{"hooks": [entry]}]
    return json.dumps({"hooks": hooks}, indent=2, ensure_ascii=False)


def print_claude_hook_instructions(socket_path):
    home = os.path.expanduser("~")
    claude_config_path = os.path.join(home, ".claude", "settings.json")
    root_dir = os.path.dirname(SCRIPT_DIR)
    hook_script_path = os.path.join(root_dir, "scripts", "open-island-hooks.py")
    hooks_json = build_claude_hooks_config(socket_path, hook_script_path)

    instructions = f"""
======================================================================
📦 [依赖安装提示]
======================================================================
在运行此脚本前，请确保在你的 Python 环境（如 .venv）中安装了 bleak 库：
👉 pip install bleak

======================================================================
💡 [Claude Code Hooks 配置指南]
======================================================================
如果要让 Claude Code 的工作状态同步到红绿灯，请执行以下步骤：

1. 打开或创建 Claude Code 配置文件：
   👉 {claude_config_path}

2. 将以下 JSON 配置内容复制/合并到你的 "hooks" 字段下，注意修改 Python 路径：

```json
{hooks_json}
```

3. 保存并关闭文件。当运行 Claude 时，你的红绿灯便会自动切换对应的颜色。

⚠️ 注意：如果你已经用 Open Island macOS 应用安装过托管 hooks，请不要再重复
   添加以上配置（两套 hooks 会同时触发、互相干扰），二者选其一即可。
======================================================================

======================================================================
🚦 [红绿灯状态定义说明]
======================================================================
- 🟢 绿灯常亮 (SUCCESS)：当前所有会话已结束或处于空闲状态 (idle)
- 🔄 炫彩轮转 (THINKING)：Agent 正在思考、推理或执行常规工具 (running)
- ⚠️ 黄绿慢吸 (YG BREATH)：Agent 通过 AskUserQuestion 等待你回答问题 (needsAnswer)
- 🚨 红黄交替闪烁 (ALARM)：Agent 正在等待权限审批 (needsApproval)

"""
    print(instructions)


async def send_ble_command(cmd):
    global ble_client
    if ble_client and ble_client.is_connected:
        try:
            print(f"⚡️ [BLE] 发送指令: {cmd}")
            await ble_client.write_gatt_char(CMD_CHAR_UUID, cmd.encode("utf-8"))
        except Exception as e:
            print(f"❌ [BLE] 发送失败: {e}")
    else:
        print(f"⚠️ [BLE] 未连接，忽略指令: {cmd}")


async def update_signal_light():
    global current_effect, session_tracker
    agg_state = session_tracker.get_aggregate_state()
    effect = STATE_EFFECTS.get(agg_state, "OFF")

    if effect != current_effect:
        current_effect = effect
        print(f"💡 [Light] 聚合状态变更: {agg_state} -> 目标灯效: {effect}")
        await send_ble_command(effect)


async def ainput(prompt: str = "") -> str:
    print(prompt, end="", flush=True)
    return await asyncio.to_thread(sys.stdin.readline)


async def scan_and_select_device():
    global args, selected_address

    # 1. Option to filter device via CLI arg
    if args.device:
        print(f"🔍 [BLE] 正在扫描信号灯 (过滤参数: {args.device}) ...")
        devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])
        named_devices = [d for d in devices if d.name]

        target = None
        for d in named_devices:
            if (
                args.device.lower() in d.name.lower()
                or args.device.lower() in d.address.lower()
            ):
                target = d
                break
        if not target:
            print(f"❌ [BLE] 未找到匹配名称或地址 '{args.device}' 的设备。")
            return False
        selected_address = target.address
        print(f"🔗 [BLE] 根据参数自动选择设备: {target.name} ({target.address})")
        save_device(target.name, target.address)
        return True

    # 2. Check if device is saved locally
    if not args.select:
        saved_name, saved_address = read_saved_device()
        if saved_address:
            selected_address = saved_address
            print(f"📦 [BLE] 读取到本地记住的设备: {saved_name} ({saved_address})")
            return True

    # 3. Otherwise, scan and let the user select
    print(f"🔍 [BLE] 正在扫描信号灯 (服务 UUID: {SERVICE_UUID}) ...")
    devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])
    named_devices = [d for d in devices if d.name]

    if not named_devices:
        print("❌ [BLE] 未找到任何红绿灯设备，请检查硬件是否通电。")
        return False

    # Interactive selection
    print("\n扫描到以下信号灯设备:")
    for i, d in enumerate(named_devices):
        print(f"[{i}] {d.name} ({d.address})")
    print("-" * 40)

    while True:
        try:
            choice = await ainput(
                f"请选择你要连接的设备编号 (0-{len(named_devices) - 1})，或输入 q 退出: "
            )
            choice = choice.strip()
            if choice.lower() == "q":
                sys.exit(0)
            index = int(choice)
            if 0 <= index < len(named_devices):
                target = named_devices[index]
                selected_address = target.address
                print(f"✅ 已选择设备: {target.name} ({target.address})")
                save_device(target.name, target.address)
                return True
            else:
                print("❌ 编号超出范围，请重新输入。")
        except ValueError:
            print("❌ 无效输入，请输入对应的数字。")


async def ble_reconnection_loop():
    global ble_client, selected_address, current_effect
    while True:
        try:
            if selected_address and (ble_client is None or not ble_client.is_connected):
                if ble_client:
                    print("⚠️ [BLE] 连接已断开，正在尝试重连...")
                    try:
                        await ble_client.disconnect()
                    except:
                        pass
                    ble_client = None

                print(f"🔗 [BLE] 正在连接目标设备: {selected_address} ...")
                client = BleakClient(selected_address)
                await client.connect()
                ble_client = client
                print("🎉 [BLE] 蓝牙连接成功！")

                # 断连期间设备可能重启丢失灯效，重置缓存强制重发一次
                current_effect = None
                await update_signal_light()
        except Exception as e:
            print(f"❌ [BLE] 连接遇到异常: {e}，将在 5 秒后重试...")

        await asyncio.sleep(5)


async def handle_claude_approval(payload):
    """处理 Claude 的 PermissionRequest 审批。

    默认（仅灯效）模式回 acknowledged：hook 客户端不输出任何 directive，
    Claude Code 走自己的权限确认界面，红绿灯只负责用 ALARM 提醒你回终端。
    """
    global args
    if args.auto_approve:
        print("🤖 [Auto-Approve] 自动批准 PermissionRequest 请求")
        return {
            "type": "claudeHookDirective",
            "directive": {
                "type": "permissionRequest",
                "directive": {"behavior": "allow"},
            },
        }

    if not args.interactive:
        return {"type": "acknowledged"}

    # Interactive terminal approval mode
    async with approval_lock:
        print("\n" + "🚨" * 20)
        print(f"⚠️  [Claude Code 权限审批请求]")
        print(f"📂 项目路径: {payload.get('cwd')}")
        print(f"🛠️  欲调用的工具: {payload.get('tool_name')}")
        suggestions = payload.get("permission_suggestions", [])
        if suggestions:
            print(f"💡 建议授权列表:")
            for sugg in suggestions:
                print(f"   - {sugg}")
        print("🚨" * 20)

        ans = await ainput("👉 是否批准上述操作？ [y/N]: ")
    approved = ans.strip().lower() in ("y", "yes")
    print(f"📝 审批决策结果: {'批准 (Allow)' if approved else '拒绝 (Deny)'}")

    directive = {"behavior": "allow"}
    if not approved:
        directive = {"behavior": "deny", "message": "Denied via signal-light bridge"}
    return {
        "type": "claudeHookDirective",
        "directive": {"type": "permissionRequest", "directive": directive},
    }


async def handle_codex_approval(payload):
    global args
    if not args.interactive:
        return {"type": "acknowledged"}

    async with approval_lock:
        print("\n" + "🚨" * 20)
        print(f"⚠️  [Codex CLI 权限审批请求]")
        print(f"📂 工作路径: {payload.get('cwd')}")
        print(f"🛠️  工具命令: {payload.get('tool_name')}")
        print(f"💻 命令行内容: {payload.get('tool_input', {}).get('command')}")
        print("🚨" * 20)

        ans = await ainput("👉 是否批准上述操作？ [y/N]: ")
    approved = ans.strip().lower() in ("y", "yes")
    print(f"📝 审批决策结果: {'批准 (Allow)' if approved else '拒绝 (Deny)'}")

    if not approved:
        return {
            "type": "codexHookDirective",
            "directive": {"type": "deny", "reason": "Blocked by Python Script Bridge"},
        }
    return {"type": "acknowledged"}


async def handle_client_connection(reader, writer):
    global session_tracker
    try:
        data = await reader.readline()
        if not data:
            return

        line = data.decode("utf-8").strip()
        if not line:
            return

        try:
            envelope = json.loads(line)
        except Exception as e:
            print(f"❌ [Server] 接收到非法 JSON 帧: {e}")
            return

        env_type = envelope.get("type")
        if env_type != "command":
            writer.write(
                (
                    json.dumps(
                        {"type": "response", "response": {"type": "acknowledged"}}
                    )
                    + "\n"
                ).encode("utf-8")
            )
            await writer.drain()
            return

        command = envelope.get("command", {})
        cmd_type = command.get("type")
        response_data = {"type": "acknowledged"}

        source = None
        event_name = None
        session_id = None
        payload = None

        if cmd_type == "processClaudeHook":
            payload = command.get("claudeHook", {})
            source = payload.get("hook_source", "claude")
            event_name = payload.get("hook_event_name")
            session_id = payload.get("session_id")

        elif cmd_type == "processCodexHook":
            payload = command.get("codexHook", {})
            source = "codex"
            event_name = payload.get("hook_event_name")
            session_id = payload.get("session_id")

        elif cmd_type == "processCursorHook":
            payload = command.get("cursorHook", {})
            source = "cursor"
            event_name = payload.get("hook_event_name")
            session_id = payload.get("session_id")

        elif cmd_type == "processGeminiHook":
            payload = command.get("geminiHook", {})
            source = "gemini"
            event_name = payload.get("hook_event_name")
            session_id = payload.get("session_id")

        # 必须先更新状态和灯效，再进入可能阻塞等待用户输入的审批流程，
        # 保证审批挂起期间 ALARM 灯已经在闪
        if source and event_name and session_id:
            session_tracker.handle_hook(source, event_name, session_id, payload)
            await update_signal_light()

        if event_name == "PermissionRequest":
            if cmd_type == "processClaudeHook":
                response_data = await handle_claude_approval(payload)
            elif cmd_type == "processCodexHook":
                response_data = await handle_codex_approval(payload)

            # 审批已当场给出结论（交互式 y/n 或自动批准），
            # 会话回到 running，不再停留在报警灯效上
            if (
                args.interactive or args.auto_approve
            ) and session_id in session_tracker.sessions:
                session_tracker.sessions[session_id] = "running"
                await update_signal_light()

        # Write response back to socket
        envelope_response = {"type": "response", "response": response_data}
        writer.write((json.dumps(envelope_response) + "\n").encode("utf-8"))
        await writer.drain()

    except Exception as e:
        print(f"❌ [Server] 客户端连接处理出错: {e}")
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except:
            pass


async def main():
    global args
    parser = argparse.ArgumentParser(
        description="Open Island Python 硬件红绿灯桥接服务器"
    )
    parser.add_argument(
        "--socket", default="/tmp/open-island.sock", help="Unix Domain Socket 监听路径"
    )
    parser.add_argument(
        "--interactive", action="store_true", help="启用终端交互式权限审批"
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        help="自动批准所有 Claude 权限请求（危险：等于完全关闭 Claude Code 的权限确认）",
    )
    parser.add_argument("--device", help="特定蓝牙设备的名称或 MAC 地址过滤条件")
    parser.add_argument(
        "--select", action="store_true", help="强制重新扫描并选择蓝牙设备"
    )
    parser.add_argument(
        "--print-instructions",
        action="store_true",
        help="仅打印 Claude Code Hooks 配置和灯效说明后退出（供 bridge-ctl.sh 调用）",
    )
    parser.add_argument(
        "--scan-and-save",
        action="store_true",
        help="交互式扫描并选择蓝牙设备，保存到本地后退出（供 bridge-ctl.sh 首次启动调用）",
    )
    args = parser.parse_args()

    # --print-instructions: 仅打印配置指南后立即退出，
    # 供 bridge-ctl.sh 在后台启动前先展示给用户看。
    if args.print_instructions:
        print_claude_hook_instructions(args.socket)
        return

    # --scan-and-save: 前台交互选择设备，保存后退出。
    # 供 bridge-ctl.sh 在首次启动（无 .selected_device）时调用。
    if args.scan_and_save:
        args.select = True  # 强制进入扫描流程
        success = await scan_and_select_device()
        if success:
            print("✅ 设备已保存，后续启动将自动使用此设备。")
        else:
            print("❌ 未能选择设备。")
            sys.exit(1)
        return

    if args.interactive and args.auto_approve:
        parser.error("--interactive 与 --auto-approve 不能同时使用")

    # Print Claude configuration instructions on startup
    print_claude_hook_instructions(args.socket)

    # 1. Scan and choose BLE device
    success = await scan_and_select_device()
    if not success:
        print("❌ 未能选择设备，程序退出。")
        return

    # 2. Start socket server
    socket_path = args.socket
    if os.path.exists(socket_path):
        # 先探测是否有活跃进程在监听，避免顶掉正在运行的 bridge 或 Open Island app
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(1.0)
        try:
            probe.connect(socket_path)
            print(
                f"❌ [Server] {socket_path} 已有进程在监听（另一个 bridge 或 Open Island app）。"
            )
            print("请先退出该进程，或用 --socket 指定其他路径。")
            return
        except OSError:
            try:
                os.remove(socket_path)
            except Exception as e:
                print(f"⚠️  [Server] 清理旧的 socket 失败: {e}")
        finally:
            probe.close()

    server = await asyncio.start_unix_server(handle_client_connection, path=socket_path)
    print(f"📡 [Server] Unix Socket 服务器已就绪，正在监听: {socket_path}")
    if args.interactive:
        mode = "终端交互式审批 (Interactive)"
    elif args.auto_approve:
        mode = "自动批准 (Auto-Approve)"
    else:
        mode = "仅灯效 (Light-only)：审批仍由 Claude Code 自己的确认界面处理"
    print(f"⚙️  [Config] 模式: {mode}")
    if args.auto_approve:
        print(
            "🚨 [警告] --auto-approve 会自动放行所有权限请求（包括删除文件、外发网络等敏感操作），"
            "等于完全绕过 Claude Code 的权限确认，请仅在完全可信的环境中使用！"
        )

    # 3. Start BLE reconnection background loop
    ble_task = asyncio.create_task(ble_reconnection_loop())

    # Let server run forever
    try:
        async with server:
            await server.serve_forever()
    except asyncio.CancelledError:
        pass
    finally:
        ble_task.cancel()
        if os.path.exists(socket_path):
            os.remove(socket_path)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 桥接服务器已退出。")
