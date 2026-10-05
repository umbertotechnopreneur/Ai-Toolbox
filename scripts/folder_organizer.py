"""Copy one selected folder into a verified, resumable photo review workspace."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from contextlib import ExitStack, closing, contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import ai_toolbox as ai
import analyze_local as analyzer
import photo_organizer as technical
from job_log import JobLog

VERSION = 1
CONTROL = ".photo-organizer"
CHUNK = 1024 * 1024
RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".rw2"}
IMAGE_EXTENSIONS = technical.IMAGE_EXTENSIONS | RAW_EXTENSIONS
KNOWN_FOLDERS = {"photo": "Foto", "snapshot": "Snapshot", "screenshot": "Snapshot",
                 "document_image": "Scansioni", "scanned_document": "Scansioni", "graphic": "Grafica",
                 "graphic_review": "Grafica", "sticker": "Sticker", "animation": "GIF_Animazioni",
                 "icon": "Icone", "video": "Video", "audio": "Audio", "png_review": "PNG_Da_Verificare",
                 "other": "Altri_File", "document": "Documenti", "unknown": "Da_Verificare"}


class Paused(Exception):
    """A cooperative pause leaves source files and completed work intact."""


# Parameter event: structured message consumed by the GUI and CLI progress view.
def emit(event: dict[str, Any]) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


# Parameter source: exactly one user-selected directory, never a whole drive.
# Parameter destination: separate review output, not a parent or descendant of source.
# Exceptions: ValueError for unsafe overlap, broad roots or unowned nonempty output.
def validate_paths(source: Path, destination: Path) -> tuple[Path, Path]:
    source = source.resolve()
    destination = destination.resolve()
    if not source.is_dir() or source == Path(source.anchor):
        raise ValueError("Scegli una singola cartella sorgente esistente, non un intero disco")
    if source.name.casefold() == "onedrive" or source == ai.ROOT.resolve():
        raise ValueError("Scegli una sottocartella specifica, non tutta OneDrive o la toolbox")
    if source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError("Sorgente e destinazione non possono coincidere o contenersi")
    if destination == Path(destination.anchor):
        raise ValueError("La destinazione deve essere una cartella, non la radice del disco")
    if destination.exists() and not destination.is_dir():
        raise ValueError("La destinazione non e una cartella")
    if destination.exists() and any(destination.iterdir()) and not (destination / CONTROL / "state.sqlite3").is_file():
        raise ValueError("Destinazione non vuota e non riconosciuta: scegli una cartella temporanea nuova")
    return source, destination


# Parameter source: canonical source directory to enumerate without reading contents.
# Parameter callback: progress receiver, invoked periodically while enumerating.
# Exceptions: OSError for inaccessible folders; links/junctions are reported as omissions.
def scan_source(source: Path, callback: Callable = emit) -> tuple[list[dict[str, Any]], list[str]]:
    records = []
    omissions = []
    folders = [source]
    while folders:
        folder = folders.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                path = Path(entry.path)
                if entry.is_symlink() or path.is_junction():
                    omissions.append(str(path))
                    continue
                if entry.is_dir(follow_symlinks=False):
                    folders.append(path)
                elif entry.is_file(follow_symlinks=False):
                    stat = entry.stat(follow_symlinks=False)
                    relative = str(path.relative_to(source))
                    records.append({"relative": relative, "size": stat.st_size, "mtime": stat.st_mtime_ns,
                                    "attributes": int(getattr(stat, "st_file_attributes", 0))})
                    if len(records) % 250 == 0:
                        callback({"event": "scan", "phase": "inventario", "done": len(records), "total": 0,
                                  "message": f"Inventario: {len(records)} file"})
                else:
                    omissions.append(str(path))
    records.sort(key=lambda item: item["relative"].casefold())
    return records, omissions


# Parameter path: selected original file, opened read-only with write/delete sharing denied.
# Parameter allow_cloud: explicit user opt-in to OneDrive hydration through a normal read.
# Exceptions: LocalReadDenied or OSError on disallowed remote content or failed reads.
@contextmanager
def source_stream(path: Path, allow_cloud: bool):
    if not allow_cloud:
        with analyzer.guarded_local_stream(path) as (stream, guard):
            yield stream
        return
    if os.name != "nt":
        with path.open("rb") as stream:
            yield stream
        return
    kernel, cloud = analyzer.windows_apis()
    absolute = str(path.absolute())
    if absolute.startswith("\\\\?\\"):
        extended = absolute
    elif absolute.startswith("\\\\"):
        extended = "\\\\?\\UNC\\" + absolute[2:]
    else:
        extended = "\\\\?\\" + absolute
    handle = kernel.CreateFileW(extended, 0x80000000, 1, None, 3, 0x08000000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        import msvcrt
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
        handle = None
        with os.fdopen(descriptor, "rb") as stream:
            yield stream
    finally:
        if handle is not None:
            kernel.CloseHandle(handle)


# Parameter path: already-local output or staging file, never an online-only original.
# Exceptions: OSError if output verification fails.
def file_hash(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


# Parameter directory: intended output path that may not exist yet.
# Parameter required: conservative byte requirement before starting a copy.
# Parameter reserve: free-space margin to leave untouched.
# Exceptions: OSError if available disk space is insufficient.
def check_space(directory: Path, required: int, reserve: int) -> None:
    probe = directory
    while not probe.exists():
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    if free < required + reserve:
        raise OSError(f"Spazio insufficiente su {probe.anchor}: servono {required / 1024**3:.1f} GiB + {reserve / 1024**3:.1f} GiB di margine")


# Parameter path: single source file being copied.
# Parameter stage: package-owned partial copy under the output control directory.
# Parameter allow_cloud: authorizes content reads that can hydrate this selected file.
# Parameter pause: package-owned pause marker checked between buffered chunks.
# Parameter callback: console/GUI progress receiver.
# Parameter progress: shared total-count and byte-throughput values.
# Parameter reserve: per-volume free-space margin.
# Exceptions: Paused, OSError or LocalReadDenied; a partial copy is left for inspection/resume.
def stage_file(path: Path, stage: Path, allow_cloud: bool, pause: Path, callback: Callable,
               progress: dict[str, Any], reserve: int) -> tuple[str, os.stat_result]:
    before = path.stat()
    check_space(stage.parent, before.st_size, reserve)
    digest = hashlib.sha256()
    last_event = 0.0
    with source_stream(path, allow_cloud) as source, stage.open("wb") as target:
        while True:
            if pause.exists():
                raise Paused()
            chunk = source.read(CHUNK)
            if not chunk:
                break
            target.write(chunk)
            digest.update(chunk)
            progress["bytes_done"] += len(chunk)
            now = time.monotonic()
            if now - last_event > 0.4:
                send_progress(callback, progress, "copia", path.name)
                last_event = now
        target.flush()
        os.fsync(target.fileno())
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise OSError("Sorgente modificata durante la copia")
    if stage.stat().st_size != before.st_size or file_hash(stage) != digest.hexdigest():
        raise OSError("La copia temporanea non coincide con la sorgente")
    return digest.hexdigest(), before


# Parameter callback: receiver for one JSON progress event.
# Parameter progress: current counters and monotonic start time.
# Parameter phase: human-readable phase description.
# Parameter filename: current original filename for the progress display.
def send_progress(callback: Callable, progress: dict[str, Any], phase: str, filename: str = "") -> None:
    elapsed = max(time.monotonic() - progress["started"], 0.001)
    rate = progress["bytes_done"] / elapsed
    remaining = max(progress["bytes_total"] - progress["bytes_done"], 0)
    callback({"event": "progress", "phase": phase, "done": progress["done"], "total": progress["total"],
              "filename": filename, "bytes_done": progress["bytes_done"], "bytes_total": progress["bytes_total"],
              "elapsed_seconds": round(elapsed, 1), "rate_mib_s": round(rate / CHUNK, 2),
              "eta_seconds": round(remaining / rate) if rate else None})


# Parameter stage: verified local staging copy, not the original.
# Exceptions: ffprobe failures become review metadata, not lost files.
def video_metadata(stage: Path) -> dict[str, Any]:
    binary = ai.ROOT / "runtime/ffmpeg/ffprobe.exe"
    if not binary.exists():
        return {"read_error": "portable_ffprobe_not_available"}
    try:
        result = subprocess.run([str(binary), "-v", "error", "-protocol_whitelist", "file", "-probesize", "1000000",
                                 "-show_format", "-show_streams", "-of", "json", str(stage)],
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            return {"read_error": result.stderr[:500]}
        metadata = json.loads(result.stdout)
        metadata.get("format", {}).pop("filename", None)
        return metadata
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {"read_error": str(error)}


# Parameter path: original source path whose bytes are preserved in stage.
# Parameter source: canonical selected root.
# Parameter stage: verified local copy to inspect without more OneDrive reads.
# Parameter digest: SHA-256 already computed while copying the original.
# Parameter original_stat: timestamps and size captured before copying.
# Exceptions: unexpected metadata errors are preserved as review flags.
def inspect_metadata(path: Path, source: Path, stage: Path, digest: str,
                     original_stat: os.stat_result) -> dict[str, Any]:
    record = {"schema_version": 1, "organizer_version": VERSION, "sha256": digest,
              "asset_id": "sha256:" + digest, "original_path": str(path), "original_root": str(source),
              "original_relative_path": str(path.relative_to(source)), "original_filename": path.name,
              "source_label": technical.source_label(source), "extension_normalized": path.suffix.casefold(),
              "size_bytes": original_stat.st_size, "created_at_utc": technical.iso_from_timestamp(getattr(original_stat, "st_birthtime", original_stat.st_ctime)),
              "modified_at_utc": technical.iso_from_timestamp(original_stat.st_mtime),
              "analysis_fingerprint": [original_stat.st_size, original_stat.st_mtime_ns],
              "image_metadata": {}, "analyzed_at_utc": ai.utc_now(), "review_reasons": []}
    extension = path.suffix.casefold()
    if extension in IMAGE_EXTENSIONS:
        with stage.open("rb") as stream:
            record["image_metadata"] = analyzer.image_metadata(stream)
    elif extension in technical.VIDEO_EXTENSIONS | technical.AUDIO_EXTENSIONS:
        record["video_metadata"] = video_metadata(stage)
    screenshot, confidence, reasons = technical.classify_screenshot(path, source, record["image_metadata"])
    document, confidence, reasons = technical.classify_document_image(path, source)
    record["category"] = technical.category_for(path, screenshot, document, record["image_metadata"])[0]
    # These dedicated buckets must not depend on a screenshot-looking filename.
    if extension in {".ico", ".svg"}:
        record["category"] = "icon"
    elif extension == ".gif":
        record["category"] = "animation"
    if extension in RAW_EXTENSIONS:
        record["category"] = "photo"
    if extension == ".webp" and not record["image_metadata"].get("animated", True):
        record["category"] = "sticker" if "sticker" in str(path).casefold() else "graphic_review"
    # Preserve all candidates, but never promote filesystem/download timestamps to capture dates.
    analyzer.enrich_dates(record)
    today = datetime.now(timezone(timedelta(hours=7))).date()
    usable = [item for item in record["capture_date_candidates"]
              if 1800 <= datetime.fromisoformat(item["value"]).year
              and datetime.fromisoformat(item["value"]).date() <= today + timedelta(days=1)]
    if usable:
        chosen = usable[0]
        record.update(capture_datetime=chosen["value"], capture_precision=chosen["precision"],
                      capture_date_source=chosen["source"], capture_date_confidence=chosen["rank"] / 100)
    else:
        record.update(capture_datetime=None, capture_precision=None, capture_date_source=None)
    if not record.get("capture_datetime") or record.get("capture_precision") not in {"day", "second"}:
        record["review_reasons"].append("capture_day_unknown")
    if record.get("capture_date_source") in {"filename", "folder"}:
        record["review_reasons"].append("capture_date_inferred_from_name_not_metadata")
    record["review_reasons"].extend(record.get("date_issues", []))
    if original_stat.st_size == 0:
        record["review_reasons"].append("empty_original_preserved")
    if record["image_metadata"].get("read_error") or record.get("video_metadata", {}).get("read_error"):
        record["review_reasons"].append("metadata_decoder_error_original_bytes_preserved")
    return record


# Parameter record: technical metadata plus optional independent AI labels.
# Parameter asset_key: content identity, or per-occurrence identity for an empty file.
def output_relative(record: dict[str, Any], asset_key: str) -> Path:
    category = record["category"]
    image = record["extension_normalized"] in IMAGE_EXTENSIONS
    if record.get("ai", {}).get("status") == "analyzed" and image and category not in {"icon", "animation"}:
        category = record["ai"]["category"]
    bucket = KNOWN_FOLDERS.get(category, "Altri_File")
    value = record.get("capture_datetime")
    precision = record.get("capture_precision")
    if record["size_bytes"] == 0:
        folder = Path("Da_Verificare/File_Vuoti")
        prefix = "empty"
    elif value and precision in {"day", "second"}:
        date = value[:10]
        folder = Path(bucket) / date[:4] / date[5:7] / date
        prefix = date
        if precision == "second":
            prefix += "_" + value[11:19].replace(":", "-")
    else:
        folder = Path(bucket) / "Da_Datare"
        prefix = "undated"
    extension = record["extension_normalized"]
    if not extension or len(extension) > 12 or any(character not in ".abcdefghijklmnopqrstuvwxyz0123456789" for character in extension):
        extension = ".bin"
    return Path("Risultato") / folder / (prefix + "__" + asset_key[:20] + extension)


# Parameter destination: one owned review workspace with persistent SQLite checkpoints.
# Parameter source: immutable canonical root identity for this workspace.
# Parameter config_id: fixed metadata/model/settings identity for safe resumes.
# Exceptions: ValueError for mismatched source/settings or invalid stored state.
def open_state(destination: Path, source: Path, config_id: str) -> sqlite3.Connection:
    control = destination / CONTROL
    control.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(control / "state.sqlite3")
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.executescript("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS assets(asset_key TEXT PRIMARY KEY, sha256 TEXT NOT NULL,
                output TEXT UNIQUE NOT NULL, record TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS entries(relative TEXT PRIMARY KEY, size INTEGER NOT NULL,
                mtime INTEGER NOT NULL, asset_key TEXT NOT NULL, origin TEXT NOT NULL);
        """)
        columns = {row[1] for row in connection.execute("PRAGMA table_info(assets)")}
        if "sidecar_hash" not in columns:
            connection.execute("ALTER TABLE assets ADD COLUMN sidecar_hash TEXT")
        if "sidecar_pending" not in columns:
            connection.execute("ALTER TABLE assets ADD COLUMN sidecar_pending INTEGER NOT NULL DEFAULT 1")
        existing = dict(connection.execute("SELECT key,value FROM settings"))
        expected = {"source": os.path.normcase(str(source)), "config_id": config_id}
        if existing and any(existing.get(key) != value for key, value in expected.items()):
            raise ValueError("Output appartiene a un'altra sorgente o impostazioni: scegli una nuova destinazione")
        connection.executemany("INSERT OR IGNORE INTO settings(key,value) VALUES (?,?)", expected.items())
        connection.commit()
        return connection
    except BaseException:
        connection.close()
        raise


