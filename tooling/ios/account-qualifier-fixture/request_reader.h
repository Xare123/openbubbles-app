#ifndef OB_QUALIFIER_REQUEST_READER_H
#define OB_QUALIFIER_REQUEST_READER_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>

enum { OBFixtureRequestBytes = 41 };
typedef int (*OBFixtureRequestActive)(double deadline, void *context);
typedef int (*OBFixtureRequestWait)(int fd, double deadline, void *context);

/* The only request is a fixed nonce frame, never a body or signing payload.
 * A complete frame does not require EOF. Reject trailing bytes already queued;
 * later bytes cannot be excluded without EOF and are never read as another request.
 * Both recv calls are nonblocking; the caller supplies deadline/cancellation waits.
 */
static int OBFixtureReadRequest(int fd, const char *run_id, double deadline,
                                OBFixtureRequestWait wait_readable,
                                OBFixtureRequestActive active, void *context) {
    if (!run_id || !wait_readable || !active || strnlen(run_id, 33) != 32) return 0;
    for (size_t i = 0; i < 32; ++i) {
        if (!((run_id[i] >= '0' && run_id[i] <= '9')
              || (run_id[i] >= 'a' && run_id[i] <= 'f'))) return 0;
    }
    uint8_t expected[OBFixtureRequestBytes], bytes[OBFixtureRequestBytes];
    memcpy(expected, "OBQUAL2:", 8);
    memcpy(expected + 8, run_id, 32);
    expected[40] = '\n';
    size_t used = 0;
    while (used < sizeof(bytes)) {
        if (!active(deadline, context) || !wait_readable(fd, deadline, context)) return 0;
        ssize_t count = recv(fd, bytes + used, sizeof(bytes) - used, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return 0; /* Truncated frame, including premature EOF. */
        used += (size_t)count;
    }
    if (!active(deadline, context) || memcmp(bytes, expected, sizeof(bytes)) != 0) return 0;
    for (;;) {
        if (!active(deadline, context)) return 0;
        uint8_t trailing;
        ssize_t count = recv(fd, &trailing, 1, MSG_PEEK | MSG_DONTWAIT);
        if (count > 0) return 0;
        if (count < 0 && errno == EINTR) continue;
        if (count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            return active(deadline, context);
        }
        return 0;
    }
}

#endif
