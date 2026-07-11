#!/usr/bin/env python3
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

# ESP32-C3 Safe GPIO Pins (0 保留给物理开关机按键，固件已拒绝分配/测试该引脚)
CANDIDATE_PINS = [1, 3, 4, 5, 6, 7, 10, 20, 21]

# Global state to capture notifications
config_future = None
last_config = None

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

def notification_handler(sender, data):
    global config_future, last_config
    text = data.decode('utf-8').strip()
    if text.startswith("CONFIG:"):
        # Parse CONFIG:R=5,Y=6,G=7,NAME=WG-A1B2
        config = {}
        for item in text[7:].split(","):
            parts = item.split("=", 1)
            if len(parts) == 2:
                config[parts[0]] = parts[1]
        last_config = config
        if config_future and not config_future.done():
            config_future.set_result(config)

async def ainput(prompt: str = "") -> str:
    print(prompt, end="", flush=True)
    return await asyncio.to_thread(sys.stdin.readline)

async def scan_and_select_device(args):
    # 1. Option to filter device via CLI arg
    if args.device:
        print(f"🔍 [BLE] 正在扫描信号灯 (过滤参数: {args.device}) ...")
        devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])
        named_devices = [d for d in devices if d.name]
        
        target = None
        for d in named_devices:
            if args.device.lower() in d.name.lower() or args.device.lower() in d.address.lower():
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
            choice = await ainput(f"请选择你要校准的设备编号 (0-{len(named_devices)-1})，或输入 q 退出: ")
            choice = choice.strip()
            if choice.lower() == 'q':
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

async def main():
    global config_future, last_config
    
    parser = argparse.ArgumentParser(description="Open Island 红绿灯引脚接线校准工具")
    parser.add_argument("--device", help="特定蓝牙设备的名称或 MAC 地址过滤条件")
    parser.add_argument("--select", action="store_true", help="强制重新扫描并选择蓝牙设备")
    args = parser.parse_args()

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
        
        # 2. Subscribe to NVS config reports via notifications
        await client.start_notify(OTA_CONTROL_UUID, notification_handler)
        
        # 3. Stop any current mode to avoid interference with PINTEST
        print("🤫 正在关闭当前活跃的灯光效果...")
        await client.write_gatt_char(CMD_CHAR_UUID, b"OFF", response=True)
        await asyncio.sleep(0.5)

        # 4. Request current pin mapping
        print("📥 正在读取设备当前的引脚配置...")
        config_future = asyncio.get_running_loop().create_future()
        await client.write_gatt_char(CMD_CHAR_UUID, b"GETCONFIG", response=True)
        
        try:
            config = await asyncio.wait_for(config_future, timeout=5.0)
            print("\n📊 当前引脚映射配置 (从板子 flash 读出):")
            print(f"  🔴 红灯 GPIO: {config.get('R', '未知')}")
            print(f"  🟡 黄灯 GPIO: {config.get('Y', '未知')}")
            print(f"  🟢 绿灯 GPIO: {config.get('G', '未知')}")
            print(f"  🏷️  蓝牙名称: {config.get('NAME', '未知')}")
        except asyncio.TimeoutError:
            print("⚠️  读取当前配置超时，板子可能没有返回配置通知。")
            
        print("\n" + "="*50)
        print("💡 校准向导说明：")
        print("本脚本将逐个通电测试 ESP32-C3 的 GPIO 引脚。")
        print("当有灯亮起时，请输入对应的颜色，脚本会自动记录映射并保存到板子中。")
        print("="*50 + "\n")
        
        ans = await ainput("❓ 是否开始引脚接线校准？ [Y/n]: ")
        if ans.strip().lower() in ('n', 'no'):
            print("❌ 操作已取消。")
            return

        mapping = {"R": None, "Y": None, "G": None}
        
        # 5. Loop through candidates
        for pin in CANDIDATE_PINS:
            # Check if all color pins are resolved
            if all(v is not None for v in mapping.values()):
                break
                
            unresolved = [k for k, v in mapping.items() if v is None]
            print(f"\n--- 💡 正在测试 GPIO 引脚: {pin} ---")
            print(f"目前待校准的颜色: {unresolved}")
            
            # Send test pin ON command
            await client.write_gatt_char(CMD_CHAR_UUID, f"PINTEST:{pin}:1".encode('utf-8'), response=True)
            print(f"⚡️ GPIO {pin} 已通电亮起，请观察硬件。")
            
            # Prompt user observation
            while True:
                obs = await ainput("👉 板子上的灯亮了吗？如果是，请输入对应颜色 (r:红 / y:黄 / g:绿 / n:没亮，回车跳过): ")
                obs = obs.strip().lower()
                
                if not obs or obs == 'n':
                    break
                elif obs == 'r':
                    if mapping["R"] is None:
                        mapping["R"] = pin
                        print(f"✅ 记录：🔴 红灯 = GPIO {pin}")
                    else:
                        print(f"⚠️ 红灯已经分配给了 GPIO {mapping['R']}，不可重复分配。")
                    break
                elif obs == 'y':
                    if mapping["Y"] is None:
                        mapping["Y"] = pin
                        print(f"✅ 记录：🟡 黄灯 = GPIO {pin}")
                    else:
                        print(f"⚠️ 黄灯已经分配给了 GPIO {mapping['Y']}，不可重复分配。")
                    break
                elif obs == 'g':
                    if mapping["G"] is None:
                        mapping["G"] = pin
                        print(f"✅ 记录：🟢 绿灯 = GPIO {pin}")
                    else:
                        print(f"⚠️ 绿灯已经分配给了 GPIO {mapping['G']}，不可重复分配。")
                    break
                else:
                    print("❌ 无效选项，请输入 r, y, g, n 或直接回车跳过。")
            
            # Send test pin OFF command
            await client.write_gatt_char(CMD_CHAR_UUID, f"PINTEST:{pin}:0".encode('utf-8'), response=True)

        # 6. Save results
        if all(v is not None for v in mapping.values()):
            print("\n" + "="*40)
            print("🎉 校准收集完成！新映射规划如下:")
            print(f"  🔴 红灯 GPIO: {mapping['R']}")
            print(f"  🟡 黄灯 GPIO: {mapping['Y']}")
            print(f"  🟢 绿灯 GPIO: {mapping['G']}")
            print("="*40 + "\n")
            
            save_ans = await ainput("❓ 确定要将新的引脚映射保存到板子的闪存 (NVS) 中吗？ [y/N]: ")
            if save_ans.strip().lower() in ('y', 'yes'):
                print("💾 正在向板子写入配置...")
                await client.write_gatt_char(CMD_CHAR_UUID, f"SETPIN:R:{mapping['R']}".encode('utf-8'), response=True)
                await asyncio.sleep(0.3)
                await client.write_gatt_char(CMD_CHAR_UUID, f"SETPIN:Y:{mapping['Y']}".encode('utf-8'), response=True)
                await asyncio.sleep(0.3)
                await client.write_gatt_char(CMD_CHAR_UUID, f"SETPIN:G:{mapping['G']}".encode('utf-8'), response=True)
                await asyncio.sleep(0.3)
                print("🎉 保存成功！引脚配置已在板子固件中永久生效。")
            else:
                print("❌ 未保存配置，直接退出。")
        else:
            print("\n⚠️  未能收集全红、黄、绿三色灯的引脚映射，校准失败退出。")
            
        # Stop notify on disconnect
        try:
            await client.stop_notify(OTA_CONTROL_UUID)
        except:
            pass

        # Turn off everything
        await client.write_gatt_char(CMD_CHAR_UUID, b"OFF", response=True)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 校准程序被用户手动中断。")
