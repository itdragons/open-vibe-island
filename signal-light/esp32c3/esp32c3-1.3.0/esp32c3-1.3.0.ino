#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Update.h>
#include <Preferences.h>
#include <esp_sleep.h>
#include <esp_system.h>
#include "driver/ledc.h"
#include "driver/gpio.h"
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

// LED 接线极性：false=低电平点亮（出厂默认，历史机型行为不变），true=高电平点亮。
// 通过 SETPOLARITY 命令运行时切换并持久化到 NVS，无需重新烧录固件（见 handleSetPolarityCommand）。
bool ledActiveHigh = false;

// 该 LED 接线为反相逻辑（PWM 数值越小越亮）：
// LED_ON=0 表示全亮（低电平），LED_OFF=255 表示全灭（高电平）。
const int LED_ON = 0; // 0 是全亮（低电平）
const int LED_DIM = 128; // 半亮
const int LED_OFF = 255; // 255 是全灭（高电平）
const int PWM_MIN = 0; // PWM 取值下限
const int PWM_MAX = 255; // PWM 取值上限

// LED 用底层 IDF LEDC 驱动并开启输出反相（output_invert）。LEDC 通道配置那一刻占空比
// 默认为 0，反相接线下 0=全亮；开启反相后 0=灭，通道从接管起就是灭的，消除开机满亮闪。
// 反相使占空比语义翻转，故写入 duty = PWM_MAX - value（value 约定 0=亮、255=灭）。
const int LED_PWM_FREQUENCY = 25000;
const ledc_mode_t LED_PWM_MODE = LEDC_LOW_SPEED_MODE;       // ESP32-C3 只有低速模式
const ledc_timer_t LED_PWM_TIMER = LEDC_TIMER_0;
const ledc_timer_bit_t LED_PWM_RESOLUTION = LEDC_TIMER_8_BIT; // 占空比 0-255

// 三路 LED 各占一个固定 LEDC 通道；SETPIN 改引脚时只改该通道绑定的 GPIO，通道号不变。
// PINTEST 走纯数字 GPIO，不占用 LEDC 通道（见 handlePinTestCommand）。
const ledc_channel_t LED_CHANNEL_RED = LEDC_CHANNEL_0;
const ledc_channel_t LED_CHANNEL_YELLOW = LEDC_CHANNEL_1;
const ledc_channel_t LED_CHANNEL_GREEN = LEDC_CHANNEL_2;

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