# Parameter destination: owned review workspace; only its runner lock is touched.
# Exceptions: OSError if another process already owns the output workspace.
@contextmanager
def workspace_lock(destination: Path):
    lock_path = destination / CONTROL / "runner.lock"
    with lock_path.open("a+b") as lock:
        if lock.seek(0, os.SEEK_END) == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        if os.name == "nt":
            import msvcrt
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise OSError("Questa destinazione e gia in uso da un'altra istanza") from error
        try:
            yield
        finally:
            if os.name == "nt":
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


# Parameter destination: canonical owned output directory.
# Parameter relative: database path that must remain inside output and outside control state.
# Exceptions: ValueError on altered/traversing output paths.
def owned_output(destination: Path, relative: str) -> Path:
    path = (destination / relative).resolve()
    if not path.is_relative_to(destination) or path.is_relative_to(destination / CONTROL):
        raise ValueError("Percorso output non valido nello stato salvato")
    return path


# Parameter destination: canonical review workspace.
# Parameter output: owned media path whose sibling sidecar will be read or written.
# Exceptions: ValueError if an existing sidecar is a link, directory or external path.
def owned_sidecar(destination: Path, output: Path) -> Path:
    sidecar = Path(str(output) + ".meta.json")
    if sidecar.is_symlink() or sidecar.is_junction():
        raise ValueError("Sidecar collegato altrove: preservato senza modificarlo")
    owned_output(destination, str(sidecar.relative_to(destination)))
    if sidecar.exists() and not sidecar.is_file():
        raise ValueError("Il percorso del sidecar non e un file")
    return sidecar


