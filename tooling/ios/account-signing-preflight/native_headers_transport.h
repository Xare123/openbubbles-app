#ifndef OB_NATIVE_HEADERS_TRANSPORT_H
#define OB_NATIVE_HEADERS_TRANSPORT_H
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { OBNativeHeadersPort = 49174, OBNativeHeadersRequestBytes = 41 };
typedef int (*OBNativeHeadersActive)(double deadline, void *context);
typedef int (*OBNativeHeadersWait)(int fd, double deadline, void *context);

static int OBNativeHeadersListen(void) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    int enabled = 1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(OBNativeHeadersPort);
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0
        || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0
        || setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0
        || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0
        || listen(fd, 1) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

/* Exactly one nonce, not a URL, body, account, credential or signing command.
 * A full frame need not EOF. Later input can never become a second request.
 */
static int OBNativeHeadersReadRequest(int fd, char nonce[33], double deadline,
        OBNativeHeadersWait wait_readable, OBNativeHeadersActive active, void *context) {
    if (!nonce || !wait_readable || !active) return 0;
    memset(nonce, 0, 33);
    uint8_t bytes[OBNativeHeadersRequestBytes];
    size_t used = 0;
    while (used < sizeof(bytes)) {
        if (!active(deadline, context) || !wait_readable(fd, deadline, context)) return 0;
        ssize_t count = recv(fd, bytes + used, sizeof(bytes) - used, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return 0;
        used += (size_t)count;
    }
    if (!active(deadline, context) || memcmp(bytes, "OBHDRS1:", 8) != 0 || bytes[40] != '\n') return 0;
    for (size_t i = 8; i < 40; ++i) {
        if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'a' && bytes[i] <= 'f'))) return 0;
    }
    for (;;) {
        if (!active(deadline, context)) return 0;
        uint8_t extra;
        ssize_t count = recv(fd, &extra, 1, MSG_PEEK | MSG_DONTWAIT);
        if (count > 0) return 0;
        if (count < 0 && errno == EINTR) continue;
        if (count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) break;
        return 0;
    }
    if (!active(deadline, context)) return 0;
    memcpy(nonce, bytes + 8, 32);
    return 1;
}
#endif
