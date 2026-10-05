"""Regression tests for portable AI safety, provenance and process ownership."""

import argparse
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import ai_toolbox as toolbox


class ToolboxTests(unittest.TestCase):
    # Parameter self: the active regression case.
    def example_result(self):
        return {"category": "photo", "description": "A landscape.", "tags": ["landscape"],
                "contains_visible_text": False, "text_excerpt": "", "needs_review": False,
                "uncertainty_reasons": []}

    # Parameter self: the active regression case.
    def test_valid_result_is_accepted(self):
        self.assertEqual(toolbox.validate_result(self.example_result())["category"], "photo")

    # Parameter self: the active regression case.
    def test_unknown_category_is_rejected(self):
        result = self.example_result()
        result["category"] = "delete_me"
        with self.assertRaises(ValueError):
            toolbox.validate_result(result)

    # Parameter self: the active regression case.
    def test_ocr_is_disabled(self):
        result = self.example_result()
        result["text_excerpt"] = "unrequested personal document content"
        with self.assertRaises(ValueError):
            toolbox.validate_result(result)

    # Parameter self: the active regression case.
    def test_extra_model_fields_are_rejected(self):
        result = self.example_result()
        result["capture_date"] = "invented"
        with self.assertRaises(ValueError):
            toolbox.validate_result(result)

    # Parameter self: the active regression case.
    def test_remote_inference_is_rejected_before_http(self):
        with patch.object(toolbox.urllib.request, "build_opener") as opener:
            with self.assertRaises(ValueError):
                toolbox.local_request("https://example.com", {})
            opener.assert_not_called()

    # Parameter self: the active regression case.
    def test_fake_loopback_prefix_cannot_send_images_remotely(self):
        with patch.object(toolbox.urllib.request, "build_opener") as opener:
            with self.assertRaises(ValueError):
                toolbox.local_request("http://127.0.0.1:8091@example.com", {})
            opener.assert_not_called()

    # Parameter self: the active regression case.
    def test_cache_changes_with_prompt_and_preview_size(self):
        config = toolbox.configuration()
        original = toolbox.cache_fingerprint(config, "first")
        self.assertNotEqual(original, toolbox.cache_fingerprint(config, "second"))
        config["max_image_edge"] += 1
        self.assertNotEqual(original, toolbox.cache_fingerprint(config, "first"))

    # Parameter self: the active regression case.
    def test_inference_sends_nested_strict_schema(self):
        response = {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(self.example_result())}}]}
        with patch.object(toolbox, "local_request", return_value=response) as request:
            result = toolbox.infer("http://127.0.0.1:8091", "data:image/jpeg;base64,test", toolbox.configuration(), "catalog")
        self.assertEqual(result["category"], "photo")
        payload = request.call_args.args[1]
        self.assertTrue(payload["response_format"]["json_schema"]["strict"])
        self.assertEqual(payload["response_format"]["json_schema"]["schema"], toolbox.SCHEMA)

    # Parameter self: the active regression case.
    def test_default_dry_run_does_not_start_ai_or_read_sources(self):
        args = argparse.Namespace(manifest=None, category=None, all=False, limit=2, run=False)
        with patch.object(toolbox, "running_server") as server, patch.object(toolbox, "preview") as preview:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(toolbox.catalog(args, toolbox.configuration()), 0)
            self.assertEqual(json.loads(output.getvalue())["selected"], 2)
            server.assert_not_called()
            preview.assert_not_called()

    # Parameter self: the active regression case.
    def test_occupied_port_does_not_attach_or_spawn(self):
        connection = Mock()
        connection.connect_ex.return_value = 0
        with patch.object(toolbox.socket, "socket") as socket_factory, patch.object(toolbox.subprocess, "Popen") as spawn:
            socket_factory.return_value.__enter__.return_value = connection
            with self.assertRaises(RuntimeError):
                with toolbox.running_server(toolbox.configuration()):
                    self.fail("Occupied server should not be used")
            spawn.assert_not_called()

    # Parameter self: the active regression case.
    def test_owned_server_is_stopped_on_batch_http_error(self):
        config = toolbox.configuration()
        config["engine_backend"] = "cpu"  # Lifecycle test must not perform GPU discovery.
        config["model_path"] = str(toolbox.ROOT / "scripts/ai_toolbox.py")
        config["projector_path"] = config["model_path"]
        connection = Mock()
        connection.connect_ex.return_value = 1
        process = Mock()
        process.poll.return_value = None
        with tempfile.TemporaryDirectory(prefix="ai-server-lifecycle-") as folder, patch.object(toolbox, "ROOT", Path(folder)), patch.object(toolbox.socket, "socket") as socket_factory, patch.object(toolbox, "engine_path") as binary:
            socket_factory.return_value.__enter__.return_value = connection
            binary.return_value = toolbox.ROOT / "runtime/fake/llama-server.exe"
            with patch.object(toolbox.subprocess, "Popen", return_value=process), patch.object(toolbox, "local_request", return_value={"status": "ok"}):
                with self.assertRaises(toolbox.urllib.error.URLError):
                    with toolbox.running_server(config):
                        raise toolbox.urllib.error.URLError("inference failed")
        process.terminate.assert_called_once()
        process.wait.assert_called_once()

    # Parameter self: the active regression case.
    def test_atomic_json_writer_preserves_unicode(self):
        with tempfile.TemporaryDirectory(prefix="ai-toolbox-test-") as folder:
            path = Path(folder) / "record.json"
            toolbox.write_json(path, {"tag": "città"})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["tag"], "città")
            self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
