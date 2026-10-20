#ifndef OB_QUALIFIER_LOOPBACK_LISTENER_H
#define OB_QUALIFIER_LOOPBACK_LISTENER_H

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { OBFixtureLoopbackPort = 49173 };

/* One fixed local listener. REUSEADDR permits a new process after TCP teardown;
 * REUSEPORT is deliberately absent, so a second live listener still fails.
 * No endpoint, port, account data or signing payload is supplied by a caller.
 */
static int OBFixtureOpenLoopbackListener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    int reuse = 1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(OBFixtureLoopbackPort);
    int flags = fcntl(fd, F_GETFL, 0);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0
        || inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1
        || flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0
        || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0
        || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0
        || listen(fd, 1) != 0) {
        int failure = errno;
        close(fd);
        errno = failure;
        return -1;
    }
    return fd;
}

#endif
