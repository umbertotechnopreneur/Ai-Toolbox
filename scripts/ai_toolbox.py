"""Portable, local-only photo catalog enrichment; never move or modify originals."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from contextlib import contextmanager, ExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps, __version__ as pillow_version

from analyze_local import BLOCKED_ATTRIBUTES, LocalReadDenied, guarded_local_stream
from job_log import JobLog

ROOT = Path(__file__).resolve().parent.parent
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".gif", ".ico", ".heic", ".heif", ".avif", ".mpo"}
CATEGORIES = ["photo", "screenshot", "scanned_document", "graphic", "sticker", "unknown"]
SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "category": {"type": "string", "enum": CATEGORIES},
        "description": {"type": "string", "maxLength": 400},
        "tags": {"type": "array", "items": {"type": "string", "maxLength": 60}, "maxItems": 8},
        "contains_visible_text": {"type": "boolean"},
        "text_excerpt": {"type": "string", "maxLength": 0},
        "needs_review": {"type": "boolean"},
        "uncertainty_reasons": {"type": "array", "items": {"type": "string", "maxLength": 160}, "maxItems": 3},
    },
    "required": ["category", "description", "tags", "contains_visible_text", "text_excerpt", "needs_review", "uncertainty_reasons"],
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# Parameter path: generated toolbox artifact, never an original source file.
# Parameter value: JSON-serializable report or cached AI record.
# Exceptions: OSError if the artifact cannot be written atomically.
def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


# Exceptions: OSError, JSONDecodeError or ValueError for missing or invalid configuration.
def configuration() -> dict[str, Any]:
    config = json.loads((ROOT / "config/toolbox.json").read_text(encoding="utf-8-sig"))
    if config["host"] != "127.0.0.1":
        raise ValueError("This toolbox only permits a loopback server")
    return config


# Parameter config: validated loopback server configuration.
# Exceptions: OSError if the portable runtime is not installed.
def engine_path(config: dict[str, Any]) -> Path:
    candidates = list((ROOT / config["engine_directory"]).rglob("llama-server.exe"))
    if len(candidates) != 1:
        raise OSError("Run Setup-Portable.ps1 first; expected one llama-server.exe")
    return candidates[0]


# Parameter config: validated model and inference settings.
# Parameter prompt: the exact catalog instruction text.
# Exceptions: OSError or JSONDecodeError if the pinned download lock is unavailable.
def cache_fingerprint(config: dict[str, Any], prompt: str) -> str:
    lock = json.loads((ROOT / "config/downloads.lock.json").read_text(encoding="utf-8-sig"))
    identity = {
        "schema": SCHEMA, "prompt": prompt, "runtime_release": lock["runtime_release"],
        "model_revision": lock["model_revision"],
        "model_hashes": [item["sha256"] for item in lock["downloads"] if item["destination"].startswith("models/")],
        "max_image_edge": config["max_image_edge"], "max_output_tokens": config["max_output_tokens"],
        "preprocessing_version": 1, "response_format_version": 2,
        "sampling": {"temperature": 0, "seed": 0},
    }
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode("utf-8")).hexdigest()


# Parameter url: an explicitly loopback URL, never a remote service.
# Parameter payload: JSON request body, or None for a health check.
# Parameter timeout: bounded HTTP timeout in seconds.
# Exceptions: ValueError, URLError or JSONDecodeError for invalid/failed local calls.
def local_request(url: str, payload: Any = None, timeout: int = 10) -> Any:
    address = urllib.parse.urlsplit(url)
    if (address.scheme != "http" or address.hostname != "127.0.0.1" or address.port is None
            or address.username is not None or address.password is not None):
        raise ValueError("Remote inference is disabled")
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    # Ignore proxy variables so even loopback photo data cannot be sent through a proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=timeout) as response:
        return json.load(response)


# Parameter config: requested backend policy and portable inference settings.
# Exceptions: Unrelated occupied ports abort; startup failures may fall back only in auto mode.
@contextmanager
def running_server(config: dict[str, Any]):
    with socket.socket() as probe:
        if probe.connect_ex((config["host"], config["port"])) == 0:
            raise RuntimeError("Port is already in use; refusing to attach to or stop an unrelated server")
    policy = config.get("engine_backend", "cuda").lower()
    if policy not in {"auto", "cuda", "vulkan", "cpu"}:
        raise ValueError("Invalid AI backend; choose auto, cuda, vulkan or cpu")
    choices = ["cuda", "vulkan", "cpu"] if policy == "auto" else [policy]
    failures = []
    with ExitStack() as lifetime:
        dispatch_log = lifetime.enter_context(JobLog("backend", {"policy": policy}, root=ROOT))
        endpoint = None
        for backend in choices:
            settings = {**config, **config.get("backends", {}).get(backend, {})}
            settings["resolved_backend"] = backend
            settings.setdefault("gpu_layers", 0 if backend == "cpu" else 999)
            try:
                binary = engine_path(settings)
                # Avoid treating a GPU build silently running on CPU as GPU acceleration.
                if policy == "auto" and backend != "cpu":
                    for directory in (ROOT / "temp", ROOT / "cache"):
                        directory.mkdir(exist_ok=True)
                    probe_environment = {**os.environ, "TEMP": str(ROOT / "temp"), "TMP": str(ROOT / "temp"),
                                         "CUDA_CACHE_PATH": str(ROOT / "cache/cuda")}
                    probe = subprocess.run([str(binary), "--list-devices"], capture_output=True, text=True,
                                           encoding="utf-8", errors="replace", timeout=20,
                                           env=probe_environment, creationflags=subprocess.CREATE_NO_WINDOW)
                    devices = (probe.stdout or "") + (probe.stderr or "")
                    dispatch_log.write({"event": "device_probe", "backend": backend, "exit_code": probe.returncode, "output": devices})
                    if probe.returncode or not any(line.strip().startswith(backend.capitalize() if backend == "vulkan" else "CUDA")
                                                   for line in devices.splitlines()):
                        raise RuntimeError(f"No usable {backend} device reported")
                endpoint = lifetime.enter_context(single_backend_server(settings))
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                failures.append(f"{backend}: {error}")
                dispatch_log.write({"event": "startup_failed", "backend": backend, "error": str(error)})
                if policy != "auto":
                    raise
                continue
            config["resolved_backend"] = backend
            dispatch_log.write({"event": "backend_selected", "backend": backend})
            break
        if endpoint is None:
            raise RuntimeError("No backend could start. Run portable setup. " + "; ".join(failures))
        # Inference exceptions must propagate, never replay a partly completed batch.
        yield endpoint


# Parameter config: one resolved backend, with bounded single-slot inference settings.
# Exceptions: OSError or RuntimeError if startup fails; the owned child is always stopped.
@contextmanager
def single_backend_server(config: dict[str, Any]):
    with socket.socket() as probe:
        if probe.connect_ex((config["host"], config["port"])) == 0:
            raise RuntimeError("Port is already in use; refusing to attach to or stop an unrelated server")
    binary = engine_path(config)
    for key in ("model_path", "projector_path"):
        if not (ROOT / config[key]).is_file():
            raise OSError("Model download is incomplete; run Setup-Portable.ps1")
    for folder in ("logs", "temp", "cache"):
        (ROOT / folder).mkdir(exist_ok=True)
    child_environment = os.environ.copy()
    child_environment.update({
        "TEMP": str(ROOT / "temp"), "TMP": str(ROOT / "temp"),
        "HF_HOME": str(ROOT / "cache/huggingface"), "LLAMA_CACHE": str(ROOT / "cache/llama"),
        "CUDA_CACHE_PATH": str(ROOT / "cache/cuda"), "HF_HUB_OFFLINE": "1",
    })
    arguments = [
        str(binary), "--model", str(ROOT / config["model_path"]),
        "--mmproj", str(ROOT / config["projector_path"]), "--alias", config["model_alias"],
        "--host", config["host"], "--port", str(config["port"]),
        "--ctx-size", str(config["context_tokens"]), "--parallel", "1",
        "--n-gpu-layers", str(config.get("gpu_layers", 999)), "--batch-size", "256", "--ubatch-size", "128",
        "--flash-attn", "on" if config.get("resolved_backend", "cuda") == "cuda" else "auto",
        "--cache-type-k", "q8_0" if config.get("resolved_backend", "cuda") == "cuda" else "f16",
        "--cache-type-v", "q8_0" if config.get("resolved_backend", "cuda") == "cuda" else "f16",
        "--jinja", "--offline",
    ]
    log_path = ROOT / ("logs/server-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") +
                       "-" + config.get("resolved_backend", "cuda") + ".log")
    with log_path.open("x", encoding="utf-8") as log:
        process = subprocess.Popen(arguments, cwd=binary.parent, env=child_environment,
                                   stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            deadline = time.monotonic() + config["startup_timeout_seconds"]
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Engine exited with {process.returncode}; inspect {log_path}")
                healthy = False
                try:
                    healthy = local_request(f"http://127.0.0.1:{config['port']}/health", timeout=2).get("status") == "ok"
                except (urllib.error.URLError, TimeoutError, ConnectionError):
                    pass
                # Exceptions in the caller's batch must not be treated as health-check failures.
                if healthy:
                    yield f"http://127.0.0.1:{config['port']}"
                    return
                time.sleep(0.5)
            raise RuntimeError(f"Engine startup timed out; inspect {log_path}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


# Parameter value: decoded model JSON, checked independently of grammar constraints.
# Exceptions: ValueError if the model omitted fields or returned invalid values.
def validate_result(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != set(SCHEMA["required"]):
        raise ValueError("AI output does not match the required fields")
    if value["category"] not in CATEGORIES:
        raise ValueError("Unknown AI category")
    for key, maximum in (("description", 400), ("text_excerpt", 0)):
        if not isinstance(value[key], str) or len(value[key]) > maximum:
            raise ValueError(f"Invalid {key}")
    for key in ("contains_visible_text", "needs_review"):
        if not isinstance(value[key], bool):
            raise ValueError(f"Invalid {key}")
    for key, count, length in (("tags", 8, 60), ("uncertainty_reasons", 3, 160)):
        if not isinstance(value[key], list) or len(value[key]) > count:
            raise ValueError(f"Invalid {key}")
        if any(not isinstance(item, str) or len(item) > length for item in value[key]):
            raise ValueError(f"Invalid entries in {key}")
    return value


# Parameter record: technical metadata from the frozen, previously local manifest.
# Parameter maximum_edge: pixel limit for the in-memory preview, not the original.
# Exceptions: LocalReadDenied, OSError or ValueError for unsafe, stale or unreadable files.
def preview(record: dict[str, Any], maximum_edge: int) -> tuple[str, dict[str, Any]]:
    path = Path(record["original_path"])
    with guarded_local_stream(path) as (stream, guard):
        before = path.stat()
        fingerprint = [before.st_size, before.st_mtime_ns]
        if fingerprint != record.get("analysis_fingerprint"):
            raise ValueError("Original changed since technical analysis; refresh its metadata first")
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != record["sha256"]:
            raise ValueError("Content SHA-256 differs from the frozen inventory")
        stream.seek(0)
        with Image.open(stream) as source:
            frame_count = getattr(source, "n_frames", 1)
            source.seek(0)
            # JPEG draft avoids decoding full camera resolution when supported.
            source.draft("RGB", (maximum_edge, maximum_edge))
            image = ImageOps.exif_transpose(source)
            image.thumbnail((maximum_edge, maximum_edge), Image.Resampling.LANCZOS)
            if image.mode in ("RGBA", "LA") or "transparency" in image.info:
                rgba = image.convert("RGBA")
                background = Image.new("RGB", rgba.size, "white")
                background.paste(rgba, mask=rgba.getchannel("A"))
                image = background
            else:
                image = image.convert("RGB")
            encoded = io.BytesIO()
            image.save(encoded, format="JPEG", quality=85)
            info = {"width": image.width, "height": image.height, "frames_in_original": frame_count,
                    "frame_analyzed": 0, "locality_guard": guard}
        after = path.stat()
        if [after.st_size, after.st_mtime_ns] != fingerprint:
            raise ValueError("Original changed during preview generation")
    return "data:image/jpeg;base64," + base64.b64encode(encoded.getvalue()).decode("ascii"), info


# Parameter endpoint: exclusively local running engine URL.
# Parameter image_url: in-memory JPEG data URI, without original paths or metadata.
# Parameter config: generation limits and model alias.
# Parameter prompt: current visual classification instructions.
# Exceptions: ValueError or local HTTP errors if inference/validation fails.
def infer(endpoint: str, image_url: str, config: dict[str, Any], prompt: str) -> dict[str, Any]:
    payload = {
        "model": config["model_alias"], "temperature": 0, "seed": 0,
        "max_tokens": config["max_output_tokens"], "stream": False,
        "chat_template_kwargs": {"enable_thinking": False},
        "response_format": {"type": "json_schema", "json_schema": {
            "name": "photo_catalog", "schema": SCHEMA, "strict": True,
        }},
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": image_url}},
                {"type": "text", "text": "Catalog this image."},
            ]},
        ],
    }
    response = local_request(endpoint + "/v1/chat/completions", payload, config["request_timeout_seconds"])
    choice = response["choices"][0]
    if choice.get("finish_reason") == "length":
        raise ValueError("AI output was truncated; no successful result was cached")
    result = validate_result(json.loads(choice["message"]["content"]))
    return {**result, "usage": response.get("usage", {}), "engine_timings": response.get("timings", {})}


# Parameter args: bounded manifest selection and explicit inference opt-in.
# Parameter config: portable model configuration.
# Exceptions: invalid manifests or report failures abort; individual image failures are reported.
def catalog(args: argparse.Namespace, config: dict[str, Any]) -> int:
    manifest = args.manifest or ROOT / config["default_manifest"]
    records = [json.loads(line) for line in manifest.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    candidates = [item for item in records if item.get("analysis_status") == "analyzed"
                  and item.get("size_bytes", 0) > 0 and item.get("sha256")
                  and item.get("extension_normalized", "").lower() in IMAGE_EXTENSIONS
                  and not item.get("probably_online_only")
                  and not item.get("windows_file_attributes", 0) & BLOCKED_ATTRIBUTES]
    if args.category:
        candidates = [item for item in candidates if item.get("category") == args.category]
    selected = candidates if args.all else candidates[:args.limit]
    output = (ROOT / "output/catalog").resolve()
    if any(output.is_relative_to(Path(item["original_root"]).resolve()) for item in selected):
        raise ValueError("Output must be outside every original source folder")
    if not args.run:
        print(json.dumps({"mode": "what-if", "eligible": len(candidates), "selected": len(selected),
                          "source_content_opened": False, "inference_started": False,
                          "output": str(output)}, indent=2))
        return 0

    prompt = (ROOT / "config/catalog-prompt.txt").read_text(encoding="utf-8")
    identity = cache_fingerprint(config, prompt)
    cache_folder = ROOT / "cache/catalog" / identity
    completed = []
    pending = []
    elapsed_samples = []
    summary = {"mode": "local-ai-analysis", "started_at_utc": utc_now(), "selected": len(selected),
               "inferred": 0, "cache_hits": 0, "skipped": 0, "errors": 0,
               "config_fingerprint": identity, "originals_modified": False, "hydration_requested": False}
    for record in selected:
        path = Path(record["original_path"])
        cached_path = cache_folder / (record["sha256"] + ".json")
        try:
            stat = path.lstat()
            if int(getattr(stat, "st_file_attributes", 0)) & BLOCKED_ATTRIBUTES:
                raise LocalReadDenied("Source is no longer fully local")
            if [stat.st_size, stat.st_mtime_ns] != record.get("analysis_fingerprint"):
                raise ValueError("Source metadata changed; refresh the technical inventory")
            if cached_path.exists():
                cached = json.loads(cached_path.read_text(encoding="utf-8"))
                enriched = {**record, "ai": cached}
                completed.append(enriched)
                occurrence = record.get("occurrence_id") or hashlib.sha256(record["original_path"].encode()).hexdigest()[:16]
                write_json(output / "records" / (occurrence + ".json"), enriched)
                summary["cache_hits"] += 1
            else:
                pending.append(record)
        except (OSError, ValueError) as error:
            completed.append({**record, "ai": {"status": "skipped", "reason": str(error)}})
            summary["skipped"] += 1

    try:
        if pending:
            with running_server(config) as endpoint:
                for index, record in enumerate(pending, 1):
                    started = time.monotonic()
                    try:
                        cached_path = cache_folder / (record["sha256"] + ".json")
                        if cached_path.exists():
                            # Earlier occurrences in this same batch may have populated the cache.
                            ai = json.loads(cached_path.read_text(encoding="utf-8"))
                            summary["cache_hits"] += 1
                        else:
                            image_url, image_info = preview(record, config["max_image_edge"])
                            result = infer(endpoint, image_url, config, prompt)
                            if image_info["frames_in_original"] > 1:
                                result["needs_review"] = True
                                result["uncertainty_reasons"] = (result["uncertainty_reasons"] + ["Only the first frame was analyzed"])[:3]
                            ai = {"status": "analyzed", **result, "model": "Qwen3-VL-4B-Instruct-Q4_K_M",
                                  "inference_backend": config.get("resolved_backend", "cuda"),
                                  "config_fingerprint": identity, "analyzed_at_utc": utc_now(),
                                  "asset_sha256": record["sha256"], "input_preview": image_info,
                                  "elapsed_seconds": round(time.monotonic() - started, 3),
                                  "review_status": "unreviewed"}
                            write_json(cached_path, ai)
                            elapsed_samples.append(ai["elapsed_seconds"])
                            summary["inferred"] += 1
                    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
                        ai = {"status": "error", "reason": str(error), "analyzed_at_utc": utc_now()}
                        summary["errors"] += 1
                    enriched = {**record, "ai": ai}
                    completed.append(enriched)
                    # Per-occurrence records and per-content cache survive an interrupted batch.
                    occurrence = record.get("occurrence_id") or hashlib.sha256(record["original_path"].encode()).hexdigest()[:16]
                    write_json(output / "records" / (occurrence + ".json"), enriched)
                    print(f"Catalog {index}/{len(pending)}; inferred {summary['inferred']}; errors {summary['errors']}", flush=True)
    finally:
        summary["finished_at_utc"] = utc_now()
        summary["median_seconds_per_new_image"] = round(statistics.median(elapsed_samples), 3) if elapsed_samples else None
        summary["ai_categories"] = dict(Counter(item["ai"].get("category", item["ai"].get("status")) for item in completed))
        output.mkdir(parents=True, exist_ok=True)
        temporary = output / "latest-manifest.jsonl.tmp"
        with temporary.open("w", encoding="utf-8") as stream:
            for record in completed:
                stream.write(json.dumps(record, ensure_ascii=False) + "\n")
        temporary.replace(output / "latest-manifest.jsonl")
        write_json(output / "latest-summary.json", summary)
    print(json.dumps(summary, indent=2))
    return 1 if summary["errors"] else 0


# Exceptions: configuration, server or report errors result in a nonzero process exit.
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="Check portable Python, models and installed inference backends")
    commands.add_parser("serve", help="Run the local web UI until Ctrl+C; no automatic startup")
    catalog_parser = commands.add_parser("catalog", help="Plan by default; --run performs local AI analysis")
    catalog_parser.add_argument("--manifest", type=Path)
    catalog_parser.add_argument("--limit", type=int, default=25)
    catalog_parser.add_argument("--all", action="store_true")
    catalog_parser.add_argument("--category", help="Filter technical category, e.g. png_review or photo")
    modes = catalog_parser.add_mutually_exclusive_group()
    modes.add_argument("--run", action="store_true")
    modes.add_argument("--what-if", "--dry-run", action="store_true")
    args = parser.parse_args()
    if getattr(args, "limit", 1) <= 0:
        parser.error("--limit must be positive")
    config = configuration()
    if args.command == "doctor":
        print(json.dumps({"root": str(ROOT), "python": sys.version, "python_executable": sys.executable,
                          "pillow": pillow_version, "models_present": all((ROOT / config[key]).is_file() for key in ("model_path", "projector_path")),
                          "loopback_url": f"http://127.0.0.1:{config['port']}"}, indent=2))
        policy = config.get("engine_backend", "cuda").lower()
        backends = ["cuda", "vulkan", "cpu"] if policy == "auto" else [policy]
        available = 0
        for backend in backends:
            try:
                binary = engine_path({**config, **config.get("backends", {}).get(backend, {})})
            except OSError:
                print(f"{backend}: not installed; run portable setup")
                continue
            print(f"{backend}: {binary}", flush=True)
            environment = {**os.environ, "TEMP": str(ROOT / "temp"), "TMP": str(ROOT / "temp"),
                           "CUDA_CACHE_PATH": str(ROOT / "cache/cuda")}
            result = subprocess.run([str(binary), "--list-devices"], cwd=binary.parent, env=environment,
                                    timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
            available += result.returncode == 0
        return 0 if available else 1
    if args.command == "serve":
        with running_server(config) as endpoint:
            print(f"Local UI: {endpoint}; Ctrl+C stops the owned engine and frees VRAM.", flush=True)
            while True:
                time.sleep(0.5)
    return catalog(args, config)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Stopped. Completed AI records are cached; originals remain untouched.")
        raise SystemExit(130)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Toolbox error: {error}", file=sys.stderr)
        raise SystemExit(1)
