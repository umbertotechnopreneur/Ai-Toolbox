"""Regression checks for locality denial, nested EXIF, and exact duplicates."""

import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from PIL import Image, PngImagePlugin

import analyze_local as analyzer


class LocalAnalysisTests(unittest.TestCase):
    # Parameter self: the active regression test case.
    def test_recall_attribute_is_rejected_before_windows_open(self):
        path = Mock(spec=Path)
        path.lstat.return_value = SimpleNamespace(st_file_attributes=0x00400000)
        with patch.object(analyzer, "windows_apis") as apis:
            with self.assertRaises(analyzer.LocalReadDenied):
                with analyzer.guarded_local_stream(path):
                    self.fail("Should never open offline contents")
            apis.assert_not_called()

    # Parameter self: the active regression test case.
    def test_incomplete_placeholder_is_rejected(self):
        path = Mock(spec=Path)
        path.lstat.return_value = SimpleNamespace(st_file_attributes=0x400, st_size=100)
        cloud = Mock()
        # The returned on-disk byte count is zero in the initialized structure.
        cloud.CfGetPlaceholderInfo.return_value = 0
        with self.assertRaises(analyzer.LocalReadDenied):
            analyzer.verify_placeholder(path, 1, cloud)

    # Parameter self: the active regression test case.
    def test_unverifiable_placeholder_is_rejected(self):
        path = Mock(spec=Path)
        path.lstat.return_value = SimpleNamespace(st_file_attributes=0x400, st_size=100)
        cloud = Mock()
        cloud.CfGetPlaceholderInfo.return_value = -1
        with self.assertRaises(analyzer.LocalReadDenied):
            analyzer.verify_placeholder(path, 1, cloud)

    # Parameter self: the active regression test case.
    def test_original_date_is_read_from_nested_exif(self):
        stream = io.BytesIO()
        exif = Image.Exif()
        exif[34665] = {36867: "2020:07:10 12:34:56", 36881: "+07:00"}
        Image.new("RGB", (8, 8)).save(stream, format="JPEG", exif=exif)
        metadata = analyzer.image_metadata(stream)
        self.assertNotIn("read_error", metadata)
        self.assertEqual(metadata["exif_dates"]["DateTimeOriginal"], "2020:07:10 12:34:56")
        record = {
            "image_metadata": metadata, "original_filename": "IMG-20210101-WA0001.jpg",
            "original_relative_path": "IMG-20210101-WA0001.jpg",
        }
        analyzer.enrich_dates(record)
        self.assertEqual(record["capture_date_source"], "exif_DateTimeOriginal")
        self.assertEqual(record["capture_timezone"], "+07:00")
        self.assertIn("embedded_date_vs_filename_conflict", record["date_issues"])

    # Parameter self: the active regression test case.
    def test_png_text_metadata_and_integrity_can_be_read_together(self):
        stream = io.BytesIO()
        info = PngImagePlugin.PngInfo()
        info.add_text("Creation Time", "2020-07-10T12:34:56")
        Image.new("RGB", (8, 8)).save(stream, format="PNG", pnginfo=info)
        metadata = analyzer.image_metadata(stream)
        self.assertNotIn("read_error", metadata)
        self.assertTrue(metadata["container_verified"])
        self.assertEqual(metadata["text_metadata"]["Creation Time"], "2020-07-10T12:34:56")

    # Parameter self: the active regression test case.
    def test_duplicates_exclude_empty_files_and_estimate_extra_copies(self):
        records = []
        for index, (digest, size) in enumerate((("same", 10), ("same", 10), ("different", 10), ("empty", 0), ("empty", 0))):
            records.append({
                "analysis_status": "analyzed", "sha256": digest, "size_bytes": size,
                "original_path": f"file-{index}.jpg", "extension_normalized": ".jpg",
                "category": "photo", "source_label": "test", "image_metadata": {},
            })
        with tempfile.TemporaryDirectory(prefix="photo-analysis-test-") as folder:
            summary = analyzer.save_reports(records, Path(folder))
        self.assertEqual(summary["exact_duplicate_groups"], 1)
        self.assertEqual(summary["extra_identical_copies"], 1)
        self.assertEqual(summary["potential_duplicate_bytes"], 10)


if __name__ == "__main__":
    unittest.main()
