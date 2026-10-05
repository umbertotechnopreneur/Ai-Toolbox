AI Toolbox - portable local image catalog
=======================================

Photo Organizer by Umberto Giacobbi - https://umbertogiacobbi.biz/
Code description: VibeWare, built with AI assistance; this is not a license.
Publisher links appear in the main footer, Options and the About dialog.
The owned VibeWare floppy icon is used for window/taskbar branding.
See assets/branding/ASSET-NOTES.txt. The old third-party blue folder icon is
kept only locally and excluded from Git. No private profile documents are bundled.

Everything is relative to this folder; no fixed drive or E: path is required.
Windows x64, Windows PowerShell 5.1, Windows Forms and curl.exe are prerequisites.
GPU drivers must be provided by the user; setup does not install drivers.
No service, permanent PATH entry, CUDA Toolkit, Docker or global Python package is used.
Default fonts are private to the application. Optional Windows-user font
installation is the only explicit opt-in registry/user-profile change.
The embedded Python 3.13.16 and Pillow 12.3.0 do not depend on system Python.

Included model: official Qwen3-VL-4B-Instruct-GGUF, Q4_K_M language weights
and F16 vision projector. Engine: llama.cpp b11146, CUDA 12.4 / Vulkan / CPU.
Downloads are pinned and checked against publisher SHA-256 checksums.
Re-run Setup-Portable.ps1 to verify/resume dependencies, not to update versions.

COMMANDS (Command Prompt or PowerShell)

From the toolbox folder (PowerShell uses .\Toolbox.cmd):
  Toolbox.cmd doctor
  Toolbox.cmd test
  Toolbox.cmd catalog --limit 25 --what-if
  Toolbox.cmd catalog --category png_review --limit 10 --run
  Toolbox.cmd catalog --limit 100 --run
  Toolbox.cmd catalog --all --run

Default catalog mode is what-if: no source-content reads and no AI startup.
--run permits AI analysis only, never a move, rename, deletion or source sidecar.
It launches the loopback engine for the job and stops its owned process after
completion, failure or Ctrl+C. It refuses to use an already occupied port.
The --all command still processes only the frozen manifest, not the cloud.

Start-AI.cmd opens an optional foreground local UI at http://127.0.0.1:8091.
Ctrl+C in that window stops the engine. Nothing starts automatically at login.
Do not use UI file selection for online-only files: the UI has no OneDrive guard.
Use the catalog command for guarded source reads.

PHOTO SAFETY AND JSON

input/local-files.jsonl is a copy of the 3,893-file technical local analysis.
The tool never recursively scans or hydrates more images. It rejects Windows
offline/recall flags and incomplete Cloud Files placeholders before contents.
Source size, mtime and SHA-256 must match the frozen technical record.
Preview resizing is in memory only; the original image is never changed.
HEIC/HEIF or other unsupported codecs are reported as errors, not converted.
Only frame zero of an animation/MPO is inspected, with an explicit review flag.

