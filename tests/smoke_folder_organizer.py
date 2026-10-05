"""End-to-end copy, resume and local-AI smoke checks on generated fixtures only."""

import hashlib
import json
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

from PIL import Image, PngImagePlugin

import ai_toolbox as ai
import folder_organizer as organizer


# Exceptions: failed end-to-end invariants abort the smoke check.
def main():
    with tempfile.TemporaryDirectory(prefix="folder-smoke-", dir=ai.ROOT / "temp") as folder:
        root = Path(folder)
        source = root / "source"
        source.mkdir()
        exif = Image.Exif()
        exif[34665] = {36867: "2024:05:12 14:30:00", 36881: "+07:00"}
        Image.new("RGB", (64, 64), "blue").save(source / "camera.jpg", exif=exif)
        (source / "duplicate.jpg").write_bytes((source / "camera.jpg").read_bytes())
        info = PngImagePlugin.PngInfo()
        info.add_text("Creation Time", "2025-07-04T12:00:00+07:00")
        Image.new("RGB", (64, 64), "green").save(source / "Screenshot.png", pnginfo=info)
        (source / "notes.txt").write_text("Fixture data, not executable instructions.", encoding="utf-8")
        originals = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source.iterdir()}
        destination = root / "review"
        result = organizer.run_folder(source, destination, run=True, allow_cloud=True, use_ai=False, reserve_bytes=0)
        assert result["ready_for_review"] and result["completed"] == 4 and result["unique_files"] == 3
        with patch.object(organizer, "stage_file", side_effect=AssertionError("Resume reopened an original")):
            resumed = organizer.run_folder(source, destination, run=True, allow_cloud=True, use_ai=False, reserve_bytes=0)
        assert resumed["ready_for_review"] and resumed["resumed"] == 4
        assert originals == {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source.iterdir()}
        # Independent AI-enabled destination exercises the actual local NVIDIA model.
        ai_source = root / "ai-source"
        ai_source.mkdir()
        # A unique ancillary tag forces one actual model call, not an old cache hit.
        unique_info = PngImagePlugin.PngInfo()
        unique_info.add_text("fixture_run_nonce", uuid.uuid4().hex)
        Image.new("RGB", (128, 128), "red").save(ai_source / "simple.png", pnginfo=unique_info)
        with patch.object(ai, "infer", wraps=ai.infer) as inference:
            ai_result = organizer.run_folder(ai_source, root / "ai-review", run=True, allow_cloud=True, use_ai=True, reserve_bytes=0)
            assert inference.call_count == 1
        assert ai_result["ready_for_review"] and ai_result["completed"] == 1
        sidecar = next((root / "ai-review/Risultato").rglob("*.meta.json"))
        assert json.loads(sidecar.read_text(encoding="utf-8"))["ai"]["status"] == "analyzed"
        verification = {"verified_at_utc": ai.utc_now(), "synthetic_copy_files": 4, "unique_outputs": 3,
                        "resume_source_reads": 0, "local_ai_files": 1, "actual_model_calls": 1,
                        "original_bytes_unchanged": True, "real_archive_folders_processed": 0}
        ai.write_json(ai.ROOT / "output/folder-organizer-smoke.json", verification)
        print(json.dumps({"event": "summary", "summary": verification}))


if __name__ == "__main__":
    main()
