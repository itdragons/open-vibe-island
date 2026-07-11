#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Update.h>
#include <Preferences.h>
#include <esp_sleep.h>
#include "config.h"


// ESP32-C3 Super Mini 支持 BLE，但不支持 BluetoothSerial（经典蓝牙）。
// 通过名为 C3_LED 的 BLE 设备来控制灯光，并推送固件 OTA 升级。


Preferences prefs; // NVS 键值存储句柄，用于持久化引脚分配与蓝牙名称

// 运行时的引脚分配与蓝牙名称 —— 会在 setup() 中从 NVS 读取，
// 新芯片首次上电时回退到 config.h 中的默认值；
// 可在运行时通过 SETPIN/SETNAME 命令重新分配，无需重新烧录固件。
int led_red = DEFAULT_LED_RED;
int led_yellow = DEFAULT_LED_YELLOW;
int led_green = DEFAULT_LED_GREEN;
String bleName; // 蓝牙广播名称，来自 NVS，或首次上电时用 config.h 的默认前缀

bool lightOn = true; // 灯光总开关：OFF 命令置为 false，其余命令通常会置为 true

// 该 LED 接线为反相逻辑（PWM 数值越小越亮）：
// LED_ON=0 表示全亮（低电平），LED_OFF=255 表示全灭（高电平）。
const int LED_ON = 0; // 0 是全亮（低电平）
const int LED_DIM = 128; // 半亮
const int LED_OFF = 255; // 255 是全灭（高电平）
const int PWM_MIN = 0; // PWM 取值下限
const int PWM_MAX = 255; // PWM 取值上限

// 时间相关常量（单位：毫秒）—— 动画节奏与重启/超时延迟。
const unsigned long GREEN_BLINK_INTERVAL_MS = 600;    // GREEN_BLINK 模式绿灯闪烁间隔
const unsigned long BUSY_BLINK_INTERVAL_MS = 600;     // BUSY 模式黄灯闪烁间隔
const unsigned long THINKING_FRAME_INTERVAL_MS = 130; // THINKING 模式三色轮转的帧间隔
const unsigned long ERROR_BLINK_INTERVAL_MS = 140;    // ERROR 模式红灯闪烁间隔
const unsigned long ALARM_BLINK_INTERVAL_MS = 180;    // ALARM 模式红黄交替闪烁间隔
const unsigned long WORKING_BREATHE_PERIOD_MS = 2400; // WORKING 模式呼吸灯周期
const unsigned long OTA_RESTART_DELAY_MS = 3000;      // OTA 成功后延迟重启的等待时间
const unsigned long RENAME_RESTART_DELAY_MS = 3000;   // 改名成功后延迟重启的等待时间
const unsigned long PIN_TEST_TIMEOUT_MS = 5000;       // 接线测试单次点亮的超时时间
const unsigned long BLE_RECONNECT_DELAY_MS = 100;     // 客户端断开后、重新开启广播前的延迟

int brightnessPercent = 100; // 0-100，通过 BRIGHTNESS 命令调节；App 重连后会重新同步

// 手动模式（MODE_MANUAL）下三路 LED 当前使用的 PWM 值
int redValue = LED_ON;
int yellowValue = LED_ON;
int greenValue = LED_ON;

// 灯光渲染模式：MODE_MANUAL 为手动直接赋值，其余均为动画/特殊模式
enum LedMode {
  MODE_MANUAL,
  MODE_GREEN_BLINK,
  MODE_THINKING,
  MODE_WORKING,
  MODE_BUSY,
  MODE_SUCCESS,
  MODE_ERROR,
  MODE_ALARM,
  MODE_CUSTOM_EFFECT,
  MODE_PIN_TEST,
  MODE_DISCONNECTED // 未连接任何 BLE 客户端时的提示态：三色呼吸，等待配对/重连
};

LedMode currentMode = MODE_MANUAL; // 当前正在渲染的模式
unsigned long lastFrameMs = 0;     // 上一帧动画的时间戳（如 THINKING 用它控制节奏）
int frame = 0;                     // 当前动画帧序号（如 THINKING 用它轮转三色）

// 接线校准测试引脚状态（详见 handlePinTestCommand）。与上方的效果渲染
// 模式互相隔离，避免 PINTEST 流程被正在进行的 EFFECT: 推送静默覆盖，
// 也避免 PINTEST 反过来覆盖正在播放的效果。
int pinTestActivePin = -1;              // 当前正在测试点亮的引脚，-1 表示未在测试
bool pinTestPriorLightOn = true;        // 进入测试前的灯光开关状态，测试结束后恢复
LedMode pinTestPriorMode = MODE_MANUAL; // 进入测试前的模式，测试结束后恢复
unsigned long pinTestDeadlineMs = 0;    // 当前测试引脚的自动熄灭时间点

// EFFECT: 命令支持的自定义效果类型：纯色 / 闪烁 / 流转 / 呼吸
enum CustomEffectType {
  EFFECT_SOLID,
  EFFECT_BLINK,
  EFFECT_CYCLE,
  EFFECT_BREATHE
};