# Parameter connection: persistent workspace checkpoint store.
# Parameter destination: canonical review output.
# Parameter asset: one known content asset to verify before declaring it reusable.
# Parameter repair_sidecar: allows regeneration of a missing sidecar, never overwrites a changed one.
# Exceptions: OSError or ValueError for damaged output or user-modified sidecars.
def verify_asset(connection: sqlite3.Connection, destination: Path, asset: sqlite3.Row,
                 repair_sidecar: bool = False) -> bool:
    output = owned_output(destination, asset["output"])
    record = json.loads(asset["record"])
    if not output.is_file():
        return False
    if output.stat().st_size != record["size_bytes"] or file_hash(output) != asset["sha256"]:
        raise ValueError("Output alterato: " + str(output))
    sidecar = owned_sidecar(destination, output)
    expected = sidecar_payload(connection, asset, destination)
    if not sidecar.exists():
        if not repair_sidecar:
            return False
        ai.write_json(sidecar, expected)
    else:
        saved = json.loads(sidecar.read_text(encoding="utf-8"))
        if saved != expected:
            # A committed provenance update may have been interrupted before its atomic JSON write.
            previous_owned_bytes = asset["sidecar_hash"] and file_hash(sidecar) == asset["sidecar_hash"]
            if asset["sidecar_pending"] and previous_owned_bytes and repair_sidecar:
                ai.write_json(sidecar, expected)
            else:
                raise ValueError("Sidecar modificato o incompleto: preservato senza sovrascriverlo: " + str(sidecar))
    connection.execute("UPDATE assets SET sidecar_hash=?,sidecar_pending=0 WHERE asset_key=?",
                       (file_hash(sidecar), asset["asset_key"]))
    connection.commit()
    return True


