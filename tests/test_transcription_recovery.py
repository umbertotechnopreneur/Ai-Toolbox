"""Synthetic speech regressions: no model downloads or real media processing."""

import json
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest.mock import MagicMock, patch

import folder_organizer as organizer
import transcription as speech


class TranscriptionRecoveryTests(unittest.TestCase):
    # Parameter self: synthetic fixture owner.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="speech-recovery-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.media = self.root / "fixture.opus"
        self.media.write_bytes(b"synthetic audio container")
        self.digest = speech.checksum(self.media)
        self.config = {"identity": "fixture", "engine": "fixture", "model_revision": "fixture",
                       "language": None, "beam_size": 5, "vad_filter": True}

    # Parameter self: active regression case.
    def test_decoder_type_error_becomes_local_media_failure(self):
        connection = MagicMock()
        asset = {"record": json.dumps({"extension_normalized": ".opus"}), "sha256": self.digest,
                 "output": "fixture.opus"}
        with patch.object(organizer, "owned_output", return_value=self.media), \
                patch.object(speech, "transcribe", side_effect=TypeError("unsupported decoder keyword")):
            with self.assertRaisesRegex(RuntimeError, "Trascrizione fallita.*TypeError"):
                organizer.enrich_transcription(connection, self.root, asset, self.root / "pause", {}, lambda event: None)
        connection.execute.assert_not_called()
        self.assertEqual(self.media.read_bytes(), b"synthetic audio container")

    # Parameter self: active regression case.
    def test_pause_is_not_converted_to_media_failure(self):
        asset = {"record": json.dumps({"extension_normalized": ".opus"}), "sha256": self.digest,
                 "output": "fixture.opus"}
        with patch.object(organizer, "owned_output", return_value=self.media), \
                patch.object(speech, "transcribe", side_effect=speech.TranscriptionPaused()):
            with self.assertRaises(organizer.Paused):
                organizer.enrich_transcription(MagicMock(), self.root, asset, self.root / "pause", {}, lambda event: None)

    # Parameter self: active regression case.
    def test_empty_audio_samples_do_not_reach_whisper(self):
        container = MagicMock()
        container.__enter__.return_value.streams.audio = [object()]
        fake_av = types.ModuleType("av")
        fake_av.open = MagicMock(return_value=container)
        model = MagicMock()
        with patch.dict(sys.modules, {"av": fake_av}), \
                patch.object(speech, "load_model", return_value=model), \
                patch.object(speech, "decode_media_audio", return_value=types.SimpleNamespace(size=0)):
            result = speech.transcribe(self.media, self.digest, self.root / "pause",
                                       {"transcription_config": self.config}, lambda event: None)
        model.transcribe.assert_not_called()
        self.assertEqual(result["status"], "no_speech")
        self.assertEqual(Path(str(self.media) + ".srt").read_bytes(), b"")

    # Parameter self: active regression case.
    def test_changed_silent_subtitle_is_preserved(self):
        subtitle = Path(str(self.media) + ".srt")
        subtitle.write_text("manual text", encoding="utf-8")
        receipt = {"source_sha256": self.digest, "config_identity": self.config["identity"],
                   "status": "no_speech", "srt_sha256": "0" * 64}
        Path(str(self.media) + ".transcription.json").write_text(json.dumps(receipt), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "SRT modificato o mancante"):
            speech.transcribe(self.media, self.digest, self.root / "pause",
                              {"transcription_config": self.config}, lambda event: None)
        self.assertEqual(subtitle.read_text(encoding="utf-8"), "manual text")

    # Parameter self: synthetic completed receipt whose missing SRT needs publication again.
    def test_missing_completed_subtitle_is_regenerated_without_recopy(self):
        receipt = {"source_sha256": self.digest, "config_identity": self.config["identity"],
                   "status": "complete", "srt_sha256": "0" * 64}
        Path(str(self.media) + ".transcription.json").write_text(json.dumps(receipt), encoding="utf-8")
        container = MagicMock()
        container.__enter__.return_value.streams.audio = []
        fake_av = types.ModuleType("av")
        fake_av.open = MagicMock(return_value=container)
        before = self.media.read_bytes()
        with patch.dict(sys.modules, {"av": fake_av}), patch.object(speech, "load_model"):
            result = speech.transcribe(self.media, self.digest, self.root / "pause",
                                       {"transcription_config": self.config}, lambda event: None)
        self.assertEqual(result["status"], "no_audio")
        self.assertTrue(Path(str(self.media) + ".srt").is_file())
        self.assertEqual(self.media.read_bytes(), before)

    # Parameter self: active regression case; saved silence must not invoke recognition again.
    def test_missing_silent_subtitle_does_not_repeat_recognition(self):
        for status in ("no_audio", "no_speech"):
            with self.subTest(status=status):
                receipt = {"source_sha256": self.digest, "config_identity": self.config["identity"],
                           "status": status, "srt_sha256": speech.hashlib.sha256(b"").hexdigest()}
                Path(str(self.media) + ".transcription.json").write_text(json.dumps(receipt), encoding="utf-8")
                with patch.object(speech, "load_model") as model:
                    result = speech.transcribe(self.media, self.digest, self.root / "pause",
                                               {"transcription_config": self.config}, lambda event: None)
                model.assert_not_called()
                self.assertEqual(result["status"], status)

    # Parameter self: active regression case; existing manual subtitles are never queued.
    def test_queue_preserves_manual_subtitle_and_deduplicates_missing_media(self):
        asset = {"asset_key": self.digest, "output": "fixture.opus"}
        queue = {}
        subtitle = Path(str(self.media) + ".srt")
        subtitle.write_text("manual text", encoding="utf-8")
        with patch.object(organizer, "owned_output", return_value=self.media):
            organizer.queue_missing_transcription(self.root, asset, queue, lambda event: None)
            self.assertEqual(queue, {})
            self.assertEqual(subtitle.read_text(encoding="utf-8"), "manual text")
            subtitle.unlink()  # Synthetic fixture only: simulate the missing-artifact case.
            organizer.queue_missing_transcription(self.root, asset, queue, lambda event: None)
            organizer.queue_missing_transcription(self.root, asset, queue, lambda event: None)
        self.assertEqual(queue, {self.digest: "fixture.opus"})

    # Parameter self: active regression case using installed decoder packages, never downloading.
    def test_installed_pyav_decodes_synthetic_wav_and_whisper_receives_pcm(self):
        installation = speech.ROOT / "runtime/transcription/installation.json"
        if not installation.is_file():
            self.skipTest("Optional speech runtime is not installed")
        receipt = json.loads(installation.read_text(encoding="utf-8"))
        packages = (speech.ROOT / receipt["packages_directory"]).resolve()
        self.assertTrue(packages.is_relative_to((speech.ROOT / "runtime/transcription").resolve()))
        self.assertTrue(packages.is_dir())
        wav = self.root / "silence.wav"
        with wave.open(str(wav), "wb") as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(48000)
            output.writeframes(b"\0" * (48000 * 2 * 2))
        model = MagicMock()
        model.transcribe.return_value = (iter(()), types.SimpleNamespace(language="en", language_probability=1.0))
        with patch.object(sys, "path", [str(packages), *sys.path]), \
                patch.object(speech, "load_model", return_value=model):
            audio = speech.decode_media_audio(wav, self.root / "pause")
            self.assertEqual(audio.shape, (16000,))
            self.assertEqual(str(audio.dtype), "float32")
            self.assertTrue((audio == 0).all())
            result = speech.transcribe(wav, speech.checksum(wav), self.root / "pause",
                                       {"transcription_config": self.config}, lambda event: None)
        argument = model.transcribe.call_args.args[0]
        self.assertEqual(argument.shape, (16000,))
        self.assertFalse(isinstance(argument, str))
        self.assertEqual(result["status"], "no_speech")


if __name__ == "__main__":
    unittest.main()
