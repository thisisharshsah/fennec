// bedsense v0.1
// Streams raw accelerometer + gyroscope samples from the on-board LSM6DSL
// over the ST-LINK virtual serial port, one CSV line per sample.
//
// Board : ST B-L475E-IOT01A (STM32L475VG IoT Discovery kit; see platformio.ini for why not the L4S5 target)
// Bus   : I2C2 on PB11 (SDA) / PB10 (SCL), the internal sensor bus
// Rate  : 104 Hz, accel +/-2 g (0.061 mg per count), gyro +/-500 dps (17.5 mdps per count)
//
// Line format:  t_ms,ax,ay,az,gx,gy,gz      (all raw signed 16-bit counts)
// Lines starting with '#' are status messages, "#MARK" is sent when the blue
// user button is pressed (handy for ground truth when the board is reachable).

#include <Arduino.h>
#include <Wire.h>
#include <LSM6DSLSensor.h>

static const uint32_t BAUD      = 115200;
static const float    ODR_HZ    = 104.0f;
static const uint32_t PERIOD_US = 9615;      // 1e6 / 104

TwoWire dev_i2c(PB11, PB10);                 // internal sensor bus (I2C2)

// The IoT node wires SA0 low (address 0xD4); probe both to be safe.
LSM6DSLSensor imuLow(&dev_i2c, LSM6DSL_ACC_GYRO_I2C_ADDRESS_LOW);
LSM6DSLSensor imuHigh(&dev_i2c, LSM6DSL_ACC_GYRO_I2C_ADDRESS_HIGH);
LSM6DSLSensor *imu = nullptr;

static bool probe(LSM6DSLSensor &s)
{
  uint8_t id = 0;
  s.begin();
  s.ReadID(&id);
  return id == 0x6A;                         // LSM6DSL WHO_AM_I
}

static int btnIdle = -1;

static void leds(bool a, bool b)
{
#ifdef LED_BUILTIN
  digitalWrite(LED_BUILTIN, a ? HIGH : LOW);
#endif
#ifdef LED2
  digitalWrite(LED2, b ? HIGH : LOW);
#endif
}

static void i2cScan()
{
  Serial.print("# i2c scan:");
  for (uint8_t addr = 0x08; addr < 0x78; addr++) {
    dev_i2c.beginTransmission(addr);
    if (dev_i2c.endTransmission() == 0) {
      Serial.print(" 0x");
      Serial.print(addr, HEX);
    }
  }
  Serial.println();
}

void setup()
{
  // LEDs first: a boot flash proves the core and clock are running
#ifdef LED_BUILTIN
  pinMode(LED_BUILTIN, OUTPUT);                // LD1 (PA5)
#endif
#ifdef LED2
  pinMode(LED2, OUTPUT);                       // LD2 (PB14)
#endif
  for (int i = 0; i < 6; i++) { leds(i & 1, !(i & 1)); delay(120); }
  leds(false, false);

  Serial.begin(BAUD);
  delay(300);
  Serial.println("# boot");

#ifdef USER_BTN
  pinMode(USER_BTN, INPUT);
  btnIdle = digitalRead(USER_BTN);
#endif

  dev_i2c.begin();
  dev_i2c.setClock(400000);
  delay(100);
  Serial.println("# i2c2 up (PB11 sda / PB10 scl)");

  Serial.println("# probe lsm6dsl at 0xD4");
  if (probe(imuLow)) {
    imu = &imuLow;
  } else {
    Serial.println("# probe lsm6dsl at 0xD6");
    if (probe(imuHigh)) imu = &imuHigh;
  }

  if (imu == nullptr) {
    while (true) {                             // fast LD2 blink = IMU not found
      Serial.println("# ERROR: LSM6DSL not found on I2C2 (PB11/PB10)");
      i2cScan();
      for (int i = 0; i < 10; i++) { leds(false, i & 1); delay(100); }
    }
  }
  Serial.println("# lsm6dsl found");

  imu->Set_X_FS(2.0f);
  imu->Set_G_FS(500.0f);
  imu->Enable_X();
  imu->Enable_G();
  imu->Set_X_ODR(ODR_HZ);
  imu->Set_G_ODR(ODR_HZ);

  Serial.println("# bedsense v0.1");
  Serial.print("# lsm6dsl at 0x");
  Serial.println(imu == &imuLow ? "D4" : "D6");
  Serial.println("# fs_xl=2g (0.061 mg/LSB)  fs_g=500dps (17.5 mdps/LSB)  odr=104Hz");
  Serial.println("t_ms,ax,ay,az,gx,gy,gz");
}

void loop()
{
  static uint32_t next_us   = micros();
  static uint32_t lastBlink = 0;
  static uint32_t lastBtn   = 0;

  if ((int32_t)(micros() - next_us) < 0) return;   // wait for the next slot
  next_us += PERIOD_US;

  int16_t a[3], g[3];
  imu->Get_X_AxesRaw(a);
  imu->Get_G_AxesRaw(g);

  char line[64];
  snprintf(line, sizeof line, "%lu,%d,%d,%d,%d,%d,%d",
           (unsigned long)millis(), a[0], a[1], a[2], g[0], g[1], g[2]);
  Serial.println(line);

  uint32_t now = millis();
  if (now - lastBlink >= 1000) {              // 1 Hz heartbeat on both user LEDs
    lastBlink = now;
#ifdef LED_BUILTIN
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
#endif
#ifdef LED2
    digitalWrite(LED2, !digitalRead(LED2));
#endif
  }
#ifdef USER_BTN
  if (btnIdle >= 0 && digitalRead(USER_BTN) != btnIdle && now - lastBtn > 300) {
    lastBtn = now;
    Serial.println("#MARK");
  }
#endif
}
