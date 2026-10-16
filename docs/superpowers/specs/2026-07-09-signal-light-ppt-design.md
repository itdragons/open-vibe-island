# Claude 红绿灯智造局 — PPT 大纲设计

**日期**：2026-07-09  
**活动**：2026-07-10 研发全员趣味实操活动  
**受众**：研发全员（有技术背景，但不了解硬件和本项目内部实现）  
**目标**：培训小白完成 ESP32-C3 + 红绿灯模块的焊接、烧录、配对全流程  
**结构**：线性数据流叙事（方案 A）——每节按数据/操作顺序推进

---

## Section 1：成品展示（4 页）

### Slide 1 — 封面
- 标题：Claude 红绿灯智造局
- 副标题：把 AI 的状态，焊成看得见的反馈
- 活动时间 / 地点

### Slide 2 — 这是什么
- 一句话：一个物理信号灯，实时显示你的 Claude Code 在干什么
- 配图：实物照片 + Open Island App 信号灯设置界面截图并排

### Slide 3 — 灯光状态一览

| 状态 | 触发条件 | 灯光效果 |
|------|---------|---------|
| 等待审批 | Claude 请求执行危险操作 | 红黄交替呼吸（1200ms）|
| 等待回答 | Claude 问了你一个问题 | 黄绿交替呼吸（1200ms）|
| 运行中 | 工具调用执行中 | 黄灯快速闪烁（300ms）|
| 空闲 | 无活跃会话 | 绿灯缓慢呼吸（2000ms）|
| 三色呼吸 | 未连接蓝牙时 | 红黄绿同步呼吸，等待配对 |

### Slide 4 — 其他已实现功能
- 自定义效果（SOLID / BLINK / CYCLE / BREATHE，可指定颜色和速度）
- 亮度调节（0–100%）
- 接线校准向导（逐引脚点亮验证，无需串口工具）
- 空中升级固件（BLE OTA，配对后不再需要插线）
- 断连后三色呼吸提示，重连后自动恢复效果

---

## Section 2：工作原理（9 页）

### Slide 5 — 全链路一图

```
Claude Code
   │  Hook 触发（JSON 事件写入 stdin）
   ▼
OpenIslandHooks（原生可执行文件，内置于 App bundle）
   │  Unix domain socket（NDJSON，每行一条消息）
   ▼
Open Island App（macOS 菜单栏 App）
   │  BLE GATT（UTF-8 文本指令，withResponse 写入）
   ▼
ESP32-C3 固件
   │  PWM 输出（反相逻辑）
   ▼
红绿灯模块（物理 LED）
```

### Slide 6 — 第 1 跳：Claude Code Hook

- Claude Code 在关键事件节点会调用外部命令（Hook），把上下文以 JSON 写入进程的 stdin
- 支持的事件：会话开始、工具调用前/后、会话结束、等待用户输入等
- JSON payload 包含：session_id、事件类型、工具名称、执行结果等
- 配置位置：`~/.claude/settings.json` 的 `hooks` 字段
- **Hook 安装器自动写入**：App 设置里点一次"安装 Hook"即可，无需手动编辑配置

### Slide 7 — 第 2 跳：Unix Socket IPC

- **OpenIslandHooks 是一个原生可执行文件**，内置在 App bundle 的 `Contents/Helpers/` 目录，随 App 一起分发，无需单独安装
- 调用方式：Claude Code 像调用 `git`、`curl` 一样直接 exec 它
- 读取 stdin 的 JSON → 通过 Unix domain socket 发送给 App（NDJSON 格式）
- Socket 路径：`~/Library/Application Support/OpenIsland/bridge.sock`
- 消息外层统一包在 `BridgeEnvelope` 里，有 4 种类型：

| 类型 | 方向 | 用途 |
|------|------|------|
| `hello` | App → Hooks | 握手，告知协议版本 |
| `command` | Hooks → App | 上报 Hook 事件 |
| `response` | App → Hooks | 回包（含审批决策） |
| `event` | App → Hooks | App 主动推送状态 |

- **审批门控是同步阻塞的**：PreToolUse 时 Hooks 阻塞等待 App 回包，收到决策后才写回 stdout 给 Claude Code
- **失败开放原则**：App 不在线时 Hooks 超时静默退出，Claude Code 不受影响，照常运行

