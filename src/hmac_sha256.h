// SHA-256 and HMAC-SHA256 (FIPS 180-4, RFC 2104), small and dependency free.
#pragma once
#include <stdint.h>
#include <stddef.h>

struct Sha256 {
  uint32_t h[8];
  uint8_t  buf[64];
  uint64_t bits;
  size_t   fill;
};

void sha256Init(Sha256 &s);
void sha256Update(Sha256 &s, const void *data, size_t n);
void sha256Final(Sha256 &s, uint8_t out[32]);

// out = HMAC-SHA256(key, message parts concatenated)
void hmacSha256(const uint8_t *key, size_t keyLen, const void *const *parts, const size_t *lens, int count, uint8_t out[32]);

// constant time compare of n bytes
bool equalCt(const uint8_t *a, const uint8_t *b, size_t n);
void toHex(const uint8_t *in, size_t n, char *out);   // out has room for 2n + 1
bool fromHex(const char *in, uint8_t *out, size_t n); // exactly 2n hex digits
