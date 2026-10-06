"""Explicit on-demand ASR setup: packages, model, caches and logs stay in the toolbox."""

import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from transcription import ROOT, atomic_text, checksum, configuration
from job_log import JobLog


# Exceptions: download/install failures leave the prior activated runtime untouched.
def main() -> int:
    config = configuration()
    runtime = ROOT / "runtime/transcription"
    runtime.mkdir(parents=True, exist_ok=True)
    receipt_path = runtime / "installation.json"
    with JobLog("setup-transcription", {"engine_version": config["engine_version"], "model_revision": config["model_revision"]}) as log:
        if receipt_path.exists():
            previous = json.loads(receipt_path.read_text(encoding="utf-8"))
            if (previous.get("engine_version") == config["engine_version"]
                    and previous.get("model_revision") == config["model_revision"]
                    and (ROOT / previous["packages_directory"]).is_dir()
                    and previous.get("packages_hashes")
                    and all((ROOT / previous["packages_directory"] / name).is_file()
                            and checksum(ROOT / previous["packages_directory"] / name) == digest
                            for name, digest in previous["packages_hashes"].items())
                    and all((Path(config["model_directory"]) / name).is_file()
                            and checksum(Path(config["model_directory"]) / name) == digest
                            for name, digest in previous.get("model_hashes", {}).items())
                    and previous.get("model_hashes")):
                log.emit({"event": "log", "message": "Trascrizione gia preparata; nessun download"})
                return 0
        downloads = ROOT / "downloads/transcription"
        downloads.mkdir(parents=True, exist_ok=True)
        # Obtain the published wheel hash from the official Python package registry.
        with urllib.request.urlopen("https://pypi.org/pypi/pip/" + config["pip_version"] + "/json", timeout=60) as response:
            metadata = json.load(response)
        package = next(item for item in metadata["urls"] if item["filename"].endswith(".whl"))
        pip_wheel = downloads / package["filename"]
        if not pip_wheel.exists():
            partial = pip_wheel.with_suffix(".part")
            urllib.request.urlretrieve(package["url"], partial)
            if checksum(partial) != package["digests"]["sha256"]:
                raise ValueError("Checksum download pip non valido")
            partial.replace(pip_wheel)
        if checksum(pip_wheel) != package["digests"]["sha256"]:
            raise ValueError("Wheel pip locale modificata")
        packages = runtime / ("packages-" + str(time.time_ns()))
        report = runtime / (packages.name + "-pip-report.json")
        env = dict(os.environ)
        env["PIP_CACHE_DIR"] = str(ROOT / "cache/pip-transcription")
        env["HF_HOME"] = str(ROOT / "cache/huggingface-transcription")
        env["TEMP"] = env["TMP"] = str(ROOT / "temp/transcription")
        Path(env["TEMP"]).mkdir(parents=True, exist_ok=True)
        command = [sys.executable, "-B", "-c", "import sys,runpy;sys.path.insert(0,sys.argv.pop(1));runpy.run_module('pip',run_name='__main__')",
                   str(pip_wheel), "install", "--disable-pip-version-check", "--no-input", "--only-binary=:all:",
                   "--index-url", "https://pypi.org/simple", "--target", str(packages), "--report", str(report),
                   "faster-whisper==" + config["engine_version"]]
        log.emit({"event": "log", "message": "Installazione pacchetti isolati; nessuna modifica a Python globale o PATH"})
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   encoding="utf-8", errors="replace", env=env,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        for line in process.stdout:
            log.emit({"event": "log", "message": line.rstrip()})
        if process.wait():
            raise RuntimeError("Installazione trascrizione fallita; vedi log dettagliato")
        sys.path.insert(0, str(packages))
        os.environ["HF_HOME"] = env["HF_HOME"]
        from huggingface_hub import snapshot_download
        log.emit({"event": "log", "message": "Download modello Whisper small multilingua (circa 500 MB), revisione fissata"})
        model_path = Path(snapshot_download(repo_id=config["model_repository"], revision=config["model_revision"],
                        local_dir=config["model_directory"], cache_dir=env["HF_HOME"],
                        allow_patterns=["*.json", "*.bin", "*.txt", "README.md", "LICENSE*"]))
        model_hashes = {str(path.relative_to(model_path)): checksum(path)
                        for path in model_path.rglob("*") if path.is_file() and ".cache" not in path.relative_to(model_path).parts}
        for required in ("model.bin", "config.json", "tokenizer.json"):
            if required not in model_hashes:
                raise ValueError("Download modello incompleto: " + required)
        packages_hashes = {str(path.relative_to(packages)): checksum(path)
                           for path in packages.rglob("*") if path.is_file() and "__pycache__" not in path.relative_to(packages).parts}
        receipt = {"engine_version": config["engine_version"], "model_revision": config["model_revision"],
                   "packages_directory": str(packages.relative_to(ROOT)), "model_hashes": model_hashes,
                   "packages_hashes": packages_hashes,
                   "pip_report": str(report.relative_to(ROOT))}
        atomic_text(receipt_path, json.dumps(receipt, indent=2))
        log.emit({"event": "log", "message": "Trascrizione preparata: CPU int8, offline; nessun file personale elaborato"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
