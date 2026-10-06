# Ai-Toolbox · Photo Organizer

Portable Windows photo organizer by [Umberto Giacobbi](https://umbertogiacobbi.biz), with local AI and VibeWare branding.

![VibeWare](assets/branding/vibeware/vibeware-logo.png)

> VibeWare = Human intent, AI, and plenty of tokens ;-)

Process one selected folder into a temporary review workspace. Preserve originals, organize copies from metadata, deduplicate exact bytes with SHA-256, and retain adjacent JSON provenance. Preview, pause/resume and output verification are available in the Italian GUI.

## Start from a source checkout

Windows x64 with Windows PowerShell 5.1, Windows Forms and `curl.exe` is required. Use a writable checkout. GPU drivers are supplied by the machine owner.

```powershell
# From the checkout directory. Prepare runtime dependencies without AI models:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Portable.ps1 -Backend CPU -NoModels

# Open the GUI:
.\Photo-Organizer.cmd
```

For local AI, deliberately run setup with `-Backend Auto` and without `-NoModels`. It downloads pinned models and appropriate runtime packages. Intel GPU Vulkan and CPU modes are available; Intel NPU is not implemented. Dependencies and models are excluded from Git, so a checkout is source, not a ready-to-run binary distribution.

The GUI provides Light/Dark themes, installed/private monospace fonts, a Windows monospace fallback and on-demand setup. Only private application fonts are prepared by default. Optional Windows-user font installation is an explicit choice.

## Workflow

1. Select one source folder and a separate temporary destination.
2. Simulate, then copy/resume when ready. Optional inference stays local.
3. Verify and inspect the destination's `Risultato` folder and `.meta.json` sidecars.
4. Copy the reviewed deliverable into the final archive, preserving provenance when merging batches.

PNG files are not blindly classified as screenshots. Missing capture dates remain undated; filesystem/download timestamps are provenance. Videos and audio, including OPUS, are preserved and inspected with ffprobe where supported.

Panel 04 is a separate bounded cleanup preview/recycling workflow with a persistent SQLite target index. **The target-cache mitigation passed authorized synthetic regressions; real Windows recycling remains untested. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md) for scope and limitations.** Copy-only review is separate from recycling. OneDrive deletions can synchronize to the cloud.

## Development and verification

### Resuming after moving the source folder

When **Copia / Riprendi** encounters a different source root for an existing workspace,
the GUI asks before reporting a mismatch. **Yes** verifies SHA-256 for every completed
original at the new root and its retained output, checks the sidecars, then updates
the checkpoint paths and resumes copying. **No** opens the destination picker;
**Cancel** leaves the workspace unchanged. This verification can hydrate files in
the selected source folder. No original is modified or deleted.

Completed originals must retain their relative paths and byte content. Missing or
different originals, changed outputs/sidecars, or different AI/model settings block
adoption. The tool backs up SQLite state before committing the new root. Sidecars
retain previous source locations and UTC relocation dates; pending sidecar updates
can be recovered after interruption. Unprocessed files continue through the normal
copy workflow; relocation does not certify the entire output as ready for review.
The equivalent explicit CLI mode is `--relocate-source` (with `--allow-cloud` if needed).
Missing or unreadable sidecars (including zero-filled JSON after a PC interruption)
offer a separate confirmation dialog. Recovery verifies completed originals and
retained copies, preserves corrupt bytes under `.photo-organizer/sidecar-recovery`,
backs up SQLite, and regenerates the JSON from checkpoint metadata before resuming.
Approval is bound to the exact damaged-file inventory; changes require another
confirmation. Valid but altered JSON remains protected. CLI approval uses
`--confirm-sidecar-recovery` with the request's confirmation hash.
This feature has not been runtime-tested under the repository's current approval rule.

```powershell
.\Toolbox.cmd test
.\Photo-Organizer.cmd -DialogSmokeTest
.\Photo-Organizer.cmd -WorkflowSmokeTest
```

GUI smoke tests render app-owned windows; workflow tests use generated fixtures. They do not establish whole-archive throughput, clean-machine setup, real Intel inference performance or actual Recycle Bin safety.

See [README.txt](README.txt) for detailed architecture, commands and historical verification records. Options now use Aspetto/Setup tabs with Annulla/Applica at the lower right. Rendering uses buffered panels/shared fonts; the visible log is batched while complete events remain on disk.
Options also include Percorsi and a dedicated **Attività setup** tab. Font/runtime/
speech setup commands select that activity tab automatically; its terminal fills
the available tab area instead of occupying a fixed strip under every page.
Tab headers and surrounding chrome are drawn in application theme colors, with
a cyan selected-tab indicator and native keyboard navigation retained. These
latest layout/theme changes have not been runtime-tested.

## Optional offline audio/video transcription

### Remembered source and destination paths