// 防欠压死循环的"本次开机是否已稳定跑起来"标记（判据见 setup()）。存 NVS 而非 RTC 变量：
// brownout 会拉低电压、可能清空 RTC 内存，只有 flash 能可靠保住状态。
bool bootConfirmed = false;                 // 本次运行是否已稳定足够久，可清除 pendingBoot
const unsigned long BOOT_STABLE_MS = 3000;  // 稳定运行超此时长即认定越过 BLE 电流冲击、开机成功

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
void handleSetPolarityCommand(String cmd);
int currentOnValue();
int scaleToOnValue(int rawValue, int onValue);
void checkButton();
void enterDeepSleep();
void sleepWithGpioWakeup();
void enterSafeBootSleep();
void holdLedOutputsOffDuringSleep();
void releaseLedOutputHolds();
void configureLedChannel(int pin, ledc_channel_t channel);
void configureAllLedChannels();
void writeLedChannel(ledc_channel_t channel, int value);
void driveTestPin(int pin, bool on);

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

  // 防欠压死循环：低电时 BLE 初始化的电流冲击会触发 brownout 复位，若每次开机都照常初始化
  // BLE 就会"复位→BLE→再 brownout"无限循环——灯一直微亮频闪，且走不到 loop() 的按键处理而
  // 关不了机。判据不用 RTC 变量或复位原因（brownout 时都不可靠：RTC 可能被清、复位原因未必
  // 归类为 brownout），改用 NVS 持久标记 pendingBoot——它为 true 表示"上次开机跑到了 BLE 却
  // 没稳定运行就挂了"。本次开机若它仍为 true 且非按键唤醒（即 brownout 自动重启），即判定死
  // 循环，熄灯直接深睡、保持关机；按键唤醒视为用户主动开机，无条件再给一次机会。
  prefs.begin("wglight", false);
  bool pendingBoot = prefs.getBool("pendingBoot", false);
  bool wokenByButton = esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_GPIO;
  bool shouldSafeBoot = pendingBoot && !wokenByButton;
  Serial.println("Reset reason: " + String(esp_reset_reason()) +
                  ", pendingBoot: " + String(pendingBoot) +
                  ", wokenByButton: " + String(wokenByButton) +
                  (shouldSafeBoot ? " -> safe boot" : ""));

  // 从 NVS 读取持久化的引脚分配与蓝牙名称；全新芯片没有记录时用 config.h 默认值
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
  ledActiveHigh = prefs.getBool("ledActiveHigh", false);
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);
  Serial.println("Polarity -> " + String(ledActiveHigh ? "HIGH" : "LOW"));

  // 先把三路引脚摁灭，覆盖 configureAllLedChannels 接管前的窗口。熄灯电平由
  // ledActiveHigh 决定：低电平点亮（默认，未跑过 SETPOLARITY 的设备恒为此值）时熄灯电平是
  // HIGH——与改动前完全一致；高电平点亮时熄灯电平是 LOW。
  // 顺序关键：先 pinMode(OUTPUT) 再 digitalWrite；反过来时引脚仍是 INPUT，pinMode(OUTPUT)
  // 生效瞬间会输出默认低电平，若恰好是当前极性下的点亮电平，会造成开机满亮闪。
  int bootOffLevel = ledActiveHigh ? LOW : HIGH;
  pinMode(led_green, OUTPUT);
  digitalWrite(led_green, bootOffLevel);
  pinMode(led_red, OUTPUT);
  digitalWrite(led_red, bootOffLevel);
  pinMode(led_yellow, OUTPUT);
  digitalWrite(led_yellow, bootOffLevel);

  // 配置 LEDC 定时器与三路输出反相通道（占空比 0=灭），接管三路引脚
  configureAllLedChannels();

  // 深睡唤醒后 GPIO hold 仍然有效。必须先让普通 GPIO 和 LEDC 都准备好高电平
  // 熄灯态，再解除 hold；否则从复位到 setup() 完成之间三路会同时闪亮。
  releaseLedOutputHolds();

  // 无自锁开关，接 GND，内部上拉；旧硬件该引脚悬空，稳定读 HIGH，不会误触发
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  lastButtonState = digitalRead(BUTTON_PIN);

  // 安全降级：跳过 BLE 初始化（最大的电流冲击源），熄灯后直接深度睡眠，交给用户按键决定
  // 何时重试。enterSafeBootSleep() 内部会进入深度睡眠，不会返回。
  if (shouldSafeBoot) {
    enterSafeBootSleep();
  }

  // BLE 初始化前（电流最小、电压最高，写 flash 最安全；NVS 写入本身掉电安全）先落
  // pendingBoot=true。若随后 brownout，标记留在 flash，下次非按键开机即降级；稳定运行
  // 后由 loop() 清除。
  prefs.putBool("pendingBoot", true);

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

  // 信息特征值：只读，以紧凑 JSON 暴露硬件标识与当前固件版本号，供 App
  // 解析出 {hardware, version} —— hardware 决定在线更新的取用路径。旧固件
  // 只上报裸版本号，App 端会回退为 hardware="esp32c3"，保持向后兼容。
  BLECharacteristic *infoCharacteristic = service->createCharacteristic(
    INFO_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  String infoJson = String("{\"hardware\":\"") + HARDWARE_ID +
                    "\",\"version\":\"" + FIRMWARE_VERSION + "\"}";
  infoCharacteristic->setValue(infoJson.c_str());

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
  // 稳定运行超过 BOOT_STABLE_MS，说明已越过 BLE 电流冲击、未被 brownout 打断：清除 pendingBoot
  // 标记，使下次正常开机不被误判为欠压死循环。bootConfirmed 去重，整段运行只写一次 flash。
  if (!bootConfirmed && millis() >= BOOT_STABLE_MS) {
    prefs.putBool("pendingBoot", false);
    bootConfirmed = true;
  }

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

// 松开即关机，不判断按住时长——代价是无意碰到/松开也会关机，已知并接受。
// buttonPressSeen 保证"唤醒自己的那次按压"的松开不会被当成新点击（开机时
// 读到的初始电平可能就是 LOW，并未现场见证过按下沿）。
// 与 BLE OFF/CLOSE/IDLE 的软熄灯无关，按键始终是真关机。
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

  sleepWithGpioWakeup();
}