CustomEffectType customEffectType = EFFECT_SOLID; // 当前生效的自定义效果类型
int customEffectColors[3] = { -1, -1, -1 };        // 参与效果的引脚号（最多三路），未使用位置为 -1
int customEffectColorCount = 0;                    // customEffectColors 中实际有效的颜色数量
unsigned long customEffectIntervalMs = 0;          // 效果的闪烁/流转/呼吸周期（毫秒）

BLECharacteristic *otaControlCharacteristic = nullptr; // OTA 控制特征值指针，setOtaStatus 用它向 App 推送状态通知

bool otaActive = false;                       // 是否有一次 OTA 升级正在进行
bool restartAfterOta = false;                 // OTA 成功结束后，是否需要延迟重启
size_t otaExpectedSize = UPDATE_SIZE_UNKNOWN; // 本次 OTA 预期的固件总字节数，未知时为 UPDATE_SIZE_UNKNOWN
size_t otaWrittenBytes = 0;                   // 本次 OTA 已写入的字节数
unsigned long restartAtMs = 0;                // 达到该时间点后执行重启（配合 restartAfterOta）

bool restartAfterRename = false;            // 改名成功后，是否需要延迟重启
unsigned long restartAfterRenameAtMs = 0;   // 达到该时间点后执行重启（配合 restartAfterRename）

bool lastButtonState = HIGH;           // 按键上一次读到的电平，LOW->HIGH 的上升沿即视为一次点击的完成
bool buttonPressSeen = false;          // 本次运行期间是否现场检测到过按下沿，避免把唤醒自己的
                                        // 那次按压（开机时读到的初始电平已是 LOW）的松开误判为新点击

// 函数前向声明，方便在文件中以任意顺序定义/调用
void handleCommand(String cmd);
bool handleModeCommand(String cmd);
void handleManualLedCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
bool splitCommandFields(const String &cmd, char sep, String fields[], int fieldCount);
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
bool isSafeGpioPin(int pin);
bool isNumericString(const String &text);
void handleSetPinCommand(String cmd);
void sendConfigStatus();
void handlePinTestCommand(String cmd);
void endPinTestIfExpired(unsigned long nowMs);
void handleSetNameCommand(String cmd);
void handleBrightnessCommand(String cmd);
int currentOnValue();
int scaleToOnValue(int rawValue, int onValue);
void checkButton();
void enterDeepSleep();

// 客户端断开连接后：立即切换到"未连接"三色呼吸提示态（无条件覆盖灯开关
// 与上一个模式——断开时 App 已无法控制灯光，呼吸提示比停留在旧状态更有用），
// 再重新开启广播，方便下一次连接。重连后 App 会自行 resync 回正确的效果。
class ServerCallback : public BLEServerCallbacks {
  void onDisconnect(BLEServer *server) {
    startMode(MODE_DISCONNECTED);
    delay(BLE_RECONNECT_DELAY_MS);
    server->startAdvertising();
  }
};

// 命令特征值被写入时，把原始字节转成字符串，交给统一的指令处理入口
class LedCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String cmd = String(characteristic->getValue().c_str());
    handleCommand(cmd);
  }
};

// OTA 控制特征值被写入时，转交给 OTA 控制指令处理函数
class OtaControlCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String cmd = String(characteristic->getValue().c_str());
    handleOtaControl(cmd);
  }
};

// OTA 数据特征值被写入时，把固件分片交给 OTA 数据处理函数
class OtaDataCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    handleOtaData(characteristic);
  }
};

