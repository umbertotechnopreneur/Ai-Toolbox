"""Preview and recycle individually verified originals; never bulk-delete folders."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import time
import uuid
from contextlib import ExitStack, closing, contextmanager
from pathlib import Path

import ai_toolbox as ai
import analyze_local as analyzer
import folder_organizer as organizer
from job_log import JobLog

CONTROL = ".photo-cleanup"
EXCLUDED = {CONTROL, organizer.CONTROL}
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


class BasicInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_longlong) for name in ("created", "accessed", "written", "changed")]
    _fields_.append(("attributes", ctypes.c_uint32))


# Parameter path: absolute local/UNC name, represented for the Windows file APIs.
def extended_path(path):
    value = str(path.absolute())
    if value.startswith("\\\\?\\"):
        return value
    return "\\\\?\\UNC\\" + value[2:] if value.startswith("\\\\") else "\\\\?\\" + value


# Parameter path: regular file whose cache identity is being checked without reading data.
# Exceptions: OSError on missing files; missing Windows change-time disables hash reuse.
def fingerprint(path):
    stat = path.stat()
    change = stat.st_ctime_ns if os.name != "nt" else None
    if os.name == "nt":
        kernel, cloud = analyzer.windows_apis()
        kernel.GetFileInformationByHandleEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        kernel.GetFileInformationByHandleEx.restype = ctypes.c_int
        handle = kernel.CreateFileW(extended_path(path), 0x80, 7, None, 3, 0x00100000, None)
        if handle != ctypes.c_void_p(-1).value:
            try:
                info = BasicInfo()
                if kernel.GetFileInformationByHandleEx(handle, 0, ctypes.byref(info), ctypes.sizeof(info)):
                    change = int(info.changed) or None
            finally:
                kernel.CloseHandle(handle)
    return {"size": stat.st_size, "mtime": stat.st_mtime_ns, "device": stat.st_dev,
            "file_id": stat.st_ino, "change": change, "strong": bool(change and stat.st_ino)}


# Parameter source: one exact user-selected input folder, never a drive/toolbox/OneDrive root.
# Parameter target: separately selected archive containing the retained copies.
# Exceptions: ValueError on broad roots, overlap, links or missing folders.
def validate_paths(source, target):
    source, target = source.resolve(), target.resolve()
    for folder in (source, target):
        if not folder.is_dir() or folder == Path(folder.anchor) or folder == ai.ROOT.resolve() or folder.name.casefold() == "onedrive":
            raise ValueError("Scegli due cartelle specifiche esistenti, non radici di disco/OneDrive/toolbox")
    if source.is_relative_to(target) or target.is_relative_to(source):
        raise ValueError("Input e target non possono coincidere o contenersi")
    return source, target


# Parameter root: fixed root to enumerate, excluding bookkeeping and every link/junction.
# Parameter callback: progress/log receiver.
# Parameter pause: optional package-owned cooperative pause marker.
# Exceptions: OSError for inaccessible folders; Paused for an explicit stop request.
def scan_files(root, callback, pause=None):
    files, omissions, folders = [], [], [root]
    while folders:
        if pause and pause.exists():
            raise organizer.Paused()
        with os.scandir(folders.pop()) as entries:
            for entry in entries:
                path = Path(entry.path)
                if entry.is_symlink() or path.is_junction():
                    omissions.append(str(path))
                elif entry.is_dir(follow_symlinks=False):
                    if entry.name.casefold() not in EXCLUDED:
                        folders.append(path)
                elif entry.is_file(follow_symlinks=False):
                    files.append(path)
                    if len(files) % 250 == 0:
                        callback({"event": "scan", "phase": "inventario pulizia", "done": len(files), "total": 0})
    return sorted(files, key=lambda path: str(path).casefold()), omissions


# Parameter root: exact canonical folder.
# Parameter relative: stored relative file path, never a glob or recursive-delete target.
# Exceptions: ValueError on traversal, links, directories or bookkeeping paths.
def scoped_file(root, relative):
    part = Path(relative)
    if part.is_absolute() or ".." in part.parts or any(item.casefold() in EXCLUDED for item in part.parts):
        raise ValueError("Percorso fuori dal perimetro autorizzato")
    path = root / part
    for parent in [path, *path.parents]:
        if parent == root:
            break
        if parent.is_symlink() or parent.is_junction():
            raise ValueError("Collegamento/junction: nessuna eliminazione")
    resolved = path.resolve()
    if not resolved.is_relative_to(root) or resolved == root or not resolved.is_file():
        raise ValueError("Il percorso non e un file regolare nel perimetro")
    return resolved


# Parameter target: selected archive, with its own SQLite index and lock.
# Exceptions: OSError/ValueError/SQLite errors fail closed.
@contextmanager
def index_state(target):
    control = target / CONTROL
    if control.is_symlink() or control.is_junction():
        raise ValueError("La cartella indice non puo essere un collegamento")
    control.mkdir(exist_ok=True)
    if any(path.is_symlink() or path.is_junction() for path in control.iterdir()):
        raise ValueError("Un file dell'indice e un collegamento: operazione rifiutata")
    with ExitStack() as stack:
        # Reuse the same byte-range lock protocol without sharing copy-workspace state.
        lock = stack.enter_context((control / "runner.lock").open("a+b"))
        if lock.seek(0, os.SEEK_END) == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            stack.callback(msvcrt.locking, lock.fileno(), msvcrt.LK_UNLCK, 1)
        connection = stack.enter_context(closing(sqlite3.connect(control / "index.sqlite3")))
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=FULL")
        connection.executescript("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(relative TEXT PRIMARY KEY,signature TEXT NOT NULL,
                size INTEGER NOT NULL,sha256 TEXT,side_signature TEXT,origins TEXT NOT NULL DEFAULT '[]');
            CREATE INDEX IF NOT EXISTS files_size ON files(size);
            CREATE INDEX IF NOT EXISTS files_hash ON files(sha256);
            CREATE TABLE IF NOT EXISTS origins(original TEXT NOT NULL,relative TEXT NOT NULL,
                PRIMARY KEY(original,relative));
            CREATE TABLE IF NOT EXISTS plans(id TEXT PRIMARY KEY,digest TEXT NOT NULL,body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS receipts(plan_id TEXT NOT NULL,relative TEXT NOT NULL,
                status TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(plan_id,relative));
        """)
        saved = dict(connection.execute("SELECT key,value FROM settings"))
        expected = {"target": os.path.normcase(str(target)), "version": "1"}
        if saved and saved != expected:
            raise ValueError("Indice appartenente a un altro target/versione")
        connection.executemany("INSERT OR IGNORE INTO settings VALUES (?,?)", expected.items())
        connection.commit()
        yield connection, control