// 等按键释放后使能 GPIO 唤醒并进入深度睡眠，供 enterDeepSleep 与 enterSafeBootSleep 复用。
// 不会返回：调用后芯片进入深度睡眠，下次从 setup() 重新开始。
void sleepWithGpioWakeup() {
  while (digitalRead(BUTTON_PIN) == LOW) {
    delay(10);
  }
  delay(50);

  // LED 是低电平点亮：睡眠前锁住当前的高电平（熄灯），并让锁定在
  // deep sleep 期间持续有效。按键唤醒导致 CPU 重新启动时，引脚仍保持熄灯电平。
  holdLedOutputsOffDuringSleep();

  esp_deep_sleep_enable_gpio_wakeup(1ULL << BUTTON_PIN, ESP_GPIO_WAKEUP_GPIO_LOW);
  esp_deep_sleep_start();
}

// 保持三路 LED 的熄灯电平，跨越 deep sleep 和唤醒复位。
void holdLedOutputsOffDuringSleep() {
  gpio_hold_en((gpio_num_t)led_red);
  gpio_hold_en((gpio_num_t)led_yellow);
  gpio_hold_en((gpio_num_t)led_green);
  gpio_deep_sleep_hold_en();
}

// setup() 已把三路 LEDC 配成熄灯态后再释放 pad hold，避免释放瞬间跳到低电平。
void releaseLedOutputHolds() {
  gpio_hold_dis((gpio_num_t)led_red);
  gpio_hold_dis((gpio_num_t)led_yellow);
  gpio_hold_dis((gpio_num_t)led_green);
  gpio_deep_sleep_hold_dis();
}

// 判定为欠压死循环（pendingBoot 仍 true 且非按键唤醒，见 setup()）时的降级入口：不初始化
// BLE、不点任何灯，直接深睡，不返回。刻意「什么都不点」——低电时点灯的电流冲击本身就可能
// 再次触发 brownout。熄灯睡死后深睡电流极低、电压回升，设备保持关机不再频闪；之后按键唤醒
// 会跳过本降级、再给一次正常启动的机会，循环被打破。
void enterSafeBootSleep() {
  Serial.println(">>> 安全降级：疑似欠压死循环，跳过 BLE 初始化，不点灯，直接进入深度睡眠");
  Serial.flush();

  turnOffLights();

  sleepWithGpioWakeup();
}

// 把一路 LED 引脚绑定到指定 LEDC 通道并设置输出反相标志，初始占空比 0（反相后=灭）。
// 开机与 SETPIN 改引脚都用它。
void configureLedChannel(int pin, ledc_channel_t channel) {
  ledc_channel_config_t channelConfig = {};
  channelConfig.gpio_num = pin;
  channelConfig.speed_mode = LED_PWM_MODE;
  channelConfig.channel = channel;
  channelConfig.timer_sel = LED_PWM_TIMER;
  channelConfig.duty = 0;                 // 灭：具体对应哪个电平由 output_invert 决定
  channelConfig.hpoint = 0;
  // 低电平点亮（默认）需要反相：duty=0 时输出高电平=灭。高电平点亮则不反相，
  // duty=0 时输出低电平=灭。writeLedChannel()的 duty = PWM_MAX - value 公式对两种
  // 极性都成立，因此这里是极性生效的唯一位置——上层的亮度/动画代码完全不用感知极性。
  channelConfig.flags.output_invert = ledActiveHigh ? 0 : 1;
  ledc_channel_config(&channelConfig);
}

// 配置 LEDC 定时器并把三路 LED 各绑定到自己的反相通道。开机、以及 PINTEST 结束后
// 恢复渲染前都调用，保证三个颜色通道都指向当前（可能被 SETPIN/PINTEST 改过的）引脚。
void configureAllLedChannels() {
  ledc_timer_config_t timerConfig = {};
  timerConfig.speed_mode = LED_PWM_MODE;
  timerConfig.duty_resolution = LED_PWM_RESOLUTION;
  timerConfig.timer_num = LED_PWM_TIMER;
  timerConfig.freq_hz = LED_PWM_FREQUENCY;
  timerConfig.clk_cfg = LEDC_AUTO_CLK;
  ledc_timer_config(&timerConfig);

  configureLedChannel(led_red, LED_CHANNEL_RED);
  configureLedChannel(led_yellow, LED_CHANNEL_YELLOW);
  configureLedChannel(led_green, LED_CHANNEL_GREEN);
}