void setup() {
  // 不等待 USB 串口枚举完成：物理按键开机后 loop() 要等 setup() 完全返回
  // 才会开始渲染灯光，这里阻塞多久，灯就要晚亮多久。串口日志有没接上都
  // 直接打印，接上监视器晚了就错过最早几行，下次重新开机再看即可。
  Serial.begin(115200);

  Serial.println();
  Serial.println("============================");
  Serial.println("C3 LED starting...");
  Serial.println("Wakeup cause: " + String(esp_sleep_get_wakeup_cause()));

  // 从 NVS 读取持久化的引脚分配与蓝牙名称；全新芯片没有记录时用 config.h 默认值
  prefs.begin("wglight", false);
  led_red = prefs.getInt("pinRed", DEFAULT_LED_RED);
  led_yellow = prefs.getInt("pinYellow", DEFAULT_LED_YELLOW);
  led_green = prefs.getInt("pinGreen", DEFAULT_LED_GREEN);
  bleName = prefs.getString("bleName", "");
  if (bleName.length() == 0) {
    bleName = BLE_NAME_PREFIX;
    prefs.putString("bleName", bleName);
  }
  // 亮度不在每次调节时写 NVS（避免拖动滑杆时频繁写 flash），只在真正关机前
  // 写一次（见 enterDeepSleep），这里读回来的是"上次关机时的亮度"，仅作为
  // App 连接前的初始值；App 连接后会立即用 BRIGHTNESS 命令覆盖为它自己的值。
  brightnessPercent = prefs.getInt("brightness", 100);
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);

  // 将三路 LED 引脚初始化为输出模式。先写入熄灭电平（HIGH，反相逻辑下=灭）
  // 再切换成 OUTPUT：pinMode(OUTPUT) 生效那一刻引脚默认电平是低电平，反相
  // 逻辑下低电平=点亮，先把电平写好可以避免这一瞬间被误点亮。
  digitalWrite(led_green, HIGH);
  pinMode(led_green, OUTPUT);
  digitalWrite(led_red, HIGH);
  pinMode(led_red, OUTPUT);
  digitalWrite(led_yellow, HIGH);
  pinMode(led_yellow, OUTPUT);

  // 无自锁开关，接 GND，内部上拉；旧硬件该引脚悬空，稳定读 HIGH，不会误触发
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  lastButtonState = digitalRead(BUTTON_PIN);

  // 再用 PWM 方式确认一次熄灭状态，交给后续的 analogWrite 接管；不用
  // showManualLights() 是因为它固定用 LED_ON（100% 亮度）点亮，会在
  // MODE_DISCONNECTED 接管前的这一瞬间无视用户设置的亮度，闪一下满亮
  turnOffLights();

  // 初始化 BLE 协议栈，并调大 MTU 以提升 OTA 数据传输效率
  BLEDevice::init(bleName.c_str());
  BLEDevice::setMTU(517);

  // 创建 BLE 服务端，断开重连由 ServerCallback 负责重新广播
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallback());

  // 创建统一的信号灯服务，下面的特征值都挂在这个服务下
  BLEService *service = server->createService(SERVICE_UUID);

  // 命令特征值：仅可写，用于接收灯光/模式控制指令
  BLECharacteristic *commandCharacteristic = service->createCharacteristic(
    COMMAND_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  commandCharacteristic->setCallbacks(new LedCallback());

  // OTA 控制特征值：可写可读可通知，用于 OTA 握手与状态上报
  otaControlCharacteristic = service->createCharacteristic(
    OTA_CONTROL_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR |
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  otaControlCharacteristic->addDescriptor(new BLE2902());
  otaControlCharacteristic->setCallbacks(new OtaControlCallback());
  otaControlCharacteristic->setValue("BLE OTA ready");

  // OTA 数据特征值：只写，用于分片传输固件数据
  BLECharacteristic *otaDataCharacteristic = service->createCharacteristic(
    OTA_DATA_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  otaDataCharacteristic->setCallbacks(new OtaDataCallback());

  // 信息特征值：只读，暴露当前固件版本号
  BLECharacteristic *infoCharacteristic = service->createCharacteristic(
    INFO_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  infoCharacteristic->setValue(FIRMWARE_VERSION.c_str());

  // 启动服务，使上面注册的特征值对外可见
  service->start();

  // 启动 BLE 广播，等待 App 发现并连接
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->start();

  // 开机即进入"未连接"三色呼吸提示态，直到 App 首次连接并推送真正的效果
  startMode(MODE_DISCONNECTED);

  Serial.println("BLE ready.");
  Serial.println("Commands: OTA_BEGIN:<bytes>, OTA_END, OTA_ABORT, OTA_STATUS");
}

// 主循环：处理延迟重启、串口调试指令、接线测试超时，并渲染当前灯光模式
void loop() {
  // OTA 升级成功后，延迟重启让状态提示先发送出去
  if (restartAfterOta && millis() >= restartAtMs) {
    ESP.restart();
  }

  // 改名成功后，延迟重启使新的蓝牙名称生效
  if (restartAfterRename && millis() >= restartAfterRenameAtMs) {
    ESP.restart();
  }

  // 同时支持通过 USB 串口直接输入调试指令
  if (Serial.available() > 0) {
    String serialCmd = Serial.readStringUntil('\n');
    serialCmd.trim();
    if (serialCmd.length() > 0) {
      Serial.println(">>> 收到串口指令: " + serialCmd);
      handleCommand(serialCmd);
    }
  }

  checkButton();

  endPinTestIfExpired(millis());

  if (!lightOn) {
    turnOffLights();
    return;
  }

  updateLights();
}

// 点击（按下+松开）即关机——松开瞬间触发，不判断按住了多久。这是有意
// 接受的取舍：换来更简单直接的关机手感，代价是手持/接线时无意碰到并松开
// 按键也会触发关机。
// 只有现场检测到过按下沿（buttonPressSeen）之后的松开才算一次点击：开机
// 时读到的初始电平可能已经是 LOW（GPIO 唤醒时手指还按着），若不加这层判断，
// 松开这次"唤醒自己的按压"会被误判成新点击，导致刚开机又立刻重新关机。
// 不判断当前 lightOn/模式，也不受 BLE 的 OFF/CLOSE/IDLE 命令影响，按键始终
// 是"真关机"，与软熄灯命令相互独立。
void checkButton() {
  bool buttonState = digitalRead(BUTTON_PIN);

  if (lastButtonState == HIGH && buttonState == LOW) {
    buttonPressSeen = true;
  }

  if (lastButtonState == LOW && buttonState == HIGH && buttonPressSeen) {
    enterDeepSleep();
  }

  lastButtonState = buttonState;
}

// 进入深度睡眠（真正关机）。OTA 升级中禁止关机；等按键释放后再使能 GPIO
// 唤醒，避免按键还按着就进入深睡眠、被同一次按压立刻唤醒。
void enterDeepSleep() {
  if (otaActive) {
    return;
  }

  Serial.println(">>> 按键触发，进入深度睡眠");
  Serial.flush();

  // 真关机会清空内存，唯独把亮度存一下：低频事件（每次关机一次），不会
  // 造成拖动滑杆那样的 flash 磨损问题
  prefs.putInt("brightness", brightnessPercent);

  turnOffLights();

  while (digitalRead(BUTTON_PIN) == LOW) {
    delay(10);
  }
  delay(50);

  esp_deep_sleep_enable_gpio_wakeup(1ULL << BUTTON_PIN, ESP_GPIO_WAKEUP_GPIO_LOW);
  esp_deep_sleep_start();
}

// 底层输出：直接写三路 PWM（反相逻辑，数值越小越亮）
void setLights(int red, int yellow, int green) {
  analogWrite(led_red, red);
  analogWrite(led_yellow, yellow);
  analogWrite(led_green, green);
}

// 按手动模式当前保存的三色数值点亮
void showManualLights() {
  setLights(redValue, yellowValue, greenValue);
}

// 熄灭三路 LED
void turnOffLights() {
  setLights(LED_OFF, LED_OFF, LED_OFF);
}

// 切换到新的渲染模式，并重置动画帧状态，保证新模式从第一帧开始
void startMode(LedMode mode) {
  lightOn = true;
  currentMode = mode;
  lastFrameMs = 0;
  frame = 0;
}

// 根据当前模式分发到对应的动画渲染函数
void updateLights() {
  unsigned long nowMs = millis();

  if (currentMode == MODE_MANUAL) {
    showManualLights();
  } else if (currentMode == MODE_GREEN_BLINK) {
    animateGreenBlink(nowMs);
  } else if (currentMode == MODE_THINKING) {
    animateThinking(nowMs);
  } else if (currentMode == MODE_WORKING || currentMode == MODE_DISCONNECTED) {
    // MODE_DISCONNECTED 复用 WORKING 的三色同步呼吸渲染；两者不会同时出现
    // （前者仅在已连接且 App 主动驱动时生效，后者仅在未连接时生效），共用
    // 同一种视觉效果不会造成用户混淆。
    animateWorking(nowMs);
  } else if (currentMode == MODE_BUSY) {
    animateBusy(nowMs);
  } else if (currentMode == MODE_SUCCESS) {
    animateSuccess();
  } else if (currentMode == MODE_ERROR) {
    animateError(nowMs);
  } else if (currentMode == MODE_ALARM) {
    animateAlarm(nowMs);
  } else if (currentMode == MODE_CUSTOM_EFFECT) {
    animateCustomEffect(nowMs);
  } else if (currentMode == MODE_PIN_TEST) {
    // 引脚状态由 handlePinTestCommand() 直接驱动，这里无需渲染
  }
}

// GREEN_BLINK 模式：绿灯按固定间隔闪烁
void animateGreenBlink(unsigned long nowMs) {
  bool on = (nowMs / GREEN_BLINK_INTERVAL_MS) % 2 == 0;
  setLights(LED_OFF, LED_OFF, on ? currentOnValue() : LED_OFF);
}

// THINKING 模式：三色按固定间隔轮转，制造"思考中"的观感
void animateThinking(unsigned long nowMs) {
  if (nowMs - lastFrameMs < THINKING_FRAME_INTERVAL_MS) {
    return;
  }

  lastFrameMs = nowMs;
  frame = (frame + 1) % 3;

  int onValue = currentOnValue();
  int dimValue = scaleToOnValue(LED_DIM, onValue);

  if (frame == 0) {
    setLights(onValue, dimValue, LED_OFF);
  } else if (frame == 1) {
    setLights(LED_OFF, onValue, dimValue);
  } else {
    setLights(dimValue, LED_OFF, onValue);
  }
}

// 把 0-100 的亮度百分比换算成反相 PWM 下的"点亮"数值
int currentOnValue() {
  return map(brightnessPercent, 0, 100, LED_OFF, LED_ON);
}

// 把一个 LED_ON..LED_OFF 范围内的原始 PWM 值（如呼吸灯曲线、半亮档位），
// 按亮度等比缩放到 onValue..LED_OFF 范围，使其相对亮度不变
int scaleToOnValue(int rawValue, int onValue) {
  return map(rawValue, LED_ON, LED_OFF, onValue, LED_OFF);
}

// 计算呼吸灯在一个周期内当前的 PWM 值：前半周期从灭渐亮，后半周期从亮渐灭
int breathValue(unsigned long nowMs, unsigned long periodMs) {
  unsigned long phase = nowMs % periodMs;

  if (phase < periodMs / 2) {
    return map(phase, 0, periodMs / 2, LED_OFF, LED_ON);
  }

  return map(phase, periodMs / 2, periodMs, LED_ON, LED_OFF);
}

// WORKING 模式：用呼吸灯效果表现"正在生成"的状态。呼吸曲线以本次进入模式
// 的时刻为起点（而不是绝对的 millis()），保证每次切换到这个模式都是从灭
// 开始渐亮，不会因为 millis() 恰好落在曲线中段而一进入就显得忽然变亮
void animateWorking(unsigned long nowMs) {
  if (lastFrameMs == 0) {
    lastFrameMs = nowMs;
  }
  int value = breathValue(nowMs - lastFrameMs, WORKING_BREATHE_PERIOD_MS);
  int scaledValue = scaleToOnValue(value, currentOnValue());
  setLights(scaledValue, scaledValue, scaledValue);
}

// BUSY 模式：黄灯按固定间隔闪烁
void animateBusy(unsigned long nowMs) {
  bool on = (nowMs / BUSY_BLINK_INTERVAL_MS) % 2 == 0;
  setLights(LED_OFF, on ? currentOnValue() : LED_OFF, LED_OFF);
}

// SUCCESS 模式：常亮绿灯
void animateSuccess() {
  setLights(LED_OFF, LED_OFF, currentOnValue());
}

// ERROR 模式：红灯快速闪烁
void animateError(unsigned long nowMs) {
  bool on = (nowMs / ERROR_BLINK_INTERVAL_MS) % 2 == 0;
  setLights(on ? currentOnValue() : LED_OFF, LED_OFF, LED_OFF);
}

// ALARM 模式：红黄交替闪烁，用于强提醒
void animateAlarm(unsigned long nowMs) {
  bool redOn = (nowMs / ALARM_BLINK_INTERVAL_MS) % 2 == 0;
  int onValue = currentOnValue();
  setLights(redOn ? onValue : LED_OFF, redOn ? LED_OFF : onValue, LED_OFF);
}

// 解析并启动一个自定义效果（纯色/闪烁/流转/呼吸）
void handleEffectCommand(String cmd) {
  // 格式：EFFECT:<类型>:<颜色>:<间隔毫秒>，例如 EFFECT:CYCLE:RYG:200
  String fields[3];
  if (!splitCommandFields(cmd, ':', fields, 3)) {
    return;
  }

  String typeText = fields[0];
  String colorsText = fields[1];
  String intervalText = fields[2];

  CustomEffectType parsedType;
  if (typeText == "SOLID") {
    parsedType = EFFECT_SOLID;
  } else if (typeText == "BLINK") {
    parsedType = EFFECT_BLINK;
  } else if (typeText == "CYCLE") {
    parsedType = EFFECT_CYCLE;
  } else if (typeText == "BREATHE") {
    parsedType = EFFECT_BREATHE;
  } else {
    return;
  }

  int parsedColors[3];
  int parsedColorCount = 0;
  for (unsigned int i = 0; i < colorsText.length() && parsedColorCount < 3; i++) {
    char c = colorsText.charAt(i);
    if (c == 'R') {
      parsedColors[parsedColorCount++] = led_red;
    } else if (c == 'Y') {
      parsedColors[parsedColorCount++] = led_yellow;
    } else if (c == 'G') {
      parsedColors[parsedColorCount++] = led_green;
    }
  }

  if (parsedColorCount == 0) {
    return;
  }

  long parsedInterval = intervalText.toInt();
  if (parsedInterval < 0) {
    return;
  }

  customEffectType = parsedType;
  customEffectColorCount = parsedColorCount;
  for (int i = 0; i < parsedColorCount; i++) {
    customEffectColors[i] = parsedColors[i];
  }
  customEffectIntervalMs = (unsigned long)parsedInterval;

  startMode(MODE_CUSTOM_EFFECT);
}

// 把 onValue 写入 activeIndex 指定的颜色；activeIndex 为 -1 时对所有参与颜色生效
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex) {
  for (int i = 0; i < customEffectColorCount; i++) {
    if (activeIndex >= 0 && i != activeIndex) {
      continue;
    }
    int pin = customEffectColors[i];
    if (pin == led_red) {
      red = onValue;
    } else if (pin == led_yellow) {
      yellow = onValue;
    } else if (pin == led_green) {
      green = onValue;
    }
  }
}

// 按当前自定义效果类型（纯色/闪烁/流转/呼吸）渲染当前帧
void animateCustomEffect(unsigned long nowMs) {
  if (customEffectColorCount == 0) {
    return;
  }

  int red = LED_OFF;
  int yellow = LED_OFF;
  int green = LED_OFF;
  int onValue = currentOnValue();

  if (customEffectType == EFFECT_SOLID) {
    applyCustomEffectValue(red, yellow, green, onValue, -1);
  } else if (customEffectType == EFFECT_BLINK) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    bool on = (nowMs / interval) % 2 == 0;
    applyCustomEffectValue(red, yellow, green, on ? onValue : LED_OFF, -1);
  } else if (customEffectType == EFFECT_CYCLE) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int activeIndex = (int)((nowMs / interval) % customEffectColorCount);
    applyCustomEffectValue(red, yellow, green, onValue, activeIndex);
  } else if (customEffectType == EFFECT_BREATHE) {
    unsigned long period = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int rawValue = breathValue(nowMs, period);
    int scaledValue = scaleToOnValue(rawValue, onValue);
    applyCustomEffectValue(red, yellow, green, scaledValue, -1);
  }

  setLights(red, yellow, green);
}

