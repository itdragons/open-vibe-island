#!/bin/bash
#
# build-firmware.sh — 编译 ESP32-C3 信号灯固件
#
# 用法:
#   build-firmware.sh <version>
#
# 示例:
#   build-firmware.sh 1.2.2
#
# 依赖: Arduino IDE 2.x（用其内置的 arduino-cli，无需单独安装）以及
# esp32:esp32 core（已通过 Arduino IDE 的开发板管理器安装）。
#
# 行为:
#   1. 在 esp32c3-<version>/ 目录下找到唯一的 .ino 文件并编译
#      （FQBN 与开发板选项固定为 esp32:esp32:esp32c3，需与既往构建保持一致）
#   2. 把编译产物中的 app 分区镜像（<sketch>.ino.bin，OTA 实际刷入的那个）
#      复制为 firmware/esp32c3-<version>.bin
#   3. 清理临时 build/ 目录，只留下最终的 .bin

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARDUINO_CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
FQBN="esp32:esp32:esp32c3:UploadSpeed=921600,CDCOnBoot=default,CPUFreq=160,FlashFreq=80,FlashMode=qio,FlashSize=4M,PartitionScheme=default,DebugLevel=none,EraseFlash=none,JTAGAdapter=default,ZigbeeMode=default"

usage() {
    cat <<EOF
用法: $(basename "$0") <version>

示例:
  $(basename "$0") 1.2.2   # 编译 esp32c3-1.2.2/ 下的 .ino，产出 firmware/esp32c3-1.2.2.bin
EOF
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 1
fi

VERSION="$1"
SKETCH_DIR="$SCRIPT_DIR/esp32c3-$VERSION"
FIRMWARE_DIR="$SCRIPT_DIR/firmware"
OUTPUT_BIN="$FIRMWARE_DIR/esp32c3-$VERSION.bin"

if [[ ! -d "$SKETCH_DIR" ]]; then
    echo "错误: 找不到目录 $SKETCH_DIR" >&2
    exit 1
fi

if [[ ! -x "$ARDUINO_CLI" ]]; then
    echo "错误: 找不到 arduino-cli（预期路径: $ARDUINO_CLI）" >&2
    echo "请确认已安装 Arduino IDE 2.x。" >&2
    exit 1
fi

# 目录下必须只有一个 .ino（Arduino 会把同目录下所有 .ino 拼接编译，
# 多个版本共存会导致 setup()/loop() 重复定义）
INO_COUNT=$(find "$SKETCH_DIR" -maxdepth 1 -name "*.ino" | wc -l | tr -d ' ')
if [[ "$INO_COUNT" -ne 1 ]]; then
    echo "错误: $SKETCH_DIR 下应有且只有一个 .ino 文件，实际找到 $INO_COUNT 个：" >&2
    find "$SKETCH_DIR" -maxdepth 1 -name "*.ino" >&2
    exit 1
fi
INO_FILE=$(find "$SKETCH_DIR" -maxdepth 1 -name "*.ino")

BUILD_DIR="$SKETCH_DIR/build"
echo ">>> 编译 $INO_FILE"
"$ARDUINO_CLI" compile --fqbn "$FQBN" --output-dir "$BUILD_DIR" "$INO_FILE"

APP_BIN=$(find "$BUILD_DIR" -maxdepth 1 -name "*.ino.bin")
if [[ -z "$APP_BIN" ]]; then
    echo "错误: 编译产物中没有找到 <sketch>.ino.bin" >&2
    exit 1
fi

mkdir -p "$FIRMWARE_DIR"
cp "$APP_BIN" "$OUTPUT_BIN"
rm -rf "$BUILD_DIR"

echo ">>> 完成: $OUTPUT_BIN"
echo "    大小: $(stat -f%z "$OUTPUT_BIN" 2>/dev/null || stat -c%s "$OUTPUT_BIN") 字节"
echo "    sha256: $(shasum -a 256 "$OUTPUT_BIN" | awk '{print $1}')"
echo ""
echo "接下来: 手动更新 firmware/version.json 的 version/binary/notes/history 字段。"
