"""Only synthetic fixtures; never invoke Windows recycling or inspect photo archives."""

import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ai_toolbox as ai
import cleanup_processed as cleanup
from job_log import JobLog


class FixtureRecycler:
    # Parameter self: fixture-only quarantine owner, unavailable from CLI.
    # Parameter root: isolated test directory, never a real Recycle Bin.
    def __init__(self, root):
        self.root = root
        self.calls = []

    # Parameter self: fixture quarantine owner.
    # Parameter path: synthetic original file.
    # Parameter source: fixture input root.
    # Parameter digest: expected synthetic content hash.
    def recycle(self, path, source, digest):
        if not path.is_relative_to(source) or not source.is_relative_to(self.root.parent):
            raise AssertionError("Fixture escaped its temporary root")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise AssertionError("Wrong fixture hash")
        self.root.mkdir(exist_ok=True)
        destination = self.root / (str(len(self.calls)) + "-" + path.name)
        shutil.move(str(path), destination)
        self.calls.append(path)
        return {"recycled": True, "recycle_path": str(destination)}


class CleanupTests(unittest.TestCase):
    # Parameter self: isolated fixture owner.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cleanup-test-", dir=ai.ROOT / "temp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source, self.target = self.root / "originals", self.root / "archive"
        self.source.mkdir(); self.target.mkdir()
        self.recycler = FixtureRecycler(self.root / "quarantine")
        self.events = []

    # Parameter self: fixture owner.
    # Parameter name: synthetic original filename.
    # Parameter content: tiny byte sequence for both independent files.
    # Parameter metadata: whether to include locator metadata.
    def pair(self, name="one.txt", content=b"AAAA", metadata=True):
        original = self.source / name
        original.write_bytes(content)
        copy = self.target / ("clean-" + name)
        copy.write_bytes(content)
        if metadata:
            Path(str(copy) + ".meta.json").write_text(json.dumps({
                "sha256": hashlib.sha256(content).hexdigest(), "size_bytes": len(content),
                "originals": [{"path": str(original)}], "copied_to": "Z:/obsolete/path.txt"
            }), encoding="utf-8")
        return original, copy

    # Parameter self: fixture owner.
    # Parameter options: optional preview bounds or logging receiver.
    def plan(self, **options):
        return cleanup.run_cleanup(self.source, self.target, callback=options.pop("callback", self.events.append), **options)

    # Parameter self: fixture owner.
    # Parameter plan: previously persisted synthetic preview.
    # Parameter callback: optional failure-injection event receiver.
    def apply(self, plan, callback=None):
        return cleanup.run_cleanup(self.source, self.target, mode="apply", plan_id=plan["plan_id"],
                                   confirmation=plan["confirmation_hash"], callback=callback or self.events.append,
                                   recycler=self.recycler)

    # Parameter self: active regression case.
    def test_preview_hashes_but_never_recycles_or_starts_ai(self):
        original, copy = self.pair()
        with patch.object(ai, "running_server", side_effect=AssertionError("AI started")), \
                patch.object(cleanup.RecycleBridge, "recycle", side_effect=AssertionError("Real recycling")):
            summary = self.plan()
        self.assertEqual(summary["matched"], 1)
        self.assertEqual(original.read_bytes(), copy.read_bytes())
        self.assertEqual(self.recycler.calls, [])
        match = next(event for event in self.events if event["event"] == "match")
        self.assertEqual(match["method"], "metadati + SHA-256")

    # Parameter self: active regression case.
    def test_hash_fallback_without_metadata(self):
        self.pair(metadata=False)
        self.assertEqual(self.plan()["matched"], 1)
        self.assertEqual(next(event for event in self.events if event["event"] == "match")["method"], "SHA-256")

    # Parameter self: active regression case.
    def test_malformed_sidecar_still_allows_hash_fallback(self):
        _, copy = self.pair()
        Path(str(copy) + ".meta.json").write_text("bad JSON", encoding="utf-8")
        self.assertEqual(self.plan()["matched"], 1)
        self.assertTrue(any(event.get("action") == "sidecar_unusable" for event in self.events))

    # Parameter self: active regression case.
    def test_sidecar_and_same_size_are_never_evidence(self):
        original, copy = self.pair()
        copy.write_bytes(b"BBBB")
        plan = self.plan()
        self.assertEqual((plan["matched"], plan["kept"]), (0, 1))
        self.assertEqual(original.read_bytes(), b"AAAA")

    # Parameter self: active regression case.
    def test_target_hash_is_reused_only_for_unchanged_fingerprint(self):
        self.pair()
        self.plan(); self.events.clear()
        self.assertEqual(self.plan()["matched"], 1)
        self.assertTrue(any(event.get("action") == "target_hash_cache_hit" for event in self.events))
        self.assertFalse(any(event.get("action") == "target_hash_verified" for event in self.events))

    # Parameter self: active regression case.
    def test_changed_target_with_restored_size_mtime_invalidates_cache(self):
        original, copy = self.pair()
        self.plan(); self.events.clear()
        saved = copy.stat()
        copy.write_bytes(b"BBBB")
        os.utime(copy, ns=(saved.st_atime_ns, saved.st_mtime_ns))
        self.assertEqual(self.plan()["matched"], 0)
        self.assertEqual(original.read_bytes(), b"AAAA")
        self.assertTrue(any(event.get("action") == "target_hash_verified" for event in self.events))

    # Parameter self: active regression case.
    def test_unavailable_change_signature_disables_cache(self):
        self.pair(); self.plan(); self.events.clear()
        actual = cleanup.fingerprint
        with patch.object(cleanup, "fingerprint", side_effect=lambda path: {**actual(path), "strong": False}):
            self.assertEqual(self.plan()["matched"], 1)
        self.assertTrue(any(event.get("action") == "target_hash_verified" for event in self.events))

    # Parameter self: active regression case.
    def test_apply_moves_only_proven_fixture_and_keeps_target(self):
        original, copy = self.pair()
        unknown = self.source / "different.txt"; unknown.write_bytes(b"BBBB")
        plan = self.plan()
        result = self.apply(plan)
        self.assertEqual(result["deleted"], 1)
        self.assertFalse(original.exists())
        self.assertTrue(self.source.is_dir())
        self.assertEqual(unknown.read_bytes(), b"BBBB")
        self.assertEqual(copy.read_bytes(), b"AAAA")

    # Parameter self: active regression case.
    def test_repeat_apply_and_restored_file_require_new_preview(self):
        original, _ = self.pair()
        plan = self.plan(); self.apply(plan)
        self.assertEqual(self.apply(plan)["already_done"], 1)
        original.write_bytes(b"AAAA")
        self.assertEqual(self.apply(plan)["already_done"], 1)
        self.assertTrue(original.exists())
        self.assertEqual(len(self.recycler.calls), 1)
        self.assertEqual(self.apply(self.plan())["deleted"], 1)

    # Parameter self: active regression case.
    def test_changed_source_after_preview_is_kept(self):
        original, _ = self.pair()
        plan = self.plan(); original.write_bytes(b"BBBB")
        result = self.apply(plan)
        self.assertEqual((result["deleted"], result["kept"]), (0, 1))
        self.assertEqual(original.read_bytes(), b"BBBB")

    # Parameter self: active regression case.
    def test_changed_or_missing_target_after_preview_is_kept(self):
        original, copy = self.pair()
        plan = self.plan(); copy.rename(self.root / "moved-copy.txt")
        self.assertEqual(self.apply(plan)["deleted"], 0)
        self.assertTrue(original.exists())

    # Parameter self: active regression case.
    def test_target_is_write_locked_through_the_recycle_callback(self):
        if os.name != "nt": self.skipTest("Windows share modes")
        _, copy = self.pair(); plan = self.plan()
        recycle = self.recycler.recycle

        # Parameter path: scoped synthetic source file.
        # Parameter source: fixture root.
        # Parameter digest: verified synthetic hash.
        def check_lock(path, source, digest):
            with self.assertRaises(PermissionError): copy.write_bytes(b"BBBB")
            return recycle(path, source, digest)

        with patch.object(self.recycler, "recycle", side_effect=check_lock):
            self.assertEqual(self.apply(plan)["deleted"], 1)
        self.assertEqual(copy.read_bytes(), b"AAAA")

    # Parameter self: active regression case.
    def test_apply_requires_exact_token(self):
        original, _ = self.pair(); plan = self.plan()
        plan["confirmation_hash"] = "0" * 64
        with self.assertRaises(ValueError): self.apply(plan)
        self.assertTrue(original.exists())

    # Parameter self: active regression case.
    def test_apply_without_preview_is_refused(self):
        original, _ = self.pair()
        with self.assertRaises(ValueError):
            cleanup.run_cleanup(self.source, self.target, mode="apply", callback=self.events.append, recycler=self.recycler)
        self.assertTrue(original.exists())

    # Parameter self: active regression case.
    def test_preview_is_bounded_per_confirmation(self):
        self.pair("one.txt"); self.pair("two.txt", b"BBBB")
        plan = self.plan(limit=1)
        self.assertEqual((plan["matched"], plan["checked"], plan["remaining"]), (1, 1, 1))
        self.assertEqual(self.apply(plan)["deleted"], 1)
        self.assertEqual(len(list(self.source.iterdir())), 1)

    # Parameter self: active regression case.
    def test_empty_files_are_preserved(self):
        original, _ = self.pair(content=b"")
        self.assertEqual(self.plan()["matched"], 0)
        self.assertTrue(original.exists())

    # Parameter self: active regression case.
    def test_hardlinked_target_is_not_an_independent_copy(self):
        original = self.source / "one.txt"; original.write_bytes(b"AAAA")
        os.link(original, self.target / "same.txt")
        self.assertEqual(self.plan()["matched"], 0)

    # Parameter self: active regression case.
    def test_scopes_and_traversal_are_refused(self):
        with self.assertRaises(ValueError): cleanup.validate_paths(self.source, self.source)
        with self.assertRaises(ValueError): cleanup.validate_paths(self.source, self.source / "nested")
        with self.assertRaises(ValueError): cleanup.scoped_file(self.target, "../originals/one.txt")
        with self.assertRaises(ValueError): cleanup.run_cleanup(self.source, self.target, limit=501)

    # Parameter self: active regression case.
    def test_index_mode_does_not_recycle(self):
        original, _ = self.pair()
        result = self.plan(mode="index")
        self.assertEqual((result["indexed"], result["deleted"]), (1, 0))
        self.assertTrue(original.exists())

    # Parameter self: active regression case.
    def test_intent_log_failure_prevents_recycling(self):
        original, _ = self.pair(); plan = self.plan()

        # Parameter event: controlled failure before the first authorized action.
        def failing_log(event):
            if event.get("action") == "recycle_intent": raise OSError("Disk full")
            self.events.append(event)

        self.assertTrue(self.apply(plan, failing_log)["stopped"])
        self.assertTrue(original.exists())
        self.assertEqual(self.recycler.calls, [])

    # Parameter self: active regression case.
    def test_receipt_failure_stops_batch_and_reports_uncertainty(self):
        self.pair("one.txt"); self.pair("two.txt", b"BBBB"); plan = self.plan()

        # Parameter event: controlled post-operation log failure.
        def failing_receipt(event):
            if event.get("action") == "recycled": raise OSError("Disk full")
            self.events.append(event)

        result = self.apply(plan, failing_receipt)
        self.assertEqual((result["uncertain"], result["stopped"]), (1, True))
        self.assertEqual(len(self.recycler.calls), 1)
        self.assertEqual(len(list(self.source.iterdir())), 1)
        self.assertFalse(result["ready_for_review"])

    # Parameter self: active regression case.
    def test_pause_and_resume_preview(self):
        self.pair("one.txt"); self.pair("two.txt", b"BBBB")

        # Parameter event: requests pause after the first successful preview match.
        def pause_on_match(event):
            self.events.append(event)
            if event["event"] == "match": (self.target / cleanup.CONTROL / "pause.request").write_bytes(b"pause")

        self.assertTrue(self.plan(callback=pause_on_match)["stopped"])
        self.assertEqual(self.plan()["matched"], 2)
        self.assertEqual(self.recycler.calls, [])

    # Parameter self: active regression case.
    def test_job_logs_live_under_tool_root_and_preserve_unicode(self):
        with JobLog("cleanup", {"source": "C:/unrelated/citta"}, root=self.root) as log:
            log.write({"event": "log", "action": "recycle_intent", "path": "città"})
        self.assertEqual(log.path.parent, self.root / "logs/photo-organizer")
        records = [json.loads(line) for line in log.path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(records[1]["path"], "città")
        self.assertEqual(records[-1]["status"], "finished")


if __name__ == "__main__":
    unittest.main()