// 蓝牙/串口指令的统一入口：归一化大小写后按前缀依次匹配并分发
void handleCommand(String cmd) {
  String original = cmd;
  original.trim();
  cmd.trim();
  cmd.toUpperCase();

  if (cmd.length() == 0) {
    return;
  }

  if (cmd.startsWith("EFFECT:")) {
    handleEffectCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETPIN:")) {
    handleSetPinCommand(cmd);
    return;
  }

  if (cmd == "GETCONFIG") {
    sendConfigStatus();
    return;
  }

  if (cmd.startsWith("PINTEST:")) {
    handlePinTestCommand(cmd);
    return;
  }

  if (cmd.startsWith("SETNAME:")) {
    handleSetNameCommand(original);
    return;
  }

  if (cmd.startsWith("BRIGHTNESS:")) {
    handleBrightnessCommand(cmd);
    return;
  }

  if (handleModeCommand(cmd)) {
    return;
  }

  if (cmd == "BLE") {
    Serial.println("Bluetooth Name: " + bleName);
    return;
  }

  handleManualLedCommand(cmd);
}

// 命名模式命令（GREEN_BLINK/THINKING/.../OFF 及其别名）。
// 命中则返回 true；返回 false 时调用方应继续尝试单字母手动灯光控制。
bool handleModeCommand(String cmd) {
  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
    lightOn = true;
    startMode(MODE_GREEN_BLINK);
    return true;
  }

  if (isCommand(cmd, "THINKING", "THINK", "ANALYSIS")) {
    startMode(MODE_THINKING);
    return true;
  }

  if (isCommand(cmd, "WORKING", "AI", "GENERATING", "GENERATE")) {
    startMode(MODE_WORKING);
    return true;
  }

  if (isCommand(cmd, "BUSY", "COMMAND", "EXECUTING")) {
    startMode(MODE_BUSY);
    return true;
  }

  if (isCommand(cmd, "SUCCESS", "OK", "DONE")) {
    startMode(MODE_SUCCESS);
    return true;
  }

  if (isCommand(cmd, "ERROR", "FAILED", "FAIL")) {
    startMode(MODE_ERROR);
    return true;
  }

  if (isCommand(cmd, "ALARM", "BLOCKED", "CRITICAL")) {
    startMode(MODE_ALARM);
    return true;
  }

  if (isCommand(cmd, "OFF", "CLOSE", "IDLE")) {
    lightOn = false;
    turnOffLights();
    return true;
  }

  return false;
}

