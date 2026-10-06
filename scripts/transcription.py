"""Optional offline speech recognition for verified output media, never originals."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent


class TranscriptionPaused(Exception):
    """The current subtitle is not published; completed receipts remain reusable."""


# Exceptions: invalid settings or missing setup fail without downloading anything.
def configuration() -> dict[str, Any]:
    config = json.loads((ROOT / "config/transcription.json").read_text(encoding="utf-8-sig"))
    if config.get("backend") != "cpu":
        raise ValueError("Questa prima versione della trascrizione supporta CPU; CUDA/NPU non abilitate")
    model = (ROOT / config["model_directory"]).resolve()
    if not model.is_relative_to(ROOT.resolve()):
        raise ValueError("Modello trascrizione fuori dalla toolbox")
    config["model_directory"] = str(model)
    config["identity"] = hashlib.sha256(json.dumps({key: config[key] for key in (
        "engine", "engine_version", "model_revision", "language", "beam_size", "vad_filter")}, sort_keys=True).encode()).hexdigest()
    return config


# Parameter path: local output, subtitle or setup artifact to verify.
# Exceptions: inaccessible files abort rather than declaring them reusable.
def checksum(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


# Parameter path: generated artifact; existing user-owned artifacts are checked by the caller.
# Parameter text: complete UTF-8 output, published only after flushing temporary bytes.
# Exceptions: filesystem errors preserve the old file and any interrupted temporary file.
def atomic_text(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + "." + str(time.time_ns()) + ".tmp")
    with temporary.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


# Parameter seconds: segment time, rounded to SRT milliseconds.
def timestamp(seconds: float) -> str:
    milliseconds = max(0, round(seconds * 1000))
    seconds, milliseconds = divmod(milliseconds, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{milliseconds:03d}"


# Parameter config: fixed local runtime/model and recognition settings.
# Parameter session: per-job model cache, independent of the Qwen server.
# Exceptions: missing setup instructs the user to install explicitly; no online model fallback.
def load_model(config: dict[str, Any], session: dict[str, Any]):
    if "whisper" in session:
        return session["whisper"]
    receipt_path = ROOT / "runtime/transcription/installation.json"
    if not receipt_path.is_file():
        raise RuntimeError("Trascrizione non preparata: Opzioni / Setup > Installa trascrizione")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("model_revision") != config["model_revision"] or receipt.get("engine_version") != config["engine_version"]:
        raise RuntimeError("Setup trascrizione non corrisponde alla configurazione: ripeti il setup")
    packages = (ROOT / receipt["packages_directory"]).resolve()
    if not packages.is_relative_to((ROOT / "runtime/transcription").resolve()) or not packages.is_dir():
        raise ValueError("Runtime trascrizione non valido")
    if not receipt.get("model_hashes"):
        raise ValueError("Ricevuta modello trascrizione priva di checksum")
    for name, expected in receipt["model_hashes"].items():
        path = (Path(config["model_directory"]) / name).resolve()
        if not path.is_relative_to(Path(config["model_directory"])) or not path.is_file() or checksum(path) != expected:
            raise ValueError("Modello trascrizione danneggiato: ripeti il setup")
    sys.path.insert(0, str(packages))
    from faster_whisper import WhisperModel
    # CPU int8 is portable across Intel/AMD and does not require CUDA or NPU.
    session["whisper"] = WhisperModel(config["model_directory"], device="cpu", compute_type="int8",
                                     local_files_only=True, cpu_threads=max(1, min(8, (os.cpu_count() or 2) - 1)))
    return session["whisper"]


# Parameter media: verified audio/video output, never the selected original.
# Parameter pause: cooperative pause marker, also honored during audio decoding.
# Exceptions: decoding errors stop recognition without publishing incomplete subtitles.
def decode_media_audio(media: Path, pause: Path):
    import av
    import numpy as np

    # Pass PCM to Whisper rather than its path decoder: newer PyAV removed
    # metadata_errors from av.open, which faster-whisper 1.2.1 still supplies.
    resampler = av.audio.resampler.AudioResampler(format="s16", layout="mono", rate=16000)
    samples = bytearray()
    with av.open(str(media), mode="r") as container:
        for frame in container.decode(audio=0):
            if pause.exists():
                raise TranscriptionPaused()
            frame.pts = None
            for converted in resampler.resample(frame):
                samples.extend(converted.to_ndarray().tobytes())
        for converted in resampler.resample(None):
            samples.extend(converted.to_ndarray().tobytes())
    if pause.exists():
        raise TranscriptionPaused()
    return np.frombuffer(samples, dtype=np.int16).astype(np.float32) / 32768.0


# Parameter media: verified audio/video output, never the selected original.
# Parameter digest: SHA-256 identity already established by the organizer.
# Parameter pause: cooperative job pause marker.
# Parameter session: per-job model cache.
# Parameter callback: detailed application log and per-segment progress receiver.
# Exceptions: changed/manual subtitles are preserved; interrupted files restart recognition only.
def transcribe(media: Path, digest: str, pause: Path, session: dict[str, Any],
               callback: Callable) -> dict[str, Any]:
    if "transcription_config" not in session:
        session["transcription_config"] = configuration()
    config = session["transcription_config"]
    subtitle = Path(str(media) + ".srt")
    receipt_path = Path(str(media) + ".transcription.json")
    for artifact in (subtitle, receipt_path):
        if artifact.is_symlink() or artifact.is_junction() or (artifact.exists() and not artifact.is_file()):
            raise ValueError("Artefatto trascrizione non sicuro: " + str(artifact))
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if (receipt.get("source_sha256") == digest and receipt.get("config_identity") == config["identity"]
                and receipt.get("status") in {"complete", "no_audio", "no_speech"}):
            if subtitle.exists() and checksum(subtitle) == receipt.get("srt_sha256"):
                callback({"event": "log", "action": "transcription_resumed", "message": "SRT gia verificato: " + str(subtitle)})
                return receipt
            if subtitle.exists():
                raise ValueError("SRT modificato o mancante: preservato, controllo manuale richiesto: " + str(subtitle))
            if receipt["status"] in {"no_audio", "no_speech"}:
                callback({"event": "log", "action": "transcription_resumed",
                          "message": "Nessuna voce/audio gia rilevata: " + str(media)})
                return receipt
            # A matching completed receipt with a missing SRT is repairable:
            # repeat recognition only, without recopying or overwriting media.
            callback({"event": "log", "action": "transcription_missing",
                      "message": "SRT mancante: rigenerazione in coda per " + str(media)})
        # Recover our interrupted publication only when its exact intended SRT is present.
        if (receipt.get("status") == "pending" and receipt.get("source_sha256") == digest
                and receipt.get("config_identity") == config["identity"]):
            if subtitle.exists() and checksum(subtitle) == receipt.get("srt_sha256"):
                receipt["status"] = receipt["final_status"]
                atomic_text(receipt_path, json.dumps(receipt, ensure_ascii=False, indent=2))
                return receipt
            if subtitle.exists():
                raise ValueError("SRT non corrisponde alla ricevuta interrotta: preservato")
        elif not (receipt.get("status") == "complete" and receipt.get("source_sha256") == digest
                  and receipt.get("config_identity") == config["identity"] and not subtitle.exists()):
            raise ValueError("Ricevuta trascrizione diversa o incompleta: preservata: " + str(receipt_path))
    elif subtitle.exists():
        raise ValueError("SRT preesistente senza ricevuta: non viene sovrascritto: " + str(subtitle))
    if pause.exists():
        raise TranscriptionPaused()
    if checksum(media) != digest:
        raise ValueError("Media cambiato prima della trascrizione")
    # Initialize the local decoder packages without requiring speech inference
    # for video containers that have no audio stream.
    model = load_model(config, session)
    import av
    with av.open(str(media)) as container:
        has_audio = bool(container.streams.audio)
    blocks = []
    language = None
    probability = None
    if has_audio:
        callback({"event": "log", "phase": "trascrizione", "filename": media.name,
                  "message": "Decodifica audio locale: " + media.name})
        audio = decode_media_audio(media, pause)
        # An audio stream can exist but contain no samples. Do not send an
        # empty array through Whisper/VAD or invent a transcript for it.
        segments = ()
        if audio.size:
            segments, info = model.transcribe(audio, language=config["language"], beam_size=config["beam_size"],
                                              vad_filter=config["vad_filter"], condition_on_previous_text=False)
            language, probability = info.language, info.language_probability
        for segment in segments:
            if pause.exists():
                raise TranscriptionPaused()
            text = " ".join(segment.text.split())
            if text:
                blocks.append(f"{len(blocks) + 1}\n{timestamp(segment.start)} --> {timestamp(segment.end)}\n{text}\n")
            callback({"event": "log", "phase": "trascrizione", "filename": media.name,
                      "message": f"Trascrizione {media.name}: {segment.end:.1f} s", "audio_seconds": segment.end})
    if pause.exists():
        raise TranscriptionPaused()
    if checksum(media) != digest:
        raise ValueError("Media cambiato durante la trascrizione: SRT non pubblicato")
    text = "\n".join(blocks)
    final_status = "complete" if blocks else ("no_speech" if has_audio else "no_audio")
    receipt = {"schema_version": 1, "status": "pending", "final_status": final_status,
               "source_sha256": digest, "config_identity": config["identity"], "engine": config["engine"],
               "model_revision": config["model_revision"], "backend": "cpu", "language": language,
               "language_probability": probability, "segments": len(blocks), "srt_file": subtitle.name,
               "srt_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
               "created_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "manual_review_required": True}
    atomic_text(receipt_path, json.dumps(receipt, ensure_ascii=False, indent=2))
    atomic_text(subtitle, text)
    receipt["status"] = final_status
    atomic_text(receipt_path, json.dumps(receipt, ensure_ascii=False, indent=2))
    callback({"event": "log", "action": "transcription_completed", "message": "SRT: " + str(subtitle), "status": final_status})
    return receipt
