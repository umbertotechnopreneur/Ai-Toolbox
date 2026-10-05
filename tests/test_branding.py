"""Read-only checks on packaged identity/icon; never open a browser or user assets."""

import hashlib
import json
import struct
import unittest
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class BrandingTests(unittest.TestCase):
    # Parameter self: active read-only packaged-asset check.
    def test_publisher_link_and_vibeware_label(self):
        brand = json.loads((ROOT / "config/branding.json").read_text(encoding="utf-8"))
        self.assertEqual(brand["publisher_name"], "Umberto Giacobbi")
        self.assertEqual(brand["code_style"], "VibeWare")
        address = urllib.parse.urlsplit(brand["website_url"])
        self.assertEqual((address.scheme, address.hostname), ("https", "umbertogiacobbi.biz"))

    # Parameter self: active read-only packaged-asset check.
    def test_icon_is_portable_multiresolution_and_unchanged(self):
        brand = json.loads((ROOT / "config/branding.json").read_text(encoding="utf-8"))
        relative = Path(brand["icon_path"])
        self.assertFalse(relative.is_absolute())
        self.assertNotIn("..", relative.parts)
        content = (ROOT / relative).read_bytes()
        reserved, kind, count = struct.unpack_from("<HHH", content)
        self.assertEqual((reserved, kind), (0, 1))
        self.assertGreater(count, 1)
        self.assertEqual(hashlib.sha256(content).hexdigest(), "92fc5198fc4e42b71bb4350957fffa07fe948c3f80a1e0d67ed364e5c4f2a01c")

    # Parameter self: active read-only packaged-source check.
    def test_about_and_branding_have_no_external_local_dependency(self):
        script = (ROOT / "scripts/Ui-Branding.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("function Show-ToolboxAbout", script)
        self.assertIn("New-PublisherCredit", script)
        self.assertNotIn("C:/Users/", script)
        self.assertNotIn("E:/", script)
        self.assertNotIn("folder_organizer.py", script)


if __name__ == "__main__":
    unittest.main()