# Parameter target: actual archive path, not a historical copied_to field.
# Parameter connection: open archive index.
# Parameter callback: progress/log receiver.
# Parameter pause: cooperative stop marker.
# Exceptions: inaccessible/malformed individual assets are logged and omitted, never deletion evidence.
def refresh_index(target, connection, callback, pause):
    files, omissions = scan_files(target, callback, pause)
    assets = [path for path in files if not path.name.casefold().endswith(".meta.json")]
    seen, errors, cached = set(), 0, 0
    for done, path in enumerate(assets, 1):
        if pause.exists():
            raise organizer.Paused()
        relative = str(path.relative_to(target))
        seen.add(relative)
        try:
            signature = fingerprint(path)
            previous = connection.execute("SELECT * FROM files WHERE relative=?", (relative,)).fetchone()
            encoded = json.dumps(signature, sort_keys=True)
            digest = previous["sha256"] if previous and signature["strong"] and previous["signature"] == encoded else None
            cached += bool(digest)
            sidecar = Path(str(path) + ".meta.json")
            side_signature, origins = None, []
            if sidecar.is_file() and not sidecar.is_symlink():
                side_info = fingerprint(sidecar)
                side_signature = json.dumps(side_info, sort_keys=True)
                if previous and side_info["strong"] and previous["side_signature"] == side_signature:
                    origins = json.loads(previous["origins"])
                else:
                    try:
                        record = json.loads(sidecar.read_text(encoding="utf-8-sig"))
                        if DIGEST.fullmatch(str(record.get("sha256", ""))) and record.get("size_bytes") == signature["size"]:
                            origins = [item["path"] for item in record.get("originals", []) if isinstance(item, dict) and isinstance(item.get("path"), str)]
                            if isinstance(record.get("original_path"), str):
                                origins.append(record["original_path"])
                    except (OSError, ValueError, TypeError, AttributeError) as error:
                        callback({"event": "log", "action": "sidecar_unusable", "target_relative": relative, "reason": str(error)})
                        # A bad locator must not exclude the media from actual-content fallback.
                        origins, side_signature = [], None
            connection.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)",
                               (relative, encoded, signature["size"], digest, side_signature, json.dumps(sorted(set(origins)))))
            connection.execute("DELETE FROM origins WHERE relative=?", (relative,))
            connection.executemany("INSERT OR IGNORE INTO origins VALUES (?,?)",
                                   [(os.path.normcase(value), relative) for value in origins])
        except (OSError, ValueError, TypeError, AttributeError) as error:
            errors += 1
            connection.execute("DELETE FROM files WHERE relative=?", (relative,))
            connection.execute("DELETE FROM origins WHERE relative=?", (relative,))
            callback({"event": "log", "action": "index_omitted", "target_relative": relative, "reason": str(error)})
        if done % 100 == 0 or done == len(assets):
            connection.commit()
            callback({"event": "progress", "phase": "indice SQLite: firme e metadati", "done": done, "total": len(assets), "filename": relative})
    for row in connection.execute("SELECT relative FROM files").fetchall():
        if row[0] not in seen:
            connection.execute("DELETE FROM files WHERE relative=?", (row[0],))
            connection.execute("DELETE FROM origins WHERE relative=?", (row[0],))
    connection.commit()
    return {"indexed": connection.execute("SELECT COUNT(*) FROM files").fetchone()[0], "cached_target_hashes": cached,
            "index_errors": errors, "target_omissions": omissions}


