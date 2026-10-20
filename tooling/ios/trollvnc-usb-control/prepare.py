#!/usr/bin/env python3
"""Prepare an independent, pinned TrollVNC checkout. No network or build steps."""

import argparse
from dataclasses import dataclass
import difflib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile


PIN = "cfdb737e72977d961eb7d0a8110d2fe1a58551d7"
APP = "app/TrollVNC/TrollVNC/"
SERVER = "src/trollvncserver.mm"
MANAGER = "src/trollvncmanager.mm"
LIFETIME = "src/OBUSBSessionLifetime.h"
MANAGED = "prefs/TrollVNCPrefs/Resources/Managed.plist"
TOOL_REPO = Path(__file__).resolve().parents[3]
CONFIG = {
    "BindHost": "127.0.0.1", "Port": 5901, "Enabled": True,
    "BonjourEnabled": False, "HttpPort": 0, "ClipboardEnabled": False,
    "FileTransferEnabled": False, "ReverseMode": "none", "ReverseSocket": "",
    "ReverseHost": "", "ReversePort": 0, "LaunchAtLogin": False,
    "ViewOnly": False, "KeyLogging": False, "AutoAssistEnabled": False,
}

GUI_PASSWORD_CHECK = '''#ifdef THEBOOTSTRAP
// USB qualification build: inspect the same environment supplied to TRTask.
static BOOL TVNCUSBPasswordIsValid(NSDictionary *environment) {
    NSString *password = environment[@"TROLLVNC_PASSWORD"];
    NSData *ascii = [password dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    if (ascii.length != 8) return NO;
    const unsigned char *bytes = ascii.bytes;
    for (NSUInteger i = 0; i < 8; ++i) {
        if (bytes[i] < 0x20 || bytes[i] > 0x7e) return NO;
    }
    return YES;
}
#endif

'''

SERVER_PASSWORD_CHECK = '''#ifdef THEBOOTSTRAP
// Runtime only. Never print or persist the password.
static bool tvUSBPasswordIsValid(const char *password) {
    if (!password || strlen(password) != 8) return false;
    for (size_t i = 0; i < 8; ++i) {
        unsigned char c = (unsigned char)password[i];
        if (c < 0x20 || c > 0x7e) return false;
    }
    return true;
}
#endif

'''

SERVER_OPTIONS = '''#ifdef THEBOOTSTRAP
        if (!tvUSBPasswordIsValid(getenv("TROLLVNC_PASSWORD"))) {
            TVPrintError("USB test: exactly 8 printable ASCII password bytes required");
            return EXIT_FAILURE;
        }
        if (unsetenv("TROLLVNC_VIEWONLY_PASSWORD") != 0) return EXIT_FAILURE;
#endif
        parseCLI(argc, argv);
#ifdef THEBOOTSTRAP
        // Override CLI, defaults and managed settings before any server setup.
        gEnabled = YES;
        gBindHost = @"127.0.0.1";
        gPort = 5901;
        gTvCtlPort = 0;
        gHttpPort = 0;
        gBonjourEnabled = NO;
        gClipboardEnabled = NO;
        gFileTransferEnabled = NO;
        gViewOnly = NO;
        gKeyEventLogging = NO;
        gAutoAssistEnabled = NO;
        gRepeaterMode = 0;
        free(gRepeaterHost);
        gRepeaterHost = NULL;
        gRepeaterPort = 0;
        free(gHttpDirOverride);
        gHttpDirOverride = NULL;
        free(gSslCertPath);
        gSslCertPath = NULL;
        free(gSslKeyPath);
        gSslKeyPath = NULL;
#endif
'''

BEFORE_BIND = '''#ifdef THEBOOTSTRAP
    // Last check before LibVNCServer can bind. Allocation failure must not
    // turn a valid environment into an unauthenticated listener.
    if (!tvUSBPasswordIsValid(getenv("TROLLVNC_PASSWORD")) ||
        !gAuthPasswdVec || !gAuthPasswdVec[0] || gAuthPasswdVec[1] ||
        strcmp(gAuthPasswdVec[0], getenv("TROLLVNC_PASSWORD")) != 0 ||
        gScreen->authPasswdData != (void *)gAuthPasswdVec ||
        gScreen->passwordCheck != tvCheckPasswordByList) {
        TVPrintError("USB test: runtime authentication unavailable");
        exit(EXIT_FAILURE);
    }
    gScreen->autoPort = FALSE;
    gScreen->port = 5901;
    gScreen->listenInterface = htonl(INADDR_LOOPBACK);
    gScreen->ipv6port = 0;
    gScreen->udpPort = 0;
    gScreen->httpPort = 0;
    gScreen->http6Port = 0;
    gScreen->httpDir = NULL;
    gScreen->httpEnableProxyConnect = FALSE;
    gScreen->sslcertfile = NULL;
    gScreen->sslkeyfile = NULL;
#endif
'''