### Slide 8 — 第 3 跳：App 内状态机

- BridgeServer 接收消息 → 解析为 AgentEvent（枚举）
- `SessionState.apply()` 是唯一的状态变更入口（纯 Reducer）
- 多个并发 session 按优先级折叠为 4 个 Bucket：

```
needsApproval  >  needsAnswer  >  running  >  idle
  (最高优先级)                              (最低优先级)
```

- Bucket 变化 → SignalLightCoordinator 推送新灯光效果

### Slide 9 — 第 4 跳：BLE 指令下发

- App 使用 macOS CoreBluetooth 连接 ESP32-C3 的 BLE 服务
- 配对一次后自动记住设备，App 启动时自动重连
- **指令是 UTF-8 纯文本**，写入 Command Characteristic，类型为 `withResponse`（有 ACK 确认）
- 示例：`EFFECT:BLINK:Y:300`（黄灯，闪烁，300ms 间隔）

**GATT 结构（4 个 Characteristic，挂在同一 Service 下）：**

| Characteristic | 方向 | 用途 |
|---|---|---|
| Command（`...0002`） | App → ESP32 | 灯光效果和控制指令（纯文本） |
| OTA Control（`...0003`） | 双向 + Notify | OTA 握手与状态上报 |
| OTA Data（`...0004`） | App → ESP32 | 固件数据分片（二进制） |
| Info（`...0005`） | ESP32 → App | 固件版本号（只读） |

Service UUID 是 `"wisdomgarden"` 的 ASCII 十六进制编码：`77697364-6f6d-6761-7264-656e00000001`

### Slide 10 — 第 5 跳：固件指令处理与渲染

- BLE 写入回调收到文本 → `handleCommand()` 按前缀分发到对应处理函数
- `loop()` 主循环每帧调用 `updateLights()` 渲染当前模式动画
- 引脚分配和蓝牙名称持久化到 NVS（非易失存储），断电不丢失
- **反相逻辑**：PWM 值 0 = 全亮（0V），PWM 值 255 = 全灭（3.3V）

### Slide 11 — 零部件认识

| 零件 | 说明 |
|------|------|
| ESP32-C3 SuperMini | 主控芯片，BLE 5.0，USB CDC 直连烧录，13 个可用 GPIO |
| 红绿灯模块 | 共阳极 3 路 LED，默认接线：红→GPIO7，黄→GPIO6，绿→GPIO5 |
| 杜邦线（公对母） | 模块与开发板之间的连接线，4 根 |
| Type-C 数据线 | 初次烧录固件用（注意：必须是数据线，非纯充电线）|

### Slide 12 — 共阳极原理 + 为什么接 3.3V

**共阳极接法：**

```
3.3V ──┬── 红灯阳极(+)        红灯阴极(-) ── GPIO7
       ├── 黄灯阳极(+)        黄灯阴极(-) ── GPIO6
       └── 绿灯阳极(+)        绿灯阴极(-) ── GPIO5
```

三个 LED 正极接在一起连到 3.3V，负极各自由 GPIO 控制。

| GPIO 输出 | 两端电压差 | 灯 |
|-----------|-----------|-----|
| 低电平 0V | 3.3 − 0 = 3.3V | **亮** |
| 高电平 3.3V | 3.3 − 3.3 = 0V | **灭** |

→ 固件里 `LED_ON = 0`、`LED_OFF = 255` 由此而来

**为什么不能接 5V：**

| VCC | 关灯时 GPIO = 3.3V | 实际压差 | 结果 |
|-----|-------------------|---------|------|
| **5V** | 5 − 3.3 = 1.7V | 超过导通阈值 | 灭不掉，有残影 ✗ |
| **3.3V** | 3.3 − 3.3 = 0V | 零电位差 | 完全熄灭 ✓ |

结论：**共阳极 + ESP32-C3，VCC 必须接 3.3V**。

### Slide 13 — 完整指令速查表

