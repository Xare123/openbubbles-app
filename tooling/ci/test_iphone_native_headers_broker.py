"""Source guards and Mac-only real C transport tests. No iPhone/AuthKit/account calls."""
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "tooling/ios/account-signing-preflight"


def without_comments(source):
    # Keep string/character literals, including URLs, while excluding comments.
    tokens = r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/'
    return re.sub(tokens, lambda match: "" if match[0].startswith(("//", "/*")) else match[0], source)


def method_source(source, signature):
    return source.split(signature + " {", 1)[1].split("\n}\n", 1)[0]


# Compile the app's actual shared header, not a Python translation of its parser.
# The only network sockets here are the actual fixed localhost listener tests;
# reader cases use AF_UNIX socketpair. All request values are synthetic nonces.
C_HARNESS = r'''
#include "native_headers_transport.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

struct controls {
    int cancelled;
    int fail_wait;
    int waits;
    int feed_fd;
    const char *feed;
    size_t feed_size;
    double cancel_at;
};

static double now_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static int active(double deadline, void *context) {
    struct controls *control = context;
    double now = now_seconds();
    return !control->cancelled && now < deadline
        && (!control->cancel_at || now < control->cancel_at);
}

static int wait_readable(int fd, double deadline, void *context) {
    struct controls *control = context;
    if (control->fail_wait) return 0;
    if (++control->waits == 2 && control->feed_size) {
        if (send(control->feed_fd, control->feed, control->feed_size, 0)
            != (ssize_t)control->feed_size) return 0;
        control->feed_size = 0;
    }
    while (active(deadline, context)) {
        struct pollfd item = {.fd = fd, .events = POLLIN, .revents = 0};
        int result = poll(&item, 1, 10);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (item.revents & (POLLERR | POLLNVAL))) return 0;
        if (result > 0 && (item.revents & (POLLIN | POLLHUP))) return 1;
    }
    return 0;
}

static int reader_case(const char *mode) {
    const char frame[] = "OBHDRS1:0123456789abcdef0123456789abcdef\n";
    char queued[sizeof(frame) * 2], nonce[33];
    memset(nonce, 0xa5, sizeof(nonce));
    memcpy(queued, frame, sizeof(frame) - 1);
    size_t length = sizeof(frame) - 1;
    int pair[2], expected = 0, half_close = 0;
    struct controls control = {0};
    if (OBNativeHeadersRequestBytes != 41 || length != 41) return 10;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 11;
    if (!strcmp(mode, "open")) expected = 1;
    else if (!strcmp(mode, "alternate-nonce")) {
        memset(queued + 8, 'f', 32); expected = 1;
    } else if (!strcmp(mode, "fragmented")) {
        length = 9; expected = 1;
        control.feed_fd = pair[1]; control.feed = frame + length;
        control.feed_size = sizeof(frame) - 1 - length;
    } else if (!strcmp(mode, "bad-magic")) queued[6] = '0';
    else if (!strcmp(mode, "uppercase")) queued[8] = 'A';
    else if (!strcmp(mode, "nonhex")) queued[8] = 'g';
    else if (!strcmp(mode, "nul-nonce")) queued[8] = '\0';
    else if (!strcmp(mode, "nonascii")) queued[8] = (char)0xff;
    else if (!strcmp(mode, "bad-newline")) queued[40] = '\r';
    else if (!strcmp(mode, "nul-newline")) queued[40] = '\0';
    else if (!strcmp(mode, "truncated-open")) --length;
    else if (!strcmp(mode, "truncated-eof")) { --length; half_close = 1; }
    else if (!strcmp(mode, "empty-eof")) { length = 0; half_close = 1; }
    else if (!strcmp(mode, "queued-byte")) queued[length++] = 'x';
    else if (!strcmp(mode, "queued-frame")) {
        memcpy(queued + length, frame, length); length *= 2;
    } else if (!strcmp(mode, "cancelled")) control.cancelled = 1;
    else if (!strcmp(mode, "cancel-during")) {
        --length; control.cancel_at = now_seconds() + 0.02;
    } else if (!strcmp(mode, "expired")) { /* Set deadline below. */ }
    else if (!strcmp(mode, "wait-failed")) control.fail_wait = 1;
    else { close(pair[0]); close(pair[1]); return 12; }

    int result = 0;
    if (length && send(pair[1], queued, length, 0) != (ssize_t)length) result = 13;
    if (!result && half_close && shutdown(pair[1], SHUT_WR) != 0) result = 14;
    double started = now_seconds();
    double deadline = started + (!strcmp(mode, "expired") ? -0.01 : 0.15);
    if (!result && OBNativeHeadersReadRequest(pair[0], nonce, deadline,
            wait_readable, active, &control) != expected) result = 15;
    if (!result && expected) {
        if (nonce[32] != '\0' || memcmp(nonce, queued + 8, 32) != 0) result = 16;
        /* A complete frame returned while the writer remains OPEN. Later bytes
         * are not another operation; this test does not claim to exclude them. */
        if (!result && send(pair[1], "x", 1, 0) != 1) result = 17;
        if (!result && !strcmp(mode, "fragmented") && control.feed_size) result = 18;
    }
    if (!result && now_seconds() - started > 1.0) result = 19;
    close(pair[0]); close(pair[1]);
    return result;
}

static int listener_case(int rebind) {
    for (int round = 0; round < (rebind ? 4 : 1); ++round) {
        int listener = OBNativeHeadersListen();
        if (listener < 0) return 30;
        int result = 0, reuse = 0, client = -1, peer = -1;
        socklen_t size = sizeof(reuse), address_size = sizeof(struct sockaddr_in);
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        /* Darwin enabled socket options need only be nonzero, not literal 1. */
        if (getsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, &size) != 0 || !reuse
            || getsockname(listener, (struct sockaddr *)&address, &address_size) != 0
            || address.sin_family != AF_INET
            || address.sin_addr.s_addr != htonl(INADDR_LOOPBACK)
            || ntohs(address.sin_port) != 49174 || OBNativeHeadersPort != 49174
            || fcntl(listener, F_GETFL, 0) < 0 || !(fcntl(listener, F_GETFL, 0) & O_NONBLOCK)
            || fcntl(listener, F_GETFD, 0) < 0 || !(fcntl(listener, F_GETFD, 0) & FD_CLOEXEC)) result = 31;
#ifdef SO_REUSEPORT
        int reuse_port = 0;
        size = sizeof(reuse_port);
        if (getsockopt(listener, SOL_SOCKET, SO_REUSEPORT, &reuse_port, &size) != 0 || reuse_port) result = 32;
#endif
        errno = 0;
        int second = OBNativeHeadersListen();
        int second_errno = errno;
        if (second >= 0) { close(second); result = 33; }
        else if (second_errno != EADDRINUSE) result = 38;
        if (!result && rebind) {
            client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
            if (client < 0 || setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout))
                || setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout))
                || connect(client, (struct sockaddr *)&address, sizeof(address))) result = 34;
            if (!result && (peer = accept(listener, NULL, NULL)) < 0) result = 35;
            close(listener); listener = -1;
            char byte;
            /* Actual TCP teardown, with the server actively closing first. */
            if (!result && (shutdown(peer, SHUT_WR) || recv(client, &byte, 1, 0) != 0
                || shutdown(client, SHUT_WR))) result = 36;
            if (!result) {
                struct pollfd item = {.fd = peer, .events = POLLIN, .revents = 0};
                if (poll(&item, 1, 1000) <= 0 || recv(peer, &byte, 1, MSG_DONTWAIT) != 0) result = 37;
            }
        }
        if (peer >= 0) close(peer);
        if (client >= 0) close(client);
        if (listener >= 0) close(listener);
        if (result) return result;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    signal(SIGPIPE, SIG_IGN);
    int result;
    if (!strcmp(argv[1], "listener-exclusive")) result = listener_case(0);
    else if (!strcmp(argv[1], "listener-rebind")) result = listener_case(1);
    else result = reader_case(argv[1]);
    if (result) fprintf(stderr, "synthetic transport case %s failed: %d\n", argv[1], result);
    return result;
}
'''


class NativeHeadersSourceGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Missing parent sources fail closed when this module is used as a CI gate.
        cls.main = (DIRECTORY / "main.m").read_text()
        cls.transport = (DIRECTORY / "native_headers_transport.h").read_text()
        cls.broker = (DIRECTORY / "native_headers_broker.h").read_text()

    def test_bundle_version_and_exact_entitlements_do_not_expand(self):
        info = plistlib.loads((DIRECTORY / "Info.plist").read_bytes())
        entitlements = plistlib.loads((DIRECTORY / "entitlements.plist").read_bytes())
        bundle = "dev.openbubbles.diagnostics.accountsigning"
        self.assertEqual(info["CFBundleIdentifier"], bundle)
        self.assertEqual(info["CFBundleExecutable"], "OBAccountSigningProbe")
        self.assertEqual(info["CFBundleVersion"], "3")
        self.assertNotIn("CFBundleURLTypes", info)
        self.assertNotIn("NSAppTransportSecurity", info)
        self.assertEqual(set(entitlements), {"application-identifier", "keychain-access-groups",
            "com.apple.private.MobileGestalt.AllowedProtectedKeys", "abs-client", "com.apple.authkit.client.private"})
        self.assertEqual(entitlements["application-identifier"], bundle)
        self.assertEqual(entitlements["keychain-access-groups"], [bundle])
        self.assertEqual(entitlements["abs-client"], 772496756)
        self.assertIs(entitlements["com.apple.authkit.client.private"], True)
        self.assertEqual(entitlements["com.apple.private.MobileGestalt.AllowedProtectedKeys"],
                         ["SerialNumber", "UniqueDeviceID"])

    def test_usb_mode_is_exact_singleton_and_existing_modes_remain(self):
        entry = self.main.split("int main(int argc, char **argv)", 1)[1]
        expression = re.search(r'\b\w+\s*=\s*([^;]*"--ob-native-authkit-usb-once-v1"[^;]*);', entry)
        self.assertIsNotNone(expression)
        selection = expression[1]
        self.assertIn("argc == 2", selection)
        self.assertIn("argv[0]", selection)
        self.assertIn("argv[1]", selection)
        self.assertIn('strcmp(argv[1], "--ob-native-authkit-usb-once-v1") == 0', selection)
        self.assertNotIn("||", selection)
        self.assertEqual(self.main.count('"--ob-native-authkit-usb-once-v1"'), 1)
        self.assertIn('"--ob-native-authkit-no-provision-v1"', entry)
        self.assertIn("action:@selector(runCheck)", self.main)
        for forbidden in ["getenv(", ".arguments", ".environment", "openURL:", "continueUserActivity:"]:
            self.assertNotIn(forbidden, without_comments(self.main + self.broker))

    def test_transport_contract_is_fixed_loopback_and_not_a_shared_listener(self):
        source = without_comments(self.transport)
        self.assertRegex(source, r"OBNativeHeadersPort\s*=\s*49174\b")
        self.assertRegex(source, r"OBNativeHeadersRequestBytes\s*=\s*41\b")
        for token in ["OBNativeHeadersListen", "OBNativeHeadersReadRequest", '"OBHDRS1:"',
                      "SO_REUSEADDR", "O_NONBLOCK", "FD_CLOEXEC", "MSG_DONTWAIT"]:
            self.assertIn(token, source)
        self.assertTrue("INADDR_LOOPBACK" in source or '"127.0.0.1"' in source)
        for forbidden in ["INADDR_ANY", '"0.0.0.0"', "AF_INET6", "SO_REUSEPORT", "SO_REUSEPORT_LB"]:
            self.assertNotIn(forbidden, source)

    def test_native_fetch_is_one_explicit_no_with_no_convenience_fallback(self):
        broker = without_comments(self.broker)
        selector = re.search(r'SEL\s+(\w+)\s*=\s*NSSelectorFromString\(@"fetchAnisetteDataAndProvisionIfNecessary:error:"\)', broker)
        self.assertIsNotNone(selector)
        calls = re.findall(r'\)\(\s*\w+\s*,\s*' + re.escape(selector[1]) + r'\s*,\s*NO\s*,\s*&\w+\s*\)', broker)
        self.assertEqual(len(calls), 1)
        self.assertIn("NSError **", broker)
        for forbidden in ["AKAppleIDSession", "anisetteDataWithError:", "anisetteDataWithCompletion:",
                          "provisionWithCompletion:", "eraseWithCompletion:", "syncWithSIMData:",
                          "legacyAnisetteDataForDSID:", "signatureForData:", "ACAccount"]:
            self.assertNotIn(forbidden, broker)

    def test_headers_use_native_request_factories_with_runtime_abi_checks(self):
        source = without_comments(self.main + self.broker)
        self.assertIn("NSMutableURLRequest", self.broker)
        for selector in ["ak_anisetteHeadersWithData:", "ak_clientInfoHeader", "ak_clientTimeHeader",
                         "ak_deviceUDIDHeader", "ak_localeHeader", "ak_timeZoneHeader"]:
            self.assertIn('@"' + selector + '"', self.broker)
        for check in ["class_getClassMethod", "class_getInstanceMethod", "method_getArgumentType",
                      "method_getNumberOfArguments", "method_getReturnType", '"^@"']:
            self.assertIn(check, source)
        self.assertRegex(source, r'strcmp\([^,]+,\s*"B"\)')
        self.assertRegex(source, r'strcmp\([^,]+,\s*"c"\)')

    def test_private_reply_is_bounded_and_never_a_file_log_or_http_request(self):
        broker = without_comments(self.broker)
        self.assertIn("32768", broker)
        self.assertIn("htonl(", broker)
        self.assertIn("OB_SOURCE_SHA", broker)
        self.assertIn("NSJSONSerialization", broker)
        for forbidden in ["NSLog(", "printf(", "fprintf(", "writeToURL:", "writeToFile:",
                          "NSFileHandle", "NSDocumentDirectory", "NSUserDefaults", "UIPasteboard",
                          "SecItem", "URLSession", "NSURLConnection", "NSURLComponents", "setHTTPBody:",
                          "URLWithString:", "https://", "http://", "NWListener", "CFStream"]:
            self.assertNotIn(forbidden, broker)

    def test_first_active_once_cancellation_and_ui_receipt_are_metadata_only(self):
        active = method_source(self.main, "- (void)applicationDidBecomeActive:(UIApplication *)application")
        run = method_source(self.main, "- (void)runNativeHeadersBroker")
        resign = method_source(self.main, "- (void)applicationWillResignActive:(UIApplication *)application")
        finish = method_source(self.main, "- (void)finish:(NSString *)disposition")
        self.assertIn("if (OBNativeHeadersRequested && !self.started)", active)
        self.assertEqual(self.main.count("[self runNativeHeadersBroker]"), 1)
        self.assertIn("[self runNativeHeadersBroker]", active)
        self.assertLess(run.index("if (self.started) return"), run.index("self.started = NSDate.date"))
        self.assertNotIn("self.started = nil", self.main)
        self.assertIn("self.runButton.enabled = NO", run)
        self.assertIn("60 * NSEC_PER_SEC", run)
        self.assertLess(run.index("dispatch_after("), run.index("[self.headerBroker startWithCompletion:"))
        self.assertIn("self.headerBroker.cancelled = YES", resign)
        self.assertIn("self.headerBroker.cancelled = YES", finish)
        self.assertIn("idleTimerDisabled = NO", resign)
        self.assertIn("idleTimerDisabled = NO", finish)
        callback = run.split("[self.headerBroker startWithCompletion:", 1)[1]
        self.assertIn("^(NSString *disposition, NSUInteger count, long long elapsed)", callback)
        self.assertLess(callback.index("if (!owner || owner.finished) return"), callback.index("[owner.stages addObject:"))
        keys = set(re.findall(r'@"([^"\n]+)"\s*:', callback))
        self.assertEqual(keys, {"stage", "header_count", "native_elapsed_ms", "header_values_saved"})
        self.assertIn('@"header_values_saved": @NO', callback)
        callback_code = re.sub(r'@?"(?:\\.|[^"\\])*"', '""', callback)
        for forbidden in ["wire", "nonce", "data", "headers", "NSDictionary", "NSData"]:
            self.assertNotRegex(callback_code, rf"\b{forbidden}\b")
        self.assertIn('@"login_qualified": @NO', finish)

    def test_exchange_has_one_nonce_response_and_no_payload_input(self):
        exchange = self.broker.split("@implementation OBNativeHeadersBroker", 1)[1]
        self.assertEqual(exchange.count("OBNativeHeadersListen()"), 1)
        self.assertEqual(exchange.count("peer = accept("), 1)
        self.assertEqual(exchange.count("OBNativeHeadersReadRequest("), 1)
        self.assertLess(exchange.index("close(listener); listener = -1"), exchange.index("OBNativeHeadersReadRequest("))
        self.assertLess(exchange.index("OBNativeHeadersReadRequest("), exchange.index("[job start]"))
        response = exchange.split("NSDictionary *response = @{", 1)[1].split("};", 1)[0]
        keys = set(re.findall(r'@"([^"\n]+)"\s*:', response))
        self.assertEqual(keys, {"schema", "source_sha", "purpose", "nonce", "headers", "elapsed_ms", "error"})
        self.assertIn('@"schema": @1', response)
        self.assertIn('@"source_sha": @OB_SOURCE_SHA', response)
        self.assertIn('@"nonce": [NSString stringWithUTF8String:nonce]', response)
        self.assertIn('@"purpose": @"native-anisette-headers"', response)
        self.assertIn("wire.length > 32768", exchange)
        self.assertIn("htonl((uint32_t)wire.length)", exchange)
        self.assertEqual(exchange.count("OBNativeHeadersSend(peer,"), 2)
        for forbidden in ["recv(", "HTTPBody", "NSURL", "URLRequest", "plist"]:
            self.assertNotIn(forbidden, without_comments(exchange))

    def test_native_deadlines_failed_reply_and_fd_cleanup_are_explicit(self):
        fetch = self.broker.split("static NSDictionary *OBFetchNativeHeaders", 1)[1].split("@interface OBNativeHeaderJob", 1)[0]
        preinvoke = fetch.split("id controller = [controllerClass new];", 1)[1].split("id data =", 1)[0]
        self.assertIn("!active()", preinvoke)
        self.assertIn("if (!active() || error || !data)", fetch)
        self.assertRegex(fetch, r'if \(!active\(\)\) \{ \*failure = @"cancelled"; return nil; \}\s*id values =')
        self.assertIn("@property(nonatomic, strong) dispatch_semaphore_t ready;", self.broker)
        job = self.broker.split("@implementation OBNativeHeaderJob", 1)[1].split("@end", 1)[0]
        active = method_source(job, "- (BOOL)active")
        self.assertIn("!self.done && (!self.isCancelled || !self.isCancelled())", active)
        start = method_source(job, "- (void)start")
        self.assertLess(start.index("dispatch_after("), start.index("dispatch_async("))
        self.assertLess(start.index("if (![self active]) return"), start.index("OBFetchNativeHeaders("))
        self.assertIn("OBFetchNativeHeaders(^BOOL{ return [self active]; }, &failure)", start)
        self.assertIn("OBNativeHeadersNow() < self.deadline", start)
        failed = method_source(job, "- (void)fail:(NSString *)failure")
        self.assertIn("self.headers = nil", failed)
        consume = method_source(job, "- (NSDictionary *)consume")
        self.assertIn("self.done && !self.failure && self.headers", consume)
        self.assertIn("OBNativeHeadersNow() < self.deadline", consume)
        self.assertIn('@"headers": @{}', consume)
        self.assertIn("self.headers = nil", consume)
        exchange = self.broker.split("@implementation OBNativeHeadersBroker", 1)[1]
        for bound in ["OBNativeHeadersNow() + 60", "OBNativeHeadersNow() + 15", "OBNativeHeadersNow() + 10",
                      "started + 45", "OBNativeHeadersNow() + 3", "SO_NOSIGPIPE", "O_NONBLOCK", "FD_CLOEXEC"]:
            self.assertIn(bound, exchange)
        cleanup = exchange.split("@finally", 1)[1]
        for operation in ['[job fail:@"cancelled"]', "resetBytesInRange:", "[wire setLength:0]",
                          "shutdown(peer, SHUT_RDWR)", "close(peer)", "close(listener)"]:
            self.assertIn(operation, cleanup)
        self.assertLess(cleanup.index("[wire setLength:0]"), cleanup.index("completion(disposition, count, elapsed)"))
        self.assertIn("@property(atomic) BOOL cancelled;", self.broker)