# Parameter path: scoped regular file, held read-only while hashing.
# Parameter pause: cooperative stop marker, checked per MiB.
# Parameter callback: detailed hash progress receiver.
# Exceptions: Paused/OSError/ValueError on a changed file or unavailable contents.
def hash_file(path, pause, callback):
    with organizer.source_stream(path, True) as stream:
        digest, signature = hash_stream(path, stream, pause, callback)
    return digest, signature


# Parameter path: path corresponding to the held read handle.
# Parameter stream: read-only handle denying write/delete sharing.
# Parameter pause: stop marker checked between chunks.
# Parameter callback: detailed hash progress receiver.
# Exceptions: Paused/ValueError if interrupted or the file identity/size/mtime changes.
def hash_stream(path, stream, pause, callback):
    before = fingerprint(path)
    digest, count, last = hashlib.sha256(), 0, 0.0
    stream.seek(0)
    while True:
        if pause.exists():
            raise organizer.Paused()
        chunk = stream.read(organizer.CHUNK)
        if not chunk:
            break
        digest.update(chunk)
        count += len(chunk)
        if time.monotonic() - last > 0.5:
            callback({"event": "log", "action": "hash_progress", "filename": str(path), "bytes_hashed": count,
                      "size_bytes": before["size"], "message": "SHA-256: " + path.name})
            last = time.monotonic()
    after = fingerprint(path)
    if count != before["size"] or any(before[key] != after[key] for key in ("size", "mtime", "file_id", "device")):
        raise ValueError("File modificato durante la verifica")
    return digest.hexdigest(), after