```
# 内置状态模式
WORKING / BUSY / THINKING / SUCCESS / ERROR / ALARM / GREEN_BLINK / OFF

# 自定义效果
EFFECT:<SOLID|BLINK|CYCLE|BREATHE>:<R|Y|G|RYG|...>:<间隔ms>
示例：EFFECT:CYCLE:RYG:200   → 红黄绿依次轮流，每色 200ms

# 配置指令
BRIGHTNESS:75       → 亮度 75%
SETPIN:R:10         → 红灯改到 GPIO10
SETNAME:team-A      → 改蓝牙名称（重启生效）
GETCONFIG           → 查询当前引脚和名称
PINTEST:5:1         → 点亮 GPIO5（接线校准用）

# OTA 固件升级
OTA_BEGIN:<字节数> / OTA_END / OTA_ABORT / OTA_STATUS
```

---

## Section 3：制作教程（8 页）

### Slide 14 — 今天要完成的 7 个步骤
1. USB 烧录初始固件
2. 红绿灯模块拆改
3. 焊接 4 根杜邦线
4. 连接 ESP32，配对 App，改灯效验证
5. 接线校准（如有颜色错误）
6. 验收
7. （后续）OTA 升级固件

### Slide 15 — 安全须知
- 烙铁头温度 300–350°C，不用时放回烙铁架
- 焊接时避免直视焊点烟雾
- 海绵需湿润，用于清洁烙铁头
- 烫伤膏备在桌上，有问题举手

### Slide 16 — 步骤 1：USB 烧录初始固件
- 工具：Arduino IDE + Type-C 数据线
- 板型选择：`ESP32C3 Dev Module`
- 选择对应串口，点击上传
- 上传完成后 ESP32 自动重启，开始 BLE 广播（三色呼吸灯亮起 = 成功）
- **只需烧录一次**，后续升级走 App OTA

### Slide 17 — 步骤 2：红绿灯模块拆改
- 取出纽扣电池（断开模块独立电源，防止两路电流冲突）
- 去掉原控制芯片（热风枪加热后取下，或刀片切断芯片到 LED 之间的走线）
- 目的：让 LED 阴极焊盘完全暴露，由 ESP32 GPIO 直接接管控制

### Slide 18 — 步骤 3：焊接 4 根杜邦线

接线对照（4 个焊点）：

| 红绿灯板焊盘 | ESP32-C3 引脚 |
|-------------|--------------|
| VCC | 3.3V |
| R（红灯信号） | GPIO 7 |
| Y（黄灯信号） | GPIO 6 |
| G（绿灯信号） | GPIO 5 |

- 焊点目标：圆润光亮，不虚焊、不连桥
- 配实物接线照片

### Slide 19 — 步骤 4：连接测试

- Type-C 上电，ESP32 开始 BLE 广播
- 打开 Open Island App → 设置 → 信号灯 → 扫描设备
- 选择设备名（默认 `huichengcheng`）→ 连接成功
- **验证方式**：修改 App 里"空闲"状态的灯效（如改成红灯常亮），观察三色灯是否响应、颜色是否对应正确引脚

### Slide 20 — 步骤 5：接线校准（如颜色有误）
- App → 信号灯设置 → 接线校准向导
- 向导逐一点亮 3 个引脚，观察实物灯对应是否正确
- 不对则在 App 内重新映射引脚（SETPIN），无需改接线或重新烧录

### Slide 21 — 验收 & 后续

**验收**：
- 打开 Claude Code 跑一个任务，观察灯光随会话状态自动切换（运行中→黄闪，等待审批→红黄呼吸，空闲→绿呼吸）

**后续固件升级**：
- App → 信号灯设置 → 固件更新 → 选择新版本 .bin 文件 → 一键 OTA
- 进度条走完绿灯常亮 = 升级成功，设备自动重启，不再需要插线

**常见问题：**

| 现象 | 排查方向 |
|------|---------|
| 扫描不到设备 | 检查供电 / 蓝牙是否开启 / 距离是否过远 |
| 灯亮了但颜色不对 | 运行接线校准向导，重新映射引脚 |
| OTA 烧录失败 | 检查 Type-C 是否为数据线（非纯充电线） |
| 断连后不自动重连 | 正常，App 后台自动扫描重连 |

---

## 统计

| 章节 | 页数 |
|------|------|
| Section 1：成品展示 | 4 页 |
| Section 2：工作原理 | 9 页 |
| Section 3：制作教程 | 8 页 |
| **合计** | **21 页** |