output/catalog/latest-manifest.jsonl contains original technical records plus
an independent ai section: category, description, tags, visible-text indicator,
review reasons, model/version fingerprint, analysis time and local preview info.
output/catalog/records/*.json are per-occurrence checkpoints.
cache/catalog/<configuration-hash>/<image-sha256>.json avoids repeated inference
for identical bytes under the same model, prompt, schema and preview settings.
Successful records survive interrupted batches. No AI score is represented as
a calibrated probability. Dates, GPS and exact duplicate identity are never
inferred or overwritten by AI. OCR is not enabled in this initial catalog.
Photos and descriptions stay on this PC; inference HTTP ignores proxy settings.
Model downloads require Internet only during setup. Source text is untrusted
content, not executable instructions, and the model has no tools/network access.

cache, temp, models, downloads, logs and reports stay inside this toolbox.
Standard Windows OS logs/prefetch/Defender activity are outside its control.
Archive ZIPs are retained for reproducibility; no cleanup has been performed.
Copy the whole folder to relocate it; supplied manifest original paths still
refer to this PC and must be refreshed on another computer.

SOURCE UTILITIES

scripts/analyze_local.py and photo_organizer.py are snapshots of the previously
created technical analyzer. The catalog reuses the guarded-local-read function.
Only use Toolbox.cmd commands above: the older organizer's move/apply mode
has NOT been validated for migration and is not part of this setup's workflow.

Official sources:
https://github.com/ggml-org/llama.cpp/releases/tag/b11146
https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF
https://www.python.org/downloads/release/python-31316/
https://pypi.org/project/Pillow/12.3.0/

VERIFIED ON THIS PC - 5 October 2026, Asia/Saigon

18 regression tests passed. Six publisher checksums matched; a second setup
run reused existing downloads. Four already-local archive images completed
AI inference successfully, and a repeated three-image run made no inference
calls or engine startup. The local UI returned HTTP 200; Ctrl+C terminated
the owned engine, leaving no llama-server.exe process running.
Observed total GPU usage with the model loaded was about 6.3 GiB of 8 GiB,
including other desktop applications. This is not a peak/model-only estimate.
Smoke-image times were about 1.8-2.8 seconds excluding startup, not a reliable
full-archive throughput forecast. AI labels remain unreviewed suggestions.
See output/setup-verification.json for the machine-readable verification.

FOLDER ORGANIZER GUI

Launch Photo-Organizer.cmd. The native Italian Windows Forms GUI uses a
per-monitor-DPI-aware process and responsive layout, with source/destination
folder pickers, optional local AI, progress and console output.
Simula inventories metadata only. Copia / Riprendi copies the selected folder;
OneDrive handles its normal background/content availability itself. No pin,
sync or free-up-space settings are changed. Pausa is cooperative, not deletion.
Verifica output checks each preserved output SHA-256 and its JSON sidecar.

The default review workspace is <toolbox>\output\preview-<folder-name>.
Only its Risultato subfolder is the deliverable to preview and manually copy
into immagini-pulite. .photo-organizer contains checkpoints, errors, manifest
and summary; leave these workspace bookkeeping files outside the final archive.

Layout: Risultato\Foto\YYYY\MM\YYYY-MM-DD\<date/time>__<content-id>.jpg,
with a sibling .meta.json for every unique output. Snapshot, Scansioni,
Grafica, Video, Audio, GIF_Animazioni, Icone and other-file buckets are separate.
PNG is not automatically called a screenshot. Unknown/partial dates use
Da_Datare, rather than a fabricated day. Filesystem/download timestamps are
preserved as provenance, never promoted to capture date. EXIF/filename date
conflicts and unsupported metadata/codecs are flagged for manual review.

Exact nonempty duplicate bytes produce one preserved asset with every original
path/name recorded in its sidecar. Empty files remain separate review items.
All regular source files, not just decodable photos, are accounted for; links,
junctions and scan omissions prevent a 'ready for review' status.
Deduplication is within the selected folder/workspace, not across independently
processed workspaces. When manually combining batches into immagini-pulite,
do not blindly overwrite a conflicting .meta.json: its original-path list may
contain different provenance even when both image files have identical bytes.

Resume recognizes original path + size + mtime, verifies output SHA-256 and
sidecars, and skips completed source reads, copies, metadata work and AI.
This fast source recognition assumes unchanged files keep their size/mtime;
it is not a fresh full-source-content audit on every resume. Only a file whose
copy was interrupted may need copying again. Model/prompt/layout/source settings
are fixed per workspace; use a fresh destination to change them. Concurrent
jobs cannot write the same workspace. Sidecar writes and provenance updates
have recovery receipts, while user-edited sidecars/damaged outputs are never
silently overwritten. A missing output or sidecar can be reconstructed.

'Ready for review' means every scanned occurrence is accounted for with verified
bytes, not that all dates or AI labels are correct. Copy/catalog workflows NEVER
delete, move, rename or write originals. Panel 04 is a separate, explicitly
confirmed, bounded recycling workflow. Review Risultato and keep a backup first.
Copy and check the final archive BEFORE deleting the source. Deleting a source
under OneDrive can also remove its cloud copy; this also applies to Panel 04.
Manual final relocation does not update copied_to/copy-time provenance; use
archive_relative_path for the final archive-relative location.

CLI equivalent (GUI passes these arguments to the same portable backend):
  runtime\python\python.exe -B -u scripts\folder_organizer.py --source "C:\photos\one-folder" --destination "D:\review\one-folder" --what-if
Add --run --allow-cloud for a scoped normal-read copy, --no-ai to omit local
AI, or --verify-only to check outputs. A 20 GiB output-drive free-space margin
is kept by default. Portable ffprobe 9.0.2 reads video/audio dates. Fresh setup
downloads a publisher-checksummed FFmpeg essentials package; it needs no global
FFmpeg installation. Existing bundled ffprobe is preserved.

PORTABLE OPTIONS AND ON-DEMAND SETUP

Options / Setup lets you choose installed/private monospace fonts, Light/Dark
and Auto/CUDA/Vulkan/CPU. Preferences stay in config/ui-options.json and toolbox.json.
The black console streams installer stdout/stderr without blocking the UI.
Missing default font can be prepared at launch; this downloads only four
JetBrainsMono Nerd Font Mono styles (~9.4 MiB) and their licenses, not AI models.
By default they stay in runtime/fonts and are registered only in this app.
Windows-user installation is an explicit checkbox, never an administrator install.
The reference E:/tools installer is not a runtime dependency; oh-my-posh is not required.
Fonts are pinned to a Git revision and verified by byte count and upstream Git
blob SHA-1; installation receipts additionally record each file's SHA-256.

Prepare this machine invokes the portable setup script only after confirmation.
Auto setup checks adapters when invoked: NVIDIA -> CUDA, Intel/AMD -> Vulkan,
otherwise CPU. CPU fallback is included. Driver/device suitability is checked
by the inference engine at job startup, not assumed from the adapter name.
Auto inference tries usable installed CUDA, Vulkan, then CPU; explicit modes
do not silently change backend. Startup fallback never retries a failed batch.
GPU driver installation and a complete NPU backend are outside this setup.
Intel NPU is NOT used by this GGUF/llama.cpp pipeline. Intel GPU Vulkan and CPU
support require live testing on the destination laptop; no timings are promised.

Standalone setup, from the toolbox directory:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Portable.ps1 -Backend Auto
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Portable.ps1 -Backend Vulkan
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Portable.ps1 -Backend CPU -NoModels
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Monospace.ps1
Downloads remain in .part files on interruption and are resumed on rerun.
Offline redistribution: copy the whole prepared toolbox including runtimes,
fonts/licenses, models and receipts. Re-select input/output on the other machine;
the personal input/local-files.jsonl is historical and not a portable photo inventory.
Avoid distributing personal logs, previews or that manifest with a public package.

PANEL 04 - VERIFIED ORIGINAL CLEANUP

Choose one specific original folder and the target archive with retained copies.
Index target builds .photo-cleanup/index.sqlite3 and hashes target files once.
Simulate cleanup indexes paths/metadata first, then hashes only relevant candidates.
Adjacent .meta.json original-path lists locate candidates even after final relocation;
historical copied_to paths are not trusted. Bad/missing JSON falls back to content.
Neither filename, file size nor a JSON hash claim proves a retained copy.
Target hash reuse requires unchanged file ID, size, mtime and filesystem change
time. If the change signature is unavailable, content is rehashed. The SQLite
database is trusted application bookkeeping, not a defense against malicious tampering.

Preview lists proven matches, preserved files and items not checked due to the
limit. Default maximum is 50 matches per confirmation (1-500). Apply requires
the exact persisted preview ID/digest, and rechecks source SHA-256 and target
identity/cache signature. The retained target is held read-only, denying writes
and deletion throughout recycling. Sources changed after preview are preserved.
The Windows helper again hashes and checks source identity, refuses network or
removable drives and requires Recycle Bin transfer flags and a Shell receipt.
No recursive deletion, folder removal, permanent-delete fallback or bin-emptying.
The Recycle Bin retains disk usage until you explicitly empty it yourself.

Each intent and receipt is logged durably before continuing. Uncertain helper,
storage or receipt failures stop the batch and require manual inspection.
Repeated apply skips completed individual receipts. A restored source needs a
NEW preview/confirmation; restarting the GUI requires a fresh preview, which
reuses the persistent index and naturally skips already removed originals.
Pause cooperatively stops between hashing chunks/files. Input/target changes
invalidate the GUI preview. Never move/edit the source or target during apply.

CLI preview (default and --what-if/--dry-run are equivalent):
  runtime\python\python.exe -B -u scripts\cleanup_processed.py --source "C:\photos\one-folder" --target "D:\immagini-pulite" --what-if --limit 50
Index-only: replace --what-if with --index. It never removes originals.
Apply additionally requires --apply --plan-id <ID> --confirm-plan-hash <DIGEST>
from the preview summary; the CLI cannot choose permanent deletion.
Cleanup preview reads contents and writes target index/plan/logs, unlike the
copy inventory simulation which opens no media contents and creates no output.

PERSISTENT LOGS

All application logs are independent of the chosen photo directories:
  <toolbox>/logs/photo-organizer/gui-*.jsonl        GUI and raw worker events
  <toolbox>/logs/photo-organizer/*-copy-*.jsonl    Copy job progress/hashes/resume
  <toolbox>/logs/photo-organizer/*-cleanup-*.jsonl Plans, intents and receipts
  <toolbox>/logs/server-*.log                     Unique owned AI engine sessions
  <toolbox>/logs/photo-organizer/*-backend-*.jsonl Backend detection/startup/fallback
  <toolbox>/logs/setup-*.log, font-setup-*.log     Installer transcripts
  <toolbox>/logs/toolbox-*.log                    Command-line launcher transcripts
Logs contain full paths and checksums, but never image bytes, audio or OCR text.
No automatic rotation/deletion of detailed logs is performed. Protect these
personal-path logs when distributing the app. Jobs require a writable toolbox.
Source edits take effect next launch; an already-running app is not reconfigured
retroactively and its existing process cannot acquire historical logs.

FOLDER WORKFLOW VERIFICATION - 5 October 2026, Asia/Saigon

52 regression tests passed, including copy-only source preservation, SHA-256
duplicate provenance, day/month/unknown dates, damaged-output protection,
edited/unowned/linked sidecar protection, interrupted provenance recovery,
missing-output/JSON repair, pause/resume, concurrent jobs and changing sources.
The GUI rendered successfully at 144 DPI. Physical monitor-to-monitor DPI
transitions have not been tested. The GUI's actual background worker completed
Simula, Copia, Riprendi and Verifica on four generated Unicode-path fixtures:
three unique outputs, one duplicate, and unchanged original/output/sidecar bytes.
Verification succeeded with a changed AI checkbox without starting the model.
One newly generated PNG made a real local GPU inference call; the owned model
process stopped afterward. No real archive folder was processed by these tests.
Evidence: output/gui-workflow-verification.json, folder-organizer-smoke.json,
and gui-smoke.png. These checks are not a 140 GB throughput/soak test.

Developer smoke commands (synthetic fixtures only):
  Photo-Organizer.cmd -UiSmokeTest
  Photo-Organizer.cmd -WorkflowSmokeTest
  runtime\python\python.exe -B tests\smoke_folder_organizer.py
The workflow smoke leaves its small generated fixture under temp/gui-workflow-*.
The Python tests use temporary generated fixtures and remove them on success.

SOURCE-ONLY UPDATE CHECKS - 5 October 2026, Asia/Saigon

85 Python regression tests passed (4.415 seconds), using synthetic media and
mocked AI processes. Eight modified/new PowerShell entrypoints/modules passed
AST syntax validation without execution. The packaged ICO SHA-256 matches its
selected source; multi-resolution structure and portable branding are tested.
Cleanup checks include wrong same-sized files, misleading/malformed JSON,
source/target changes, cache invalidation with restored mtime, target write locks,
bounded preview, exact confirmation tokens, repeat/resume, empty/hardlinked files
and fail-closed behavior on intent/receipt log failures. Fixture recycling moves
only generated files into a temporary quarantine, NOT the Windows Recycle Bin.
CUDA/Vulkan/CPU selection and startup-only fallback were tested with mocks.

NO new GUI/C# compilation, app launch/restart, actual Recycle Bin operation,
font installation, setup downloads or Intel hardware benchmark was performed,
as requested while the original app was in use. The GUI/runtime/native Shell
changes still need a controlled live smoke test when the user permits it.
The older 52-test GUI/inference evidence above predates these source-only changes.
No real photo/video/audio original was processed or removed during these checks.
