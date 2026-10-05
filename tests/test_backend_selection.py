"""Backend dispatch using mocked processes only; no GPU/hardware probing."""

import contextlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import ai_toolbox as ai


class BackendTests(unittest.TestCase):
    # Parameter self: isolated regression case.
    def setUp(self):
        self.config = ai.configuration()
        self.temporary = tempfile.TemporaryDirectory(prefix="backend-test-", dir=ai.ROOT / "temp")
        self.addCleanup(self.temporary.cleanup)
        self.root_patch = patch.object(ai, "ROOT", Path(self.temporary.name))
        self.root_patch.start(); self.addCleanup(self.root_patch.stop)
        self.connection = Mock(); self.connection.connect_ex.return_value = 1
        self.selected = []

    # Parameter self: regression case collecting selected fake backends.
    # Parameter settings: resolved runtime configuration, without any real launch.
    @contextlib.contextmanager
    def server(self, settings):
        self.selected.append(settings["resolved_backend"])
        yield "http://127.0.0.1:8091"

    # Parameter self: regression fixture.
    def mocks(self):
        stack = contextlib.ExitStack()
        socket = stack.enter_context(patch.object(ai.socket, "socket"))
        socket.return_value.__enter__.return_value = self.connection
        stack.enter_context(patch.object(ai, "engine_path", return_value=Path("synthetic/llama-server.exe")))
        stack.enter_context(patch.object(ai, "single_backend_server", side_effect=self.server))
        probe = stack.enter_context(patch.object(ai.subprocess, "run", return_value=Mock(returncode=0, stdout="", stderr="")))
        return stack, probe

    # Parameter self: active regression case.
    def test_auto_prefers_cuda_when_available(self):
        stack, probe = self.mocks()
        with stack:
            probe.return_value.stdout = "CUDA0: synthetic NVIDIA device"
            with ai.running_server(self.config): pass
        self.assertEqual(self.selected, ["cuda"])

    # Parameter self: active regression case.
    def test_auto_uses_vulkan_when_cuda_unavailable(self):
        stack, probe = self.mocks()
        with stack:
            probe.side_effect = [Mock(returncode=0, stdout="", stderr=""), Mock(returncode=0, stdout="Vulkan0: synthetic Intel GPU", stderr="")]
            with ai.running_server(self.config): pass
        self.assertEqual(self.selected, ["vulkan"])

    # Parameter self: active regression case.
    def test_auto_falls_back_to_cpu(self):
        stack, _ = self.mocks()
        with stack:
            with ai.running_server(self.config): pass
        self.assertEqual(self.selected, ["cpu"])

    # Parameter self: active regression case.
    def test_explicit_cpu_never_probes_gpu(self):
        self.config["engine_backend"] = "cpu"
        stack, probe = self.mocks()
        with stack:
            with ai.running_server(self.config): pass
            probe.assert_not_called()
        self.assertEqual(self.selected, ["cpu"])

    # Parameter self: active regression case.
    def test_auto_startup_failure_falls_back_but_explicit_failure_does_not(self):
        attempts = []

        # Parameter settings: synthetic startup configuration.
        # Exceptions: Simulated CUDA startup refusal, before any batch is yielded.
        @contextlib.contextmanager
        def startup(settings):
            attempts.append(settings["resolved_backend"])
            if settings["resolved_backend"] == "cuda": raise RuntimeError("Driver startup refused")
            yield "http://127.0.0.1:8091"

        stack, probe = self.mocks()
        with stack, patch.object(ai, "single_backend_server", side_effect=startup):
            probe.return_value.stdout = "CUDA0: synthetic NVIDIA device\nVulkan0: synthetic fallback"
            with ai.running_server(self.config): pass
            self.assertEqual(attempts, ["cuda", "vulkan"])
            attempts.clear(); self.config["engine_backend"] = "cuda"
            with self.assertRaises(RuntimeError):
                with ai.running_server(self.config): pass
            self.assertEqual(attempts, ["cuda"])

    # Parameter self: active regression case.
    def test_batch_failure_does_not_restart_on_another_backend(self):
        stack, probe = self.mocks()
        with stack:
            probe.return_value.stdout = "CUDA0: synthetic NVIDIA device"
            with self.assertRaises(RuntimeError):
                with ai.running_server(self.config): raise RuntimeError("Batch failure")
        self.assertEqual(self.selected, ["cuda"])

    # Parameter self: active regression case.
    def test_cache_identity_survives_backend_choice(self):
        self.root_patch.stop()  # Read only package config; no runtime probing for this test.
        identity = ai.cache_fingerprint(self.config, "unchanged prompt")
        self.config["engine_backend"] = "cpu"
        self.assertEqual(ai.cache_fingerprint(self.config, "unchanged prompt"), identity)


if __name__ == "__main__":
    unittest.main()