Editable source/destination ComboBoxes restore the last selections and suggest
separate MRU lists (up to 20 unique paths per list). Folder selection, leaving an
input, starting a workflow and normal exit save local preferences. Paths are not
enumerated or checked for existence during restoration. While a job runs, fields
are read-only without switching to unreadable disabled text.

**Opzioni > Percorsi** allows editing the selections, removing an entry or clearing
either history. **Applica** saves; **Annulla** discards the dialog's path/history
edits. Removing a history entry does not remove a folder; a path used again can
re-enter the MRU. Preferences and backups stay in ignored `config/path-history.json*`;
previous/corrupt preference files are preserved on replacement. Runtime behavior
has not been tested under the current approval rule.

After the current job finishes, open **Opzioni / Setup > Setup > Installa trascrizione**.
The confirmed setup installs faster-whisper 1.2.1 into an isolated toolbox runtime
and downloads the pinned multilingual Whisper small model. No media is processed
during setup; no global Python, PATH, service or driver is changed. Package download
URLs/hashes are retained in the pip installation report, and model hashes in the
local installation receipt. The optional stack is CPU/int8 on Intel or AMD;
CUDA, Intel GPU and NPU acceleration are not implemented for speech recognition.

Enable **Trascrivi audio e video in SRT** and choose **Copia / Riprendi**. Recognition
runs only on verified output copies, including OPUS and the first audio stream of
supported videos, not on original files. Beside `clip.mp4.meta.json`, the tool writes
`clip.mp4.srt` and `clip.mp4.transcription.json`; metadata also links the transcription.
Language is auto-detected and text is transcribed rather than translated. Silent
media produce an empty SRT with `no_speech`/`no_audio` status, not invented dialogue.
Recognition is fallible: subtitles always require human review. There is no speaker
diarization or word-level forced alignment.

Existing copies can be enriched without recopying or rerunning visual AI. Completed
subtitles are resumed only with matching media/config identity and SRT checksum.
Manual/unowned subtitle changes are preserved, not overwritten. Pause is cooperative
between recognition segments; the interrupted file restarts transcription, completed
files are retained. Large-file loading/model initialization may delay pause response.
SRT publication uses a flushed temporary file and a pending receipt for crash recovery.
Speech dependencies/models remain offline during processing; only explicit setup
contacts PyPI/Hugging Face. Application/job logs stay in `logs/photo-organizer`.

CLI: append `--transcribe` to `scripts/folder_organizer.py --run`.
Setup can also be invoked with `Setup-Transcription.ps1`. Runtime behavior of the
source changes was checked with explicitly authorized synthetic regressions; actual
Whisper-model inference and transcription quality remain unverified.

### Settings and cleanup layout

**Opzioni > AI / Models** provides a read-only, copyable terminal inventory on
request: managed model/engine paths, expected releases and installed speech receipt,
package versions, Windows GPU drivers, CPU/RAM, logical component sizes and free
disk space. Enumeration runs in a background child process and does not download
models or scan selected media. Presence is not a checksum/inference certification.

**Nuclearizza...** requires a fresh inventory and two default-No confirmations,
including the exact paths. It permanently removes only allowlisted AI components,
their model/engine download archives and related caches. It preserves the shared
Python runtime, FFmpeg, fonts, Windows drivers, configurations, logs and selected
media/output directories. Links, changed inventory, overlapping selected folders,
and detected active toolbox AI/setup processes refuse reset. Every removal is
logged; a file-lock/error stops the reset and reports partial progress. Reinstall
AI with the explicit setup afterwards. Nine maintenance regressions passed using
isolated synthetic toolbox replicas, including real reset execution on fake
components only. Installed components and personal media were not reset.

Settings separate theme, monospace font, font installation, photo cataloging and
audio/video transcription into spaced groups with short explanations. Recent
sources and destinations remain independent editable histories. Setup output has
its own terminal tab; Applica and Annulla stay outside the scrollable pages.

Main panel 03 separates progress and statistics into **Avanzamento** and the
black, scrollable log into **Registro eventi**. Action buttons remain shared
above the tabs; switching pages does not stop processing or discard log entries.
The actual panel source passed an isolated Dark/Light WinForms fixture: progress
and log have separate parents, the terminal remains black and switching pages
preserves its text. The user's running GUI was not restarted.

With transcription enabled, **Copia / Riprendi** inventories missing SRT files
for registered audio/video outputs, completes copying/verification first, then
processes a deduplicated subtitle queue. Existing SRT files are preserved,
including manual edits and files without a recognition receipt. Missing subtitles
with matching completed receipts are regenerated without recopying media;
matching no-audio/no-speech receipts avoid repeating recognition. Individual
recognition failures remain retryable and do not stop subsequent files. The
added missing-subtitle, preserved-edit and silent-receipt regressions passed.

