#include <Arduino_RouterBridge.h>
#include <Wire.h>
#include <VL53L1X.h>

const int XSHUT[2] = {2, 3};
const byte NEW_ADDR[2] = {0x30, 0x31};

VL53L1X sensors[2];
bool ok[2] = {false, false};

int read_mm(int i) {
  if (i < 0 || i > 1 || !ok[i]) return -1;
  int mm = sensors[i].read();
  if (sensors[i].timeoutOccurred() || mm <= 0) return -1;
  return mm;
}

int status(int i) { return ok[i] ? 1 : 0; }

void setup() {
  for (int i = 0; i < 2; i++) {
    pinMode(XSHUT[i], OUTPUT);
    digitalWrite(XSHUT[i], LOW);
  }
  delay(300);

  Wire1.begin();
  Wire1.setClock(100000);
  delay(100);

  for (int i = 0; i < 2; i++) {
    digitalWrite(XSHUT[i], HIGH);
    delay(500);

    sensors[i].setBus(&Wire1);
    sensors[i].setTimeout(1000);

    if (sensors[i].init()) {
      sensors[i].setAddress(NEW_ADDR[i]);
      delay(50);
      sensors[i].setDistanceMode(VL53L1X::Long);
      sensors[i].setMeasurementTimingBudget(50000);
      sensors[i].startContinuous(50);
      ok[i] = true;
    }
    delay(200);
  }

  Bridge.begin();
  Bridge.provide("read_mm", read_mm);
  Bridge.provide("status", status);
}

void loop() {}