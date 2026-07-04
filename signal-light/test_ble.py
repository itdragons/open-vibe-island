import asyncio
from bleak import BleakScanner, BleakClient

# led.ino 里定义的 UUID 
SERVICE_UUID = "77697364-6f6d-6761-7264-656e00000001"
CMD_CHAR_UUID = "77697364-6f6d-6761-7264-656e00000002"

COMMAND_HELP = """
可用指令 (发到 COMMAND characteristic):
  模式 (任选其一别名):
    GREEN_BLINK / GREENBLINK / BLINK / GBLINK   绿灯慢闪
    THINKING / THINK / ANALYSIS                  思考中 (红黄绿轮转)
    WORKING / AI / GENERATING / GENERATE         生成中 (全灯呼吸)
    BUSY / COMMAND / EXECUTING                   执行中 (黄灯闪烁)
    SUCCESS / OK / DONE                          成功 (绿灯常亮)
    ERROR / FAILED / FAIL                        出错 (红灯快闪)
    ALARM / BLOCKED / CRITICAL                   告警 (红黄交替)
    OFF / CLOSE / IDLE                           关闭所有灯
  手动控制单色:
    R<0-255> / Y<0-255> / G<0-255> / A<0-255>    例如 R0 (红灯全亮), G255 (绿灯全灭)
    也支持 R0/R1 简写为全亮/全灭
  自定义效果:
    EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>
      TYPE   = SOLID | BLINK | CYCLE | BREATHE
      COLORS = R/Y/G 任意组合，例如 RYG
      例如: EFFECT:CYCLE:RYG:200
  其他:
    BLE                                          让板子在串口打印蓝牙设备名
""".strip()


async def main():
    print("正在扫描专属信号灯设备，请稍候 (大约 5 秒)...")
    # 传入 service_uuids 参数，底层会自动过滤掉非相关设备（如鼠标、耳机）
    devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])

    # 过滤掉没有名字的设备，让列表看起来更清爽
    named_devices = [d for d in devices if d.name]

    if not named_devices:
        print("❌ 附近没有找到任何发出广播的信号灯设备，请确保板子已通电。")
        return

    print("\n扫描到以下设备:")
    for i, d in enumerate(named_devices):
        print(f"[{i}] {d.name} ({d.address})")

    print("-" * 40)

    # 等待用户选择设备
    selected_device = None
    while True:
        try:
            choice = input(f"请选择你要连接的设备编号 (0-{len(named_devices)-1})，或输入 q 退出: ").strip()
            if choice.lower() == 'q':
                return
            index = int(choice)
            if 0 <= index < len(named_devices):
                selected_device = named_devices[index]
                break
            else:
                print("❌ 编号超出范围，请重新输入。")
        except ValueError:
            print("❌ 无效输入，请输入对应的数字。")

    print(f"\n正在尝试连接设备: {selected_device.name} ...")

    try:
        async with BleakClient(selected_device) as client:
            print("✅ 蓝牙连接成功！你可以开始发指令了。")
            print("-" * 40)
            print(COMMAND_HELP)
            print("-" * 40)

            while True:
                cmd = input("请输入指令 (输入 help 查看指令列表，q 退出): ").strip()
                if cmd.lower() == 'q':
                    break
                if not cmd:
                    continue
                if cmd.lower() == 'help':
                    print(COMMAND_HELP)
                    continue

                try:
                    # BLE 传输需要将字符串转换为字节串
                    await client.write_gatt_char(CMD_CHAR_UUID, cmd.encode('utf-8'))
                    print(f"🔼 指令 '{cmd}' 发送成功！看下板子的灯。")
                except Exception as e:
                    print(f"❌ 发送失败: {e}")
    except Exception as e:
        print(f"❌ 连接失败或意外断开: {e}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n已退出调试。")
