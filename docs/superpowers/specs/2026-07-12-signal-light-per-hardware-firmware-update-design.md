# 信号灯:多硬件固件标识 + 按硬件拉取更新

- 日期:2026-07-12
- 分支基线:`wg`(信号灯固件与 App 更新检查均以 `wg` 分支为发布源)
- 状态:设计已确认,待写实现计划

## 背景与目标

信号灯设备目前只有一种硬件(ESP32-C3),固件通过 BLE 的 INFO 特征值
(`…00000005`)只上报裸版本号(如 `"1.2.0"`),App 端 `SignalLightFirmwareUpdateChecker`
把它直接当版本号解析,并从**固定 URL** 拉取更新:

- manifest:`https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/firmware/version.json`
- binary:`https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/firmware/signal-light.bin`

本次改造为**多硬件打基础**:

1. 固件把自己的**硬件 ID**(`esp32c3`)连同版本号一起上报。
2. App 依据设备上报的硬件 ID,把更新路径推导为
   `…/signal-light/{hardwareID}/firmware/…`,而不再写死单一路径。
3. manifest 显式点名要下载的 binary 文件(不可变 URL),取代被覆盖的可变 `signal-light.bin`。

非目标(本次不做):

- 真正接入第二种硬件(仅确保结构与协议可扩展)。
- 改动 BLE OTA 烧录流程本身(`SignalLightFirmwareUpdater`)。
- 改动 App 与信号灯的连接、灯效、校准等其它功能。

## 目录结构(发布源,`wg` 分支)

```
signal-light/esp32c3/                 ← 每种硬件自成一体
  ├─ esp32c3.ino                      ← 固件源码
  ├─ config.h
  └─ firmware/                        ← 已发布、可下载的版本化产物
       ├─ version.json                ← manifest
       └─ esp32c3_v1_2_1.bin          ← 按版本命名 → 不可变 URL
```

约定:

- 按**硬件 ID** 平铺 `signal-light/{hardwareID}/`,将来加 `esp32s3/` 等直接并列。
- 每种硬件目录下的 `firmware/` 存放发布产物;`{hardwareID}` 即设备上报的 ID,App
  路径零特判地拼出。
- **删除可变的 `signal-light.bin`**:manifest 的 `binary` 字段是要下载文件的唯一真相源。
  可变文件名正是当前代码注释记录的 jsDelivr 12h 边缘缓存陈旧的根源;按版本命名的
  bin 是不可变 URL,天然绕开该问题。

## 组件设计

### 1. 固件 — 硬件标识与 INFO 载荷

**`signal-light/esp32c3/config.h`**

- 在版本号旁新增:
  ```cpp
  const String HARDWARE_ID = "esp32c3";
  ```

**`signal-light/esp32c3/esp32c3.ino`**(setup 中设置 INFO 特征值处,约 313 行)

- INFO 特征值由裸 `FIRMWARE_VERSION` 改为**紧凑 JSON**(无空格,省 BLE 载荷):
  ```json
  {"hardware":"esp32c3","version":"1.2.0"}
  ```
- 用 Arduino `String` 拼接;`hardware` 取 `HARDWARE_ID`,`version` 取 `FIRMWARE_VERSION`。

### 2. Core — 设备信息模型

**`Sources/OpenIslandCore/SignalLightDeviceInfo.swift`**(新文件)

```swift
public struct SignalLightDeviceInfo: Codable, Sendable {
    public let hardware: String
    public let version: String
}
```

- 静态 `parse(_ raw: String) -> SignalLightDeviceInfo`:
  1. 先尝试 JSON 解码(`{"hardware":…,"version":…}`)→ 原样返回。
  2. 解码失败(旧固件上报裸版本号)→ 回退
     `SignalLightDeviceInfo(hardware: "esp32c3", version: <去除首尾空白的原串>)`。
- `SignalLightFirmwareVersion` 保持不变(仍负责 `major.minor.patch` 比较)。

### 3. App — 协调器暴露硬件 ID

**`Sources/OpenIslandApp/SignalLightCoordinator.swift`**

- 新增 `private(set) var hardwareID: String?`。
- INFO 回调分支(约 292 行)改用 `SignalLightDeviceInfo.parse(text)`,同时写入
  `firmwareVersion = info.version` 与 `hardwareID = info.hardware`。
- 断连清理(约 216 行)将 `firmwareVersion` 与 `hardwareID` 一并置 `nil`。

### 4. App — 更新检查器按硬件拼路径

**`Sources/OpenIslandApp/SignalLightFirmwareUpdateChecker.swift`**

