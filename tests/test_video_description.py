"""Synthetic sampled-video regressions: no models, downloads or personal media."""

import json
import tempfile
import subprocess
import types
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

import folder_organizer as organizer
import transcription as speech
import video_description as video


class VideoDescriptionTests(unittest.TestCase):
    # Parameter self: isolated synthetic fixture owner.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="video-description-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.media = self.root / "fixture.mp4"
        self.media.write_bytes(b"synthetic video")
        self.digest = speech.checksum(self.media)
        self.config = {"min_frames": 4, "max_frames": 24, "seconds_per_frame": 30,
                       "max_image_edge": 896, "ffmpeg_timeout_seconds": 60}

    # Parameter self: active sampling boundary regression.
    def test_duration_controls_bounded_midpoint_sampling(self):
        self.assertEqual(len(video.sample_times(1, self.config)), 4)
        self.assertEqual(len(video.sample_times(300, self.config)), 10)
        self.assertEqual(len(video.sample_times(36000, self.config)), 24)
        times = video.sample_times(120, self.config)
        self.assertEqual(times, [15, 45, 75, 105])
        for invalid in (0, -1, float("inf"), float("nan")):
            with self.assertRaises(ValueError):
                video.sample_times(invalid, self.config)

    # Parameter self: existing manually owned descriptions must never be overwritten.
    def test_existing_json_does_not_decode_or_start_ai(self):
        target = Path(str(self.media) + ".video.json")
        target.write_text("manually edited", encoding="utf-8")
        with ExitStack() as stack, patch.object(video.subprocess, "run") as run:
            result = video.describe(self.media, self.digest, self.root / "pause", self.root / "cache",
                                    self.config, {}, stack, {}, lambda event: None)
        run.assert_not_called()
        self.assertEqual(result["status"], "preserved")
        self.assertEqual(target.read_text(encoding="utf-8"), "manually edited")

    # Parameter self: interrupted inference resumes completed frames, not media copying.
    def test_missing_json_resumes_frame_checkpoint_and_can_be_regenerated(self):
        probe = types.SimpleNamespace(returncode=0, stderr=b"", stdout=json.dumps({
            "format": {"duration": "120"}, "streams": [{"codec_type": "video", "index": 0}]}).encode())
        jpeg = types.SimpleNamespace(returncode=0, stderr=b"", stdout=b"synthetic jpeg")
        description = {"description": "A synthetic frame.", "tags": [], "needs_review": True}
        settings = {"model_alias": "fixture"}
        target = Path(str(self.media) + ".video.json")
        with patch.object(video, "executable", return_value=self.root / "ffmpeg.exe"), \
                patch.object(video.ai, "cache_fingerprint", return_value="fixture"), \
                patch.object(video.subprocess, "run", side_effect=lambda args, **kwargs: probe if "-show_format" in args else jpeg):
            with ExitStack() as stack, patch.object(video.ai, "infer", side_effect=[description, RuntimeError("interrupted")]):
                with self.assertRaisesRegex(RuntimeError, "interrupted"):
                    video.describe(self.media, self.digest, self.root / "pause", self.root / "cache",
                                   self.config, settings, stack, {"endpoint": "fixture"}, lambda event: None)
            self.assertFalse(target.exists())
            with ExitStack() as stack, patch.object(video.ai, "infer", return_value=description) as infer:
                result = video.describe(self.media, self.digest, self.root / "pause", self.root / "cache",
                                        self.config, settings, stack, {"endpoint": "fixture"}, lambda event: None)
            self.assertEqual(infer.call_count, 3)
            self.assertEqual(len(result["frames"]), 4)
            self.assertEqual(result["status"], "complete")
            target.unlink()  # Only remove a synthetic fixture to exercise missing-result recovery.
            with ExitStack() as stack, patch.object(video.ai, "infer") as infer:
                video.describe(self.media, self.digest, self.root / "pause", self.root / "cache",
                               self.config, settings, stack, {}, lambda event: None)
            infer.assert_not_called()
        self.assertEqual(self.media.read_bytes(), b"synthetic video")
        self.assertTrue(target.is_file())

    # Parameter self: repeated originals share one queued video result.
    def test_queue_deduplicates_and_preserves_existing_json(self):
        asset = {"asset_key": self.digest, "output": "fixture.mp4"}
        queue = {}
        with patch.object(organizer, "owned_output", return_value=self.media):
            organizer.queue_missing_video_description(self.root, asset, queue, lambda event: None)
            organizer.queue_missing_video_description(self.root, asset, queue, lambda event: None)
            self.assertEqual(len(queue), 1)
            Path(str(self.media) + ".video.json").write_text("manual", encoding="utf-8")
            queue.clear()
            organizer.queue_missing_video_description(self.root, asset, queue, lambda event: None)
            self.assertEqual(queue, {})

    # Parameter self: real portable FFmpeg fixture; AI inference is mocked, never started.
    def test_invalid_video_does_not_start_ai_or_publish_json(self):
        failed = types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"moov atom not found")
        with ExitStack() as stack, patch.object(video, "executable", return_value=self.root / "ffprobe.exe"), \
                patch.object(video.ai, "cache_fingerprint", return_value="fixture"), \
                patch.object(video.subprocess, "run", return_value=failed), \
                patch.object(video.ai, "running_server") as server:
            with self.assertRaisesRegex(ValueError, "moov atom not found"):
                video.describe(self.media, self.digest, self.root / "pause", self.root / "cache",
                               self.config, {}, stack, {}, lambda event: None)
        server.assert_not_called()
        self.assertFalse(Path(str(self.media) + ".video.json").exists())
        self.assertEqual(self.media.read_bytes(), b"synthetic video")

    # Parameter self: real portable FFmpeg fixture; AI inference is mocked, never started.
    def test_real_ffmpeg_samples_generated_video(self):
        try:
            binary = video.executable("ffmpeg.exe")
        except ValueError:
            self.skipTest("Optional portable FFmpeg is not installed")
        self.media.unlink()  # Replace only the synthetic invalid input with a generated video.
        generated = subprocess.run([str(binary), "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=10", "-t", "2", "-an",
            "-c:v", "mpeg4", "-threads", "1", str(self.media)], capture_output=True, timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(generated.returncode, 0, generated.stderr.decode("utf-8", "replace"))
        digest = speech.checksum(self.media)
        with ExitStack() as stack, patch.object(video.ai, "cache_fingerprint", return_value="fixture"), \
                patch.object(video.ai, "infer", return_value={"description": "A blue frame.", "tags": []}) as infer:
            result = video.describe(self.media, digest, self.root / "pause", self.root / "cache",
                                    self.config, {"model_alias": "fixture"}, stack,
                                    {"endpoint": "fixture"}, lambda event: None)
        self.assertEqual(infer.call_count, 4)
        self.assertTrue(all(call.args[1].startswith("data:image/jpeg;base64,/9j/") for call in infer.call_args_list))
        self.assertEqual(result["status"], "complete")
        self.assertEqual(speech.checksum(self.media), digest)

    # Parameter self: verify copy/resume repairs only the separate JSON, not copied media.
    def test_organizer_repairs_missing_json_without_recopy(self):
        source = self.root / "source"
        source.mkdir()
        (source / "fixture.mp4").write_bytes(b"synthetic video")
        destination = self.root / "review"

        # Parameter media: synthetic verified output.
        # Parameter args: ignored isolated description parameters.
        # Parameter kwargs: ignored isolated description parameters.
        def publish(media, *args, **kwargs):
            Path(str(media) + ".video.json").write_text('{"status":"complete"}', encoding="utf-8")

        options = dict(run=True, allow_cloud=True, use_ai=False, reserve_bytes=0, describe_videos=True,
                       callback=lambda event: None)
        with patch.object(video.ai, "configuration", return_value={}), \
                patch.object(video, "describe", side_effect=publish) as describe:
            first = organizer.run_folder(source, destination, **options)
            self.assertTrue(first["ready_for_review"])
            self.assertEqual(describe.call_count, 1)
            describe.reset_mock()
            target = next((destination / "Risultato").rglob("*.video.json"))
            media = Path(str(target).removesuffix(".video.json"))
            original_stat = media.stat()
            with patch.object(organizer, "stage_file", side_effect=AssertionError("Media recopied")):
                resumed = organizer.run_folder(source, destination, **options)
                self.assertTrue(resumed["ready_for_review"])
                describe.assert_not_called()
                target.unlink()  # Deliberately remove only the tiny fixture result.
                repaired = organizer.run_folder(source, destination, **options)
            self.assertTrue(repaired["ready_for_review"])
            self.assertEqual(describe.call_count, 1)
            self.assertEqual(media.stat().st_mtime_ns, original_stat.st_mtime_ns)
            self.assertEqual(media.read_bytes(), b"synthetic video")

    # Parameter self: one description failure must not prevent copying or subsequent descriptions.
    def test_description_failure_is_local_and_next_video_completes(self):
        source = self.root / "source"
        source.mkdir()
        (source / "bad.mp4").write_bytes(b"bad fixture")
        (source / "good.mp4").write_bytes(b"good fixture")
        destination = self.root / "review"

        # Parameter media: verified synthetic media whose byte content identifies the failing fixture.
        # Parameter args: ignored isolated description parameters.
        # Parameter kwargs: ignored isolated description parameters.
        def publish(media, *args, **kwargs):
            if media.read_bytes() == b"bad fixture":
                raise RuntimeError("synthetic decoder failure")
            Path(str(media) + ".video.json").write_text('{"status":"complete"}', encoding="utf-8")

        with patch.object(video.ai, "configuration", return_value={}), \
                patch.object(video, "describe", side_effect=publish) as describe:
            result = organizer.run_folder(source, destination, run=True, allow_cloud=True, use_ai=False,
                                          reserve_bytes=0, describe_videos=True, callback=lambda event: None)
        self.assertEqual(describe.call_count, 2)
        self.assertEqual(result["completed"], 2)
        self.assertEqual(result["errors"], 1)
        self.assertEqual(result["video_descriptions_completed"], 1)
        self.assertEqual(len(list((destination / "Risultato").rglob("*.video.json"))), 1)


if __name__ == "__main__":
    unittest.main()
