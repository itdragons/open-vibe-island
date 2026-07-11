#!/bin/bash
#
# bridge-ctl.sh — Open Island 信号灯管理入口
#
# 用法:
#   bridge-ctl.sh [命令] [选项]
#
# 命令:
#   (无)            启动桥接服务器（默认）
#   --stop          停止运行中的桥接服务器
#   --status        查看桥接服务器运行状态
#   --calibrate     启动接线校准向导
#   --ota [--file PATH]  无线固件升级
#   --device-name   查看当前设备蓝牙名称
#   --set-name NAME 修改设备蓝牙名称
#   --help          显示此帮助信息
#
# 选项:
#   --force         强制停止已有实例后重新启动

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PID_FILE="$WORKSPACE_ROOT/bridge.pid"
LOG_FILE="$WORKSPACE_ROOT/bridge.log"
BRIDGE_SCRIPT="$WORKSPACE_ROOT/signal-light/signal-light-bridge.py"
CALIBRATE_SCRIPT="$WORKSPACE_ROOT/signal-light/calibrate.py"
OTA_SCRIPT="$WORKSPACE_ROOT/signal-light/flash_ota.py"
DEVICE_NAME_SCRIPT="$WORKSPACE_ROOT/signal-light/device_name.py"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
用法: $(basename "$0") [命令] [选项]

命令:
  (无)                  启动桥接服务器（后台运行）
  --stop                停止运行中的桥接服务器
  --status              查看桥接服务器运行状态
  --calibrate           启动接线校准向导（交互式，前台运行）
  --ota [--file PATH]   无线 OTA 固件升级（交互式，前台运行）
  --device-name         查看当前设备蓝牙广播名称
  --set-name NAME       修改设备蓝牙广播名称（修改后设备自动重启生效）

选项:
  --force               强制停止已有实例后重新启动桥接服务器
  --help                显示此帮助信息

示例:
  $(basename "$0")                    # 启动桥接服务
  $(basename "$0") --stop             # 停止桥接服务
  $(basename "$0") --status           # 查看运行状态
  $(basename "$0") --force            # 强制重启
  $(basename "$0") --calibrate        # 引脚接线校准
  $(basename "$0") --ota              # OTA 升级（默认固件）
  $(basename "$0") --ota --file fw.bin  # OTA 升级（指定固件）
  $(basename "$0") --device-name      # 查看设备名
  $(basename "$0") --set-name "MyLight" # 改名
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
FORCE=false
STOP=false
STATUS=false
CALIBRATE=false
OTA=false
DEVICE_NAME=false
SET_NAME=""
OTA_FILE=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --stop)
            STOP=true
            shift
            ;;
        --status)
            STATUS=true
            shift
            ;;
        --calibrate)
            CALIBRATE=true
            shift
            ;;
        --ota)
            OTA=true
            shift
            ;;
        --file)
            OTA_FILE="$2"
            shift 2
            ;;
        --device-name)
            DEVICE_NAME=true
            shift
            ;;
        --set-name)
            SET_NAME="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect Python interpreter
# ---------------------------------------------------------------------------
detect_python() {
    if [ -f "$WORKSPACE_ROOT/.venv/bin/python" ]; then
        echo "$WORKSPACE_ROOT/.venv/bin/python"
    elif [ -f "$WORKSPACE_ROOT/venv/bin/python" ]; then
        echo "$WORKSPACE_ROOT/venv/bin/python"
    elif command -v uv &>/dev/null && [ -f "$WORKSPACE_ROOT/uv.lock" ]; then
        # uv run python3 — must be invoked as separate words, not quoted as one
        echo "uv run python3"
    elif command -v poetry &>/dev/null && [ -f "$WORKSPACE_ROOT/poetry.lock" ]; then
        echo "poetry run python3"
    else
        echo "python3"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_running() {
    local pid=$1
    if [ -n "$pid" ]; then
        kill -0 "$pid" 2>/dev/null
    else
        return 1
    fi
}

stop_bridge() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if [ -n "$pid" ] && is_running "$pid"; then
            echo "Stopping bridge process (PID $pid)..."
            kill "$pid" 2>/dev/null

            # Wait up to 5 seconds for process to exit
            local count=0
            while is_running "$pid" && [ $count -lt 5 ]; do
                sleep 1
                ((count++))
            done

            # Force kill if still running
            if is_running "$pid"; then
                echo "Process did not exit cleanly. Force killing (PID $pid)..."
                kill -9 "$pid" 2>/dev/null
            fi
            echo "Bridge process stopped."
        else
            echo "PID file exists but process (PID $pid) is not running."
        fi
        rm -f "$PID_FILE"
    else
        echo "No running bridge process found (bridge.pid not found)."
    fi
}

# Run a Python script in the foreground with correct interpreter.
# Usage: run_python_foreground <script> [args...]
run_python_foreground() {
    local script="$1"
    shift

    if [ ! -f "$script" ]; then
        echo "❌ 找不到脚本: $script"
        exit 1
    fi

    local python_bin
    python_bin="$(detect_python)"
    cd "$WORKSPACE_ROOT" || exit 1
    # NOTE: python_bin is intentionally unquoted to allow word splitting
    # for multi-word commands like "uv run python3"
    exec $python_bin "$script" "$@"
}

