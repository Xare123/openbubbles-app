"""Pure guards for pinned artifact transfer. No network or SDK use."""
import copy
import unittest
import zipfile
import materialize as m


class MaterializeGuards(unittest.TestCase):
    def item(self):
        return dict(id=m.ARTIFACT_ID, expired=False, size_in_bytes=m.ZIP_SIZE,
                    name=f"GCE CloudKit V2 Canary APK {m.SOURCE} writer-true automatic-true",
                    workflow_run=dict(id=m.RUN_ID, head_sha=m.WORKFLOW_SHA,
                                      head_branch="agent/gce-runner-pilot"))

    def test_provenance_requires_exact_candidate_and_orchestrator(self):
        item = self.item()
        self.assertTrue(m.artifact_valid(item))
        for key, value in [("id", 1), ("expired", True), ("size_in_bytes", 0), ("name", "other")]:
            with self.subTest(key=key):
                changed = dict(item, **{key:value})
                self.assertFalse(m.artifact_valid(changed))
        for key, value in [("id", 1), ("head_sha", m.SOURCE), ("head_branch", "other")]:
            with self.subTest(key=key):
                changed = copy.deepcopy(item)
                changed["workflow_run"][key] = value
                self.assertFalse(m.artifact_valid(changed))

    def test_storage_redirect_keeps_tls_and_uses_known_hosts_only(self):
        self.assertEqual(m.storage_host("https://productionresultssa0.blob.core.windows.net/path?sig=fake"),
                         "productionresultssa0.blob.core.windows.net")
        for url in ("http://a.blob.core.windows.net/file", "https://blob.core.windows.net.evil.test/file",
                    "https://a:b@a.blob.core.windows.net/file", "https://a.blob.core.windows.net:8080/file",
                    "https://api.github.com/file"):
            with self.subTest(url=url), self.assertRaises(RuntimeError):
                m.storage_host(url)

    def test_zip_allows_only_the_qualified_apk(self):
        item = zipfile.ZipInfo("app-canary-debug.apk")
        item.file_size = m.APK_SIZE
        self.assertIs(m.only_apk([item]), item)
        for entries in ([], [item, item], [zipfile.ZipInfo("../app-canary-debug.apk")]):
            with self.assertRaises(RuntimeError):
                m.only_apk(entries)
        item.flag_bits = 1
        with self.assertRaises(RuntimeError):
            m.only_apk([item])


if __name__ == "__main__":
    unittest.main(verbosity=2)