// 单字母手动控制，例如 "R"、"R0"、"R128"（颜色 + 可选 PWM 值；
// 单独的 "0"/"1" 分别映射为全灭/全亮）。
void handleManualLedCommand(String cmd) {
  char led = cmd.charAt(0);
  int value = LED_ON; // 默认单字母输入为亮起

  if (cmd.length() > 1) {
    String arg = cmd.substring(1);
    if (arg == "0") {
      value = LED_OFF; // 输入 0 代表熄灭
    } else if (arg == "1") {
      value = LED_ON;  // 输入 1 代表亮起
    } else {
      value = arg.toInt();
      value = constrain(value, PWM_MIN, PWM_MAX);
    }
  }

  if (led == 'R') {
    redValue = value;
    yellowValue = LED_OFF;
    greenValue = LED_OFF;
  } else if (led == 'Y') {
    redValue = LED_OFF;
    yellowValue = value;
    greenValue = LED_OFF;
  } else if (led == 'G') {
    redValue = LED_OFF;
    yellowValue = LED_OFF;
    greenValue = value;
  } else if (led == 'A') {
    redValue = value;
    yellowValue = value;
    greenValue = value;
  } else {
    return;
  }

  currentMode = MODE_MANUAL;
  lightOn = true;
  showManualLights();
}

