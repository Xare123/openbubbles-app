"""Offline composition guards for the separate, credential-free helper lane."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]


class USBControlBuildTests(unittest.TestCase):
    def test_lane_has_no_gce_apk_device_account_or_secret_input(self):
        workflow=(ROOT/".github/workflows/gce-runner-pilot.yml").read_text()
        job=workflow.split("  iphone-usb-control:\n",1)[1].split("\n  iphone-account-signing-preflight:",1)[0]
        self.assertIn("inputs.validation_mode == 'iphone-usb-control-only'",job)
        self.assertIn("runs-on: macos-15",job)
        self.assertIn("timeout-minutes: 25",job)
        self.assertIn("-p test_lifetime_native.py -v",job)
        self.assertIn("contents: read",job)
        for prohibited in ("secrets.","id-token: write","create-runner","adb ","gcloud ","-Run","TROLLVNC_PASSWORD:"):
            self.assertNotIn(prohibited,job)
        create=workflow.split("  create-runner:\n",1)[1].split("\n    runs-on:",1)[0]
        self.assertIn("inputs.validation_mode != 'iphone-usb-control-only'",create)

    def test_source_and_toolchain_are_fixed_and_runtime_password_not_bundled(self):
        build=(ROOT/"tooling/ios/trollvnc-usb-control/build.sh").read_text()
        fetch=(ROOT/"tooling/ios/trollvnc-usb-control/fetch_sdks.py").read_text()
        for text in ("cfdb737e72977d961eb7d0a8110d2fe1a58551d7","cfba89a53a05b4a1b822121158acc3669c20602f",
                     "--no-hardlinks --local","codesign --verify --deep --strict","prepare.CONFIG"):
            self.assertIn(text,build)
        self.assertNotIn("TROLLVNC_PASSWORD=",build)
        self.assertIn("Set :CFBundleVersion 280",build)
        self.assertNotIn("releases/latest",fetch)
        self.assertIn("137098923",fetch)
        self.assertIn("137098925",fetch)
        self.assertIn('filter="data"',fetch)


if __name__=="__main__":
    unittest.main()