@unittest.skipUnless(sys.platform == "darwin", "Real shared-C socketpair/listener tests require the macOS SDK")
class NativeHeadersRealTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = tempfile.TemporaryDirectory(prefix=".native-headers-test-", dir=DIRECTORY)
        cls.addClassCleanup(cls.output.cleanup)
        cls.executable = pathlib.Path(cls.output.name) / "native-headers-transport"
        clang = subprocess.run(["xcrun", "--find", "clang"], check=True,
                               capture_output=True, text=True, timeout=15).stdout.strip()
        sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True,
                             capture_output=True, text=True, timeout=15).stdout.strip()
        compiled = subprocess.run([clang, "-std=c11", "-D_DARWIN_C_SOURCE", "-isysroot", sdk,
            "-Wall", "-Wextra", "-Werror", "-I", str(DIRECTORY), "-x", "c", "-", "-o", str(cls.executable)],
            input=C_HARNESS, capture_output=True, text=True, timeout=30)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_cases(self, *modes):
        for mode in modes:
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.executable), mode], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_frames_extract_nonce_while_peer_write_direction_stays_open(self):
        self.run_cases("open", "alternate-nonce")

    def test_real_reader_handles_fragmented_frame(self):
        self.run_cases("fragmented")

    def test_bad_magic_nonce_encoding_and_newline_are_rejected(self):
        self.run_cases("bad-magic", "uppercase", "nonhex", "nul-nonce", "nonascii", "bad-newline", "nul-newline")

    def test_truncation_and_empty_eof_fail_with_bounded_open_wait(self):
        self.run_cases("truncated-open", "truncated-eof", "empty-eof")

    def test_queued_trailing_byte_or_second_frame_is_rejected(self):
        self.run_cases("queued-byte", "queued-frame")

    def test_cancelled_expired_and_failed_wait_requests_are_rejected(self):
        self.run_cases("cancelled", "cancel-during", "expired", "wait-failed")

    def test_actual_listener_is_loopback_nonblocking_cloexec_and_exclusive(self):
        self.run_cases("listener-exclusive")

    def test_actual_listener_rebinds_after_four_immediate_tcp_teardowns(self):
        self.run_cases("listener-rebind")


if __name__ == "__main__":
    unittest.main()