// 向一路反相 LEDC 通道写入应用层亮度值（value：0=最亮，255=灭）。反相后 duty = PWM_MAX - value。
void writeLedChannel(ledc_channel_t channel, int value) {
  int duty = PWM_MAX - value;
  ledc_set_duty(LED_PWM_MODE, channel, duty);
  ledc_update_duty(LED_PWM_MODE, channel);
}

// 底层输出：把三色值写入各自的反相 LEDC 通道（反相逻辑，数值越小越亮）。
void setLights(int red, int yellow, int green) {
  writeLedChannel(LED_CHANNEL_RED, red);
  writeLedChannel(LED_CHANNEL_YELLOW, yellow);
  writeLedChannel(LED_CHANNEL_GREEN, green);
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

  if (cmd.startsWith("SETPOLARITY:")) {
    handleSetPolarityCommand(cmd);
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

  // 更新颜色→引脚映射，并把该颜色对应的反相 LEDC 通道重新绑定到新引脚（占空比 0=灭）。
  if (colorText == "R") {
    led_red = pin;
    prefs.putInt("pinRed", pin);
    configureLedChannel(pin, LED_CHANNEL_RED);
  } else if (colorText == "Y") {
    led_yellow = pin;
    prefs.putInt("pinYellow", pin);
    configureLedChannel(pin, LED_CHANNEL_YELLOW);
  } else if (colorText == "G") {
    led_green = pin;
    prefs.putInt("pinGreen", pin);
    configureLedChannel(pin, LED_CHANNEL_GREEN);
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
                   ",NAME=" + bleName +
                   ",POL=" + (ledActiveHigh ? "HIGH" : "LOW");
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
    driveTestPin(pinTestActivePin, false);
  }

  driveTestPin(pin, value == 1);
  pinTestActivePin = pin;
  pinTestDeadlineMs = millis() + PIN_TEST_TIMEOUT_MS;
}

// PINTEST 用纯数字 GPIO 点灯（不占用 LEDC 通道）：先 gpio_reset_pin 断开该引脚可能存在的
// LEDC 绑定（被测引脚可能正是某路 LED 的通道引脚），再按极性逻辑写电平。
void driveTestPin(int pin, bool on) {
  gpio_reset_pin((gpio_num_t)pin);
  pinMode(pin, OUTPUT);
  int onLevel = ledActiveHigh ? HIGH : LOW;
  int offLevel = ledActiveHigh ? LOW : HIGH;
  digitalWrite(pin, on ? onLevel : offLevel);
}

// PINTEST 序列超时后自动熄灭测试引脚，并恢复进入测试前的模式与灯光开关状态
void endPinTestIfExpired(unsigned long nowMs) {
  if (currentMode != MODE_PIN_TEST || nowMs < pinTestDeadlineMs) {
    return;
  }

  if (pinTestActivePin != -1) {
    driveTestPin(pinTestActivePin, false);
  }
  pinTestActivePin = -1;

  // 恢复三路 LED 的反相通道绑定：测试期间可能用 gpio_reset_pin 断开过某路 LED 引脚
  configureAllLedChannels();

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

// 切换 LED 接线极性（低电平点亮 / 高电平点亮），持久化到 NVS 并立即生效，无需重启：
// 重新配置三路 LEDC 通道的 output_invert 即可，同一份亮度/动画代码在两种极性下都正确
// （见 configureLedChannel 的注释）。
void handleSetPolarityCommand(String cmd) {
  // 格式：SETPOLARITY:<LOW|HIGH>
  String fields[1];
  if (!splitCommandFields(cmd, ':', fields, 1)) {
    setOtaStatus("SETPOLARITY failed: malformed command");
    return;
  }

  String valueText = fields[0];
  bool newActiveHigh;
  if (valueText == "HIGH") {
    newActiveHigh = true;
  } else if (valueText == "LOW") {
    newActiveHigh = false;
  } else {
    setOtaStatus("SETPOLARITY failed: unknown value " + valueText);
    return;
  }

  ledActiveHigh = newActiveHigh;
  prefs.putBool("ledActiveHigh", ledActiveHigh);
  configureAllLedChannels();
  setOtaStatus("SETPOLARITY ok: " + valueText);
}