# Parameter connection: state store containing every original occurrence of this asset.
# Parameter asset: canonical byte-identical output asset and its technical metadata.
# Parameter destination: output root recorded as informational provenance.
def sidecar_payload(connection: sqlite3.Connection, asset: sqlite3.Row, destination: Path) -> dict[str, Any]:
    record = json.loads(asset["record"])
    origins = [json.loads(row[0]) for row in connection.execute("SELECT origin FROM entries WHERE asset_key=? ORDER BY relative", (asset["asset_key"],))]
    return {**record, "output_relative_path": asset["output"],
            "archive_relative_path": str(Path(asset["output"]).relative_to("Risultato")),
            "copied_to": str(destination / asset["output"]),
            "originals": origins, "original_occurrences": len(origins),
            "operation": "copy_only", "source_deleted": False,
            "verification": {"algorithm": "SHA-256", "source_equals_output": True},
            "manual_review_required": True}


# Parameter connection: open state store.
# Parameter destination: owned output root.
# Parameter item: scanned source occurrence.
# Parameter asset_key: target byte identity.
# Parameter origin: preserved original name/path/timestamps and input fingerprint.
# Exceptions: state or filesystem errors leave resumable database intent and no source changes.
def commit_occurrence(connection: sqlite3.Connection, destination: Path, item: dict[str, Any],
                      asset_key: str, origin: dict[str, Any]) -> None:
    asset = connection.execute("SELECT * FROM assets WHERE asset_key=?", (asset_key,)).fetchone()
    sidecar = owned_sidecar(destination, owned_output(destination, asset["output"]))
    if sidecar.exists() and asset["sidecar_hash"] and file_hash(sidecar) != asset["sidecar_hash"]:
        raise ValueError("Sidecar cambiato durante il lavoro: non viene sovrascritto")
    connection.execute("INSERT OR REPLACE INTO entries VALUES (?,?,?,?,?)",
                       (item["relative"], item["size"], item["mtime"], asset_key, json.dumps(origin, ensure_ascii=False)))
    connection.execute("UPDATE assets SET sidecar_pending=1 WHERE asset_key=?", (asset_key,))
    connection.commit()
    asset = connection.execute("SELECT * FROM assets WHERE asset_key=?", (asset_key,)).fetchone()
    ai.write_json(sidecar, sidecar_payload(connection, asset, destination))
    connection.execute("UPDATE assets SET sidecar_hash=?,sidecar_pending=0 WHERE asset_key=?", (file_hash(sidecar), asset_key))
    connection.commit()


