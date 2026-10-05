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

Panel 04 is a separate bounded cleanup preview/recycling workflow with a persistent SQLite target index. **An intermittent target-cache invalidation regression remains open; see [KNOWN-ISSUES.md](KNOWN-ISSUES.md) before recycling real originals.** Copy-only review is separate from recycling. OneDrive deletions can synchronize to the cloud.

## Development and verification

```powershell
.\Toolbox.cmd test
.\Photo-Organizer.cmd -DialogSmokeTest
.\Photo-Organizer.cmd -WorkflowSmokeTest
```

GUI smoke tests render app-owned windows; workflow tests use generated fixtures. They do not establish whole-archive throughput, clean-machine setup, real Intel inference performance or actual Recycle Bin safety.

See [README.txt](README.txt) for detailed architecture, commands and historical verification records. Options now use Aspetto/Setup tabs with Annulla/Applica at the lower right. Rendering uses buffered panels/shared fonts; the visible log is batched while complete events remain on disk.

## Repository scope

Only source, tests, portable default configuration, download locks and owned brand assets are published. The allowlist in `.gitignore` excludes runtime, models, downloads, cache, input, outputs, logs, temporary files and local UI preferences. No local photos are removed during repository preparation.

The former third-party folder icon is retained only locally and excluded from Git. The published app icon is derived from the approved VibeWare floppy. This code repository is separate from the [VibeWare press kit](https://github.com/umbertotechnopreneur/VibeWare).

[MIT license](LICENSE) · [Attribution](ATTRIBUTION.md) · [Creator](https://umbertogiacobbi.biz) · [Planned manifesto](https://umbertogiacobbi.biz/vibeware)