// 处理 OTA_BEGIN/OTA_END/OTA_ABORT/OTA_STATUS 等 OTA 控制指令
void handleOtaControl(String cmd) {
  cmd.trim();

  String upper = cmd;
  upper.toUpperCase();

  if (upper.startsWith("OTA_BEGIN") || upper.startsWith("OTA_START")) {
    // 开始一次新的 OTA：若有残留的旧会话先中止，再按可选的字节数启动写入
    if (otaActive) {
      Update.abort();
      otaActive = false;
    }

    otaExpectedSize = UPDATE_SIZE_UNKNOWN;
    int separator = cmd.indexOf(':');
    if (separator < 0) {
      separator = cmd.indexOf(' ');
    }

    if (separator >= 0) {
      String sizeText = cmd.substring(separator + 1);
      sizeText.trim();
      long parsedSize = sizeText.toInt();
      if (parsedSize > 0) {
        otaExpectedSize = (size_t)parsedSize;
      }
    }

    if (!Update.begin(otaExpectedSize, U_FLASH)) {
      setOtaStatus("OTA_BEGIN failed: " + String(Update.errorString()));
      lightOn = true;
      startMode(MODE_ERROR);
      return;
    }

    otaActive = true;
    otaWrittenBytes = 0;
    restartAfterOta = false;
    lightOn = true;
    startMode(MODE_BUSY);
    setOtaStatus("OTA_BEGIN ok");
    return;
  }

  if (upper == "OTA_END" || upper == "OTA_FINISH") {
    // 结束 OTA：校验写入字节数是否吻合，成功则延迟重启以加载新固件
    if (!otaActive) {
      setOtaStatus("OTA_END ignored: not active");
      return;
    }

    bool sizeOk = otaExpectedSize == UPDATE_SIZE_UNKNOWN || otaWrittenBytes == otaExpectedSize;
    bool endOk = Update.end(sizeOk);
    otaActive = false;

    if (!endOk) {
      setOtaStatus("OTA_END failed: " + String(Update.errorString()));
      lightOn = true;
      startMode(MODE_ERROR);
      return;
    }

    setOtaStatus("OTA_END ok, restarting");
    lightOn = true;
    startMode(MODE_SUCCESS);
    restartAfterOta = true;
    restartAtMs = millis() + OTA_RESTART_DELAY_MS;
    return;
  }

  if (upper == "OTA_ABORT" || upper == "OTA_CANCEL") {
    // 中止当前 OTA 会话
    if (otaActive) {
      Update.abort();
      otaActive = false;
    }

    setOtaStatus("OTA_ABORT ok");
    lightOn = true;
    startMode(MODE_ALARM);
    return;
  }

  if (upper == "OTA_STATUS") {
    // 上报当前 OTA 会话的进度
    String status = "OTA_STATUS ";
    status += otaActive ? "active " : "idle ";
    status += String(otaWrittenBytes);
    if (otaExpectedSize != UPDATE_SIZE_UNKNOWN) {
      status += "/";
      status += String(otaExpectedSize);
    }
    setOtaStatus(status);
    return;
  }

  setOtaStatus("Unknown OTA command");
}

