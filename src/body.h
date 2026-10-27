// Expression engine: ears, head, tail and cheek lights. Runs with or without
// servos (PCA9685 on the Arduino-header I2C1 bus), so the app and the agent
// can drive the body before it is built.
#pragma once
#include <stdint.h>
#include <stddef.h>

void bodyBegin();                       // detect the servo driver, start at neutral
void bodyTick();                        // call often; eases joints, plays gestures, writes servos
bool bodyHasServos();

// reflex inputs
void bodyOnSound(float dir, bool loud); // dir -1..1; loud = something is audible now
void bodyOnClap(float dir);
void bodyOnKnock();
void bodyOnPresence(bool present);

// commands
bool bodyExpress(const char *mood);     // false if unknown mood
bool bodyGesture(const char *name);
void bodyLookAt(float pan, float tilt, uint32_t holdMs);
void bodyCheek(uint32_t rgb);

// calibration (stored in flash). joints: 0 ear_l, 1 ear_r, 2 pan, 3 tilt, 4 tail
bool bodyServoRaw(int channel, int microseconds);     // drive one PCA9685 channel directly for 15 s (0 = release)
bool bodyTrim(int joint, int offsetUs, bool invert);  // centre offset and direction for a joint, saved
size_t bodyCalibJson(char *dst, size_t n);            // {"servos":..,"trim":[..],"invert":[..],"cheek_invert":..}
void bodyCheekInvert(bool inverted);                  // common-anode LEDs

// output
size_t bodyJson(char *dst, size_t n);   // {"ear_l":..,...,"servos":..} without braces' outer type
bool   bodyTakeChange(char *why, size_t n); // true once per mood/gesture/look change