- 移除写死的 `manifestURL` / `binaryURL` 常量,改为以 `hardware`(必要时加
  `binary` 文件名)为参数的**路径构造**;保留 raw-给-manifest、jsDelivr-给-binary
  的分工,以及超时、重试、cache-buster 逻辑不变:
  - base(概念上):`signal-light/{hardware}/firmware/`
  - manifest:`https://raw.githubusercontent.com/itdragons/open-vibe-island/wg/signal-light/{hardware}/firmware/version.json`
  - binary:`https://cdn.jsdelivr.net/gh/itdragons/open-vibe-island@wg/signal-light/{hardware}/firmware/{binary}`
- API 变更(硬件 ID 作为参数传入,贴合现有 `currentVersion:` 风格):
  - `checkForUpdates(currentVersion:)` → `checkForUpdates(hardware:currentVersion:)`。
    检查成功后**存下解析到的 manifest**(至少含 `binary` 文件名与 `hardware`),
    供后续下载复用同一路径与文件名。
  - `downloadLatestBinary()` 用已存下的 `hardware` + `binary` 文件名拼 URL。
  - `loadChangelog(hardware:)`;无设备连接、硬件未知时默认 `"esp32c3"`。
- manifest 解码模型 `SignalLightFirmwareManifest` 新增 `let binary: String?`;
  为兼容缺字段的旧 manifest,`nil` 时回退 `"signal-light.bin"`。

### 5. Manifest 文件

**`signal-light/esp32c3/firmware/version.json`**

```json
{
  "hardware": "esp32c3",
  "version": "1.2.1",
  "binary": "esp32c3_v1_2_1.bin",
  "notes": "…",
  "history": ["…"]
}
```

- 新增 `binary`:App 要下载的文件名(App 端必需依据,缺失才回退)。
- 新增 `hardware`:自描述用,App 不强制校验(路径已隐含硬件)。
- **版本一致性(实现时对齐)**:`FIRMWARE_VERSION`(config.h)、manifest `version`、
  `binary` 文件名三者必须指向同一版本。当前 manifest 写 `1.2.0` 但目录中已有
  `esp32c3_v1_2_1.bin`,实现时确认目标版本(预期 bump 到 `1.2.1`)并同步三处。

### 6. 调用点

**`Sources/OpenIslandApp/Views/SignalLightSettingsPane.swift`**

- 约 576 行:`checkForUpdates(hardware: model.signalLight.hardwareID, currentVersion: model.signalLight.firmwareVersion)`。
- 约 371 行:`loadChangelog(hardware: model.signalLight.hardwareID)`。

## 数据流

```
设备 INFO(JSON)
  {"hardware":"esp32c3","version":"1.2.0"}
        │
        ▼  SignalLightDeviceInfo.parse
  { hardware: "esp32c3", version: "1.2.0" }
        │
        ▼  SignalLightCoordinator
  firmwareVersion = "1.2.0" ; hardwareID = "esp32c3"
        │
        ▼  SignalLightSettingsPane 传入
  SignalLightFirmwareUpdateChecker.checkForUpdates(hardware:currentVersion:)
        │  拼 …/signal-light/esp32c3/firmware/version.json → 比较版本
        ▼
  updateAvailable → downloadLatestBinary()
        │  拼 …/signal-light/esp32c3/firmware/{manifest.binary}
        ▼
  本地临时 .bin → 交给既有 beginFirmwareUpdate(fileURL:) 烧录流程(不变)
```

## 向后兼容

- **旧固件(裸版本号 INFO)**:`parse` 回退 `hardware = "esp32c3"` → 命中重组后的
  同一路径,更新检查照常工作。
- **旧 manifest(无 `binary`)**:回退 `signal-light.bin`(尽管本次会删除该文件,
  回退分支保留作为防御)。
- **设备已连但硬件未知**:legacy 分支即已默认 `esp32c3`,故 `hardwareID` 在检查时
  一定有值。

## 错误处理

- 沿用现有:超时、`maxAttempts` 重试、404 立即失败、429/5xx 视为瞬时重试、
  `.failed` 状态提示。
- 逻辑不变,仅 URL 由固定改为按 `hardware` 拼接。

## 测试

- 单测 `SignalLightDeviceInfo.parse`:标准 JSON、旧裸版本号、含首尾空白、畸形串、
  缺字段。
- 单测更新检查器的 URL 拼接:给定 `hardware` 与 manifest `binary`,断言 manifest
  与 binary 两个 URL 正确(含 raw / jsDelivr 主机分工)。
- `swift build` + `swift test`。
- 手动:烧录新固件 → 连接 → 确认 App 版本行正确显示 → 「检查更新」命中
  `…/esp32c3/firmware/…` 路径。

## 范围外(实现与发布时的操作步骤,非代码)

- 发布产物必须提交并推送到远端 `wg` 分支的 `signal-light/esp32c3/firmware/`,
  App 才能拉到。
- 删除旧的顶层 `signal-light/firmware/`(在无任何引用后)。
- App 源码(`Sources/`)的改动遵循 `CLAUDE.md` 工作流(worktree + PR),实现计划阶段
  再定分支策略。