class PreparationError(ValueError):
    pass


@dataclass(frozen=True)
class Edit:
    path: str
    before: str
    after: str


# Each before string must occur exactly once in the reviewed Git blob.
EDITS = (
    Edit(APP + "TVNCServiceCoordinator.m", "@interface TVNCServiceCoordinator ()\n",
         GUI_PASSWORD_CHECK + "@interface TVNCServiceCoordinator ()\n"),
    Edit(APP + "TVNCServiceCoordinator.m", "- (void)spawnService {\n", '''- (void)spawnService {
#ifdef THEBOOTSTRAP
    // A GUI launch owns one bounded manager. Health polling cannot renew it.
    static BOOL usbLaunchAttempted = NO;
    if (!TVNCUSBPasswordIsValid([TVNCServiceCoordinator sharedTaskEnvironment]) || usbLaunchAttempted) return;
    usbLaunchAttempted = YES;
#endif
'''),
    Edit(APP + "TVNCServiceCoordinator.m", "- (void)checkPrebootDependencies {\n", '''- (void)checkPrebootDependencies {
#ifdef THEBOOTSTRAP
    return; // Never launch another app at login in this USB test build.
#endif
'''),
    Edit(APP + "TVNCViewController.m", '''    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
''', '''#ifdef THEBOOTSTRAP
    NSDictionary *environment = [TVNCServiceCoordinator sharedTaskEnvironment];
    NSData *password = [environment[@"TROLLVNC_PASSWORD"] dataUsingEncoding:NSASCIIStringEncoding
                                                       allowLossyConversion:NO];
    if (password.length != 8) {
        UIAlertController *waiting = [UIAlertController alertControllerWithTitle:@"Waiting for USB control"
            message:@"Leave this iPhone unlocked and connected by USB. The PC starts a temporary session; no password is needed here."
            preferredStyle:UIAlertControllerStyleAlert];
        [waiting addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:waiting animated:YES completion:nil];
        _isAlertPresented = YES;
        return;
    }
#endif
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
'''),
    Edit(APP + "TVNCRootListController.m", '''        versionString = [[GitHubReleaseUpdater shared] currentVersion];
''', '''        versionString = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
'''),
    Edit(APP + "AppDelegate.m",
         '    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];\n',
         '''#ifndef THEBOOTSTRAP
    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];
#endif
'''),
    Edit(APP + "AppDelegate.m", '''#ifdef THEBOOTSTRAP
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
''', "    // USB test build: auto updater is never configured or started.\n"),
    Edit(MANAGER, '#import "TRWatchDog.h"\n', '#import "TRWatchDog.h"\n#import "OBUSBSessionLifetime.h"\n'),
    Edit(MANAGER, '    /* Singleton */\n', '''    // Only the GUI in this exact installed bundle owns the root manager.
    NSString *ownerPath = [[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"TrollVNC"];
    if (!OBUSBStartLifetime(getppid(), ownerPath.fileSystemRepresentation, 600ULL * NSEC_PER_SEC, ^(bool ownerExited) {
        (void)ownerExited;
        CFRunLoopStop(CFRunLoopGetMain());
    })) return EXIT_FAILURE;

    /* Singleton */
'''),
    Edit(MANAGER, '    CFRunLoopRun();\n', '''    if (!obUSBStopped) CFRunLoopRun();
    OBUSBCancelLifetime();
'''),
    Edit(MANAGER, '''        [gWatchDog stop];
        gWatchDog = nil;
''', '''        [gWatchDog setKeepAlive:@NO];
        [gWatchDog stop];
'''),
    Edit(SERVER, "#pragma mark - Options\n", SERVER_PASSWORD_CHECK + "#pragma mark - Options\n"),
    Edit(SERVER, '    NSString *fullPwd = [prefs objectForKey:@"FullPassword"];\n',
         '''    NSString *fullPwd = nil;
#ifndef THEBOOTSTRAP
    fullPwd = [prefs objectForKey:@"FullPassword"];
#endif
'''),
    Edit(SERVER, '    NSString *viewPwd = [prefs objectForKey:@"ViewOnlyPassword"];\n',
         '''    NSString *viewPwd = nil;
#ifndef THEBOOTSTRAP
    viewPwd = [prefs objectForKey:@"ViewOnlyPassword"];
#endif
'''),
    Edit(SERVER, "        parseCLI(argc, argv);\n", SERVER_OPTIONS),
    Edit(SERVER, "        setupRfbScreen(argc, argv);\n", '''#ifdef THEBOOTSTRAP
        setupRfbScreen(1, argv); // Do not pass DVT arguments into LibVNCServer.
#else
        setupRfbScreen(argc, argv);
#endif
'''),
    Edit(SERVER, "static void initializeAndRunRfbServer(void) {\n    rfbInitServer(gScreen);\n",
         "static void initializeAndRunRfbServer(void) {\n" + BEFORE_BIND + "    rfbInitServer(gScreen);\n"),
)


