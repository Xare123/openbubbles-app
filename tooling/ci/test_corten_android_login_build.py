"""Build/packaging guards only, not Android or account evidence."""
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

import run_corten_android_login_build as B
import sealed_component as S


class PrivateBuildTests(unittest.TestCase):
    def test_private_overlay_restores_byte_identical_files_after_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = {
                'android/app/build.gradle':b'    compileSdk 36\n    defaultConfig {\n',
                'android/gradle.properties':b'org.gradle.jvmargs=-Xmx6400M\nandroid.useAndroidX=true\n',
                B.EXTRA_TRACKED[3]:b'if (buildType == "debug") {',
                B.EXTRA_TRACKED[4]:b"String get _toolchain => _buildOptions?.toolchain.name ?? 'stable';",
                'pubspec.lock':b'preserve lock',
            }
            (root/'rust').mkdir()
            for name, raw in original.items():
                path = root/name
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(raw)
            with self.assertRaisesRegex(RuntimeError,'injected'):
                with B.build_overlay(root,'patch.crates-io.unicorn-engine.path="/owned"'):
                    config = json.loads((root/'rust/cargokit.yaml').read_text())
                    self.assertIn('corten-dev-validation', config['cargo']['debug']['extra_flags'])
                    self.assertIn('--locked', config['cargo']['debug']['extra_flags'])
                    self.assertIn('1.98.1',(root/B.EXTRA_TRACKED[4]).read_text())
                    self.assertNotIn('abiFilters',(root/'android/app/build.gradle').read_text())
                    (root/'pubspec.lock').write_text('changed')
                    raise RuntimeError('injected')
            self.assertEqual({name:(root/name).read_bytes() for name in original},original)
            self.assertFalse((root/'rust/cargokit.yaml').exists())

    def test_reject_existing_cargokit_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            (root/'rust').mkdir()
            (root/'rust/cargokit.yaml').write_text('preserve')
            with self.assertRaisesRegex(RuntimeError,'refuse existing'):
                with B.build_overlay(root,'unused'):
                    self.fail('accepted')
            self.assertEqual((root/'rust/cargokit.yaml').read_text(),'preserve')

    def test_shape_drift_fails_closed(self):
        for text in ('absent','old old'):
            with self.assertRaisesRegex(RuntimeError,'differs'):
                B.replace_once(text,'old','new')

    def test_flutter_packaging_is_explicit_without_conflicting_ndk_filters(self):
        source = Path(B.__file__).read_text()
        self.assertIn('"--target-platform","android-x64","--split-per-abi"',source)
        self.assertIn('app-x86_64-canary-debug.apk',source)

    def test_only_resolved_plugin_targets_changed_and_restored_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            cache=root/'cache'
            (root/'.dart_tool').mkdir()
            packages=[]
            files=[]
            for name in ('irondash_engine_context','super_native_extensions'):
                package=cache/name
                plugin=package/'cargokit/gradle/plugin.gradle'
                plugin.parent.mkdir(parents=True)
                plugin.write_bytes(b'if (buildType == "debug") {\n original\r\n')
                files.append(plugin)
                packages.append({'name':name,'rootUri':package.as_uri()})
            (root/'.dart_tool/package_config.json').write_text(json.dumps({'packages':packages}))
            originals=[f.read_bytes() for f in files]
            with self.assertRaisesRegex(RuntimeError,'injected'):
                with B.single_target_pub_plugins(root,cache):
                    for file in files:
                        self.assertIn('target-platform',file.read_text())
                    raise RuntimeError('injected')
            self.assertEqual([f.read_bytes() for f in files],originals)

    def test_real_x64_apk_required_and_extra_abi_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk=Path(temporary)/'test.apk'
            elf=bytearray(32)
            elf[:6]=b'\x7fELF\x02\x01'
            struct.pack_into('<HH',elf,16,3,62)
            with zipfile.ZipFile(apk,'w') as archive:
                for name in ('libflutter.so','librust_lib_bluebubbles.so',
                             'libirondash_engine_context_native.so','libsuper_native_extensions.so'):
                    archive.writestr('lib/x86_64/'+name,elf)
            self.assertEqual(B.check_apk(apk)['abi'],'x86_64')
            with zipfile.ZipFile(apk,'a') as archive:
                archive.writestr('lib/arm64-v8a/wrong.so',elf)
            with self.assertRaisesRegex(RuntimeError,'single-x64'):
                B.check_apk(apk)

    def test_login_sealed_target_is_explicit_and_rejects_unexpected_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            S.prepare(root/'keys')
            elf=bytearray(32)
            elf[:6]=b'\x7fELF\x02\x01'
            struct.pack_into('<HH',elf,16,3,62)
            apk=io.BytesIO()
            with zipfile.ZipFile(apk,'w') as z:
                z.writestr('lib/x86_64/librust_lib_bluebubbles.so',elf)
            bundle=root/'bundle.zip'
            with zipfile.ZipFile(bundle,'w') as z:
                z.writestr('app-canary-debug.apk',apk.getvalue())
                z.writestr('corten-mac-validation-probe',elf)
            receipt=S.seal(bundle,root/'keys/public.pem',root/'sealed','a'*40,'b'*40,target=S.LOGIN_TARGET)
            with self.assertRaisesRegex(ValueError,'reviewed'):
                S.unseal(root/'sealed',root/'keys/private.pem',root/'wrong',receipt['sha256'],'b'*40)
            S.unseal(root/'sealed',root/'keys/private.pem',root/'restored',receipt['sha256'],'b'*40,S.LOGIN_TARGET)
            self.assertEqual(bundle.read_bytes(),(root/'restored').read_bytes())
            with zipfile.ZipFile(bundle,'a') as z:
                z.writestr('../unowned','reject')
            with self.assertRaisesRegex(ValueError,'members'):
                S.validate_payload(bundle.read_bytes(),S.LOGIN_TARGET)

    def test_workflow_keeps_credentials_and_gce_mutation_out_of_hosted_lane(self):
        workflow=(B.TOOLS.parent/'.github/workflows/gce-runner-pilot.yml').read_text()
        job=workflow.split('  corten-android-login:',1)[1].split('  corten-validator:',1)[0]
        self.assertIn('runs-on: ubuntu-24.04',job)
        self.assertIn('test -c /dev/kvm',job)
        self.assertIn('--accel on',job)
        self.assertNotIn('secrets.',job)
        self.assertNotIn('id-token: write',job)
        self.assertNotIn('gcloud',job)
        create=workflow.split('  create-runner:',1)[1].split('    steps:',1)[0]
        self.assertIn("inputs.validation_mode != 'corten-android-login-only'",create)


if __name__=='__main__':
    unittest.main()
