#ifndef OB_APS_AUTH_NONCE_H
#define OB_APS_AUTH_NONCE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* This diagnostic accepts one APNs nonce, not an HTTP signing payload. */
static inline bool ob_apns_nonce_valid(const uint8_t *data, size_t length, uint64_t now) {
    if (!data || length != 17 || data[0] != 0) return false;
    uint64_t stamp = 0;
    for (size_t i = 1; i < 9; ++i) stamp = (stamp << 8) | data[i];
    if (stamp == 0) return false;
    return (now >= stamp ? now - stamp : stamp - now) <= UINT64_C(30000);
}
#endif
