"""One exact hosted build lane, no GCE/APK/signing/account permissions."""
from pathlib import Path
import re
import unittest


class QualifierWorkflowIsolation(unittest.TestCase):
    def test_exact_mode_excludes_vm_creation_and_has_one_secret_free_job(self):
        text=(Path(__file__).resolve().parents[2]/".github/workflows/gce-runner-pilot.yml").read_text()
        mode="iphone-account-qualifier-fixture-only"
        self.assertIn("- "+mode,text)
        creator=text.split("  create-runner:\n",1)[1].split("    runs-on:",1)[0]
        self.assertIn("inputs.validation_mode != '"+mode+"'",creator)
        job=re.split(r"\n  [a-z][a-z0-9-]+:\n",text.split("  iphone-account-qualifier-fixture:\n",1)[1],maxsplit=1)[0]
        self.assertIn("inputs.validation_mode == '"+mode+"'",job)
        for required in ["runs-on: macos-15","timeout-minutes: 10","submodules: false","persist-credentials: false"]:
            self.assertIn(required,job)
        for forbidden in ["secrets.","id-token:","gcloud ","flutter ","source_ref", "sudo "]:
            self.assertNotIn(forbidden,job)
        self.assertEqual(job.count("uses: actions/checkout@"),1)


if __name__ == "__main__": unittest.main()
