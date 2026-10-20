# TrollVNC USB qualification source preparer

This prepares source for parent review. It does not qualify an artifact or device
runtime, create checkouts, build, dispatch CI, sign, install, contact accounts,
read a password, start services, or change device trust. Only the reviewed commit
`cfdb737e72977d961eb7d0a8110d2fe1a58551d7` is accepted. The parent established that
release `v3.2-272` has no assets and points to `17c37b2f`, so it is not an input.

## Inputs and use

Python 3.10+ and Git are sufficient for preparation. Provide two **existing,
independent Git checkouts** at that exact SHA: a clean upstream reference and a
disposable stage with independent Git metadata. The stage must be outside this
OpenBubbles worktree and outside the upstream tree. The tool never clones or
changes Git metadata. Keep the stage idle during preparation.

Use LF source checkouts. Upstream must have no modifications or untracked/ignored
files. Stage may contain only pristine source or exactly the previously prepared
changes, including the generated Managed resource. A dirty index, unrelated
files, missing/duplicate anchors, symlinked patch paths, or changed prepared bytes
are rejected before writing. The same command is a no-op once prepared and can
resume a partial preparation. Builds create extra files, so rerun preparation
before building, not over a build directory.

```text
python -B prepare.py --upstream /external/TrollVNC-reviewed --stage /external/TrollVNC-usb-stage --check
python -B prepare.py --upstream /external/TrollVNC-reviewed --stage /external/TrollVNC-usb-stage
python -B -m unittest discover -s tooling/ios/trollvnc-usb-control -p test_prepare.py -v
```

`--check` writes nothing. It prints the full proposed unified source/resource
diff to stdout and a nonsecret JSON report to stderr. Apply mode prints only the
report. There is no pin override and no password argument. The preparer changes
three source files plus `prefs/TrollVNCPrefs/Resources/Managed.plist` in the stage;
upstream entitlements, `COPYING`, build files and workflows remain byte-for-byte
unchanged. Existing upstream symlinks outside patch targets are preserved.

## Hardening and exact source anchors

All links below refer to the reviewed SHA, not a release or moving branch.

