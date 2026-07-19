#include <Arduino_RouterBridge.h>
#include <Wire.h>

const int XSHUT_VL = 2;
const byte ADDR_VL  = 0x30;
const byte ADDR_MOD = 0x32;

bool ok[2] = {false, false};
int failStage[2] = {0, 0};
int lastId[2] = {0, 0};

const byte CONFIG_L1[] = {
  0x00,0x00,0x00,0x01,0x02,0x00,0x02,0x08,0x00,0x08,
  0x10,0x01,0x01,0x00,0x00,0x00,0x00,0xff,0x00,0x0F,
  0x00,0x00,0x00,0x00,0x00,0x20,0x0b,0x00,0x00,0x02,
  0x0a,0x21,0x00,0x00,0x05,0x00,0x00,0x00,0x00,0xc8,
  0x00,0x00,0x38,0xff,0x01,0x00,0x08,0x00,0x00,0x01,
  0xdb,0x0f,0x01,0xf1,0x0d,0x01,0x68,0x00,0x80,0x08,
  0xb8,0x00,0x00,0x00,0x00,0x0f,0x89,0x00,0x00,0x00,
  0x00,0x00,0x00,0x00,0x01,0x0f,0x0d,0x0e,0x0e,0x00,
  0x00,0x02,0xc7,0xff,0x9B,0x00,0x00,0x00,0x01,0x01,
  0x40
};

void wr8(byte addr, uint16_t reg, byte val) {
  Wire1.beginTransmission(addr);
  Wire1.write(reg >> 8); Wire1.write(reg & 0xFF);
  Wire1.write(val);
  Wire1.endTransmission();
}

int rd8(byte addr, uint16_t reg) {
  Wire1.beginTransmission(addr);
  Wire1.write(reg >> 8); Wire1.write(reg & 0xFF);
  if (Wire1.endTransmission(false) != 0) return -1;
  if (Wire1.requestFrom(addr, (byte)1) != 1) return -1;
  return Wire1.read();
}

int rd16(byte addr, uint16_t reg) {
  Wire1.beginTransmission(addr);
  Wire1.write(reg >> 8); Wire1.write(reg & 0xFF);
  if (Wire1.endTransmission(false) != 0) return -1;
  if (Wire1.requestFrom(addr, (byte)2) != 2) return -1;
  int hi = Wire1.read();
  int lo = Wire1.read();
  return (hi << 8) | lo;
}

// ---- the sequence that read 2619mm: start ranging, calibrate, NEVER stop ----
int initSensor(byte addr, int idx, bool isL4) {
  int id = 0;
  for (int t = 0; t < 10; t++) {
    id = rd16(addr, 0x010F);
    if (id == (isL4 ? 0xEBAA : 0xEACC)) break;
    delay(50);
  }
  lastId[idx] = id;
  if (id != (isL4 ? 0xEBAA : 0xEACC)) return 1;

  if (!isL4) {
    // soft reset (L1 only - the L4 resets on rename poorly, skip it)
    wr8(addr, 0x0000, 0x00);
    delay(10);
    wr8(addr, 0x0000, 0x01);
    delay(20);

    bool booted = false;
    for (int i = 0; i < 200; i++) {
      int v = rd8(addr, 0x00E5);
      if (v > 0 && (v & 0x01)) { booted = true; break; }
      delay(5);
    }
    if (!booted) return 2;
  } else {
    // L4CD: wait for firmware status 0x03, no reset
    bool booted = false;
    for (int i = 0; i < 300; i++) {
      int v = rd8(addr, 0x00E5);
      if (v == 0x03) { booted = true; break; }
      delay(5);
    }
    if (!booted) return 2;
  }

  for (uint16_t i = 0; i < sizeof(CONFIG_L1); i++) {
    wr8(addr, 0x002D + i, CONFIG_L1[i]);
  }
  delay(10);

  // start ranging
  wr8(addr, 0x0087, 0x40);

  bool ranged = false;
  for (int i = 0; i < 600; i++) {
    int v = rd8(addr, 0x0031);
    if (v >= 0 && (v & 0x01) == 0) { ranged = true; break; }
    delay(5);
  }
  if (!ranged) return 3;

  // clear interrupt + VHV writes - and DO NOT stop ranging
  wr8(addr, 0x0086, 0x01);
  wr8(addr, 0x0008, 0x09);
  wr8(addr, 0x000B, 0x00);
  delay(10);
  return 0;
}

int read_mm(int i) {
  if (i < 0 || i > 1 || !ok[i]) return -1;
  byte addr = (i == 0) ? ADDR_VL : ADDR_MOD;
  for (int t = 0; t < 100; t++) {
    int st = rd8(addr, 0x0031);
    if (st >= 0 && (st & 0x01) == 0) break;
    delay(2);
  }
  int mm = rd16(addr, 0x0096);
  wr8(addr, 0x0086, 0x01);
  if (mm < 0) return -1;
  return mm;
}

int status(int i) { return ok[i] ? 1 : 0; }
int stage(int i)  { return failStage[i]; }
int got_id(int i) { return lastId[i]; }

void setup() {
  Bridge.begin();
  Bridge.provide("read_mm", read_mm);
  Bridge.provide("status", status);
  Bridge.provide("stage", stage);
  Bridge.provide("got_id", got_id);

  pinMode(XSHUT_VL, OUTPUT);
  digitalWrite(XSHUT_VL, LOW);
  delay(300);

  Wire1.begin();
  Wire1.setClock(100000);
  delay(1000);

  // Modulino alone at 0x29 - park it
  wr8(0x29, 0x0001, ADDR_MOD);
  delay(200);

  // wake VL53L1X, init with the WORKING sequence, rename
  digitalWrite(XSHUT_VL, HIGH);
  delay(500);
  int r = initSensor(0x29, 0, false);
  failStage[0] = r;
  if (r == 0) {
    wr8(0x29, 0x0001, ADDR_VL);
    delay(50);
    ok[0] = true;
  }

  // Modulino with the same no-stop pattern
  int m = initSensor(ADDR_MOD, 1, true);
  failStage[1] = m;
  ok[1] = (m == 0);
}

void loop() {}