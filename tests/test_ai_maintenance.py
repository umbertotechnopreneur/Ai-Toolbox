"""Run maintenance only in an isolated, tiny replica; never reset the real toolbox."""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import ai_toolbox as ai
import folder_organizer as organizer


class AiMaintenanceTests(unittest.TestCase):
    # Parameter self: isolated fixture owner; Windows is required by this app.
    def setUp(self):
        if os.name != "nt":
            self.skipTest("Windows PowerShell maintenance")
        self.temporary = tempfile.TemporaryDirectory(prefix="ai-reset-fixture-", dir=ai.ROOT / "temp")
        self.root = Path(self.temporary.name).resolve()
        self.assertTrue(self.root.is_relative_to((ai.ROOT / "temp").resolve()))
        self.assertNotEqual(self.root, ai.ROOT.resolve())
        self.addCleanup(self.temporary.cleanup)
        self.script = self.root / "scripts/Ai-Maintenance.ps1"
        self.script.parent.mkdir()
        shutil.copy2(ai.ROOT / "scripts/Ai-Maintenance.ps1", self.script)
        self.ps = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        (self.root / "config").mkdir()
        for name in ("downloads.lock.json", "toolbox.json", "transcription.json"):
            shutil.copy2(ai.ROOT / "config" / name, self.root / "config" / name)
        self.managed = ["models/Qwen3-VL-4B/model.gguf", "models/whisper-small/model.bin",
                        "runtime/llama-b11146-cpu/llama-server.exe", "runtime/transcription/packages-1/fake.pyd",
                        "cache/catalog/catalog.json", "downloads/transcription/pip.whl"]
        self.preserved = ["runtime/python/python.exe", "runtime/ffmpeg/ffprobe.exe", "runtime/fonts/font.ttf",
                          "input/original.jpg", "output/clean.jpg", "config/ui-options.json",
                          "models/custom-user-model/keep.bin", "logs/photo-organizer/previous.log"]
        for relative in self.managed + self.preserved:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic fixture")

    # Parameter self: fixture owner.
    # Parameter mode: Info or Reset, always run against the copied fixture script.
    # Parameter options: explicit confirmation/protected paths passed as literal arguments.
    # Exceptions: a hung child fails the test, never touches another toolbox.
    def invoke(self, mode="Info", *options):
        self.assertTrue(self.script.resolve().is_relative_to(self.root))
        return subprocess.run([str(self.ps), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                               "-File", str(self.script), "-Mode", mode, *options], cwd=self.root,
                              capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
                              creationflags=subprocess.CREATE_NO_WINDOW)

    # Parameter self: fixture owner.
    def plan(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        line = next(line for line in result.stdout.splitlines() if line.startswith("AI-MAINTENANCE-PLAN "))
        return json.loads(line.removeprefix("AI-MAINTENANCE-PLAN "))

    # Parameter self: fixture owner.
    def assert_preserved(self):
        for relative in self.preserved:
            self.assertEqual((self.root / relative).read_bytes(), b"synthetic fixture", relative)

    # Parameter self: active regression case.
    def test_inventory_is_read_only_and_hash_is_stable_between_processes(self):
        first, second = self.plan(), self.plan()
        self.assertEqual(first["hash"], second["hash"])
        self.assertEqual(first["bytes"], len(self.managed) * len(b"synthetic fixture"))
        for path in first["paths"]:
            self.assertTrue(Path(path).resolve().is_relative_to(self.root))
        for relative in self.managed:
            self.assertTrue((self.root / relative).is_file())
        self.assert_preserved()

    # Parameter self: active regression case.
    def test_missing_confirmation_refuses_every_removal(self):
        result = self.invoke("Reset")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REMOVED:", result.stdout)
        self.assert_preserved()

    # Parameter self: active regression case.
    def test_changed_inventory_requires_a_new_confirmation(self):
        plan = self.plan()
        (self.root / self.managed[0]).write_bytes(b"changed fixture content")
        result = self.invoke("Reset", "-ConfirmHash", plan["hash"])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REMOVED:", result.stdout)
        self.assert_preserved()

    # Parameter self: active regression case.
    def test_exact_reset_removes_only_allowlisted_fixture_components(self):
        plan = self.plan()
        result = self.invoke("Reset", "-ConfirmHash", plan["hash"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for relative in self.managed:
            self.assertFalse((self.root / relative).exists(), relative)
        self.assert_preserved()
        self.assertEqual(self.plan()["bytes"], 0)
        self.assertIn("REMOVE INTENT:", result.stdout)
        self.assertIn("RESET COMPLETATO", result.stdout)

    # Parameter self: active regression case.
    def test_selected_media_overlap_refuses_reset(self):
        plan = self.plan()
        result = self.invoke("Reset", "-ConfirmHash", plan["hash"], "-ProtectedPathsJson",
                             json.dumps([str(self.root / "models")]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overlaps reset", result.stdout)
        self.assertNotIn("REMOVED:", result.stdout)
        self.assert_preserved()

    # Parameter self: active regression case.
    def test_invalid_package_path_fails_before_removal(self):
        lock_path = self.root / "config/downloads.lock.json"
        lock = json.loads(lock_path.read_text(encoding="utf-8-sig"))
        package = next(package for package in lock["downloads"] if "backend" in package)
        package["extract_to"] = "runtime/../../output"
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        result = self.invoke("Reset", "-ConfirmHash", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REMOVED:", result.stdout)
        self.assert_preserved()

    # Parameter self: active regression case; a held fixture handle denies removal.
    def test_locked_file_stops_reset_and_preserves_shared_runtime(self):
        plan = self.plan()
        with organizer.source_stream(self.root / self.managed[0], True):
            result = self.invoke("Reset", "-ConfirmHash", plan["hash"])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / self.managed[0]).exists())
        self.assertIn("ERRORE:", result.stdout)
        self.assert_preserved()

    # Parameter self: active regression case; both junction and destination are inside the fixture.
    def test_junction_refuses_inventory_and_leaves_destination_intact(self):
        destination = self.root / "outside-managed-scope"
        destination.mkdir()
        sentinel = destination / "keep.txt"
        sentinel.write_bytes(b"keep")
        junction = self.root / "models/whisper-small/link"
        command = "New-Item -ItemType Junction -Path '" + str(junction).replace("'", "''") + "' -Target '" + str(destination).replace("'", "''") + "' | Out-Null"
        result = subprocess.run([str(self.ps), "-NoProfile", "-NonInteractive", "-EncodedCommand",
                                 base64.b64encode(command.encode("utf-16-le")).decode()],
                                capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(result.returncode, 0)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("AI-MAINTENANCE-PLAN ", result.stdout)
        self.assertEqual(sentinel.read_bytes(), b"keep")

    # Parameter self: active regression case using a synthetic process record, never killing a process.
    def test_active_toolbox_process_refuses_reset(self):
        plan = self.plan()
        quote = lambda value: "'" + str(value).replace("'", "''") + "'"
        command = ("function global:Get-CimInstance { [CmdletBinding()] param([string]$ClassName,[int]$OperationTimeoutSec) "
                   "[pscustomobject]@{ProcessId=999999;Name='python.exe';ExecutablePath="
                   + quote(self.root / "runtime/python/python.exe") + ";CommandLine='fixture'} }; & "
                   + quote(self.script) + " -Mode Reset -ConfirmHash " + quote(plan["hash"]))
        result = subprocess.run([str(self.ps), "-NoProfile", "-NonInteractive", "-EncodedCommand",
                                 base64.b64encode(command.encode("utf-16-le")).decode()], cwd=self.root,
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Active toolbox process", result.stdout)
        self.assertNotIn("REMOVED:", result.stdout)
        self.assert_preserved()


if __name__ == "__main__":
    unittest.main()