def harden(originals):
    """Pure source transformation; validate every anchor before returning edits."""
    result = dict(originals)
    for edit in EDITS:
        if edit.path not in originals:
            raise PreparationError(f"missing source: {edit.path}")
        text = result[edit.path].decode("utf-8")
        count = text.count(edit.before)
        if count != 1:
            raise PreparationError(f"anchor in {edit.path}: expected exactly once, found {count}")
        result[edit.path] = text.replace(edit.before, edit.after, 1).encode("utf-8")
    result[MANAGED] = plistlib.dumps(CONFIG, sort_keys=True)
    result[LIFETIME] = Path(__file__).with_name("USBSessionLifetime.h").read_bytes()
    return result


def git(root, *args):
    # Prevent incidental index refresh and lazy fetches during read-only checks.
    env = os.environ.copy()
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(
            ["git", "--no-optional-locks", "-C", str(root), *args],
            check=True, capture_output=True, timeout=30, env=env,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise PreparationError(f"read-only Git check failed in {root}") from exc


def checkout(root):
    if not root.is_dir() or Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
        raise PreparationError("paths must name existing Git checkout roots")
    if git(root, "rev-parse", "HEAD").decode().strip() != PIN:
        raise PreparationError(f"checkout must be exactly {PIN}")
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip()
    return Path(common).resolve()


def changed_paths(root):
    tracked = git(root, "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", "HEAD", "--")
    # No exclude flags: also reject ignored build outputs and generated secrets.
    others = git(root, "ls-files", "--others", "-z", "--")
    return {name.decode("utf-8") for name in (tracked + others).split(b"\0") if name}


def prepare(upstream, stage, *, check=False):
    upstream, stage = Path(upstream).resolve(), Path(stage).resolve()
    if (stage.is_relative_to(TOOL_REPO) or TOOL_REPO.is_relative_to(stage) or
            stage.is_relative_to(upstream) or upstream.is_relative_to(stage)):
        raise PreparationError("stage must be separate from upstream and the tooling repository")
    upstream_git = checkout(upstream)
    stage_git = checkout(stage)
    if upstream_git == stage_git:
        raise PreparationError("stage must have independent Git metadata")
    if changed_paths(upstream) or (upstream / MANAGED).exists():
        raise PreparationError("upstream must be clean, including untracked/ignored files")
    if git(stage, "diff", "--cached", "--name-only", "-z", "--"):
        raise PreparationError("stage index must be clean")
    originals = {path: git(upstream, "show", f"{PIN}:{path}") for path in sorted({e.path for e in EDITS})}
    expected = harden(originals)
    unexpected = changed_paths(stage) - expected.keys()
    if unexpected:
        raise PreparationError("stage has unrelated changes: " + ", ".join(sorted(unexpected)))
    pending = []
    for path, content in expected.items():
        target = stage / path
        if target.is_symlink() or target.resolve() != stage / path:
            raise PreparationError(f"stage path must not traverse links: {path}")
        if target.exists() and not target.is_file():
            raise PreparationError(f"stage target must be a regular file: {path}")
        current = target.read_bytes() if target.is_file() else None
        if current != content:
            if current != originals.get(path):
                raise PreparationError(f"stage content differs from pristine/prepared bytes: {path}")
            pending.append((target, content))
    patch = "".join(
        "".join(difflib.unified_diff(
            originals.get(path, b"").decode().splitlines(keepends=True),
            content.decode().splitlines(keepends=True),
            fromfile="a/" + path if path in originals else "/dev/null", tofile="b/" + path,
        )) for path, content in sorted(expected.items())
    )
    if not check:
        # All guards above run before any write. Replace only known files, never
        # follow hard links; interruption can be resumed with the same command.
        for target, content in pending:
            mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
            temporary = tempfile.NamedTemporaryFile(dir=target.parent, delete=False)
            temporary_path = Path(temporary.name)
            try:
                with temporary:
                    temporary.write(content)
                temporary_path.chmod(mode)
                os.replace(temporary_path, target)
            finally:
                temporary_path.unlink(missing_ok=True)
    return {"upstream_sha": PIN, "mode": "check" if check else "prepare",
            "pending_files": len(pending), "paths": sorted(expected)}, patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True, type=Path, help="clean reviewed upstream checkout")
    parser.add_argument("--stage", required=True, type=Path, help="independent existing checkout at the same pin")
    parser.add_argument("--check", action="store_true", help="validate and print the proposed patch without writing")
    args = parser.parse_args()
    try:
        report, patch = prepare(args.upstream, args.stage, check=args.check)
    except (PreparationError, OSError, UnicodeError) as exc:
        parser.exit(1, f"prepare: {exc}\n")
    if args.check:
        print(patch, end="")
    print(json.dumps(report, sort_keys=True), file=sys.stderr if args.check else sys.stdout)


if __name__ == "__main__":
    main()
