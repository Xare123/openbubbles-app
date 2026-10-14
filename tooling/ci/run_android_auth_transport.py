"""Build only the real auth crate, then run two public HTTPS GETs on Android."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import tempfile
import time

import run_corten_android_login_runtime as runtime
from run_corten_component_probe import command, OWNED_GROUPS, verify_source
from run_corten_login_integration import (SOURCE, NATIVE, TOOLS, overlay,
    unchanged_registry_pins, verify_overlay_source, digest)
from run_production_transport_probe import elf

AUTH = 'rustpush/apple-private-apis/icloud-auth/src/client.rs'
TEST = 'client::ob_android_public_transport::production_auth_client_reaches_public_endpoints'
TARGET = 'x86_64-linux-android'
TEMPLATE = Path(__file__).with_name('transport_probe') / 'android_auth_test.rs'


def test_executable(raw, target):
    matches = []
    for line in raw.splitlines():
        if not line.startswith('{'):
            continue
        entry = json.loads(line)
        if (entry.get('reason') == 'compiler-artifact'
                and entry.get('target', {}).get('name') == 'icloud_auth'
                and entry.get('profile', {}).get('test') is True
                and entry.get('executable')):
            matches.append(Path(entry['executable']).resolve())
    if (len(matches) != 1 or not matches[0].is_relative_to(target.resolve())
            or matches[0].is_symlink() or not matches[0].is_file()):
        raise RuntimeError('Expected one owned auth test executable')
    return matches[0]


def observations(code, raw):
    rows = [json.loads(line) for line in raw.decode().splitlines() if line.startswith('{')]
    expected = [('google-control', 'www.google.com'), ('gsa-public', 'gsa.apple.com')]
    passed = (code == 0 and len(rows) == 3
        and [(r.get('probe'), r.get('host')) for r in rows[:2]] == expected
        and all(r.get('strict_https') is True and type(r.get('http_status')) is int
                and 100 <= r['http_status'] <= 599 and r.get('authentication_tested') is False
                for r in rows[:2])
        and type(rows[-1].get('provider_calls')) is int and rows[-1]['provider_calls'] == 0
        and rows[-1].get('credentials_loaded') is False
        and rows[-1].get('authentication_tested') is False
        and rows[-1].get('transport_passed') is True)
    return {'passed': passed, 'exit': code, 'observations': rows}


def run(source, sdk, out):
    runtime.require(sys.platform == 'linux', 'Hosted Linux required')
    runtime.require(source != out and source not in out.parents, 'Evidence must be outside source')
    out.mkdir(parents=True, exist_ok=False)
    root = Path(os.environ['RUNNER_TEMP']).resolve()
    work = Path(tempfile.mkdtemp(prefix='ob-auth-android-', dir=root)).resolve()
    runtime.require(work.parent == root, 'Owned work escaped runner temp')
    env = os.environ.copy()
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
        runtime.require(not env.get(key), 'Direct-network lane has inherited proxy')
    compiler = Path(env['ANDROID_NDK_HOME']) / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
    target = work / 'target'
    env.update({'CARGO_TARGET_DIR': str(target), 'CARGO_BUILD_JOBS': '4',
        'CARGO_PROFILE_DEV_DEBUG': '0', 'CARGO_PROFILE_TEST_DEBUG': '0', 'CARGO_INCREMENTAL': '0',
        'CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER': str(compiler/'x86_64-linux-android24-clang'),
        'CC_x86_64_linux_android': str(compiler/'x86_64-linux-android24-clang'),
        'CXX_x86_64_linux_android': str(compiler/'x86_64-linux-android24-clang++'),
        'AR_x86_64_linux_android': str(compiler/'llvm-ar'), 'RUSTFLAGS': ''})
    env.pop('CARGO_ENCODED_RUSTFLAGS', None)
    env.pop('RUSTC_WRAPPER', None)
    env['PATH'] = str(compiler) + os.pathsep + env['PATH']
    report = {'source': SOURCE, 'native': NATIVE, 'apk_built': False, 'app_executed': False,
        'account_access': False, 'credentials_loaded': False, 'authentication_tested': False,
        'cloudkit_tested': False, 'network': {'passed': False}}
    runner = None
    prototype = source/'tooling/cloud_sync/corten_mac_validation_probe'
    owned_prototype = False
    started = time.monotonic()

    def interrupted(signum, _frame):
        raise RuntimeError('Diagnostic interrupted by signal ' + str(signum))

    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}

    def checked(name, argv, seconds):
        result = command(argv, source, out/(name+'.log'), seconds, env)
        report[name] = result
        print(json.dumps({'phase': name, **result}), flush=True)
        runtime.require(result['exit'] == 0, name + ' failed; inspect before retry')

    try:
        report['pins'] = verify_source(source)
        runtime.require(shutil.disk_usage(work).free >= 12*1024**3, 'Need12GiB free')
        runtime.require(not prototype.exists(), 'Prototype destination must be fresh')
        shutil.copytree(TOOLS/'corten_mac_validation_probe', prototype)
        owned_prototype = True
        with overlay(source, out, env) as original_lock:
            report['candidate_hashes'] = verify_overlay_source(source)
            manifest = str(source/'rust/Cargo.toml')
            checked('fetch', ['cargo', 'fetch', '--manifest-path', manifest], 300)
            report['added_pins'] = unchanged_registry_pins(original_lock, (source/'rust/Cargo.lock').read_bytes())
            report['resolved_lock_sha256'] = digest(source/'rust/Cargo.lock')
            auth = source/AUTH
            before = auth.read_bytes()
            report['auth_source_sha256'] = hashlib.sha256(before.replace(b'\r\n', b'\n')).hexdigest()
            report['test_overlay_sha256'] = digest(TEMPLATE)
            try:
                auth.write_bytes(before + b'\n' + TEMPLATE.read_bytes())
                checked('build', ['cargo', 'test', '--offline', '--locked', '--manifest-path', manifest,
                    '-p', 'icloud_auth', '--lib', '--no-run', '--target', TARGET, '--message-format=json'], 900)
                binary = test_executable((out/'build.log').read_text(), target)
                report['binary'] = elf(binary, 62)
                checked('elf', [str(compiler/'llvm-readelf'), '-l', '-d', str(binary)], 20)
                dynamic = (out/'elf.log').read_text()
                runtime.require('/system/bin/linker64' in dynamic and 'libc.so.6' not in dynamic,
                                'Not an Android-linked binary')
            finally:
                auth.write_bytes(before)
            verify_overlay_source(source)
        report['restored_pins'] = verify_source(source)
        runner = runtime.Runner(sdk, out, work)
        runtime.boot_owned_runtime(runner, 'on', True)
        for name in ('private_dns_mode', 'private_dns_specifier', 'http_proxy'):
            _, raw = runner.adb('network-setting-'+name, 'shell', 'settings', 'get', 'global', name)
            value = raw.decode().strip()
            allowed = {'null', 'off', 'opportunistic'} if name == 'private_dns_mode' else {'null', '', ':0'}
            runtime.require(value in allowed, 'Custom Android DNS/proxy present')
        remote = '/data/local/tmp/ob-auth-public-transport'
        runner.adb('push', 'push', str(binary), remote, timeout=60)
        runner.adb('mode', 'shell', 'chmod', '700', remote)
        code, raw = runner.adb('android-auth-transport', 'shell', remote, '--exact', TEST,
            '--ignored', '--nocapture', '--test-threads=1', timeout=45, required=False)
        report['network'] = observations(code, raw)
        runner.adb('remove-owned-probe', 'shell', 'rm', remote)
    except Exception as error:
        report['failure'] = str(error)
    finally:
        for group in list(OWNED_GROUPS):
            try: os.killpg(group, signal.SIGKILL)
            except ProcessLookupError: pass
        report['cleanup'] = runner.cleanup() if runner else []
        if owned_prototype:
            shutil.rmtree(prototype)
        try:
            report['final_source_pins'] = verify_source(source)
        except Exception as error:
            report['restoration_failure'] = str(error)
        if all(item['exited'] for item in report['cleanup']):
            shutil.rmtree(work)
        report['owned_work_removed'] = not work.exists()
        report['seconds'] = round(time.monotonic()-started, 3)
        report['passed'] = (report['network']['passed'] and len(report['cleanup']) == 2
            and all(item['exited'] for item in report['cleanup']) and report['owned_work_removed']
            and 'failure' not in report and 'restoration_failure' not in report)
        (out/'receipt.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'sdk', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.source.resolve(), args.sdk.resolve(), args.out.resolve()))
