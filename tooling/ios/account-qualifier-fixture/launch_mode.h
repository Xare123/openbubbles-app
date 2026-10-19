#ifndef OB_QUALIFIER_LAUNCH_MODE_H
#define OB_QUALIFIER_LAUNCH_MODE_H

#include <string.h>

/* Main-thread lifecycle state only. The flag is not account authorization and
 * never supplies a body, nonce, endpoint, credential, or signing parameter.
 */
typedef struct {
    int auto_requested;
    int first_activation_seen;
    int cancelled;
} OBFixtureLaunchMode;

static OBFixtureLaunchMode OBFixtureLaunchModeFromArguments(int argc, const char *const *argv) {
    OBFixtureLaunchMode mode = {0};
    mode.auto_requested = argc == 2 && argv && argv[0] && argv[1]
        && strcmp(argv[1], "--ob-usb-transport-once-v1") == 0;
    return mode;
}

static int OBFixtureAutoArmOnFirstActive(OBFixtureLaunchMode *mode) {
    if (!mode || mode->first_activation_seen) return 0;
    mode->first_activation_seen = 1;
    return mode->auto_requested && !mode->cancelled;
}

static void OBFixtureLaunchResignedActive(OBFixtureLaunchMode *mode) {
    if (mode) mode->cancelled = 1;
}

#endif
