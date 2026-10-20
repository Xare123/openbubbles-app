/* USB qualification only. Runtime owner binding and a bounded lifetime.
 * Included by the actual manager and the native Mac regression executable. */
#pragma once
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static dispatch_source_t obUSBOwnerSource;
static dispatch_source_t obUSBDeadlineSource;
static bool obUSBStopped;

static void OBUSBCancelLifetime(void) {
    if (obUSBOwnerSource) dispatch_source_cancel(obUSBOwnerSource);
    if (obUSBDeadlineSource) dispatch_source_cancel(obUSBDeadlineSource);
    obUSBOwnerSource = NULL;
    obUSBDeadlineSource = NULL;
}

static bool OBUSBReadOwner(pid_t owner, const char *expectedPath, struct proc_bsdinfo *identity) {
    if (owner <= 1 || getppid() != owner || !expectedPath || expectedPath[0] != '/') return false;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    char actual[PATH_MAX] = {0}, expected[PATH_MAX] = {0};
    if (proc_pidpath(owner, path, sizeof(path)) <= 0 ||
        !realpath(path, actual) || !realpath(expectedPath, expected) || strcmp(actual, expected) != 0) return false;
    memset(identity, 0, sizeof(*identity));
    return proc_pidinfo(owner, PROC_PIDTBSDINFO, 0, identity, sizeof(*identity)) == (int)sizeof(*identity) &&
        identity->pbi_pid == (uint32_t)owner && identity->pbi_start_tvsec > 0 && getppid() == owner;
}

static bool OBUSBStartLifetime(pid_t owner, const char *expectedPath, uint64_t duration,
                               void (^stopped)(bool ownerExited)) {
    if (obUSBOwnerSource || obUSBDeadlineSource || !stopped || !duration ||
        duration > 600ULL * NSEC_PER_SEC) return false;
    struct proc_bsdinfo before, after;
    if (!OBUSBReadOwner(owner, expectedPath, &before)) return false;
    obUSBOwnerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)owner,
        DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    obUSBDeadlineSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // Suspended dispatch objects must be resumed before they can be released.
    if (!obUSBOwnerSource || !obUSBDeadlineSource) {
        if (obUSBOwnerSource) dispatch_resume(obUSBOwnerSource);
        if (obUSBDeadlineSource) dispatch_resume(obUSBDeadlineSource);
        OBUSBCancelLifetime();
        return false;
    }
    obUSBStopped = false;
    dispatch_source_set_event_handler(obUSBOwnerSource, ^{
        if (obUSBStopped) return;
        obUSBStopped = true;
        OBUSBCancelLifetime();
        stopped(true);
    });
    dispatch_source_set_event_handler(obUSBDeadlineSource, ^{
        if (obUSBStopped) return;
        obUSBStopped = true;
        OBUSBCancelLifetime();
        stopped(false);
    });
    dispatch_source_set_timer(obUSBDeadlineSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)duration),
        DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    dispatch_resume(obUSBOwnerSource);
    dispatch_resume(obUSBDeadlineSource);
    // Reject an exit/PID reuse between identity capture and kernel registration.
    if (!OBUSBReadOwner(owner, expectedPath, &after) || before.pbi_start_tvsec != after.pbi_start_tvsec ||
        before.pbi_start_tvusec != after.pbi_start_tvusec) {
        OBUSBCancelLifetime();
        return false;
    }
    return true;
}
