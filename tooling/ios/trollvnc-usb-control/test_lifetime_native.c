/* Real Darwin dispatch/process lifecycle checks. No iPhone, sockets or account. */
#include "USBSessionLifetime.h"
#include <stdio.h>
#include <sys/wait.h>

int main(int argc, const char *argv[]) {
    if (argc != 2) return 90;
    int ready[2];
    if (pipe(ready) != 0) return 91;
    pid_t child = fork();
    if (child < 0) return 92;
    if (child > 0) {
        close(ready[1]);
        char admission = 0;
        if (read(ready[0], &admission, 1) != 1 || admission != 'R') return 93;
        close(ready[0]);
        if (strcmp(argv[1], "owner-exit") == 0) return 0;
        int status = 0;
        if (waitpid(child, &status, 0) != child) return 94;
        return WIFEXITED(status) ? WEXITSTATUS(status) : 95;
    }
    close(ready[0]);
    bool ownerExit = strcmp(argv[1], "owner-exit") == 0;
    bool cancel = strcmp(argv[1], "cancel") == 0;
    bool reject = strncmp(argv[1], "reject-", 7) == 0;
    pid_t owner = strcmp(argv[1], "reject-pid") == 0 ? getpid() : getppid();
    const char *path = strcmp(argv[1], "reject-path") == 0 ? "/bin/sh" : argv[0];
    uint64_t duration = strcmp(argv[1], "reject-zero") == 0 ? 0 :
        strcmp(argv[1], "reject-limit") == 0 ? 601ULL * NSEC_PER_SEC :
        ownerExit ? 2ULL * NSEC_PER_SEC : 100ULL * NSEC_PER_MSEC;
    bool started = OBUSBStartLifetime(owner, path, duration, ^(bool exited) {
        if (cancel || !obUSBStopped || obUSBOwnerSource || obUSBDeadlineSource || exited != ownerExit) _exit(80);
        puts(exited ? "owner-exit-passed" : "deadline-passed");
        fflush(stdout);
        _exit(0);
    });
    if (write(ready[1], "R", 1) != 1) _exit(96);
    close(ready[1]);
    if (reject) {
        if (started || obUSBOwnerSource || obUSBDeadlineSource) _exit(81);
        puts("rejected-before-watch-passed");
        fflush(stdout);
        _exit(0);
    }
    if (!started) _exit(82);
    if (strcmp(argv[1], "duplicate") == 0 &&
        OBUSBStartLifetime(owner, path, duration, ^(bool unused) { (void)unused; })) _exit(83);
    if (cancel) {
        OBUSBCancelLifetime();
        if (obUSBOwnerSource || obUSBDeadlineSource) _exit(84);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            puts("cancel-passed");
            fflush(stdout);
            _exit(0);
        });
    }
    dispatch_main();
}