- [AppDelegate.m:28-45](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/app/TrollVNC/TrollVNC/AppDelegate.m#L28-L45): retain startup `registerServiceMonitor`; compile out hotspot registration for bootstrap and remove updater configure/start. Managed mode does **not** prevent GUI auto-start.
- [TVNCServiceCoordinator.m:53-69, 98-128, 130-182](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/app/TrollVNC/TrollVNC/TVNCServiceCoordinator.m#L53-L182): validate the same `sharedTaskEnvironment` supplied to the manager before allocating/launching its task. Require exactly eight bytes in ASCII `0x20..0x7e`. No password is logged or bundled. Preserve the original three-second health check to the manager, avoiding VNC client churn.
- [TVNCServiceCoordinator.m:184-232](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/app/TrollVNC/TrollVNC/TVNCServiceCoordinator.m#L184-L232): return immediately in bootstrap to prevent the `LaunchAtLogin` dependency-app launch, even if persisted defaults override registered defaults.
- [trollvncmanager.mm:89-162](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/src/trollvncmanager.mm#L89-L162): **preserve** the existing `127.0.0.1:46751` health listener as the explicitly permitted exception to no extra listeners. It binds `INADDR_LOOPBACK` (line 115), accepts (line 141), then closes (line 150), with no command parser, data reads or response. The manager source, `-daemon` and [environment inheritance at lines 224-235](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/src/trollvncmanager.mm#L224-L235) remain unchanged. No new health protocol is added.
- [trollvncserver.mm:428-460, 791-805, 845-859](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/src/trollvncserver.mm#L428-L859): ignore managed/persisted password keys in bootstrap. Require the runtime environment before option parsing; remove the alternate view-only environment credential. Force enabled/input-enabled, loopback 5901, Bonjour/clipboard/file-transfer/HTTP/reverse/control socket/key logging/automatic AssistiveTouch off after parsing, before any server setup.
- [trollvncserver.mm:3613-3658, 3715-3747, 3771-3824, 3872-3874, 4172-4215](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/src/trollvncserver.mm#L3613-L4215): pass only argv[0] to LibVNCServer; immediately before `rfbInitServer`, recheck password validity and the installed authentication vector/callback, force IPv4 loopback 5901, turn auto-port selection off, set IPv6/UDP/HTTP/HTTP6 ports to zero, remove HTTP resources/proxy and TLS paths. These fields exist in the pinned [rfb.h:229-266, 326-355](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/include/rfb/rfb.h#L229-L355).

The Managed resource sets `BindHost=127.0.0.1`, `Port=5901`, `Enabled=true`,
`BonjourEnabled=false`, `HttpPort=0`, `ClipboardEnabled=false`,
`FileTransferEnabled=false`, `ReverseMode=none`, empty reverse host/socket,
`ReversePort=0`, `LaunchAtLogin=false`, `ViewOnly=false`, `KeyLogging=false`, and
`AutoAssistEnabled=false`. It contains no password keys or values. Runtime source
guards enforce the network/authentication constraints independently of defaults.
The GUI environment passes through both existing spawns; this is source evidence,
not a claim that DVT delivers it on the target phone. Classic VNC uses only eight
password bytes and does not encrypt the desktop stream.

## Parent-owned Mac build prerequisites

The parent-added `build.sh` runs this path only on the isolated Mac lane. It
pins Theos to `cfba89a53a05b4a1b822121158acc3669c20602f` and fetches SDK release
assets137098923/137098925 from the fixed public `master-146e41f` release. Those
older assets have no upstream digest: sizes and asset identity are checked,
observed SHA256 values are retained, and no independent SDK digest proof is
claimed. No credentials are sent to dependency downloads. The packaged Managed
resource additionally advertises `OB USB Control <tool-source-SHA>` as its RFB
desktop name for later source-binding checks. It still contains no password.
All other managed values must match the preparer's fixed configuration. The
package is re-signed ad hoc and checked; this is for existing TrollStore only,
not an App Store, normal iOS trust or actual runtime qualification claim.

No workflow or build was run here. The pin's [build.yml:73-109](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/.github/workflows/build.yml#L73-L109)
declares macOS, Xcode 16.2, GNU make, `xcbeautify`, `ldid-procursus`, `p7zip`,
`roothide/theos` with recursive submodules, and iPhoneOS SDKs 16.5 and 14.5.
The upstream runner label is `macos-14`; availability/compatibility of that label
with Xcode 16.2 is not established by this preparer. The parent must use its
existing established Mac lane and pin its toolchain separately.

[devkit/bootstrap.sh:3-13](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/devkit/bootstrap.sh#L3-L13)
selects an existing `theos-roothide` at `$HOME/theos-roothide` or
`$GITHUB_WORKSPACE/theos-roothide`, exports `THEOS_PACKAGE_SCHEME=roothide` and
`THEBOOTSTRAP=1`, and clears simulator mode. Those are build-tool choices, not a
request to install a jailbreak. Top-level [Makefile:10-16, 47-49](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/Makefile#L10-L49)
selects arm64 / iPhoneOS16.5 / iOS15.0 for this scheme and defines `THEBOOTSTRAP`
for the server. [app/TrollVNC/Makefile:11-21](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/app/TrollVNC/Makefile#L11-L21)
defines it for the GUI and retains the upstream entitlements. The link inputs
already tracked at the pin are `lib/`, `include/`, `include-spi/`, and private
framework declarations. Their binary provenance/reproducibility is not qualified.

For later parent review only, the existing build path is to source
`devkit/bootstrap.sh`, then use `FINALPACKAGE=1 gmake clean package`
([build.yml:142-145](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/.github/workflows/build.yml#L142-L145)).
Do not run `devkit/gen-managed-plist.sh` or the workflow's managed generator over
this stage: it overwrites the fixed resource and accepts password environment
inputs. Do not use install targets. Full Git history is needed for the intended
bundle version count: [before-package.sh:15-34](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/devkit/before-package.sh#L15-L34)
calls `git rev-list`, collects both embedded executables and the prefs bundle,
and invokes upstream pseudo-signing. [after-package.sh:10-17](https://github.com/owngoal-dev/TrollVNC/blob/cfdb737e72977d961eb7d0a8110d2fe1a58551d7/devkit/after-package.sh#L10-L17)
names the result `packages/TrollVNC_3.2-272.tipa`. A matching version filename does
not establish asset provenance. Runtime passwords belong only in the future
launch environment, never in the build environment, source, resource, logs, or
artifact metadata.

## Qualification boundary

Tests exercise synthetic source transformation, rejection paths, ordering and
idempotent staging. Real pinned source anchors are separately checked in memory.
No Objective-C/Swift compilation, packaged-resource inspection, executable
provenance, GUI launch, DVT environment delivery, socket behavior, authentication
negotiation, USB forwarding, input injection or shutdown was tested here.

Upstream manager keep-alive, server singleton/parent monitoring and signal paths
are preserved. GUI exit is not established to stop the manager or its child;
the preparer adds no shutdown guarantee or launch-at-login mechanism. The existing
manager connect probe is not proof of child ownership. The parent must qualify lifecycle
and verify the packaged Managed resource, entitlements, authentication and actual
listening sockets before treating any future device run as qualified.
