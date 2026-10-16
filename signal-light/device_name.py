#!/usr/bin/env python3
"""
Open Island 信号灯蓝牙设备名称管理工具。

功能：
  - 查看当前设备的蓝牙广播名称
  - 修改设备名称（写入 NVS 闪存并自动重启生效）

协议：
  GETCONFIG  → 设备通知 CONFIG:R=<pin>,Y=<pin>,G=<pin>,NAME=<name>
  SETNAME:<name> → 设备通知 SETNAME ok, restarting
"""

import asyncio
import os
import sys
import argparse
import json
from bleak import BleakScanner, BleakClient
from bleak.exc import BleakError

# BLE UUIDs
SERVICE_UUID = "77697364-6f6d-6761-7264-656e00000001"
CMD_CHAR_UUID = "77697364-6f6d-6761-7264-656e00000002"
OTA_CONTROL_UUID = "77697364-6f6d-6761-7264-656e00000003"

# Config file to store selected device details
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, ".selected_device")

# Global state for BLE notifications
notification_future = None


def read_saved_device():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get("name"), data.get("address")
        except Exception:
            pass
    return None, None


def save_device(name, address):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump({"name": name, "address": address}, f, ensure_ascii=False)
        print(f"💾 已在本地记住设备: {name} ({address})")
    except Exception as e:
        print(f"⚠️ 保存设备配置失败: {e}")


def notification_handler(sender, data):
    global notification_future
    text = data.decode("utf-8").strip()
    if notification_future and not notification_future.done():
        notification_future.set_result(text)


async def ainput(prompt: str = "") -> str:
    print(prompt, end="", flush=True)
    return await asyncio.to_thread(sys.stdin.readline)


async def scan_and_select_device(args):
    # 1. Option to filter device via CLI arg
    if args.device:
        print(f"🔍 [BLE] 正在扫描信号灯 (过滤参数: {args.device}) ...")
        devices = await BleakScanner.discover(
            timeout=5.0, service_uuids=[SERVICE_UUID]
        )
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
            return None
        save_device(target.name, target.address)
        return target

    # 2. Check if device is saved locally
    if not args.select:
        saved_name, saved_address = read_saved_device()
        if saved_address:
            print(f"📦 [BLE] 读取到本地记住的设备: {saved_name} ({saved_address})")

            class DummyDevice:
                def __init__(self, name, address):
                    self.name = name
                    self.address = address

            return DummyDevice(saved_name, saved_address)

    # 3. Scan and select
    print(f"🔍 [BLE] 正在扫描信号灯 (服务 UUID: {SERVICE_UUID}) ...")
    devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])
    named_devices = [d for d in devices if d.name]

    if not named_devices:
        print("❌ [BLE] 未找到任何红绿灯设备，请检查硬件是否通电。")
        return None

    print("\n扫描到以下信号灯设备:")
    for i, d in enumerate(named_devices):
        print(f"[{i}] {d.name} ({d.address})")
    print("-" * 40)

    while True:
        try:
            choice = await ainput(
                f"请选择设备编号 (0-{len(named_devices)-1})，或输入 q 退出: "
            )
            choice = choice.strip()
            if choice.lower() == "q":
                sys.exit(0)
            index = int(choice)
            if 0 <= index < len(named_devices):
                target = named_devices[index]
                save_device(target.name, target.address)
                return target
            else:
                print("❌ 编号超出范围，请重新输入。")
        except ValueError:
            print("❌ 无效输入，请输入对应的数字。")


async def get_device_name(client):
    """发送 GETCONFIG 并解析返回的 NAME 字段。"""
    global notification_future

    await client.start_notify(OTA_CONTROL_UUID, notification_handler)
    notification_future = asyncio.get_running_loop().create_future()
    await client.write_gatt_char(CMD_CHAR_UUID, b"GETCONFIG", response=True)

    try:
        text = await asyncio.wait_for(notification_future, timeout=5.0)
    except asyncio.TimeoutError:
        print("⚠️  读取设备配置超时。")
        return None
    finally:
        try:
            await client.stop_notify(OTA_CONTROL_UUID)
        except Exception:
            pass

    # Parse CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2
    if text.startswith("CONFIG:"):
        config = {}
        for item in text[7:].split(","):
            parts = item.split("=", 1)
            if len(parts) == 2:
                config[parts[0]] = parts[1]
        return config.get("NAME")

    return None


async def set_device_name(client, new_name):
    """发送 SETNAME:<name>，等待设备确认并自动重启。"""
    global notification_future

    await client.start_notify(OTA_CONTROL_UUID, notification_handler)
    notification_future = asyncio.get_running_loop().create_future()

    cmd = f"SETNAME:{new_name}"
    await client.write_gatt_char(CMD_CHAR_UUID, cmd.encode("utf-8"), response=True)

    try:
        resp = await asyncio.wait_for(notification_future, timeout=5.0)
    except asyncio.TimeoutError:
        print("⚠️  等待设备响应超时。")
        return False
    finally:
        try:
            await client.stop_notify(OTA_CONTROL_UUID)
        except Exception:
            pass

    if "ok" in resp.lower():
        return True
    else:
        print(f"❌ 设备返回错误: {resp}")
        return False


async def main():
    parser = argparse.ArgumentParser(
        description="Open Island 信号灯蓝牙设备名称管理工具"
    )
    parser.add_argument(
        "--get",
        action="store_true",
        help="查看当前设备的蓝牙广播名称",
    )
    parser.add_argument(
        "--set",
        metavar="NAME",
        help="将设备的蓝牙广播名称修改为指定值（设备将自动重启生效）",
    )
    parser.add_argument("--device", help="特定蓝牙设备的名称或 MAC 地址过滤条件")
    parser.add_argument(
        "--select", action="store_true", help="强制重新扫描并选择蓝牙设备"
    )
    args = parser.parse_args()

    if not args.get and not args.set:
        parser.error("请指定 --get（查看名称）或 --set NAME（修改名称）")

    # 1. Choose BLE Device
    device = await scan_and_select_device(args)
    if not device:
        return

    print(f"🔌 正在连接设备: {device.name} ({device.address}) ...")
    client = BleakClient(device.address)
    try:
        await client.connect()
    except (BleakError, OSError, asyncio.TimeoutError) as e:
        print(f"❌ 蓝牙连接失败: {e}")
        print("💡 请检查硬件是否通电；如果这是之前记住的设备，可用 --select 重新扫描选择。")
        return

    try:
        print("🎉 蓝牙连接成功！")

        if args.get:
            name = await get_device_name(client)
            if name:
                print(f"\n🏷️  当前蓝牙广播名称: {name}")
            else:
                print("\n❌ 未能读取设备名称。")

        if args.set:
            new_name = args.set.strip()
            if not new_name:
                print("❌ 新名称不能为空。")
                return

            # 先读取当前名称展示
            current_name = await get_device_name(client)
            if current_name:
                print(f"\n📋 当前名称: {current_name}")
            print(f"📝 新名称:   {new_name}")

            ans = await ainput(
                "\n❓ 确认修改设备名称？修改后设备将自动重启生效。 [y/N]: "
            )
            if ans.strip().lower() not in ("y", "yes"):
                print("❌ 操作已取消。")
                return

            print("💾 正在写入新名称...")
            success = await set_device_name(client, new_name)
            if success:
                print(f"🎉 改名成功！设备将在 3 秒内自动重启，新蓝牙名称: {new_name}")
                # 更新本地记住的设备名
                save_device(new_name, device.address)
            else:
                print("❌ 改名失败，请检查设备日志。")

    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 操作被用户手动中断。")