# Parameter record: unique staged media asset with original technical metadata.
# Parameter stage: local byte-preserving copy used exclusively for AI previews.
# Parameter settings: local engine settings or None to disable AI.
# Parameter identity: versioned model/prompt cache key.
# Parameter stack: owns the lazy engine context and stops it on exit.
# Parameter engine: mutable endpoint/error state shared across this batch.
# Parameter prompt: catalog instructions that treat source text as untrusted.
# Exceptions: inference errors are recorded as review issues; data copying is still preserved.
def enrich_ai(record: dict[str, Any], stage: Path, settings: dict[str, Any] | None, identity: str,
              stack: ExitStack, engine: dict[str, Any], prompt: str) -> None:
    if settings is None or record["extension_normalized"] not in ai.IMAGE_EXTENSIONS or record["image_metadata"].get("read_error") or not record["size_bytes"]:
        record["ai"] = {"status": "not_requested_or_not_decodable"}
        return
    cached = ai.ROOT / "cache/catalog" / identity / (record["sha256"] + ".json")
    try:
        if cached.exists():
            record["ai"] = json.loads(cached.read_text(encoding="utf-8"))
        else:
            if engine.get("startup_error"):
                raise RuntimeError(engine["startup_error"])
            if "endpoint" not in engine:
                try:
                    engine["endpoint"] = stack.enter_context(ai.running_server(settings))
                except (OSError, RuntimeError) as error:
                    engine["startup_error"] = str(error)
                    raise
            stat = stage.stat()
            preview_record = {**record, "original_path": str(stage), "analysis_fingerprint": [stat.st_size, stat.st_mtime_ns]}
            image_url, preview_info = ai.preview(preview_record, settings["max_image_edge"])
            result = ai.infer(engine["endpoint"], image_url, settings, prompt)
            record["ai"] = {**result, "status": "analyzed", "asset_sha256": record["sha256"],
                            "model": "Qwen3-VL-4B-Instruct-Q4_K_M", "config_fingerprint": identity,
                            "inference_backend": settings.get("resolved_backend", "cuda"),
                            "analyzed_at_utc": ai.utc_now(), "input_preview": preview_info,
                            "review_status": "unreviewed"}
            ai.write_json(cached, record["ai"])
        if record["ai"].get("needs_review"):
            record["review_reasons"].append("ai_classification_uncertain")
        if record["image_metadata"].get("frames", 1) > 1:
            record["review_reasons"].append("ai_only_first_frame_analyzed")
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        record["ai"] = {"status": "error", "reason": str(error)}
        record["review_reasons"].append("ai_analysis_failed_original_preserved")