// 接收 OTA 数据特征值分片写入的固件数据并写入 Update；超量或写入失败则中止 OTA
void handleOtaData(BLECharacteristic *characteristic) {
  if (!otaActive) {
    return;
  }

  auto value = characteristic->getValue();
  size_t length = value.length();

  if (length == 0) {
    return;
  }

  size_t written = Update.write((uint8_t *)value.c_str(), length);
  otaWrittenBytes += written;

  if (written != length) {
    Update.abort();
    otaActive = false;
    setOtaStatus("OTA_DATA failed: " + String(Update.errorString()));
    lightOn = true;
    startMode(MODE_ERROR);
    return;
  }

  if (otaExpectedSize != UPDATE_SIZE_UNKNOWN && otaWrittenBytes > otaExpectedSize) {
    Update.abort();
    otaActive = false;
    setOtaStatus("OTA_DATA failed: too many bytes");
    lightOn = true;
    startMode(MODE_ERROR);
  }
}

// 把状态消息打印到串口，并通过 OTA 控制特征值通知已订阅的 App
void setOtaStatus(const String &message) {
  Serial.println(message);

  if (otaControlCharacteristic != nullptr) {
    otaControlCharacteristic->setValue(message.c_str());
    otaControlCharacteristic->notify();
  }
}

// 判断 cmd 是否命中给定的若干候选别名之一
bool isCommand(String cmd, String a, String b, String c, String d) {
  return cmd == a || cmd == b || cmd == c || cmd == d;
}

// 按 `sep` 分割 `cmd`，跳过开头的命令名段，提取其后的 `fieldCount`
// 个字段写入 `fields`。最后一个字段会贪婪匹配其分隔符之后的全部内容。
// 若找到的分隔符数量不足 `fieldCount` 个则返回 false —— 调用方将其
// 视为命令格式错误，与被替换前逐个 indexOf/substring 的写法语义一致。
bool splitCommandFields(const String &cmd, char sep, String fields[], int fieldCount) {
  int pos = cmd.indexOf(sep);

  for (int i = 0; i < fieldCount; i++) {
    if (pos < 0) {
      return false;
    }

    bool isLastField = (i == fieldCount - 1);
    int nextPos = isLastField ? -1 : cmd.indexOf(sep, pos + 1);
    if (!isLastField && nextPos < 0) {
      return false;
    }

    fields[i] = (nextPos < 0) ? cmd.substring(pos + 1) : cmd.substring(pos + 1, nextPos);
    pos = nextPos;
  }

  return true;
}

// 校验引脚是否在允许分配/测试的安全 GPIO 白名单内
bool isSafeGpioPin(int pin) {
  for (int i = 0; i < SAFE_GPIO_PIN_COUNT; i++) {
    if (SAFE_GPIO_PINS[i] == pin) {
      return true;
    }
  }
  return false;
}

// 校验字符串是否为纯数字，用于拒绝非法的引脚号/数值参数
bool isNumericString(const String &text) {
  if (text.length() == 0) {
    return false;
  }
  for (unsigned int i = 0; i < text.length(); i++) {
    if (!isDigit(text.charAt(i))) {
      return false;
    }
  }
  return true;
}

