#!/usr/bin/env python3
import asyncio
import os
import sys
import argparse
import time
import json
from bleak import BleakScanner, BleakClient
from bleak.exc import BleakError

# BLE UUIDs from config.h
SERVICE_UUID = "77697364-6f6d-6761-7264-656e00000001"
OTA_CONTROL_UUID = "77697364-6f6d-6761-7264-656e00000003"
OTA_DATA_UUID = "77697364-6f6d-6761-7264-656e00000004"
INFO_CHAR_UUID = "77697364-6f6d-6761-7264-656e00000005"

# Config file to store selected device details
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, ".selected_device")

# Global future to await notifications
control_notification_future = None
control_notifications = []

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
    global control_notification_future
    text = data.decode('utf-8').strip()
    control_notifications.append(text)
    if control_notification_future and not control_notification_future.done():
        control_notification_future.set_result(text)

async def wait_for_notification(expected_prefix=None, timeout=10):
    global control_notification_future, control_notifications

    start_time = time.time()
    while True:
        # 每轮先扫一遍积压队列：通知可能在两次 await 之间到达，
        # 只落进列表而没能唤醒当时的 future
        if expected_prefix:
            for text in control_notifications:
                if text.startswith(expected_prefix):
                    control_notifications.remove(text)
                    return text

        remaining = timeout - (time.time() - start_time)
        if remaining <= 0:
            break
        control_notification_future = asyncio.get_running_loop().create_future()
        try:
            text = await asyncio.wait_for(control_notification_future, timeout=remaining)
            if expected_prefix is None or text.startswith(expected_prefix):
                if text in control_notifications:
                    control_notifications.remove(text)
                return text
        except asyncio.TimeoutError:
            break

    raise TimeoutError(f"等待通知超时 (未收到以 '{expected_prefix}' 开头的通知)")

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
            # We need to discover the device to verify it or BleakClient needs a BLEDevice / address.
            # Directly returning a dummy Bleak discovered device or target matching address.
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
            choice = await ainput(f"请选择你要刷入固件的设备编号 (0-{len(named_devices)-1})，或输入 q 退出: ")
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
    parser = argparse.ArgumentParser(description="Open Island ESP32-C3 固件 OTA 刷写工具")
    parser.add_argument("--file", help="要刷入的固件 .bin 文件路径")
    parser.add_argument("--device", help="特定蓝牙设备的名称或 MAC 地址过滤条件")
    parser.add_argument("--select", action="store_true", help="强制重新扫描并选择蓝牙设备")
    parser.add_argument("--chunk-size", type=int, default=500, help="分片发送的字节大小 (默认 500，吃满 MTU 517)")
    parser.add_argument("--with-response", action="store_true",
                        help="回退到「写-带响应」逐片确认的稳妥模式（更慢）。默认用写-无响应，约快 6 倍")
    parser.add_argument("--sync-every", type=int, default=32,
                        help="写-无响应模式下每发送 N 片做一次带确认写，强制 CoreBluetooth 排空发送队列防丢包 (默认 32，设 0 关闭会丢包)")
    args = parser.parse_args()

    # 1. Resolve firmware file path
    firmware_path = args.file
    if not firmware_path:
        script_dir = os.path.dirname(os.path.realpath(__file__))
        firmware_path = os.path.join(script_dir, "firmware", "signal-light.bin")
        
    if not os.path.exists(firmware_path):
        print(f"❌ 找不到固件文件: {firmware_path}")
        print("请用 --file 参数指定正确的 .bin 文件路径。")
        return

    # Read binary file
    with open(firmware_path, "rb") as f:
        firmware_data = f.read()
    total_bytes = len(firmware_data)
    print(f"📦 已加载固件: {os.path.basename(firmware_path)} ({total_bytes} 字节)")

    # 2. Select BLE device
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
        
        # 3. Read current version
        try:
            version_data = await client.read_gatt_char(INFO_CHAR_UUID)
            current_version = version_data.decode('utf-8').strip()
            print(f"🏷️  当前设备固件版本: {current_version}")
        except Exception as e:
            print(f"⚠️  读取当前版本失败 (可能设备运行着旧版固件): {e}")

        # 4. Subscribe to control characteristic notifications
        print("🔔 正在订阅 OTA 状态反馈通知...")
        await client.start_notify(OTA_CONTROL_UUID, notification_handler)

        print("\n" + "="*40)
        print("⚠️  注意事项:")
        print("1. 刷写期间请保持电脑与硬件距离较近")
        print("2. 请勿断开板子电源，切勿强行中止或退出程序")
        print("3. 大约需要 1 到 2 分钟")
        print("="*40 + "\n")
        
        ans = await ainput("❓ 确认开始刷入新固件吗？ [y/N]: ")
        if ans.strip().lower() not in ('y', 'yes'):
            print("❌ 操作已取消。")
            return

        try:
            # 5. Send OTA_BEGIN
            print(f"🚀 发送启动指令 OTA_BEGIN:{total_bytes} ...")
            await client.write_gatt_char(OTA_CONTROL_UUID, f"OTA_BEGIN:{total_bytes}".encode('utf-8'), response=True)
            
            # Wait for "OTA_BEGIN ok"
            print("⏳ 等待设备就绪响应...")
            begin_resp = await wait_for_notification("OTA_BEGIN", timeout=10)
            print(f"📥 设备响应: {begin_resp}")
            if "failed" in begin_resp.lower() or "error" in begin_resp.lower():
                print(f"❌ 固件拒绝刷入: {begin_resp}")
                return

            # 6. Send Chunks
            use_no_response = not args.with_response
            if use_no_response:
                mode_desc = f"写-无响应，每 {args.sync_every} 片流控屏障" if args.sync_every > 0 else "写-无响应，无屏障"
            else:
                mode_desc = "写-带响应（每片等确认，回退模式）"
            print(f"📤 开始传送固件数据分片 (单次分片大小: {args.chunk_size} 字节 | 模式: {mode_desc})...")
            chunk_size = args.chunk_size
            offset = 0
            chunk_index = 0
            start_time = time.time()

            while offset < total_bytes:
                chunk = firmware_data[offset : offset + chunk_size]
                # 默认写-无响应，可流水线发送多片，靠周期性带确认写排空 CoreBluetooth 队列防丢包；
                # --with-response 退回逐片带确认写。带确认写兼作屏障：它等 ATT ack，会强制排空前面同特征的无响应写。
                if use_no_response:
                    chunk_index += 1
                    is_barrier = args.sync_every > 0 and chunk_index % args.sync_every == 0
                    await client.write_gatt_char(OTA_DATA_UUID, chunk, response=is_barrier)
                else:
                    await client.write_gatt_char(OTA_DATA_UUID, chunk, response=True)
                offset += len(chunk)
                
                # Check if there were any failure notifications pushed
                if control_notifications:
                    last_msg = control_notifications[-1]
                    if "failed" in last_msg.lower():
                        print(f"\n❌ 传输中断，板子上报错误: {last_msg}")
                        return
                
                # Render progress bar
                percent = int(100 * offset / total_bytes)
                bar_len = 30
                filled_len = int(bar_len * offset / total_bytes)
                bar = '=' * filled_len + '-' * (bar_len - filled_len)
                elapsed = time.time() - start_time
                speed = (offset / 1024) / elapsed if elapsed > 0 else 0
                sys.stdout.write(f"\r进度: [{bar}] {percent}% ({offset}/{total_bytes} 字节) | 速度: {speed:.1f} KB/s")
                sys.stdout.flush()

            total_elapsed = time.time() - start_time
            avg_speed = (total_bytes / 1024) / total_elapsed if total_elapsed > 0 else 0
            print(f"\n✅ 数据分片传送完毕！耗时 {total_elapsed:.1f} 秒 | 平均速度 {avg_speed:.1f} KB/s ({total_bytes} 字节)")
            print("正在校验固件并提交更新...")
            
            # 7. Send OTA_END
            await client.write_gatt_char(OTA_CONTROL_UUID, b"OTA_END", response=True)
            
            # Wait for "OTA_END ok, restarting"
            end_resp = await wait_for_notification("OTA_END", timeout=15)
            print(f"📥 设备响应: {end_resp}")
            
            if "restarting" in end_resp.lower() or "ok" in end_resp.lower():
                print("\n🎉🎉 固件刷写成功！信号灯设备将在 3 秒内自动重启生效。")
            else:
                print(f"\n❌ 固件检验失败: {end_resp}")

        except Exception as e:
            print(f"\n❌ 刷写过程中发生意外错误: {e}")
            print("⚠️  尝试发送中止指令 OTA_ABORT...")
            try:
                await client.write_gatt_char(OTA_CONTROL_UUID, b"OTA_ABORT", response=True)
                print("👍 已中止当前 OTA 会话。")
            except Exception as abort_err:
                print(f"⚠️  未能成功发送中止指令: {abort_err}")
        finally:
            # Clean up notifications
            try:
                await client.stop_notify(OTA_CONTROL_UUID)
            except:
                pass
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
