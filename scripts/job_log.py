"""Durable, toolbox-local operation logs, independent of media folder choices."""

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class JobLog:
    # Parameter self: this owned job log.
    # Parameter operation: trusted operation name, not a user filename.
    # Parameter context: source, target and mode information, never media contents.
    # Parameter root: optional isolated log root for regression tests.
    def __init__(self, operation, context, root=None):
        self.operation = operation
        self.context = context
        folder = (root or ROOT) / "logs/photo-organizer"
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.path = folder / f"{stamp}-{operation}-{uuid.uuid4().hex[:12]}.jsonl"
        self.stream = None

    # Parameter self: this owned job log.
    # Exceptions: OSError prevents starting a job without an available log.
    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("x", encoding="utf-8")
        self.write({"event": "session_start", "operation": self.operation, "context": self.context})
        return self

    # Parameter self: this open job log.
    # Parameter event: structured progress, checksum, intent or receipt.
    # Exceptions: OSError aborts rather than silently dropping an operation record.
    def write(self, event):
        record = {"logged_at_utc": datetime.now(timezone.utc).isoformat(), "pid": os.getpid(), **event}
        self.stream.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        self.stream.flush()
        if event.get("action") in {"recycle_intent", "recycled"}:
            os.fsync(self.stream.fileno())

    # Parameter self: this open job log.
    # Parameter event: event first persisted, then sent to the GUI/console.
    # Exceptions: OSError on log/console failure.
    def emit(self, event):
        self.write(event)
        print(json.dumps(event, ensure_ascii=False, default=str), flush=True)

    # Parameter self: this owned job log.
    # Parameter error_type: exception type, or None after successful completion.
    # Parameter error: optional failure, recorded without binary media content.
    # Parameter traceback: unused Python traceback provided by the context protocol.
    # Exceptions: OSError if final log persistence fails.
    def __exit__(self, error_type, error, traceback):
        try:
            self.write({"event": "session_end", "status": "failed" if error else "finished",
                        "error_type": error_type.__name__ if error_type else None,
                        "error": str(error) if error else None})
        finally:
            self.stream.close()