// 重新分配某一路 LED 的物理引脚，并持久化到 NVS，无需重新烧录固件即可修正接线错误
void handleSetPinCommand(String cmd) {
  // 格式：SETPIN:<R|Y|G>:<引脚号>，例如 SETPIN:R:10
  String fields[2];
  if (!splitCommandFields(cmd, ':', fields, 2)) {
    setOtaStatus("SETPIN failed: malformed command");
    return;
  }

  String colorText = fields[0];
  String pinText = fields[1];
  if (!isNumericString(pinText)) {
    setOtaStatus("SETPIN failed: malformed command");
    return;
  }
  int pin = pinText.toInt();

  if (!isSafeGpioPin(pin)) {
    setOtaStatus("SETPIN failed: unsupported pin " + String(pin));
    return;
  }

  pinMode(pin, OUTPUT);

  if (colorText == "R") {
    led_red = pin;
    prefs.putInt("pinRed", pin);
  } else if (colorText == "Y") {
    led_yellow = pin;
    prefs.putInt("pinYellow", pin);
  } else if (colorText == "G") {
    led_green = pin;
    prefs.putInt("pinGreen", pin);
  } else {
    setOtaStatus("SETPIN failed: unknown color " + colorText);
    return;
  }

  setOtaStatus("SETPIN ok: " + colorText + "=" + String(pin));
}

// 上报当前引脚分配与蓝牙名称，供 App 展示或校验接线配置
void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}

// 接线校准向导：短暂点亮候选引脚，帮助确认物理接线是否正确
void handlePinTestCommand(String cmd) {
  // 格式：PINTEST:<引脚号>:<0|1>
  String fields[2];
  if (!splitCommandFields(cmd, ':', fields, 2)) {
    setOtaStatus("PINTEST failed: malformed command");
    return;
  }

  String pinText = fields[0];
  String valueText = fields[1];
  if (!isNumericString(pinText) || !isNumericString(valueText)) {
    // 防止诸如 "PINTEST:R:1" 或空字段被 String::toInt() 静默解析成
    // 引脚/值为 0 的情况 —— 与 SETPIN 里同类问题的修复思路一致，
    // isNumericString 就定义在 SETPIN 的修复里。
    setOtaStatus("PINTEST failed: malformed command");
    return;
  }

  int pin = pinText.toInt();
  int value = valueText.toInt();

  if (!isSafeGpioPin(pin)) {
    setOtaStatus("PINTEST failed: unsupported pin " + String(pin));
    return;
  }

  if (currentMode != MODE_PIN_TEST) {
    // 本次测试序列首次进入测试模式：记录需要恢复的状态，并强制点亮
    // 灯光（即使之前被开关关闭），保证向导不受灯光开关状态影响。
    pinTestPriorLightOn = lightOn;
    pinTestPriorMode = currentMode;
    lightOn = true;
    currentMode = MODE_PIN_TEST;
  } else if (pinTestActivePin != -1 && pinTestActivePin != pin) {
    // 向导过程中切换到另一个候选引脚：先关掉上一个引脚，防止 App
    // 忘记关闭导致它常亮。
    analogWrite(pinTestActivePin, LED_OFF);
  }

  pinMode(pin, OUTPUT);
  analogWrite(pin, value == 1 ? LED_ON : LED_OFF);
  pinTestActivePin = pin;
  pinTestDeadlineMs = millis() + PIN_TEST_TIMEOUT_MS;
}

// PINTEST 序列超时后自动熄灭测试引脚，并恢复进入测试前的模式与灯光开关状态
void endPinTestIfExpired(unsigned long nowMs) {
  if (currentMode != MODE_PIN_TEST || nowMs < pinTestDeadlineMs) {
    return;
  }

  if (pinTestActivePin != -1) {
    analogWrite(pinTestActivePin, LED_OFF);
  }
  pinTestActivePin = -1;
  lightOn = pinTestPriorLightOn;
  currentMode = pinTestPriorMode;
}

// 修改蓝牙广播名称并持久化到 NVS，随后延迟重启使新名称生效
void handleSetNameCommand(String cmd) {
  // 格式：SETNAME:<名称> —— 这里的 `cmd` 是未转大写的原始命令文本，
  // 以保留用户设置名称的大小写。
  String fields[1];
  if (!splitCommandFields(cmd, ':', fields, 1)) {
    setOtaStatus("SETNAME failed: malformed command");
    return;
  }

  String newName = fields[0];
  newName.trim();
  if (newName.length() == 0) {
    setOtaStatus("SETNAME failed: empty name");
    return;
  }

  prefs.putString("bleName", newName);
  setOtaStatus("SETNAME ok, restarting");
  restartAfterRename = true;
  restartAfterRenameAtMs = millis() + RENAME_RESTART_DELAY_MS;
}

// 更新全局亮度百分比，供呼吸灯/自定义效果按比例计算 PWM 值
void handleBrightnessCommand(String cmd) {
  // 格式：BRIGHTNESS:<0-100>
  String fields[1];
  if (!splitCommandFields(cmd, ':', fields, 1)) {
    setOtaStatus("BRIGHTNESS failed: malformed command");
    return;
  }

  int percent = fields[0].toInt();
  brightnessPercent = constrain(percent, 0, 100);
}
