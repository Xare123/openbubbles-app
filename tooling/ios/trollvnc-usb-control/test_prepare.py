"""Focused synthetic source/checkout tests. No compiler, network or device calls."""

from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import prepare


# Minimal synthetic slices, with independently copied anchors from the pin.
# These are not compilable upstream fixtures or evidence of iOS behavior.
SOURCES = {
    prepare.APP + "TVNCServiceCoordinator.m": b'''@interface TVNCServiceCoordinator ()
@end
+ (NSDictionary *)sharedTaskEnvironment {
    NSMutableDictionary *env =
        [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    return [env copy];
}
- (BOOL)_isServiceRunning {
    addr.sin_port = htons(kTvAlivePort);
}
- (void)spawnService {
    static TRTask *serviceTask = nil;
    serviceTask = [[TRTask alloc] init];
    [serviceTask setEnvironment:[TVNCServiceCoordinator sharedTaskEnvironment]];
    BOOL launched = [serviceTask launchAndReturnError:&error];
}
- (void)checkPrebootDependencies {
#if !TARGET_IPHONE_SIMULATOR
    id configVal = [_userDefaults objectForKey:@"LaunchAtLogin"];
#endif
}
''',
    prepare.APP + "AppDelegate.m": b'''    [[TVNCServiceCoordinator sharedCoordinator] registerServiceMonitor];
    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];

#ifdef THEBOOTSTRAP
    // Initialize Auto Updater
    GHUpdateStrategy *updateStrategy = [[GHUpdateStrategy alloc] init];
    [updateStrategy setRepoFullName:@"owngoal-dev/TrollVNC"];

    GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
#if TARGET_IPHONE_SIMULATOR
    [updater configureWithStrategy:updateStrategy];
#else
    [updater configureWithStrategy:updateStrategy currentVersion:@PACKAGE_VERSION];
#endif
    [updater start];
#endif
''',
    prepare.APP + "TVNCViewController.m": b'''- (void)viewDidAppear:(BOOL)animated {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
}
''',
    prepare.APP + "TVNCRootListController.m": b'''- (NSString *)defaultFooterText {
        versionString = [[GitHubReleaseUpdater shared] currentVersion];
}
''',
    prepare.MANAGER: b'''#import "TRWatchDog.h"
int main(int argc, const char *argv[]) {
    /* Singleton */
    openLocalDummyService(kTvAlivePort);
    CFRunLoopRun();
    @autoreleasepool {
        pid_t child = [gWatchDog processIdentifier];
        [gWatchDog stop];
        gWatchDog = nil;
    }
}
''',
    prepare.SERVER: b'''#pragma mark - Options
static void parseDaemonOptions(void) {
    NSString *fullPwd = [prefs objectForKey:@"FullPassword"];
    NSString *viewPwd = [prefs objectForKey:@"ViewOnlyPassword"];
}
static void initializeAndRunRfbServer(void) {
    rfbInitServer(gScreen);
}
int main(int argc, const char *argv[]) {
        parseCLI(argc, argv);
        monitorParentProcess();
        setupGeometry();
        setupRfbScreen(argc, argv);
        setupRfbClassicAuthentication();
        setupRfbHttpServer();
        setupRfbFileTransferExtension();
        prepareClipboardManager();
        initializeAndRunRfbServer();
        tvStartControlSocketIfNeeded();
}
''',
}