Panel 04 separates folder selection, simulation, results and confirmed recycling.
The file limit stays beside its label; result headers size to their text and the
table supports both scrollbars. These presentation changes do not change cleanup
verification or authorization. The cache mitigation in `KNOWN-ISSUES.md` passed
synthetic tests; the layout revision does not certify cleanup safety.

Persisted SQLite hashes are search hints, not deletion evidence. Each preview
rechecks candidate contents; repeated matches within that preview reuse hashes
only for copies kept write/delete-locked on Windows (up to 64 retained handles).
Locks are released at the end of the preview. Applying a confirmed plan always
calculates fresh source and target hashes. This trades cross-job hash reuse for
protection against unchanged or restored filesystem timestamps.

The speech decoder passes local mono 16 kHz PCM to Whisper instead of invoking
faster-whisper 1.2.1's filename decoder, whose `metadata_errors` argument is not
accepted by newer PyAV. Existing dependencies are left untouched; no reinstall
is performed automatically. Pause is also honored between decoded audio frames.
Copied media and completed subtitle receipts remain reusable. These source
changes passed the complete 101-test Python suite on 6 October 2026, including a generated
WAV decoded with the installed PyAV runtime. Recognition is mocked in that test;
no personal media or real Windows recycling was exercised. PowerShell parsing
passed and native GUI helpers compiled under Windows PowerShell 5.1. An isolated
GUI fixture passed for Dark/Light settings at normal and reduced sizes, themed
combos, tab captions, font fallback and asynchronous inventory against fake
components. Thirty log batches verified bounded read-only logs and a stable
scrolled viewport. Dark settings screenshots were inspected; physical DPI changes
and the reported sound in the live session remain unverified. The running app
was not restarted and no package was built.

Speech-library failures are recorded per file rather than terminating the entire
batch. Failed recognition is retried on resume without discarding verified copies.
An empty audio sample array bypasses Whisper; changed subtitles remain protected
for complete, no-speech and no-audio receipts alike.

## Optional sampled video descriptions

Enable **Descrivi i video con AI locale** independently of photo AI and SRT
transcription. Configure sampling in **Opzioni > Setup > Descrizione video /
Fotogrammi**. Defaults are 4–24 frames, with count `ceil(duration / 30 seconds)`
clamped to those limits. Limits and seconds per sample are configurable; frames
are evenly distributed at interval midpoints, resized and inferred sequentially.

After copy verification (and optional transcription), missing results are written
beside each video as `video.mp4.video.json`, not inside image metadata. Each JSON
contains duration, actual timestamps, individual English descriptions/tags,
sampling/model identity and explicit sampled-only scope. It does not claim to
describe unseen events or audio. Existing JSON files, including manual edits,
are preserved. Delete a result deliberately only if you want it regenerated on
the next opted-in run; unchanged completed frame checkpoints can reconstruct it
without repeating inference. Media is never recopied just for a missing result.

Frame checkpoints live in `.photo-organizer/video-frames`, outside `Risultato`.
Pause/crash resumes completed frames for matching video/config identities. Changed
sampling/model/prompt identities get independent checkpoints. Corrupt videos,
decoder timeouts and AI failures are logged per video and do not abort the queue.
Only installed portable FFmpeg and the existing local vision engine are used;
there is no automatic dependency installation or online AI fallback. CLI opt-in:
`--run --describe-videos`, optionally `--video-min-frames`, `--video-max-frames`
and `--video-seconds-per-frame`. Verification/simulation never generate results.

After explicit authorization on 6 October 2026, the complete 112-test Python
suite passed. Eight video regressions cover sampling bounds, manual JSON
preservation, interrupted frame checkpoints, JSON-only repair without recopy,
invalid containers, per-video failure isolation and real portable FFmpeg decoding
of a generated tiny video. AI inference is mocked: no second real backend was
started, and description quality with the actual model remains unverified.

The isolated Windows PowerShell 5.1 GUI fixture passed Dark/Light settings at
normal/reduced sizes, actual sampling parameter save and invalid-limit rejection,
panel 03 tabs and thirty bounded log updates with a stable scrolled viewport.
Sampling screenshots were inspected in both themes. Real media, installed models
and the user's already-running instance were left untouched; no package build,
live-app restart, commit or push was performed.

## Repository scope

Only source, tests, portable default configuration, download locks and owned brand assets are published. The allowlist in `.gitignore` excludes runtime, models, downloads, cache, input, outputs, logs, temporary files and local UI preferences. No local photos are removed during repository preparation.

The former third-party folder icon is retained only locally and excluded from Git. The published app icon is derived from the approved VibeWare floppy. This code repository is separate from the [VibeWare press kit](https://github.com/umbertotechnopreneur/VibeWare).

[MIT license](LICENSE) · [Attribution](ATTRIBUTION.md) · [Creator](https://umbertogiacobbi.biz) · [Planned manifesto](https://umbertogiacobbi.biz/vibeware)
