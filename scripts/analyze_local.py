"""Inspect a frozen local-file inventory; never move files or request hydration."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
import subprocess
import time
from collections import Counter, defaultdict
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, BinaryIO, Iterator
from ctypes import wintypes

from PIL import ExifTags, Image

import photo_organizer as organizer

ANALYSIS_VERSION = 2
BLOCKED_ATTRIBUTES = organizer.ONLINE_ONLY_ATTRIBUTE_MASK
FILE_ATTRIBUTE_REPARSE_POINT = 0x400
SCRIPT_ROOT = Path(__file__).absolute().parent


class LocalReadDenied(OSError):
    """A content read was refused because locality could not be established."""


class PlaceholderInfo(ctypes.Structure):
    _fields_ = [
        ("on_disk", ctypes.c_longlong),
        ("validated", ctypes.c_longlong),
        ("modified", ctypes.c_longlong),
        ("properties", ctypes.c_longlong),
        ("pin_state", wintypes.DWORD),
        ("in_sync", wintypes.DWORD),
        ("file_id", ctypes.c_longlong),
        ("root_id", ctypes.c_longlong),
        ("identity_length", wintypes.DWORD),
        ("identity", ctypes.c_byte * 4096),
    ]


# Exceptions: Windows-only initialization can raise OSError if required APIs are absent.
def windows_apis() -> tuple[Any, Any]:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    cloud = ctypes.WinDLL("cldapi", use_last_error=True)
    kernel.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    cloud.CfGetPlaceholderInfo.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    ]
    cloud.CfGetPlaceholderInfo.restype = ctypes.c_long
    return kernel, cloud


# Parameter path: original local file to inspect without reading its data.
# Parameter handle: metadata or read handle for the same file.
# Parameter cloud: configured Cloud Files API library.
# Exceptions: LocalReadDenied if a placeholder is incomplete or cannot be queried.
def verify_placeholder(path: Path, handle: Any, cloud: Any) -> dict[str, Any]:
    stat = path.lstat()
    attributes = int(getattr(stat, "st_file_attributes", 0))
    if attributes & BLOCKED_ATTRIBUTES:
        raise LocalReadDenied("offline_or_recall_attributes")
    result = {"attributes": attributes, "size_bytes": stat.st_size}
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT:
        info = PlaceholderInfo()
        returned = wintypes.DWORD()
        status = cloud.CfGetPlaceholderInfo(
            handle, 1, ctypes.byref(info), ctypes.sizeof(info), ctypes.byref(returned)
        )
        if status != 0:
            raise LocalReadDenied(f"placeholder_state_unverified: HRESULT=0x{status & 0xffffffff:08x}")
        result["on_disk_data_bytes"] = info.on_disk
        if info.on_disk < stat.st_size:
            raise LocalReadDenied("placeholder_content_not_fully_local")
    result["verified_at_utc"] = organizer.utc_now()
    return result


# Parameter path: source file; metadata is checked before granting read access.
# Exceptions: LocalReadDenied or OSError when locality/opening cannot be established.
@contextmanager
def guarded_local_stream(path: Path) -> Iterator[tuple[BinaryIO, dict[str, Any]]]:
    if os.name != "nt":
        raise LocalReadDenied("This locality guard requires Windows Cloud Files APIs")
    if int(getattr(path.lstat(), "st_file_attributes", 0)) & BLOCKED_ATTRIBUTES:
        raise LocalReadDenied("offline_or_recall_attributes")

    kernel, cloud = windows_apis()
    extended_path = "\\\\?\\" + str(path.absolute())
    invalid_handle = ctypes.c_void_p(-1).value
    # Attribute-only access to the reparse point does not request file contents.
    metadata_handle = kernel.CreateFileW(extended_path, 0x80, 7, None, 3, 0x00200000, None)
    if metadata_handle == invalid_handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        verify_placeholder(path, metadata_handle, cloud)
    finally:
        kernel.CloseHandle(metadata_handle)

    # Keep a read-share-only handle during inspection to exclude writes/renames.
    # OPEN_NO_RECALL is additional defense; the verified Cloud Files state is primary.
    read_handle = kernel.CreateFileW(extended_path, 0x80000000, 1, None, 3, 0x00100000, None)
    if read_handle == invalid_handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        guard = verify_placeholder(path, read_handle, cloud)
        import msvcrt

        descriptor = msvcrt.open_osfhandle(read_handle, os.O_RDONLY | os.O_BINARY)
        read_handle = None  # The descriptor now owns the handle.
        with os.fdopen(descriptor, "rb") as stream:
            yield stream, guard
    finally:
        if read_handle is not None:
            kernel.CloseHandle(read_handle)


# Parameter value: metadata value to represent in JSON without including binary blobs.
def json_metadata(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, bytes):
        return {"binary_bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}
    if isinstance(value, dict):
        return {str(key): json_metadata(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_metadata(item) for item in value]
    return str(value)


# Parameter stream: already verified local input stream, shared with hashing.
# Exceptions: image parsing errors are captured in the result, not propagated.
def image_metadata(stream: BinaryIO) -> dict[str, Any]:
    result: dict[str, Any] = {"metadata_mode": "deep"}
    try:
        stream.seek(0)
        with Image.open(stream) as image:
            result.update({
                "format": image.format, "width": image.width, "height": image.height,
                "mode": image.mode, "frames": getattr(image, "n_frames", 1),
                "animated": bool(getattr(image, "is_animated", False)),
            })
            exif = image.getexif()
            exif_ifd = exif.get_ifd(34665) if 34665 in exif else {}
            # Original capture timestamps usually live in this nested EXIF IFD.
            all_tags = {**dict(exif), **exif_ifd}
            date_tags = {
                306: "DateTime", 36867: "DateTimeOriginal", 36868: "DateTimeDigitized",
                36880: "OffsetTime", 36881: "OffsetTimeOriginal", 36882: "OffsetTimeDigitized",
                37520: "SubsecTime", 37521: "SubsecTimeOriginal", 37522: "SubsecTimeDigitized",
            }
            result["exif_dates"] = {
                name: organizer._text_value(all_tags[tag])
                for tag, name in date_tags.items() if tag in all_tags
            }
            result["exif_tags"] = {
                ExifTags.TAGS.get(tag, str(tag)): json_metadata(value)
                for tag, value in all_tags.items() if tag not in {34853, 34665, 37500}
            }
            result["gps_present"] = bool(exif.get(34853))
            result["maker_notes_present"] = 37500 in all_tags
            result["metadata_keys"] = sorted(str(key) for key in image.info)
            result["text_metadata"] = {
                str(key): value for key, value in image.info.items() if isinstance(value, str)
            }
            # Reopen on the same guarded stream because EXIF access can move the decoder cursor.
            if image.format == "PNG":
                result["container_verified"] = "pending"
            else:
                result["container_verified"] = None
        if result.get("format") == "PNG":
            stream.seek(0)
            with Image.open(stream) as verification_image:
                verification_image.verify()
            result["container_verified"] = True
    except Exception as error:
        result["read_error"] = f"{type(error).__name__}: {error}"
    return result


# Parameter path: original path, held open with the locality guard during probing.
# Exceptions: ffprobe failures and timeouts are returned as metadata errors.
def video_metadata(path: Path) -> dict[str, Any]:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {"read_error": "ffprobe_not_available"}
    try:
        completed = subprocess.run(
            [ffprobe, "-v", "error", "-protocol_whitelist", "file", "-probesize", "1000000",
             "-analyzeduration", "1000000", "-show_format", "-show_streams", "-of", "json", str(path)],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        if completed.returncode:
            return {"read_error": completed.stderr.strip()[:1000] or "ffprobe_failed"}
        result = json.loads(completed.stdout)
        result.get("format", {}).pop("filename", None)
        return result
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"read_error": f"{type(error).__name__}: {error}"}


# Parameter record: file record to enrich with raw candidates and date conflict flags.
def enrich_dates(record: dict[str, Any]) -> None:
    candidates: list[dict[str, Any]] = []
    dates = record["image_metadata"].get("exif_dates", {})
    for name, rank in (("DateTimeOriginal", 100), ("DateTimeDigitized", 90), ("DateTime", 55)):
        parsed, precision = organizer.parse_datetime_text(dates.get(name))
        if parsed:
            candidates.append({"value": parsed, "precision": precision, "source": f"exif_{name}", "rank": rank})
    for key, value in record["image_metadata"].get("text_metadata", {}).items():
        if key.casefold() not in {"creation time", "creation_time", "date:create", "date:modify"}:
            continue
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00")).isoformat()
        except ValueError:
            parsed, _ = organizer.parse_datetime_text(value)
        if parsed:
            candidates.append({"value": parsed, "precision": "second", "source": f"png_{key}", "rank": 70})
    media = record.get("video_metadata", {})
    tag_sources = [media.get("format", {}).get("tags", {})]
    tag_sources.extend(stream.get("tags", {}) for stream in media.get("streams", []))
    for tags in tag_sources:
        value = tags.get("creation_time") or tags.get("com.apple.quicktime.creationdate")
        if not value:
            continue
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00")).isoformat()
        except ValueError:
            continue
        candidates.append({"value": parsed, "precision": "second", "source": "video_creation_time", "rank": 75})
    for date_function, argument in (
        (organizer.parse_filename_datetime, record["original_filename"]),
        (organizer.date_from_relative_path, Path(record["original_relative_path"])),
    ):
        parsed, precision, source = date_function(argument)
        if parsed:
            candidates.append({"value": parsed, "precision": precision, "source": source,
                               "rank": 45 if source == "filename" else 20})
    candidates.sort(key=lambda candidate: candidate["rank"], reverse=True)
    issues = []
    today = datetime.now().date()
    valid_candidates = []
    for candidate in candidates:
        capture_date = datetime.fromisoformat(candidate["value"]).date()
        if capture_date > today:
            issues.append("future_date_candidate")
            continue
        if capture_date.year < 1990:
            issues.append("implausibly_old_digital_capture_date")
            continue
        valid_candidates.append(candidate)
    if valid_candidates:
        chosen = valid_candidates[0]
        record["capture_datetime"] = chosen["value"]
        record["capture_precision"] = chosen["precision"]
        record["capture_date_source"] = chosen["source"]
        record["capture_date_confidence"] = chosen["rank"] / 100
        record["capture_timezone"] = dates.get("OffsetTimeOriginal") if chosen["source"] == "exif_DateTimeOriginal" else None
        if record["capture_timezone"] is None:
            record["capture_timezone"] = "embedded" if datetime.fromisoformat(chosen["value"]).tzinfo else "unknown"
        if any(abs((datetime.fromisoformat(candidate["value"]).date() - datetime.fromisoformat(chosen["value"]).date()).days) > 1
               for candidate in valid_candidates if candidate["source"] == "filename"):
            issues.append("embedded_date_vs_filename_conflict")
    else:
        record.update(capture_datetime=None, capture_precision=None, capture_date_source=None, capture_date_confidence=0)
        issues.append("no_capture_date")
    record["capture_date_candidates"] = candidates
    record["date_issues"] = sorted(set(issues))


# Parameter baseline: one file from the previously saved local-only inventory.
# Exceptions: file access and locality failures are recorded per file.
def inspect_file(baseline: dict[str, Any]) -> dict[str, Any]:
    path = Path(baseline["original_path"])
    record = dict(baseline)
    record.update(analysis_version=ANALYSIS_VERSION, analyzed_at_utc=organizer.utc_now())
    try:
        before = path.stat()
        record["analysis_fingerprint"] = [before.st_size, before.st_mtime_ns]
        with guarded_local_stream(path) as (stream, guard):
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            record["sha256"] = digest.hexdigest()
            record["locality_guard"] = guard
            record["size_bytes"] = before.st_size
            record["image_metadata"] = image_metadata(stream) if path.suffix.casefold() in organizer.IMAGE_EXTENSIONS else {}
            if path.suffix.casefold() in organizer.VIDEO_EXTENSIONS | organizer.AUDIO_EXTENSIONS:
                record["video_metadata"] = video_metadata(path)
            after = path.stat()
            if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
                raise OSError("source_changed_during_analysis")
        record["asset_id"] = f"sha256:{record['sha256']}"
        # Content identity does not replace path identity: distinct originals remain distinct occurrences.
        record["occurrence_id"] = organizer.stable_path_token(path)
        enrich_dates(record)
        animated = record["image_metadata"].get("animated")
        if path.suffix.casefold() == ".webp" and animated is False:
            record["category"] = "sticker" if "sticker" in str(path).casefold() else "graphic_review"
        if before.st_size == 0 or record["image_metadata"].get("read_error"):
            record["review_required"] = True
        record["analysis_status"] = "analyzed"
        record["status"] = "planned"
    except LocalReadDenied as error:
        record["analysis_status"] = "skipped_not_local"
        record["analysis_error"] = str(error)
    except (OSError, ValueError) as error:
        record["analysis_status"] = "error"
        record["analysis_error"] = f"{type(error).__name__}: {error}"
    return record


# Parameter records: completed and skipped deep-analysis records.
# Parameter output: dedicated output folder separate from all originals.
# Exceptions: OSError when reports cannot be saved.
def save_reports(records: list[dict[str, Any]], output: Path) -> dict[str, Any]:
    analyzed = [record for record in records if record.get("analysis_status") == "analyzed"]
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in analyzed:
        if record.get("sha256") and record["size_bytes"] > 0:
            groups[record["sha256"]].append(record)
    duplicate_groups = [
        {"sha256": digest, "size_bytes": group[0]["size_bytes"], "copies": len(group),
         "paths": [record["original_path"] for record in group]}
        for digest, group in groups.items() if len(group) > 1
    ]
    pngs = [record for record in analyzed if record["extension_normalized"] == ".png"]
    summary = {
        "schema_version": 1, "analysis_version": ANALYSIS_VERSION,
        "generated_at_utc": organizer.utc_now(), "mode": "dry-run", "local_only": True,
        "candidate_files": len(records), "analyzed_files": len(analyzed),
        "status_counts": dict(Counter(record["analysis_status"] for record in records)),
        "analyzed_bytes": sum(record["size_bytes"] for record in analyzed),
        "categories": dict(Counter(record["category"] for record in analyzed)),
        "by_source": dict(Counter(record["source_label"] for record in analyzed)),
        "date_sources": dict(Counter(record.get("capture_date_source") or "none" for record in analyzed)),
        "date_issues": dict(Counter(issue for record in analyzed for issue in record.get("date_issues", []))),
        "image_read_errors": sum(bool(record["image_metadata"].get("read_error")) for record in analyzed),
        "video_read_errors": sum(bool(record.get("video_metadata", {}).get("read_error")) for record in analyzed),
        "zero_byte_files": sum(record["size_bytes"] == 0 for record in analyzed),
        "png_files": len(pngs), "png_categories": dict(Counter(record["category"] for record in pngs)),
        "png_embedded_dates": sum(any(candidate["source"].startswith(("exif_", "png_"))
                                     for candidate in record.get("capture_date_candidates", [])) for record in pngs),
        "exact_duplicate_groups": len(duplicate_groups),
        "extra_identical_copies": sum(group["copies"] - 1 for group in duplicate_groups),
        "potential_duplicate_bytes": sum(group["size_bytes"] * (group["copies"] - 1) for group in duplicate_groups),
        "notes": ["Candidates are frozen to the previous local-only inventory.",
                  "Cloud Files on-disk sizes were checked before reads. No hydration requests were made.",
                  "Capture dates are candidates, not proof; EXIF timezone remains unknown if absent.",
                  "SHA-256 groups prove byte identity, not visual similarity. No files were moved or deleted.",
                  "GPS presence is recorded; coordinates and maker-note blobs are omitted."],
    }
    organizer.write_jsonl(output / "latest-manifest.jsonl", records)
    organizer.write_csv(output / "latest-plan.csv", records)
    organizer.write_json(output / "latest-summary.json", summary)
    organizer.write_json(output / "exact-duplicates.json", duplicate_groups)
    organizer.write_jsonl(output / "png-review.jsonl", pngs)
    return summary


# Exceptions: argument validation and report failures terminate with a non-zero exit.
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-manifest", type=Path, default=SCRIPT_ROOT / "output/local-only/latest-manifest.jsonl")
    parser.add_argument("--report-dir", type=Path, default=SCRIPT_ROOT / "output/local-deep")
    parser.add_argument("--destination", type=Path, default=SCRIPT_ROOT.parent / "output/archive-review")
    parser.add_argument("--dry-run", "--what-if", action="store_true", help="Analysis always leaves originals in place")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    baseline = [json.loads(line) for line in args.input_manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    if args.limit:
        baseline = baseline[:args.limit]
    for record in baseline:
        if record.get("probably_online_only") or record.get("windows_file_attributes", 0) & BLOCKED_ATTRIBUTES:
            parser.error("The input must be a saved local-only inventory")
        if organizer.path_is_within(args.report_dir, Path(record["original_root"])):
            parser.error("Reports must be outside the original source folders")
    args.report_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = args.report_dir / "analysis-journal.jsonl"
    previous = {}
    if checkpoint.exists():
        for line in checkpoint.read_text(encoding="utf-8").splitlines():
            try:
                record = json.loads(line)
                previous[record["original_path"]] = record
            except (ValueError, KeyError):
                continue
    records = []
    started = time.monotonic()
    reused = 0
    with checkpoint.open("a", encoding="utf-8", newline="\n") as journal:
        try:
            for index, source in enumerate(baseline, 1):
                cached = previous.get(source["original_path"], {})
                try:
                    stat = Path(source["original_path"]).stat()
                    fingerprint = [stat.st_size, stat.st_mtime_ns]
                except OSError:
                    fingerprint = None
                if (cached.get("analysis_status") == "analyzed" and cached.get("analysis_version") == ANALYSIS_VERSION
                        and cached.get("analysis_fingerprint") == fingerprint):
                    record = cached
                    reused += 1
                else:
                    record = inspect_file(source)
                    if record.get("analysis_status") == "analyzed":
                        record["planned_path"] = str(organizer.planned_destination(record, args.destination, True))
                        record["planned_sidecar_path"] = record["planned_path"] + ".meta.json"
                    journal.write(json.dumps(record, ensure_ascii=False) + "\n")
                    journal.flush()
                records.append(record)
                if index % 100 == 0 or index == len(baseline):
                    print(f"Progress {index}/{len(baseline)}; {round(time.monotonic()-started, 1)}s; cached {reused}", flush=True)
        except KeyboardInterrupt:
            save_reports(records, args.report_dir)
            print("Stopped; completed records are saved and can be resumed.", flush=True)
            return 130
    summary = save_reports(records, args.report_dir)
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