# Parameter target: fixed archive root.
# Parameter connection: SQLite index holding verified hashes, not just JSON claims.
# Parameter relative: indexed asset to verify.
# Parameter pause: stop marker.
# Parameter callback: detailed verification receiver.
# Parameter stream: optional held target handle that remains locked throughout recycling.
# Exceptions: OSError/ValueError/Paused on unavailable or changing assets.
def target_hash(target, connection, relative, pause, callback, stream=None):
    path = scoped_file(target, relative)
    signature = fingerprint(path)
    row = connection.execute("SELECT * FROM files WHERE relative=?", (relative,)).fetchone()
    if row and row["sha256"] and signature["strong"] and json.loads(row["signature"]) == signature:
        callback({"event": "log", "action": "target_hash_cache_hit", "target_relative": relative, "sha256": row["sha256"]})
        return row["sha256"], signature
    digest, signature = hash_stream(path, stream, pause, callback) if stream else hash_file(path, pause, callback)
    if not row:
        raise ValueError("File non presente nell'indice del target")
    connection.execute("UPDATE files SET sha256=?,signature=?,size=? WHERE relative=?",
                       (digest, json.dumps(signature, sort_keys=True), signature["size"], relative))
    connection.commit()
    callback({"event": "log", "action": "target_hash_verified", "target_relative": relative, "sha256": digest})
    return digest, signature


# Parameter source: fixed original input folder.
# Parameter target: archive root and SQLite-index owner.
# Parameter connection: refreshed target index.
# Parameter control: index/control folder holding previews and the pause marker.
# Parameter limit: bounded maximum number of files authorized by one preview.
# Parameter callback: progress/candidate/log receiver.
# Exceptions: per-file errors preserve that input; global path/state errors abort.
def make_plan(source, target, connection, control, limit, callback):
    pause = control / "pause.request"
    files, omissions = scan_files(source, callback, pause)
    candidates, kept, checked = [], [], 0
    for path in files:
        if len(candidates) >= limit:
            break
        if pause.exists():
            raise organizer.Paused()
        checked += 1
        relative = str(path.relative_to(source))
        try:
            current = scoped_file(source, relative)
            signature = fingerprint(current)
            if signature["size"] == 0:
                raise ValueError("File vuoto: conservato per verifica manuale")
            direct = [row[0] for row in connection.execute("SELECT relative FROM origins WHERE original=? ORDER BY relative",
                                                         (os.path.normcase(str(current)),))]
            by_size = [row[0] for row in connection.execute("SELECT relative FROM files WHERE size=? ORDER BY sha256 IS NULL,relative",
                                                          (signature["size"],))]
            possible = list(dict.fromkeys(direct + by_size))
            if not possible:
                raise ValueError("Nessuna copia candidata nel target")
            digest, signature = hash_file(current, pause, callback)
            match = None
            for target_relative in possible:
                copy = scoped_file(target, target_relative)
                if copy.stat().st_size != signature["size"] or os.path.samefile(current, copy):
                    continue
                try:
                    saved_hash, copy_signature = target_hash(target, connection, target_relative, pause, callback)
                    if digest == saved_hash:
                        match = {"source_relative": relative, "target_relative": target_relative,
                                 "sha256": digest, "source_signature": signature, "target_signature": copy_signature,
                                 "method": "metadati + SHA-256" if target_relative in direct else "SHA-256"}
                        break
                except (OSError, ValueError) as error:
                    callback({"event": "log", "action": "candidate_rejected", "target_relative": target_relative, "reason": str(error)})
            if not match:
                raise ValueError("Contenuti diversi: originale conservato")
            candidates.append(match)
            callback({"event": "match", **match})
        except (OSError, ValueError) as error:
            kept.append({"source_relative": relative, "reason": str(error)})
            callback({"event": "log", "action": "input_kept", "source_relative": relative, "reason": str(error)})
        callback({"event": "progress", "phase": "simulazione pulizia: verifica copie", "done": checked, "total": len(files), "filename": relative})
    plan_id = uuid.uuid4().hex
    body = {"version": 1, "id": plan_id, "source": str(source), "target": str(target), "created_at_utc": ai.utc_now(),
            "total": len(files), "checked": checked, "candidates": candidates, "kept": kept,
            "not_checked_due_to_limit": len(files) - checked, "omissions": omissions, "delete_mode": "recycle_only"}
    encoded = json.dumps(body, ensure_ascii=False, sort_keys=True)
    digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    connection.execute("INSERT INTO plans VALUES (?,?,?)", (plan_id, digest, encoded))
    connection.commit()
    ai.write_json(control / "latest-plan.json", {**body, "confirmation_hash": digest})
    return {"mode": "cleanup-plan", "source": str(source), "target": str(target), "total": len(files), "checked": checked,
            "matched": len(candidates), "kept": len(kept), "remaining": len(files) - checked,
            "plan_id": plan_id, "confirmation_hash": digest, "ready_for_review": bool(candidates), "errors": 0,
            "omissions": omissions, "deleted": 0, "limit": limit}


