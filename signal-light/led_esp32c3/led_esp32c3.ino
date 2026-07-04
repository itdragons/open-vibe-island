#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Update.h>
#include <Preferences.h>
#include "config.h"


// ESP32-C3 Super Mini supports BLE, but not BluetoothSerial.
// Use the BLE device named C3_LED to control the lights and send firmware OTA.


Preferences prefs;

// Runtime pin assignment and BLE name — loaded from NVS in setup(), falling
// back to the config.h defaults on a fresh chip. Reassignable at runtime via
// SETPIN/SETNAME without reflashing.
int led_red = DEFAULT_LED_RED;
int led_yellow = DEFAULT_LED_YELLOW;
int led_green = DEFAULT_LED_GREEN;
String bleName;

bool lightOn = true;

// This LED wiring is inverted:
// 250 = default/text-command brightness, 255 = off.
const int LED_ON = 0; // 0 是全亮（低电平）
const int LED_DIM = 128; // 半亮
const int LED_OFF = 255; // 255 是全灭（高电平）
const int PWM_MIN = 0;
const int PWM_MAX = 255;

int redValue = LED_ON;
int yellowValue = LED_ON;
int greenValue = LED_ON;

enum LedMode {
  MODE_MANUAL,
  MODE_GREEN_BLINK,
  MODE_THINKING,
  MODE_WORKING,
  MODE_BUSY,
  MODE_SUCCESS,
  MODE_ERROR,
  MODE_ALARM,
  MODE_CUSTOM_EFFECT
};

LedMode currentMode = MODE_MANUAL;
unsigned long lastFrameMs = 0;
int frame = 0;

enum CustomEffectType {
  EFFECT_SOLID,
  EFFECT_BLINK,
  EFFECT_CYCLE,
  EFFECT_BREATHE
};

CustomEffectType customEffectType = EFFECT_SOLID;
int customEffectColors[3] = { -1, -1, -1 };
int customEffectColorCount = 0;
unsigned long customEffectIntervalMs = 0;

BLECharacteristic *otaControlCharacteristic = nullptr;

bool otaActive = false;
bool restartAfterOta = false;
size_t otaExpectedSize = UPDATE_SIZE_UNKNOWN;
size_t otaWrittenBytes = 0;
unsigned long restartAtMs = 0;

void handleCommand(String cmd);
void handleOtaControl(String cmd);
void handleOtaData(BLECharacteristic *characteristic);
void setOtaStatus(const String &message);
void startMode(LedMode mode);
bool isCommand(String cmd, String a, String b = "", String c = "", String d = "");
void handleEffectCommand(String cmd);
void animateCustomEffect(unsigned long nowMs);
void applyCustomEffectValue(int &red, int &yellow, int &green, int onValue, int activeIndex);
bool isSafeGpioPin(int pin);
void handleSetPinCommand(String cmd);
void sendConfigStatus();

class ServerCallback : public BLEServerCallbacks {
  void onDisconnect(BLEServer *server) {
    delay(100);
    server->startAdvertising();
  }
};

class LedCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String cmd = String(characteristic->getValue().c_str());
    handleCommand(cmd);
  }
};

class OtaControlCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String cmd = String(characteristic->getValue().c_str());
    handleOtaControl(cmd);
  }
};

class OtaDataCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    handleOtaData(characteristic);
  }
};