# Parameter source: exactly the selected folder to copy; no automatic deletion is provided.
# Parameter destination: separate user-selected temporary review workspace.
# Parameter run: explicit permission to copy contents instead of metadata-only what-if.
# Parameter allow_cloud: explicit permission for reads to hydrate selected source files.
# Parameter use_ai: enables independent local visual enrichment of decodable images.
# Parameter verify_only: rechecks existing output/sidecars without reading originals or starting AI.
# Parameter reserve_bytes: per-volume minimum free-space margin.
# Parameter callback: JSON progress/event sink used by console and GUI.
# Exceptions: path/state errors abort; per-file copy errors are recorded and prevent readiness.
def run_folder(source: Path, destination: Path, run: bool = False, allow_cloud: bool = False,
               use_ai: bool = True, verify_only: bool = False, reserve_bytes: int = 20 * 1024**3,
               callback: Callable = emit) -> dict[str, Any]:
    source, destination = validate_paths(source, destination)
    items, omissions = scan_source(source, callback)
    total_bytes = sum(item["size"] for item in items)
    if not run and not verify_only:
        summary = {"mode": "what-if", "total": len(items), "bytes_total": total_bytes,
                   "online_or_recall_flagged": sum(bool(item["attributes"] & analyzer.BLOCKED_ATTRIBUTES) for item in items),
                   "omissions": omissions, "source": str(source), "destination": str(destination),
                   "ready_for_review": False, "contents_opened": False, "destination_created": False}
        callback({"event": "summary", "summary": summary, "message": "Simulazione: nessuna copia o download"})
        return summary
    if verify_only and not (destination / CONTROL / "state.sqlite3").is_file():
        raise ValueError("Nessuno stato da verificare in questa destinazione")
    settings = ai.configuration() if use_ai and not verify_only else None
    prompt = (ai.ROOT / "config/catalog-prompt.txt").read_text(encoding="utf-8") if settings else ""
    identity = ai.cache_fingerprint(settings, prompt) if settings else "no-ai"
    config_id = hashlib.sha256(json.dumps({"version": VERSION, "ai": identity, "layout": "YYYY/MM/YYYY-MM-DD"}, sort_keys=True).encode()).hexdigest()
    control = destination / CONTROL
    control.mkdir(parents=True, exist_ok=True)
    ownership = ExitStack()
    connection = None
    try:
        ownership.enter_context(workspace_lock(destination))
        if verify_only:
            # Verification uses the workspace's settings, not today's AI checkbox/model.
            with closing(sqlite3.connect(control / "state.sqlite3")) as stored:
                saved = stored.execute("SELECT value FROM settings WHERE key='config_id'").fetchone()
                if not saved:
                    raise ValueError("Stato privo delle impostazioni originali")
                config_id = saved[0]
        connection = open_state(destination, source, config_id)
        pause = control / "pause.request"
        if pause.exists():
            pause.unlink()  # Only the tool's own pause marker is reset on an explicit new run.
        staging = control / "staging"
        staging.mkdir(exist_ok=True)
    except BaseException:
        if connection is not None:
            connection.close()
        ownership.close()
        raise
    progress = {"done": 0, "total": len(items), "bytes_done": 0, "bytes_total": total_bytes, "started": time.monotonic()}
    summary = {"mode": "verify" if verify_only else "copy-only", "source": str(source), "destination": str(destination),
               "started_at_utc": ai.utc_now(), "total": len(items), "completed": 0, "resumed": 0,
               "duplicates": 0, "unique_files": 0, "review_files": 0, "errors": 0,
               "stopped": False, "source_changed_during_run": False, "omissions": omissions,
               "source_modified_or_deleted": False, "allow_cloud": allow_cloud}
    verified = set()
    failures = []
    try:
        with ExitStack() as stack:
            engine = {}
            for item in items:
                path = source / item["relative"]
                if pause.exists():
                    raise Paused()
                try:
                    entry = connection.execute("SELECT * FROM entries WHERE relative=?", (item["relative"],)).fetchone()
                    if entry and (entry["size"], entry["mtime"]) == (item["size"], item["mtime"]):
                        send_progress(callback, progress, "verifica output per ripresa", path.name)
                        asset = connection.execute("SELECT * FROM assets WHERE asset_key=?", (entry["asset_key"],)).fetchone()
                        if asset and (asset["asset_key"] in verified or verify_asset(connection, destination, asset, repair_sidecar=not verify_only)):
                            callback({"event": "log", "action": "resume_verified", "source": str(path),
                                      "output": str(destination / asset["output"]), "sha256": asset["sha256"]})
                            verified.add(asset["asset_key"])
                            summary["completed"] += 1
                            summary["resumed"] += 1
                            progress["done"] += 1
                            progress["bytes_done"] += item["size"]
                            send_progress(callback, progress, "gia verificato / ripreso", path.name)
                            continue
                    if verify_only:
                        raise ValueError("Originale senza una copia completa verificabile")
                    callback({"event": "log", "phase": "lettura sorgente", "filename": path.name,
                              "message": "Lettura: " + item["relative"]})
                    stage = staging / (hashlib.sha256(item["relative"].encode()).hexdigest() + ".part")
                    digest, original_stat = stage_file(path, stage, allow_cloud, pause, callback, progress, reserve_bytes)
                    if (original_stat.st_size, original_stat.st_mtime_ns) != (item["size"], item["mtime"]):
                        raise ValueError("Sorgente cambiata dopo l'inventario; riprendi con una nuova scansione")
                    key = digest if item["size"] else hashlib.sha256((digest + item["relative"]).encode()).hexdigest()
                    asset = connection.execute("SELECT * FROM assets WHERE asset_key=?", (key,)).fetchone()
                    if asset:
                        # The existing output must still be intact before a second original references it.
                        if not verify_asset(connection, destination, asset, repair_sidecar=True):
                            restored = owned_output(destination, asset["output"])
                            restored.parent.mkdir(parents=True, exist_ok=True)
                            if restored.exists():
                                raise ValueError("Copia esistente non verificabile: non viene sovrascritta")
                            stage.replace(restored)
                            os.utime(restored, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
                            if file_hash(restored) != digest:
                                raise ValueError("Verifica della copia ripristinata fallita")
                        summary["duplicates"] += 1
                    else:
                        record = inspect_metadata(path, source, stage, digest, original_stat)
                        send_progress(callback, progress, "metadati / AI", path.name)
                        enrich_ai(record, stage, settings, identity, stack, engine, prompt)
                        relative_output = output_relative(record, key)
                        output = owned_output(destination, str(relative_output))
                        output.parent.mkdir(parents=True, exist_ok=True)
                        if owned_sidecar(destination, output).exists():
                            raise ValueError("Sidecar preesistente senza checkpoint: non viene sovrascritto")
                        if output.exists():
                            if file_hash(output) != digest:
                                raise ValueError("Collisione output: il file esistente non viene sovrascritto")
                        else:
                            stage.replace(output)
                            os.utime(output, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
                        if file_hash(output) != digest:
                            raise ValueError("Verifica SHA-256 dell'output fallita")
                        record["copied_at_utc"] = ai.utc_now()
                        record["copy_original_mtime_preserved"] = True
                        connection.execute("INSERT INTO assets(asset_key,sha256,output,record) VALUES (?,?,?,?)",
                                           (key, digest, str(relative_output), json.dumps(record, ensure_ascii=False)))
                        connection.commit()
                        asset = connection.execute("SELECT * FROM assets WHERE asset_key=?", (key,)).fetchone()
                    origin = {"path": str(path), "relative_path": item["relative"], "name": path.name,
                              "size_bytes": item["size"], "mtime_ns": item["mtime"],
                              "created_at_utc": technical.iso_from_timestamp(getattr(original_stat, "st_birthtime", original_stat.st_ctime)),
                              "sha256": digest, "copied_or_matched_at_utc": ai.utc_now()}
                    commit_occurrence(connection, destination, item, key, origin)
                    callback({"event": "log", "action": "copy_verified", "source": str(path),
                              "output": str(destination / asset["output"]), "sha256": digest,
                              "size_bytes": item["size"], "asset_key": key})
                    if stage.exists():
                        stage.unlink()  # Verified redundant staging bytes only, never an original.
                    verified.add(key)
                    summary["completed"] += 1
                    progress["done"] += 1
                    send_progress(callback, progress, "copiato e verificato", path.name)
                except Paused:
                    raise
                except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
                    summary["errors"] += 1
                    progress["done"] += 1
                    failure = {"relative": item["relative"], "error": str(error)}
                    failures.append(failure)
                    callback({"event": "error", "filename": path.name, "message": str(error)})
    except (Paused, KeyboardInterrupt):
        summary["stopped"] = True
    finally:
        # Reconcile every input occurrence, not merely the count of unique output files.
        try:
            current, final_omissions = scan_source(source, callback)
        except OSError as error:
            current, final_omissions = [], [str(source)]
            summary["errors"] += 1
            failures.append({"relative": ".", "error": "Controllo finale della sorgente fallito: " + str(error)})
        initial_signature = [(item["relative"], item["size"], item["mtime"]) for item in items]
        final_signature = [(item["relative"], item["size"], item["mtime"]) for item in current]
        summary["source_changed_during_run"] = initial_signature != final_signature
        summary["omissions"] = sorted(set(omissions + final_omissions))
        summary["unique_files"] = len(verified)
        summary["duplicates"] = max(summary["completed"] - len(verified), 0)
        summary["review_files"] = sum(bool(json.loads(row["record"]).get("review_reasons"))
                                      for row in connection.execute("SELECT * FROM assets") if row["asset_key"] in verified)
        summary["ready_for_review"] = (summary["completed"] == len(items) and not summary["errors"]
                                       and not summary["stopped"] and not summary["omissions"]
                                       and not summary["source_changed_during_run"])
        summary["finished_at_utc"] = ai.utc_now()
        summary["result_folder"] = str(destination / "Risultato")
        summary["historical_outputs_retained"] = connection.execute("SELECT COUNT(*) FROM assets WHERE asset_key NOT IN (SELECT asset_key FROM entries)").fetchone()[0]
        summary["elapsed_seconds"] = round(time.monotonic() - progress["started"], 2)
        summary["resume_note"] = "Originali gia completati riconosciuti da percorso/dimensione/mtime; output e sidecar verificati. Solo il file interrotto puo essere ricopiato."
        try:
            ai.write_json(destination / CONTROL / "summary.json", summary)
            ai.write_json(destination / CONTROL / "errors.json", failures)
            with (destination / CONTROL / "manifest.jsonl").open("w", encoding="utf-8") as manifest:
                for row in connection.execute("SELECT entries.relative, entries.origin, assets.output, assets.sha256 FROM entries JOIN assets USING(asset_key) ORDER BY relative"):
                    manifest.write(json.dumps(dict(row), ensure_ascii=False) + "\n")
        finally:
            connection.close()
            ownership.close()
    callback({"event": "summary", "summary": summary,
              "message": "Pronto per il tuo controllo" if summary["ready_for_review"] else "Output incompleto / sospeso: non eliminare la sorgente"})
    return summary


# Exceptions: argument/state errors emit a structured message and a nonzero exit code.
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--run", action="store_true")
    modes.add_argument("--what-if", "--dry-run", action="store_true")
    modes.add_argument("--verify-only", action="store_true")
    parser.add_argument("--allow-cloud", action="store_true")
    parser.add_argument("--no-ai", action="store_true")
    parser.add_argument("--reserve-gb", type=float, default=20)
    args = parser.parse_args()
    if args.reserve_gb < 0:
        parser.error("--reserve-gb must be nonnegative")
    with JobLog("copy", {"source": str(args.source), "destination": str(args.destination),
                         "run": args.run, "verify_only": args.verify_only, "use_ai": not args.no_ai}) as log:
        log.emit({"event": "log", "message": "Log dettagliato: " + str(log.path), "log_path": str(log.path)})
        result = run_folder(args.source, args.destination, run=args.run, allow_cloud=args.allow_cloud,
                            use_ai=not args.no_ai, verify_only=args.verify_only,
                            reserve_bytes=int(args.reserve_gb * 1024**3), callback=log.emit)
    return 0 if result.get("ready_for_review") or result["mode"] == "what-if" else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
        emit({"event": "error", "message": str(error)})
        raise SystemExit(1)