class RecycleBridge:
    # Parameter self: single owned helper, started only on the first authorized deletion.
    def __init__(self):
        self.process = None
        self.error_log = None

    # Parameter self: helper lifecycle owner.
    def __enter__(self):
        return self

    # Parameter self: helper lifecycle owner.
    # Parameter path: one scoped original, never a folder or wildcard.
    # Parameter source: approved source root.
    # Parameter digest: fresh source hash equal to the locked retained copy.
    # Exceptions: OSError/RuntimeError on helper startup, refusal or recycling failure.
    def recycle(self, path, source, digest):
        if self.process is None:
            if os.name != "nt":
                raise OSError("Il Cestino Windows non e disponibile")
            script = ai.ROOT / "scripts/Recycle-Verified.ps1"
            binary = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            log_folder = ai.ROOT / "logs/photo-organizer"
            log_folder.mkdir(parents=True, exist_ok=True)
            self.error_log = (log_folder / ("recycle-helper-" + uuid.uuid4().hex + ".log")).open("x", encoding="utf-8")
            environment = os.environ.copy()
            environment.update(TEMP=str(ai.ROOT / "temp"), TMP=str(ai.ROOT / "temp"))
            self.process = subprocess.Popen([str(binary), "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Confirmed"],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.error_log,
                                            text=True, encoding="utf-8", env=environment, creationflags=subprocess.CREATE_NO_WINDOW)
        self.process.stdin.write(json.dumps({"path": str(path), "source": str(source), "sha256": digest}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        response = self.process.stdout.readline()
        if not response:
            raise RuntimeError("Helper Cestino terminato: nessun altro file viene eliminato")
        result = json.loads(response)
        if not result.get("recycled") or not result.get("recycle_path"):
            raise RuntimeError(result.get("error", "Cestino non confermato"))
        return result

    # Parameter self: helper lifecycle owner.
    # Parameter error_type: unused context exception type.
    # Parameter error: unused context exception value.
    # Parameter traceback: unused context traceback.
    # Exceptions: helper shutdown failures do not authorize other deletions.
    def __exit__(self, error_type, error, traceback):
        if self.process:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.process.stdout.close()
        if self.error_log:
            self.error_log.close()


# Parameter source: exact approved original folder.
# Parameter target: retained-copy archive; never a deletion target.
# Parameter connection: target index plus durable individual-file receipts.
# Parameter control: package-owned control folder.
# Parameter plan_id: preview identifier from an explicit user-confirmed plan.
# Parameter confirmation: SHA-256 of that exact persisted preview.
# Parameter callback: durable log plus GUI/console sink; deletion intent is emitted first.
# Parameter recycler: optional fixture-only bridge, never selected from CLI/file metadata.
# Exceptions: global confirmation mismatch aborts; per-file doubts preserve the original.
def apply_plan(source, target, connection, control, plan_id, confirmation, callback, recycler=None):
    row = connection.execute("SELECT * FROM plans WHERE id=?", (plan_id,)).fetchone()
    if not row or not DIGEST.fullmatch(confirmation or "") or row["digest"] != confirmation or hashlib.sha256(row["body"].encode("utf-8")).hexdigest() != confirmation:
        raise ValueError("Manca la conferma del piano esatto: esegui prima Simula pulizia")
    plan = json.loads(row["body"])
    if plan["source"] != str(source) or plan["target"] != str(target) or plan["delete_mode"] != "recycle_only":
        raise ValueError("Cartelle/piano cambiati: nessuna eliminazione")
    pause = control / "pause.request"
    summary = {"mode": "cleanup-apply", "source": str(source), "target": str(target), "total": len(plan["candidates"]),
               "deleted": 0, "kept": 0, "already_done": 0, "uncertain": 0, "errors": 0, "stopped": False, "ready_for_review": False}
    with ExitStack() as stack:
        bridge = recycler or stack.enter_context(RecycleBridge())
        for done, candidate in enumerate(plan["candidates"], 1):
            if pause.exists():
                summary["stopped"] = True
                break
            relative = candidate["source_relative"]
            recycle_started = False
            try:
                receipt = connection.execute("SELECT * FROM receipts WHERE plan_id=? AND relative=?", (plan_id, relative)).fetchone()
                raw = source / relative
                if receipt and receipt["status"] == "recycled":
                    summary["already_done"] += 1
                    continue  # Even a restored file needs a NEW explicit preview/confirmation.
                if not raw.exists():
                    raise ValueError("Input assente senza ricevuta conclusiva: richiede controllo manuale")
                original = scoped_file(source, relative)
                if fingerprint(original) != candidate["source_signature"]:
                    raise ValueError("Originale cambiato dopo la simulazione: conservato")
                copy = scoped_file(target, candidate["target_relative"])
                if os.path.samefile(original, copy):
                    raise ValueError("Input e target condividono lo stesso file: conservato")
                # The target's handle denies writers AND deletion throughout source recycling.
                with organizer.source_stream(copy, True) as target_stream:
                    copied_hash, copied_signature = target_hash(target, connection, candidate["target_relative"], pause, callback, target_stream)
                    source_hash, source_signature = hash_file(original, pause, callback)
                    if copied_hash != candidate["sha256"] or source_hash != copied_hash or source_signature != candidate["source_signature"]:
                        raise ValueError("Le copie non coincidono piu: originale conservato")
                    intent = {"event": "log", "action": "recycle_intent", "plan_id": plan_id,
                              "source": str(original), "target": str(copy), "sha256": source_hash,
                              "source_signature": source_signature, "target_signature": copied_signature}
                    callback(intent)
                    connection.execute("INSERT OR REPLACE INTO receipts VALUES (?,?,?,?)",
                                       (plan_id, relative, "intent", json.dumps(intent)))
                    connection.commit()
                    recycle_started = True
                    result = bridge.recycle(original, source, source_hash)
                    if original.exists():
                        raise ValueError("Il Cestino non ha rimosso l'originale")
                    completed = {**intent, "action": "recycled", "recycled_at_utc": ai.utc_now(), "receipt": result}
                    callback(completed)
                    connection.execute("UPDATE receipts SET status='recycled',body=? WHERE plan_id=? AND relative=?",
                                       (json.dumps(completed), plan_id, relative))
                    connection.commit()
                    summary["deleted"] += 1
            except organizer.Paused:
                summary["stopped"] = True
                break
            except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
                uncertain = recycle_started and not (source / relative).exists()
                summary["uncertain" if uncertain else "kept"] += 1
                summary["errors"] += 1
                callback({"event": "error", "action": "cleanup_uncertain" if uncertain else "cleanup_refused", "source_relative": relative, "message": str(error)})
                # A helper/receipt failure may be ambiguous: never continue a destructive batch.
                if recycle_started or isinstance(error, (RuntimeError, sqlite3.Error)):
                    summary["stopped"] = True
                    break
            callback({"event": "progress", "phase": "Cestino: copie verificate", "done": done, "total": summary["total"], "filename": relative})
    summary["ready_for_review"] = not summary["errors"] and not summary["stopped"]
    ai.write_json(control / "latest-cleanup-summary.json", summary)
    return summary


# Parameter source: selected input folder.
# Parameter target: selected archive containing copies.
# Parameter mode: explicit index/preview/apply operation, preview by default.
# Parameter limit: maximum originals per explicit confirmation.
# Parameter plan_id: preview ID, only used in apply mode.
# Parameter confirmation: exact preview digest, only used in apply mode.
# Parameter callback: detailed app-local logger/GUI events.
# Parameter recycler: fixture-only alternative, unavailable from the CLI.
# Exceptions: unsafe paths, missing confirmations and index failures abort before deletion.
def run_cleanup(source, target, mode="plan", limit=50, plan_id=None, confirmation=None,
                callback=organizer.emit, recycler=None):
    if not 1 <= limit <= 500:
        raise ValueError("Il limite per conferma deve essere fra 1 e 500 file")
    source, target = validate_paths(source, target)
    actual_callback = callback

    # Parameter event: event that must be persisted before destructive work can continue.
    # Exceptions: Log failures abort the batch, including during hash progress.
    def logged_callback(event):
        try:
            actual_callback(event)
        except OSError as error:
            raise RuntimeError("Registro non scrivibile: pulizia interrotta") from error

    callback = logged_callback
    with index_state(target) as (connection, control):
        pause = control / "pause.request"
        if pause.exists():
            pause.unlink()
        try:
            if mode == "apply":
                summary = apply_plan(source, target, connection, control, plan_id, confirmation, callback, recycler)
            else:
                stats = refresh_index(target, connection, callback, pause)
                if mode == "index":
                    rows = connection.execute("SELECT relative FROM files ORDER BY relative").fetchall()
                    for done, row in enumerate(rows, 1):
                        try:
                            target_hash(target, connection, row[0], pause, callback)
                        except (OSError, ValueError) as error:
                            stats["index_errors"] += 1
                            callback({"event": "log", "action": "index_hash_failed", "target_relative": row[0], "reason": str(error)})
                        callback({"event": "progress", "phase": "indice SHA-256", "done": done, "total": len(rows), "filename": row[0]})
                    summary = {"mode": "cleanup-index", "total": stats["indexed"], "errors": stats["index_errors"], "deleted": 0, **stats}
                else:
                    summary = {**make_plan(source, target, connection, control, limit, callback), **stats}
        except organizer.Paused:
            summary = {"mode": "cleanup-" + mode, "stopped": True, "ready_for_review": False, "deleted": 0, "errors": 0}
        callback({"event": "summary", "summary": summary})
        return summary


# Exceptions: command-line/path/state failures are logged and return a nonzero status.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--index", action="store_true")
    modes.add_argument("--what-if", "--dry-run", action="store_true")
    modes.add_argument("--apply", action="store_true")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--plan-id")
    parser.add_argument("--confirm-plan-hash")
    args = parser.parse_args()
    mode = "apply" if args.apply else "index" if args.index else "plan"
    with JobLog("cleanup", {"source": str(args.source), "target": str(args.target), "mode": mode, "limit": args.limit}) as log:
        log.emit({"event": "log", "message": "Log dettagliato: " + str(log.path), "log_path": str(log.path)})
        result = run_cleanup(args.source, args.target, mode, args.limit, args.plan_id, args.confirm_plan_hash, log.emit)
    return 2 if result.get("errors") or result.get("stopped") else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
        organizer.emit({"event": "error", "message": str(error)})
        raise SystemExit(1)
