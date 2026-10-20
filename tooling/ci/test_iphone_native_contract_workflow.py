"""Native decompiler opt-in cannot widen the existing secret-free Mac lane."""
from pathlib import Path
import re
import unittest


class NativeContractWorkflowIsolation(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).resolve().parents[2] / '.github/workflows/gce-runner-pilot.yml').read_text()
        self.job = re.split(r'\n  [a-z][a-z0-9-]+:\n',
                            self.text.split('  iphone-activation-static:\n', 1)[1], maxsplit=1)[0]

    def test_native_contract_analysis_is_default_false_and_only_static_job_sees_it(self):
        block = re.split(r'\n      [a-z][a-z0-9_]*:\n',
                         self.text.split('      native_contract_analysis:\n', 1)[1], maxsplit=1)[0]
        self.assertIn('default: false', block)
        self.assertIn('type: boolean', block)
        self.assertIn('NATIVE_CONTRACT_ANALYSIS: ${{ inputs.native_contract_analysis || false }}', self.job)
        outside = self.text.replace(self.job, '')
        self.assertNotIn('NATIVE_CONTRACT_ANALYSIS:', outside)

    def test_contract_opt_in_keeps_existing_vm_exclusion_and_secret_free_owned_lane(self):
        creator = self.text.split('  create-runner:\n', 1)[1].split('    runs-on:', 1)[0]
        self.assertIn("inputs.validation_mode != 'iphone-activation-static-only'", creator)
        for value in ("inputs.validation_mode == 'iphone-activation-static-only'",
                      'runs-on: macos-15', 'timeout-minutes: 25', 'contents: read',
                      'submodules: false', 'persist-credentials: false', 'ref: ${{ github.sha }}'):
            self.assertIn(value, self.job)
        self.assertIn('NATIVE_CONTRACT_ANALYSIS:', self.job)
        for value in ('secrets.', 'id-token:', 'gcloud ', 'flutter ', 'sudo ', 'source_ref'):
            self.assertNotIn(value, self.job)
        self.assertEqual(self.job.count('uses: actions/checkout@'), 1)
        self.assertIn("-p 'test_iphone_native_contract*.py' -v", self.job)


if __name__ == '__main__':
    unittest.main()