void setup() {
  Serial.begin(115200);
  // 对于 ESP32-C3，USB 串口需要一点时间在电脑上枚举
  unsigned long startWait = millis();
  while (!Serial && millis() - startWait < 3000) { delay(10); } 
  delay(500);

  Serial.println();
  Serial.println("============================");
  Serial.println("C3 LED starting...");

  prefs.begin("wglight", false);
  led_red = prefs.getInt("pinRed", DEFAULT_LED_RED);
  led_yellow = prefs.getInt("pinYellow", DEFAULT_LED_YELLOW);
  led_green = prefs.getInt("pinGreen", DEFAULT_LED_GREEN);
  bleName = prefs.getString("bleName", "");
  if (bleName.length() == 0) {
    uint64_t chipId = ESP.getEfuseMac();
    char suffix[5];
    snprintf(suffix, sizeof(suffix), "%04X", (uint16_t)(chipId & 0xFFFF));
    bleName = BLE_NAME_PREFIX + String(suffix);
    prefs.putString("bleName", bleName);
  }
  Serial.println("Pins -> R:" + String(led_red) + " Y:" + String(led_yellow) + " G:" + String(led_green));
  Serial.println("BLE name -> " + bleName);

  pinMode(led_green, OUTPUT);
  pinMode(led_red, OUTPUT);
  pinMode(led_yellow, OUTPUT);
  // No physical button configured

  showManualLights();

  BLEDevice::init(bleName.c_str());
  BLEDevice::setMTU(517);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallback());

  BLEService *service = server->createService(SERVICE_UUID);

  BLECharacteristic *commandCharacteristic = service->createCharacteristic(
    COMMAND_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  commandCharacteristic->setCallbacks(new LedCallback());

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

  BLECharacteristic *otaDataCharacteristic = service->createCharacteristic(
    OTA_DATA_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  otaDataCharacteristic->setCallbacks(new OtaDataCallback());

  BLECharacteristic *infoCharacteristic = service->createCharacteristic(
    INFO_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ
  );
  infoCharacteristic->setValue(FIRMWARE_VERSION.c_str());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->start();

  Serial.println("BLE ready.");
  Serial.println("Commands: OTA_BEGIN:<bytes>, OTA_END, OTA_ABORT, OTA_STATUS");
}

void loop() {
  if (restartAfterOta && millis() >= restartAtMs) {
    ESP.restart();
  }

  if (Serial.available() > 0) {
    String serialCmd = Serial.readStringUntil('\n');
    serialCmd.trim();
    if (serialCmd.length() > 0) {
      Serial.println(">>> 收到串口指令: " + serialCmd);
      handleCommand(serialCmd);
    }
  }

  // checkButton(); // removed

  if (!lightOn) {
    turnOffLights();
    return;
  }

  updateLights();
}

// checkButton logic removed as hardware has no button

void setLights(int red, int yellow, int green) {
  analogWrite(led_red, red);
  analogWrite(led_yellow, yellow);
  analogWrite(led_green, green);
}

void showManualLights() {
  setLights(redValue, yellowValue, greenValue);
}

void turnOffLights() {
  setLights(LED_OFF, LED_OFF, LED_OFF);
}

void startMode(LedMode mode) {
  lightOn = true;
  currentMode = mode;
  lastFrameMs = 0;
  frame = 0;
}

void updateLights() {
  unsigned long nowMs = millis();

  if (currentMode == MODE_MANUAL) {
    showManualLights();
  } else if (currentMode == MODE_GREEN_BLINK) {
    animateGreenBlink(nowMs);
  } else if (currentMode == MODE_THINKING) {
    animateThinking(nowMs);
  } else if (currentMode == MODE_WORKING) {
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
  }
}

void animateGreenBlink(unsigned long nowMs) {
  bool on = (nowMs / 600) % 2 == 0;
  setLights(LED_OFF, LED_OFF, on ? LED_ON : LED_OFF);
}

void animateThinking(unsigned long nowMs) {
  if (nowMs - lastFrameMs < 130) {
    return;
  }

  lastFrameMs = nowMs;
  frame = (frame + 1) % 3;

  if (frame == 0) {
    setLights(LED_ON, LED_DIM, LED_OFF);
  } else if (frame == 1) {
    setLights(LED_OFF, LED_ON, LED_DIM);
  } else {
    setLights(LED_DIM, LED_OFF, LED_ON);
  }
}

int breathValue(unsigned long nowMs, unsigned long periodMs) {
  unsigned long phase = nowMs % periodMs;

  if (phase < periodMs / 2) {
    return map(phase, 0, periodMs / 2, LED_OFF, LED_ON);
  }

  return map(phase, periodMs / 2, periodMs, LED_ON, LED_OFF);
}

void animateWorking(unsigned long nowMs) {
  int value = breathValue(nowMs, 2400);
  setLights(value, value, value);
}

void animateBusy(unsigned long nowMs) {
  bool on = (nowMs / 600) % 2 == 0;
  setLights(LED_OFF, on ? LED_ON : LED_OFF, LED_OFF);
}

void animateSuccess() {
  setLights(LED_OFF, LED_OFF, LED_ON);
}

void animateError(unsigned long nowMs) {
  bool on = (nowMs / 140) % 2 == 0;
  setLights(on ? LED_ON : LED_OFF, LED_OFF, LED_OFF);
}

void animateAlarm(unsigned long nowMs) {
  bool redOn = (nowMs / 180) % 2 == 0;
  setLights(redOn ? LED_ON : LED_OFF, redOn ? LED_OFF : LED_ON, LED_OFF);
}

void handleEffectCommand(String cmd) {
  // Format: EFFECT:<TYPE>:<COLORS>:<INTERVAL_MS>, e.g. EFFECT:CYCLE:RYG:200
  int firstColon = cmd.indexOf(':');
  int secondColon = cmd.indexOf(':', firstColon + 1);
  int thirdColon = cmd.indexOf(':', secondColon + 1);

  if (firstColon < 0 || secondColon < 0 || thirdColon < 0) {
    return;
  }

  String typeText = cmd.substring(firstColon + 1, secondColon);
  String colorsText = cmd.substring(secondColon + 1, thirdColon);
  String intervalText = cmd.substring(thirdColon + 1);

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

void animateCustomEffect(unsigned long nowMs) {
  if (customEffectColorCount == 0) {
    return;
  }

  int red = LED_OFF;
  int yellow = LED_OFF;
  int green = LED_OFF;

  if (customEffectType == EFFECT_SOLID) {
    applyCustomEffectValue(red, yellow, green, LED_ON, -1);
  } else if (customEffectType == EFFECT_BLINK) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    bool on = (nowMs / interval) % 2 == 0;
    applyCustomEffectValue(red, yellow, green, on ? LED_ON : LED_OFF, -1);
  } else if (customEffectType == EFFECT_CYCLE) {
    unsigned long interval = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int activeIndex = (int)((nowMs / interval) % customEffectColorCount);
    applyCustomEffectValue(red, yellow, green, LED_ON, activeIndex);
  } else if (customEffectType == EFFECT_BREATHE) {
    unsigned long period = customEffectIntervalMs == 0 ? 1 : customEffectIntervalMs;
    int value = breathValue(nowMs, period);
    applyCustomEffectValue(red, yellow, green, value, -1);
  }

  setLights(red, yellow, green);
}

void handleCommand(String cmd) {
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

  if (isCommand(cmd, "GREEN_BLINK", "GREENBLINK", "BLINK", "GBLINK")) {
    lightOn = true;
    startMode(MODE_GREEN_BLINK);
    return;
  }

  if (isCommand(cmd, "THINKING", "THINK", "ANALYSIS")) {
    startMode(MODE_THINKING);
    return;
  }

  if (isCommand(cmd, "WORKING", "AI", "GENERATING", "GENERATE")) {
    startMode(MODE_WORKING);
    return;
  }

  if (isCommand(cmd, "BUSY", "COMMAND", "EXECUTING")) {
    startMode(MODE_BUSY);
    return;
  }

  if (isCommand(cmd, "SUCCESS", "OK", "DONE")) {
    startMode(MODE_SUCCESS);
    return;
  }

  if (isCommand(cmd, "ERROR", "FAILED", "FAIL")) {
    startMode(MODE_ERROR);
    return;
  }

  if (isCommand(cmd, "ALARM", "BLOCKED", "CRITICAL")) {
    startMode(MODE_ALARM);
    return;
  }

  if (isCommand(cmd, "OFF", "CLOSE", "IDLE")) {
    lightOn = false;
    turnOffLights();
    return;
  }

  if (cmd == "BLE") {
    Serial.println("Bluetooth Name: " + bleName);
    return;
  }

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

void handleOtaControl(String cmd) {
  cmd.trim();

  String upper = cmd;
  upper.toUpperCase();

  if (upper.startsWith("OTA_BEGIN") || upper.startsWith("OTA_START")) {
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
    restartAtMs = millis() + 3000;
    return;
  }

  if (upper == "OTA_ABORT" || upper == "OTA_CANCEL") {
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

void setOtaStatus(const String &message) {
  Serial.println(message);

  if (otaControlCharacteristic != nullptr) {
    otaControlCharacteristic->setValue(message.c_str());
    otaControlCharacteristic->notify();
  }
}

bool isCommand(String cmd, String a, String b, String c, String d) {
  return cmd == a || cmd == b || cmd == c || cmd == d;
}

bool isSafeGpioPin(int pin) {
  for (int i = 0; i < SAFE_GPIO_PIN_COUNT; i++) {
    if (SAFE_GPIO_PINS[i] == pin) {
      return true;
    }
  }
  return false;
}

void handleSetPinCommand(String cmd) {
  // Format: SETPIN:<R|Y|G>:<pin>, e.g. SETPIN:R:10
  int firstColon = cmd.indexOf(':');
  int secondColon = cmd.indexOf(':', firstColon + 1);
  if (firstColon < 0 || secondColon < 0) {
    setOtaStatus("SETPIN failed: malformed command");
    return;
  }

  String colorText = cmd.substring(firstColon + 1, secondColon);
  int pin = cmd.substring(secondColon + 1).toInt();

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

void sendConfigStatus() {
  String status = "CONFIG:R=" + String(led_red) +
                   ",Y=" + String(led_yellow) +
                   ",G=" + String(led_green) +
                   ",NAME=" + bleName;
  setOtaStatus(status);
}