# ---------------------------------------------------------------------------
# Command: --stop
# ---------------------------------------------------------------------------
if [ "$STOP" = true ]; then
    stop_bridge
    exit 0
fi

# ---------------------------------------------------------------------------
# Command: --status
# ---------------------------------------------------------------------------
if [ "$STATUS" = true ]; then
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if [ -n "$pid" ] && is_running "$pid"; then
            echo "✅ Bridge is running (PID $pid)."
            echo "📄 Log file: $LOG_FILE"
            if [ -f "$LOG_FILE" ]; then
                echo ""
                echo "--- 最近 10 行日志 ---"
                tail -n 10 "$LOG_FILE"
            fi
        else
            echo "⚠️  PID file exists (PID $pid) but process is not running."
            rm -f "$PID_FILE"
        fi
    else
        echo "❌ Bridge is not running (bridge.pid not found)."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Guard: BLE-dependent commands cannot run while bridge holds the connection.
# macOS CoreBluetooth only allows one process per BLE device.
# ---------------------------------------------------------------------------
require_bridge_stopped() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if [ -n "$pid" ] && is_running "$pid"; then
            echo "❌ 桥接服务正在运行 (PID $pid)，蓝牙连接被占用。"
            echo "请先停止桥接服务再执行此操作："
            echo ""
            echo "  bash signal-light/bridge-ctl.sh --stop"
            echo ""
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Command: --calibrate
# ---------------------------------------------------------------------------
if [ "$CALIBRATE" = true ]; then
    require_bridge_stopped
    run_python_foreground "$CALIBRATE_SCRIPT" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

# ---------------------------------------------------------------------------
# Command: --ota
# ---------------------------------------------------------------------------
if [ "$OTA" = true ]; then
    require_bridge_stopped
    ota_args=()
    if [ -n "$OTA_FILE" ]; then
        ota_args+=(--file "$OTA_FILE")
    fi
    run_python_foreground "$OTA_SCRIPT" "${ota_args[@]+"${ota_args[@]}"}" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

# ---------------------------------------------------------------------------
# Command: --device-name
# ---------------------------------------------------------------------------
if [ "$DEVICE_NAME" = true ]; then
    require_bridge_stopped
    run_python_foreground "$DEVICE_NAME_SCRIPT" --get "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

# ---------------------------------------------------------------------------
# Command: --set-name NAME
# ---------------------------------------------------------------------------
if [ -n "$SET_NAME" ]; then
    require_bridge_stopped
    run_python_foreground "$DEVICE_NAME_SCRIPT" --set "$SET_NAME" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
fi

# ---------------------------------------------------------------------------
# Default: Start bridge server
# ---------------------------------------------------------------------------

# Check if already running
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if [ -n "$pid" ] && is_running "$pid"; then
        if [ "$FORCE" = true ]; then
            echo "Force option detected. Stopping running instance first..."
            stop_bridge
        else
            echo "Bridge is already running with PID $pid."
            echo "Use --force to stop it and restart."
            exit 1
        fi
    else
        # Process not running, clean stale PID file
        rm -f "$PID_FILE"
    fi
fi

# Clear previous log
echo "Clearing log file: $LOG_FILE"
> "$LOG_FILE"

PYTHON_BIN="$(detect_python)"

# NOTE: PYTHON_BIN is intentionally unquoted to allow word splitting
# for multi-word commands like "uv run python3".
cd "$WORKSPACE_ROOT" || exit 1

# Print Claude Code hooks config and light legend to the user's terminal
# before sending the bridge to the background.
$PYTHON_BIN "$BRIDGE_SCRIPT" --print-instructions

# If no device has been selected yet, run interactive scan in foreground
# so the user can choose a BLE device before we go to background.
# (nohup disconnects stdin, making interactive selection impossible.)
DEVICE_CONFIG="$SCRIPT_DIR/.selected_device"
if [ ! -f "$DEVICE_CONFIG" ]; then
    echo "🔍 首次启动：需要先选择蓝牙设备..."
    echo ""
    $PYTHON_BIN "$BRIDGE_SCRIPT" --scan-and-save
    echo ""
fi

echo "Starting bridge server using: $PYTHON_BIN ..."
# PYTHONUNBUFFERED=1 disables block buffering so output appears in the
# log file immediately instead of being held in memory.
PYTHONUNBUFFERED=1 nohup $PYTHON_BIN "$BRIDGE_SCRIPT" > "$LOG_FILE" 2>&1 &
NEW_PID=$!

# Verify the process actually started
sleep 1
if ! is_running "$NEW_PID"; then
    echo "❌ Bridge failed to start. Check $LOG_FILE for details."
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "--- 日志输出 ---"
        cat "$LOG_FILE"
    fi
    rm -f "$PID_FILE"
    exit 1
fi

# Save PID
echo "$NEW_PID" > "$PID_FILE"
echo "Bridge started successfully with PID: $NEW_PID"
echo "Logs are being written to: $LOG_FILE"
