"""Read-only-first photo inventory and controlled organizer.

The default mode is a dry run. Moving files requires the explicit --apply flag.
The script never deletes files and writes per-file sidecars only after a move.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import sys
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1

IMAGE_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".webp",
    ".bmp",
    ".tif",
    ".tiff",
    ".heic",
    ".heif",
    ".ico",
}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".3gp", ".mpg", ".mpeg", ".mkv", ".webm"}
AUDIO_EXTENSIONS = {".opus", ".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg"}
DOCUMENT_EXTENSIONS = {
    ".pdf",
    ".doc",
    ".docx",
    ".odt",
    ".xls",
    ".xlsx",
    ".csv",
    ".txt",
    ".zip",
    ".rar",
    ".msi",
}
ONLINE_ONLY_ATTRIBUTE_MASK = 0x00001000 | 0x00040000 | 0x00100000 | 0x00400000

SOURCE_LABELS = {
    "google foto": "google_foto",
    "whatsapp images": "whatsapp_images",
    "zalo": "zalo",
    "camera": "camera",
    "com.whatsapp": "com_whatsapp",
    "eufy": "eufy",
    "facebook": "facebook",
    "foto camera sony 2024": "sony_camera_2024",
    "raccolta samsung": "samsung",
    "scans": "scans",
    "catture di schermata": "screenshots",
    "vecchissime": "vecchissime",
    "vietnam hi quality": "vietnam_hi_quality",
}

FILENAME_DATETIME_PATTERNS = (
    re.compile(
        r"(?<!\d)(?P<year>19\d{2}|20\d{2})[-_. ]?(?P<month>\d{2})[-_. ]?(?P<day>\d{2})"
        r"(?:[ _-]?(?P<hour>\d{2})(?P<minute>\d{2})(?P<second>\d{2}))?(?!\d)"
    ),
    re.compile(
        r"(?<!\d)(?P<year>19\d{2}|20\d{2})[-_. ](?P<month>\d{2})[-_. ](?P<day>\d{2})"
        r"(?:[ _-](?P<hour>\d{2})(?P<minute>\d{2})(?P<second>\d{2}))?(?!\d)"
    ),
)
FILENAME_DATE_PATTERN = re.compile(
    r"(?<!\d)(?P<year>19\d{2}|20\d{2})[-_. ](?P<month>\d{2})[-_. ](?P<day>\d{2})(?!\d)"
)
YEAR_MONTH_PATH_PATTERN = re.compile(r"^(19\d{2}|20\d{2})$")
MONTH_PATH_PATTERN = re.compile(r"^(0[1-9]|1[0-2])$")
SCREENSHOT_NAME_PATTERN = re.compile(
    r"(?i)(screenshot|screen[ _-]?shot|cattura|snip|screenclip|截屏|スクリーンショット)"
)
DOCUMENT_FOLDER_PATTERN = re.compile(r"(?i)(document|documenti|scan|scans|scanned|scansione)")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def path_is_within(path: Path, parent: Path) -> bool:
    """Return whether path is parent or a descendant of parent."""
    path_text = os.path.normcase(os.path.abspath(os.fspath(path)))
    parent_text = os.path.normcase(os.path.abspath(os.fspath(parent)))
    return path_text == parent_text or path_text.startswith(parent_text + os.sep)


def slugify(value: str, limit: int = 64) -> str:
    """Create a stable filesystem-safe ASCII slug."""
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", normalized.casefold()).strip("-")
    return (normalized or "unnamed")[:limit].strip("-") or "unnamed"


def iso_from_timestamp(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def is_probably_online_only(path: Path) -> bool:
    """Detect common Windows/OneDrive flags without opening file contents."""
    try:
        attributes = int(getattr(path.stat(), "st_file_attributes", 0))
        return bool(attributes & ONLINE_ONLY_ATTRIBUTE_MASK)
    except OSError:
        return False


def parse_datetime_text(value: Any) -> tuple[str | None, str | None]:
    """Parse common EXIF or filename timestamps, returning ISO text and precision."""
    if value is None:
        return None, None
    text = str(value).strip().replace("\x00", "")
    if not text:
        return None, None

    for fmt, precision in (
        ("%Y:%m:%d %H:%M:%S", "second"),
        ("%Y-%m-%d %H:%M:%S", "second"),
        ("%Y-%m-%dT%H:%M:%S", "second"),
        ("%Y-%m-%d", "day"),
    ):
        try:
            return datetime.strptime(text[: len(datetime.now().strftime(fmt))], fmt).isoformat(), precision
        except ValueError:
            continue
    return None, None


def parse_filename_datetime(name: str) -> tuple[str | None, str | None, str | None]:
    """Extract a timestamp or date from common camera, WhatsApp, and screenshot names."""
    for pattern in FILENAME_DATETIME_PATTERNS:
        match = pattern.search(name)
        if not match:
            continue
        parts = match.groupdict(default="00")
        try:
            year = int(parts["year"])
            month = int(parts["month"])
            day = int(parts["day"])
            hour = int(parts["hour"] or 0)
            minute = int(parts["minute"] or 0)
            second = int(parts["second"] or 0)
            parsed = datetime(year, month, day, hour, minute, second)
        except ValueError:
            continue
        precision = "second" if match.group("hour") else "day"
        return parsed.isoformat(), precision, "filename"

    match = FILENAME_DATE_PATTERN.search(name)
    if match:
        try:
            parsed = datetime(
                int(match.group("year")), int(match.group("month")), int(match.group("day"))
            )
            return parsed.isoformat(), "day", "filename"
        except ValueError:
            pass
    return None, None, None


def date_from_relative_path(relative_path: Path) -> tuple[str | None, str | None, str | None]:
    """Use a year/month folder only as a low-confidence fallback."""
    parts = list(relative_path.parts[:-1])
    for index in range(len(parts) - 1):
        year_match = YEAR_MONTH_PATH_PATTERN.match(parts[index])
        month_match = MONTH_PATH_PATTERN.match(parts[index + 1])
        if year_match and month_match:
            return f"{year_match.group(1)}-{month_match.group(1)}-01T00:00:00", "month", "folder"
    return None, None, None


def import_pillow() -> Any:
    try:
        from PIL import Image

        return Image
    except ImportError:
        return None


def read_light_image_metadata(path: Path) -> dict[str, Any]:
    """Read container headers without decoding image pixels or scanning full files."""
    extension = path.suffix.casefold()
    result: dict[str, Any] = {"metadata_mode": "light"}
    try:
        with path.open("rb") as stream:
            if extension == ".png":
                if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                    return {"metadata_mode": "light", "read_error": "invalid_png_signature"}
                stream.read(4)
                if stream.read(4) != b"IHDR":
                    return {"metadata_mode": "light", "read_error": "missing_png_ihdr"}
                header = stream.read(13)
                if len(header) != 13:
                    return {"metadata_mode": "light", "read_error": "truncated_png_ihdr"}
                width = int.from_bytes(header[0:4], "big")
                height = int.from_bytes(header[4:8], "big")
                bit_depth = header[8]
                color_type = header[9]
                color_modes = {0: "L", 2: "RGB", 3: "P", 4: "LA", 6: "RGBA"}
                result.update(
                    {
                        "format": "PNG",
                        "width": width,
                        "height": height,
                        "bit_depth": bit_depth,
                        "color_type": color_type,
                        "mode": color_modes.get(color_type, f"PNG_COLOR_TYPE_{color_type}"),
                        "frames": 1,
                        "animated": False,
                    }
                )
                return result
            if extension == ".gif":
                signature = stream.read(6)
                if signature not in {b"GIF87a", b"GIF89a"}:
                    return {"metadata_mode": "light", "read_error": "invalid_gif_signature"}
                header = stream.read(4)
                if len(header) == 4:
                    result.update(
                        {
                            "format": "GIF",
                            "width": int.from_bytes(header[0:2], "little"),
                            "height": int.from_bytes(header[2:4], "little"),
                        }
                    )
                return result
            return {"metadata_mode": "light", "format": extension.removeprefix(".").upper()}
    except Exception as error:
        return {"metadata_mode": "light", "read_error": f"{type(error).__name__}: {error}"}


def _text_value(value: Any, limit: int = 500) -> str | None:
    if value is None:
        return None
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    text = str(value).replace("\x00", "").strip()
    return text[:limit] if text else None


def read_image_metadata(path: Path, image_module: Any, metadata_mode: str) -> dict[str, Any]:
    """Read safe technical metadata and date candidates without modifying the image."""
    if metadata_mode == "filesystem":
        return {"metadata_mode": "filesystem"}
    if metadata_mode == "light":
        return read_light_image_metadata(path)
    if image_module is None:
        return {"read_error": "Pillow is not installed"}

    result: dict[str, Any] = {}
    try:
        with image_module.open(path) as image:
            result.update(
                {
                    "format": image.format,
                    "width": image.width,
                    "height": image.height,
                    "mode": image.mode,
                    "frames": getattr(image, "n_frames", 1),
                    "animated": bool(getattr(image, "is_animated", False)),
                }
            )
            exif = image.getexif()
            exif_names = {306: "DateTime", 36867: "DateTimeOriginal", 36868: "DateTimeDigitized", 274: "Orientation"}
            date_candidates: dict[str, str] = {}
            for tag_id, key in exif_names.items():
                value = _text_value(exif.get(tag_id))
                if value:
                    if key == "Orientation":
                        result["orientation"] = value
                    else:
                        date_candidates[key] = value
            if date_candidates:
                result["exif_dates"] = date_candidates

            info = getattr(image, "info", {})
            result["metadata_keys"] = sorted(str(key) for key in info.keys())[:100]
            selected_info: dict[str, str] = {}
            for key in ("Software", "Comment", "Description", "Creation Time", "creation_time", "date:create", "date:modify"):
                value = _text_value(info.get(key))
                if value:
                    selected_info[key] = value
            if selected_info:
                result["text_metadata"] = selected_info
            result["gps_present"] = bool(exif.get(34853))
    except Exception as error:  # Image decoders are intentionally isolated per file.
        result["read_error"] = f"{type(error).__name__}: {error}"
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_path_token(path: Path) -> str:
    return hashlib.sha1(str(path).casefold().encode("utf-8")).hexdigest()[:12]


def source_label(root: Path) -> str:
    if "google foto" in root.name.casefold():
        return "google_foto"
    return SOURCE_LABELS.get(root.name.casefold(), slugify(root.name))


def classify_screenshot(path: Path, root: Path, image_metadata: dict[str, Any]) -> tuple[bool, float, list[str]]:
    if path.suffix.casefold() not in IMAGE_EXTENSIONS:
        return False, 0.0, []
    reasons: list[str] = []
    root_text = " ".join(
        part.casefold() for part in (*root.parts, *path.relative_to(root).parts[:-1])
    )
    if "catture di schermata" in root_text or "screenshot" in root_text or "screenshots" in root_text:
        reasons.append("screenshot_source_folder")
    if SCREENSHOT_NAME_PATTERN.search(path.name):
        reasons.append("screenshot_filename")
    if path.suffix.casefold() == ".png" and image_metadata.get("text_metadata"):
        keys = " ".join(image_metadata["text_metadata"].keys()).casefold()
        if "screenshot" in keys or "screen" in keys:
            reasons.append("screenshot_metadata")
    if not reasons:
        return False, 0.0, []
    confidence = 0.99 if "screenshot_source_folder" in reasons else 0.90
    return True, confidence, reasons


def classify_document_image(path: Path, root: Path) -> tuple[bool, float, list[str]]:
    """Identify image files stored in an explicitly document/scan folder."""
    if path.suffix.casefold() not in IMAGE_EXTENSIONS:
        return False, 0.0, []
    parts = (*root.parts, *path.relative_to(root).parts[:-1])
    if any(DOCUMENT_FOLDER_PATTERN.search(part) for part in parts):
        return True, 0.95, ["document_or_scan_source_folder"]
    return False, 0.0, []


def choose_date(
    path: Path,
    relative_path: Path,
    image_metadata: dict[str, Any],
) -> tuple[str | None, str | None, str | None, float]:
    exif_dates = image_metadata.get("exif_dates", {})
    for key, confidence in (("DateTimeOriginal", 0.98), ("DateTimeDigitized", 0.95), ("DateTime", 0.75)):
        parsed, precision = parse_datetime_text(exif_dates.get(key))
        if parsed:
            return parsed, precision, f"exif_{key}", confidence

    parsed, precision, source = parse_filename_datetime(path.name)
    if parsed:
        return parsed, precision, source, 0.70 if precision == "second" else 0.60

    parsed, precision, source = date_from_relative_path(relative_path)
    if parsed:
        return parsed, precision, source, 0.35

    return None, None, None, 0.0


def category_for(
    path: Path,
    is_snapshot: bool,
    is_document_image: bool,
    image_metadata: dict[str, Any],
) -> tuple[str, float, list[str]]:
    extension = path.suffix.casefold()
    if is_snapshot:
        return "snapshot", 0.99, ["png_or_screenshot_signal"]
    if is_document_image:
        return "document_image", 0.95, ["document_or_scan_signal"]
    if extension == ".ico":
        return "icon", 1.0, ["ico_extension"]
    if extension == ".svg":
        return "icon", 1.0, ["svg_extension"]
    if extension == ".gif" or (extension == ".webp" and image_metadata.get("animated")):
        return "animation", 0.99, ["animated_extension_or_frames"]
    if extension == ".webp":
        return "animation", 0.75, ["webp_requires_content_check"]
    if extension == ".png":
        return "png_review", 0.50, ["png_without_screenshot_signal"]
    if extension in VIDEO_EXTENSIONS:
        return "video", 1.0, ["video_extension"]
    if extension in AUDIO_EXTENSIONS:
        return "audio", 1.0, ["audio_extension"]
    if extension in DOCUMENT_EXTENSIONS:
        return "document", 1.0, ["document_extension"]
    if extension in IMAGE_EXTENSIONS:
        return "photo", 0.80, ["image_extension"]
    return "other", 0.50, ["unclassified_extension"]


def date_path(date_value: str | None, precision: str | None) -> tuple[str, str]:
    if not date_value:
        return "99_Senza_Data", "undated"
    year = date_value[0:4]
    month = date_value[5:7]
    if precision == "month":
        return os.path.join(year, month), f"{year}-{month}"
    if precision in {"day", "second"}:
        return os.path.join(year, month), date_value[0:10]
    return "99_Senza_Data", "undated"


def planned_filename(
    record: dict[str, Any],
    extension: str,
    use_hash: bool,
) -> str:
    date_value = record.get("capture_datetime")
    precision = record.get("capture_precision")
    if date_value and precision == "second":
        prefix = date_value.replace(":", "-").replace("T", "_")
    elif date_value:
        prefix = date_value[0:10]
    else:
        prefix = "undated"
    identity = (record.get("sha256") or stable_path_token(Path(record["original_path"])))[:12]
    stem = slugify(Path(record["original_path"]).stem, limit=44)
    source = slugify(record["source_label"], limit=24)
    suffix = "content" if use_hash and record.get("sha256") else "path"
    return f"{prefix}__{source}__{stem}__{suffix}-{identity}{extension.casefold()}"


def iter_files(roots: list[Path], excluded: list[Path]) -> Iterable[tuple[Path, Path]]:
    seen: set[str] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for current, directories, filenames in os.walk(root):
            current_path = Path(current)
            directories[:] = [
                directory
                for directory in directories
                if not any(path_is_within(current_path / directory, excluded_path) for excluded_path in excluded)
            ]
            for filename in filenames:
                path = current_path / filename
                if any(path_is_within(path, excluded_path) for excluded_path in excluded):
                    continue
                key = os.path.normcase(os.path.abspath(os.fspath(path)))
                if key in seen:
                    continue
                seen.add(key)
                yield root, path


def record_file(
    root: Path,
    path: Path,
    image_module: Any,
    hash_mode: str,
    metadata_mode: str,
) -> dict[str, Any]:
    stat = path.stat()
    relative_path = path.relative_to(root)
    image_metadata = (
        read_image_metadata(path, image_module, metadata_mode)
        if path.suffix.casefold() in IMAGE_EXTENSIONS
        else {}
    )
    is_snapshot, screenshot_confidence, screenshot_reasons = classify_screenshot(path, root, image_metadata)
    is_document_image, document_confidence, document_reasons = classify_document_image(path, root)
    capture_datetime, capture_precision, capture_source, date_confidence = choose_date(
        path, relative_path, image_metadata
    )
    category, category_confidence, category_reasons = category_for(
        path, is_snapshot, is_document_image, image_metadata
    )
    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "original_path": str(path.absolute()),
        "original_root": str(root.absolute()),
        "original_relative_path": str(relative_path),
        "original_filename": path.name,
        "source_label": source_label(root),
        "extension_original": path.suffix,
        "extension_normalized": path.suffix.casefold(),
        "size_bytes": stat.st_size,
        "windows_file_attributes": int(getattr(stat, "st_file_attributes", 0)),
        "probably_online_only": bool(int(getattr(stat, "st_file_attributes", 0)) & ONLINE_ONLY_ATTRIBUTE_MASK),
        "created_at_utc": iso_from_timestamp(stat.st_ctime),
        "modified_at_utc": iso_from_timestamp(stat.st_mtime),
        "discovered_at_utc": utc_now(),
        "category": category,
        "category_confidence": category_confidence,
        "category_reasons": category_reasons + screenshot_reasons,
        "screenshot_confidence": screenshot_confidence,
        "document_confidence": document_confidence,
        "document_reasons": document_reasons,
        "capture_datetime": capture_datetime,
        "capture_precision": capture_precision,
        "capture_date_source": capture_source,
        "capture_date_confidence": date_confidence,
        "image_metadata": image_metadata,
    }
    if hash_mode == "sha256":
        record["sha256"] = sha256_file(path)
    record["asset_id"] = (
        f"sha256:{record['sha256']}"
        if record.get("sha256")
        else f"path:{stable_path_token(path)}"
    )
    return record


def planned_destination(record: dict[str, Any], destination_root: Path, use_hash: bool) -> Path:
    category = record["category"]
    if category == "photo":
        bucket = "00_Foto"
        date_folder, _ = date_path(record.get("capture_datetime"), record.get("capture_precision"))
    elif category == "snapshot":
        bucket = "01_Snapshot"
        date_folder, _ = date_path(record.get("capture_datetime"), record.get("capture_precision"))
    elif category == "animation":
        bucket, date_folder = "02_Animazioni", ""
    elif category == "icon":
        bucket, date_folder = "03_Icone", ""
    elif category == "png_review":
        bucket, date_folder = "99_Da_Verificare", "PNG"
    elif category == "document_image":
        bucket, date_folder = "06_Documenti", "Immagini"
    elif category == "video":
        bucket = "04_Video"
        date_folder, _ = date_path(record.get("capture_datetime"), record.get("capture_precision"))
    elif category == "audio":
        bucket, date_folder = "05_Audio", ""
    elif category == "document":
        bucket, date_folder = "06_Documenti", ""
    else:
        bucket, date_folder = "99_Da_Verificare", ""
    filename = planned_filename(record, record["extension_normalized"], use_hash)
    parts = [destination_root, bucket]
    if date_folder:
        parts.append(Path(date_folder))
    parts.append(filename)
    return Path(os.path.join(*(str(part) for part in parts)))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_jsonl(path: Path, records: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        for record in records:
            stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    temporary.replace(path)


def write_csv(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "category",
        "category_confidence",
        "capture_datetime",
        "capture_date_source",
        "capture_date_confidence",
        "source_label",
        "size_bytes",
        "sha256",
        "original_path",
        "planned_path",
        "status",
    ]
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)
    temporary.replace(path)


def apply_moves(records: list[dict[str, Any]]) -> None:
    for record in records:
        source = Path(record["original_path"])
        destination = Path(record["planned_path"])
        sidecar = Path(str(destination) + ".meta.json")
        record["moved_at_utc"] = utc_now()
        if not source.exists() and destination.exists() and sidecar.exists():
            record["status"] = "already_applied"
            continue
        if not source.exists():
            record["status"] = "source_missing"
            continue
        if destination.exists():
            record["status"] = "destination_conflict"
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(destination))
        record["status"] = "moved"
        write_json(sidecar, {**record, "sidecar_path": str(sidecar)})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", required=True, help="Source folder; repeat for more roots")
    parser.add_argument(
        "--destination",
        default=str(Path(__file__).resolve().parent.parent / "output" / "archive-review"),
        help="Planned destination root",
    )
    parser.add_argument(
        "--report-dir",
        default=str(Path(__file__).resolve().parent.parent / "output" / "technical-reports"),
        help="Where dry-run manifests and summaries are written",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", "--what-if", dest="dry_run", action="store_true", help="Plan only (default)")
    mode.add_argument("--apply", action="store_true", help="Move files and write destination sidecars")
    parser.add_argument("--hash", choices=("none", "sha256"), default="none", help="Content hash mode")
    parser.add_argument(
        "--metadata-mode",
        choices=("filesystem", "light", "deep"),
        default="filesystem",
        help="filesystem avoids content reads; light reads headers; deep uses Pillow EXIF/text metadata",
    )
    parser.add_argument(
        "--extensions",
        help="Comma-separated extension filter, for example .png or .jpg,.jpeg",
    )
    parser.add_argument("--limit", type=int, help="Process at most this many files")
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Skip files carrying Windows/OneDrive online-only or recall flags",
    )
    parser.add_argument("--yes", action="store_true", help="Required with --apply to avoid an interactive prompt")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.apply and not args.yes:
        print("--apply richiede anche --yes; il dry-run resta il comportamento predefinito.", file=sys.stderr)
        return 2

    roots = [Path(os.path.abspath(os.path.expanduser(value))) for value in args.root]
    destination = Path(os.path.abspath(os.path.expanduser(args.destination)))
    report_dir = Path(os.path.abspath(os.path.expanduser(args.report_dir)))
    excluded = [destination, report_dir]
    extension_filter = None
    if args.extensions:
        extension_filter = {
            extension.casefold() if extension.startswith(".") else f".{extension.casefold()}"
            for extension in args.extensions.split(",")
        }

    image_module = import_pillow() if args.metadata_mode == "deep" else None
    records: list[dict[str, Any]] = []
    run_id = utc_now()
    skipped_missing_roots: list[str] = []
    for root in roots:
        if not root.is_dir():
            skipped_missing_roots.append(str(root))
            continue
        for current_root, path in iter_files([root], excluded):
            if extension_filter and path.suffix.casefold() not in extension_filter:
                continue
            if args.local_only and is_probably_online_only(path):
                continue
            record = record_file(current_root, path, image_module, args.hash, args.metadata_mode)
            record["run_id"] = run_id
            records.append(record)
            if args.limit and len(records) >= args.limit:
                break
        if args.limit and len(records) >= args.limit:
            break

    use_hash = args.hash == "sha256"
    for record in records:
        record["planned_path"] = str(planned_destination(record, destination, use_hash))
        record["planned_sidecar_path"] = record["planned_path"] + ".meta.json"
        record["status"] = "planned" if not args.apply else "pending"

    if args.apply:
        apply_moves(records)

    duplicate_hash_groups: dict[str, list[str]] = {}
    if use_hash:
        for record in records:
            if record.get("sha256"):
                duplicate_hash_groups.setdefault(record["sha256"], []).append(record["original_path"])
    duplicate_groups = {key: paths for key, paths in duplicate_hash_groups.items() if len(paths) > 1}
    category_counts = Counter(record["category"] for record in records)
    summary = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "generated_at_utc": utc_now(),
        "mode": "apply" if args.apply else "dry-run",
        "hash_mode": args.hash,
        "metadata_mode": args.metadata_mode,
        "local_only": args.local_only,
        "roots": [str(root) for root in roots],
        "destination": str(destination),
        "report_dir": str(report_dir),
        "files_scanned": len(records),
        "bytes_scanned": sum(record["size_bytes"] for record in records),
        "categories": dict(sorted(category_counts.items())),
        "duplicate_hash_groups": len(duplicate_groups),
        "duplicate_hash_files": sum(len(paths) for paths in duplicate_groups.values()),
        "missing_roots": skipped_missing_roots,
        "status_counts": dict(Counter(record["status"] for record in records)),
        "probably_online_only_files": sum(1 for record in records if record["probably_online_only"]),
        "notes": [
            "Size alone is never treated as proof of duplication.",
            "Dry-run writes reports only; destination sidecars are written after an applied move.",
            "Date confidence is recorded per file and filesystem timestamps are not used as capture dates.",
        ],
    }
    report_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(report_dir / "latest-manifest.jsonl", records)
    write_csv(report_dir / "latest-plan.csv", records)
    write_json(report_dir / "latest-summary.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