PRESERVED = {
    "COPYING": b"synthetic upstream license fixture\n",
    prepare.APP + "TrollVNC.entitlements": b"synthetic upstream entitlements fixture\n",
}


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.output = prepare.harden(SOURCES)

    def test_managed_config_has_only_fixed_nonsecret_settings(self):
        config = plistlib.loads(self.output[prepare.MANAGED])
        self.assertEqual(config, {
            "BindHost": "127.0.0.1", "Port": 5901, "Enabled": True,
            "BonjourEnabled": False, "HttpPort": 0, "ClipboardEnabled": False,
            "FileTransferEnabled": False, "ReverseMode": "none", "ReverseSocket": "",
            "ReverseHost": "", "ReversePort": 0, "LaunchAtLogin": False,
            "ViewOnly": False, "KeyLogging": False, "AutoAssistEnabled": False,
        })
        self.assertNotIn(b"Password", self.output[prepare.MANAGED])

    def test_guards_precede_spawn_parse_and_bind(self):
        gui = self.output[prepare.APP + "TVNCServiceCoordinator.m"].decode()
        spawn = gui[gui.index("- (void)spawnService {"):]
        self.assertLess(spawn.index("if (!TVNCUSBPasswordIsValid("), spawn.index("[[TRTask alloc]"))
        self.assertLess(spawn.index("if (!TVNCUSBPasswordIsValid("), spawn.index("launchAndReturnError:"))
        self.assertIn("ascii.length != 8", gui)
        self.assertIn("bytes[i] < 0x20 || bytes[i] > 0x7e", gui)
        self.assertIn("setEnvironment:[TVNCServiceCoordinator sharedTaskEnvironment]", gui)
        self.assertIn("htons(kTvAlivePort)", gui)
        self.assertNotIn("htons(5901)", gui)
        self.assertIn("checkPrebootDependencies {\n#ifdef THEBOOTSTRAP\n    return;", gui)
        server = self.output[prepare.SERVER].decode()
        main = server[server.index("int main("):]
        self.assertLess(main.index("!tvUSBPasswordIsValid("), main.index("parseCLI(argc, argv)"))
        self.assertIn("!password || strlen(password) != 8", server)
        self.assertIn("c < 0x20 || c > 0x7e", server)
        self.assertIn('unsetenv("TROLLVNC_VIEWONLY_PASSWORD")', main)
        for setting in ("gPort = 5901;", "gTvCtlPort = 0;", "gBonjourEnabled = NO;",
                        "gClipboardEnabled = NO;", "gFileTransferEnabled = NO;", "gHttpPort = 0;",
                        "gRepeaterMode = 0;", "gRepeaterHost = NULL;"):
            self.assertLess(main.index("parseCLI(argc, argv)"), main.index(setting))
            self.assertLess(main.index(setting), main.index("setupGeometry()"))
        self.assertIn("setupRfbScreen(1, argv)", main)
        binding = server[server.index("static void initializeAndRunRfbServer(void) {"):server.index("int main(")]
        for guard in ("!tvUSBPasswordIsValid(", "!gAuthPasswdVec[0]", "gAuthPasswdVec[1]",
                      "authPasswdData !=", "passwordCheck != tvCheckPasswordByList",
                      "autoPort = FALSE", "port = 5901", "listenInterface = htonl(INADDR_LOOPBACK)",
                      "ipv6port = 0", "udpPort = 0", "httpPort = 0", "http6Port = 0",
                      "httpDir = NULL", "httpEnableProxyConnect = FALSE"):
            self.assertLess(binding.index(guard), binding.index("rfbInitServer(gScreen)"))
        self.assertIn('fullPwd = nil;\n#ifndef THEBOOTSTRAP', server)
        self.assertIn('viewPwd = nil;\n#ifndef THEBOOTSTRAP', server)

    def test_updater_and_hotspot_are_disabled(self):
        app = self.output[prepare.APP + "AppDelegate.m"].decode()
        self.assertIn("registerServiceMonitor", app)
        self.assertNotIn("[updater start]", app)
        self.assertNotIn("configureWithStrategy:", app)
        self.assertIn('#ifndef THEBOOTSTRAP\n    [[TVNCHotspotManager', app)

    def test_manual_waiting_and_packaged_version_are_honest(self):
        view = self.output[prepare.APP + "TVNCViewController.m"].decode()
        self.assertLess(view.index("Waiting for USB control"), view.index("UNUserNotificationCenter *center"))
        self.assertIn("no password is needed here", view)
        self.assertIn("password.length != 8", view)
        root = self.output[prepare.APP + "TVNCRootListController.m"].decode()
        self.assertIn('objectForInfoDictionaryKey:@"CFBundleShortVersionString"', root)
        self.assertNotIn("[[GitHubReleaseUpdater shared] currentVersion]", root)

    def test_native_lifetime_is_packaged_and_not_renewed_by_health_poll(self):
        gui = self.output[prepare.APP + "TVNCServiceCoordinator.m"].decode()
        self.assertIn("static BOOL usbLaunchAttempted = NO", gui)
        self.assertLess(gui.index("usbLaunchAttempted = YES"), gui.index("[[TRTask alloc]"))
        manager = self.output[prepare.MANAGER].decode()
        self.assertLess(manager.index("OBUSBStartLifetime(getppid()"), manager.index("/* Singleton */"))
        self.assertIn("600ULL * NSEC_PER_SEC", manager)
        self.assertIn("if (!obUSBStopped) CFRunLoopRun()", manager)
        self.assertIn("openLocalDummyService(kTvAlivePort)", manager)
        self.assertLess(manager.index("[gWatchDog setKeepAlive:@NO]"), manager.index("[gWatchDog stop]"))
        self.assertNotIn("gWatchDog = nil", manager)
        self.assertEqual(self.output[prepare.LIFETIME], Path(prepare.__file__).with_name("USBSessionLifetime.h").read_bytes())

    def test_missing_and_ambiguous_real_anchors_fail(self):
        path = prepare.SERVER
        for replacement in (b"", b"#pragma mark - Options\n" * 2):
            with self.subTest(replacement=replacement):
                broken = dict(SOURCES)
                broken[path] = broken[path].replace(b"#pragma mark - Options\n", replacement)
                with self.assertRaisesRegex(prepare.PreparationError, "expected exactly once"):
                    prepare.harden(broken)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trollvnc-prepare-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.upstream, self.stage = root / "upstream", root / "stage"
        self.heads = {self.upstream: prepare.PIN, self.stage: prepare.PIN}
        for checkout in (self.upstream, self.stage):
            for name, content in {**SOURCES, **PRESERVED}.items():
                target = checkout / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            (checkout / prepare.MANAGED).parent.mkdir(parents=True, exist_ok=True)
        (self.stage / prepare.LIFETIME).parent.mkdir(parents=True, exist_ok=True)
        self.mock_git = patch.object(prepare, "git", side_effect=self.git)
        self.mock_git.start()
        self.addCleanup(self.mock_git.stop)

    def git(self, root, *args):
        # Only the read-only interface is substituted; real temporary files are
        # transformed, compared and atomically replaced by the preparer.
        if args == ("rev-parse", "--show-toplevel"):
            return str(root).encode()
        if args == ("rev-parse", "HEAD"):
            return self.heads[root].encode()
        if args == ("rev-parse", "--path-format=absolute", "--git-common-dir"):
            return str(root / ".git").encode()
        if args[0] == "show":
            return SOURCES[args[1].split(":", 1)[1]]
        if args[0] == "diff":
            if "--cached" in args:
                return b""
            names = [p for p, data in {**SOURCES, **PRESERVED}.items() if (root / p).read_bytes() != data]
        elif args[0] == "ls-files":
            names = [p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()
                     and p.relative_to(root).as_posix() not in {**SOURCES, **PRESERVED}]
        else:
            self.fail(f"unexpected Git call: {args}")
        return b"".join(name.encode() + b"\0" for name in names)

    def test_missing_and_wrong_pins_never_write(self):
        with self.assertRaises(prepare.PreparationError):
            prepare.prepare(self.upstream / "absent", self.stage)
        for checkout in (self.upstream, self.stage):
            with self.subTest(checkout=checkout):
                self.heads[checkout] = "0" * 40
                with self.assertRaisesRegex(prepare.PreparationError, "exactly " + prepare.PIN):
                    prepare.prepare(self.upstream, self.stage)
                self.heads[checkout] = prepare.PIN
        self.assertFalse((self.stage / prepare.MANAGED).exists())

    def test_dirty_upstream_and_unrelated_stage_changes_are_rejected(self):
        for checkout in (self.upstream, self.stage):
            with self.subTest(checkout=checkout):
                extra = checkout / "unrelated.txt"
                extra.write_text("preserve")
                with self.assertRaises(prepare.PreparationError):
                    prepare.prepare(self.upstream, self.stage)
                self.assertEqual(extra.read_text(), "preserve")
                extra.unlink()
        self.assertFalse((self.stage / prepare.MANAGED).exists())

    def test_ambiguous_anchor_leaves_entire_stage_unchanged(self):
        def broken_git(root, *args):
            if args == ("show", prepare.PIN + ":" + prepare.SERVER):
                return SOURCES[prepare.SERVER] + b"#pragma mark - Options\n"
            return self.git(root, *args)
        with patch.object(prepare, "git", side_effect=broken_git), self.assertRaisesRegex(
                prepare.PreparationError, "expected exactly once"):
            prepare.prepare(self.upstream, self.stage)
        for name, data in SOURCES.items():
            self.assertEqual((self.stage / name).read_bytes(), data)

    def test_dry_run_then_apply_is_idempotent_and_preserves_upstream(self):
        report, diff = prepare.prepare(self.upstream, self.stage, check=True)
        self.assertEqual(report["pending_files"], 8)
        self.assertIn("--- /dev/null\n+++ b/" + prepare.MANAGED, diff)
        self.assertFalse((self.stage / prepare.MANAGED).exists())
        prepare.prepare(self.upstream, self.stage)
        expected = prepare.harden(SOURCES)
        before = {name: (self.stage / name).stat().st_mtime_ns for name in expected}
        report, _ = prepare.prepare(self.upstream, self.stage)
        self.assertEqual(report["pending_files"], 0)
        for name, data in expected.items():
            self.assertEqual((self.stage / name).read_bytes(), data)
            self.assertEqual((self.stage / name).stat().st_mtime_ns, before[name])
        for name, data in SOURCES.items():
            self.assertEqual((self.upstream / name).read_bytes(), data)
        for name, data in PRESERVED.items():
            self.assertEqual((self.upstream / name).read_bytes(), data)
            self.assertEqual((self.stage / name).read_bytes(), data)

    def test_partial_preparation_resumes_and_tampering_is_rejected(self):
        name = prepare.APP + "AppDelegate.m"
        (self.stage / name).write_bytes(prepare.harden(SOURCES)[name])
        report, _ = prepare.prepare(self.upstream, self.stage)
        self.assertEqual(report["pending_files"], 7)
        managed = self.stage / prepare.MANAGED
        managed.write_bytes(b"do not overwrite")
        with self.assertRaises(prepare.PreparationError):
            prepare.prepare(self.upstream, self.stage)
        self.assertEqual(managed.read_bytes(), b"do not overwrite")

    def test_parent_tooling_and_same_checkout_targets_are_rejected(self):
        for target in (self.upstream, self.upstream / "child", prepare.TOOL_REPO):
            with self.subTest(target=target), self.assertRaises(prepare.PreparationError):
                prepare.prepare(self.upstream, target)


if __name__ == "__main__":
    unittest.main()
