# Known issues — 6 October 2026

## Intermittent cleanup target-cache invalidation test

During the GUI/font/log redraw update, the first full Python regression run failed `CleanupTests.test_changed_target_with_restored_size_mtime_invalidates_cache`: after changing a retained copy to different bytes and restoring its size/mtime, a subsequent preview reported one match instead of zero. The isolated 23-test cleanup suite and a second full 85-test run passed.

Source mitigation implemented on 6 October: persisted hashes are no longer accepted as content proof, even when size/mtime/change-time/file ID match. SQLite retains locator metadata and hash search hints. A simulation can reuse a freshly calculated hash only while retaining a Windows read handle denying write/delete sharing, bounded to 64 handles and released when that simulation ends. Apply always hashes the retained copy afresh under its held handle, as well as the original. No originals were recycled while implementing or testing this mitigation. GUI copy-only behavior is a separate workflow.

The existing restored-size/mtime regression remains intact. Additional synthetic cases force an identical fingerprint despite changed target bytes, for both preview and apply, and cover locked, same-simulation reuse. All 25 cleanup regressions and the complete 92-test Python suite passed after explicit authorization on 6 October. Tests use synthetic temporary files and a fixture recycler, never the Windows Recycle Bin. These results do not certify physical recycling, all filesystems or real archives.

Evidence: test source `tests/test_cleanup_processed.py`, cache fingerprint and target hash implementation in `scripts/cleanup_processed.py`. Do not weaken or delete the regression test to make the suite pass.

The 25-test cleanup suite also passed 10 consecutive runs after the full-suite pass, targeting the previously intermittent invalidation failure.

## Speech decoder and interrupted recognition

The reported faster-whisper/PyAV `metadata_errors` mismatch is bypassed by decoding local PCM in the application before recognition. Additional source fixes turn library exceptions into individual-file errors rather than aborting the complete run, retain cooperative pause semantics, avoid calling Whisper for an empty audio sample array, and preserve modified SRT files even when the saved status is `no_audio` or `no_speech`.

All five synthetic regressions in `tests/test_transcription_recovery.py` passed, including actual installed PyAV decoding of a generated stereo 48 kHz WAV to mono 16 kHz float32 and a check that recognition receives PCM instead of a filename. Whisper inference itself is mocked in that regression; real-model transcription quality is not verified. No dependencies were installed, no models downloaded and no user media processed during this work.

## Other verification on 6 October

The interrupted-sidecar regression now injects its failure into `folder_organizer.write_sidecar`, the current atomic writer, rather than the unused `ai.write_json` hook. All 34 copy/resume regressions passed. PowerShell parsing passed for the main GUI, settings, path history, cleanup and transcription setup scripts; the native WinForms helpers compiled in Windows PowerShell 5.1. No package build, live-app restart or visual UI inspection was performed.

## Synthetic UI and AI maintenance validation — 6 October 2026

Later source changes add themed owner-drawn ComboBoxes, wider settings-card padding
and background AI inventory/reset. After explicit authorization, the complete
101-test Python suite passed, including nine maintenance regressions using tiny
isolated toolbox replicas. These exercise allowlisted reset, stale confirmation,
protected paths, unsafe links, file locks and active-process guards. The reset
action was deliberately not executed on installed components or real media.

For the reported main-window bouncing/doubled text, `ScrollToCaret` plus outer
scroll restoration was replaced with an inner-log scroll message. A dedicated
viewport suppresses focus-driven scrolling during background updates and invalidates
translated children on user scroll. The changing phase label has stable height;
cleanup matches are accepted only for cleanup workflows.

The GUI fixture exposed another bug: trimming a read-only RichTextBox through
SelectedText did not remove text. Batched log updates now temporarily permit the
internal edit, restore read-only state, bound retained text and repaint once.
The Windows input sound could be related to that rejected edit; its audible
resolution has not been verified in the live app.

The isolated WinForms fixture passed under Windows PowerShell 5.1 using the actual
native helpers and settings controls: Dark/Light pages at 880x720 and 650x560,
combo painting, complete tab captions, font fallback, background inventory and
reset-plan binding against fake components. Thirty large log batches crossed the
trimming threshold while an actually scrolled viewport stayed unchanged. Dark
settings screenshots were inspected. Physical DPI transitions, the user's live
session and real-component reset remain unverified. No live app was restarted,
no package was built and no user media or installed AI component was removed.

## Opt-in video descriptions and missing-subtitle recovery — 6 October 2026

The complete 112-test Python suite passed after explicit authorization while the
user's production instance remained running. Eight video-description regressions
cover duration-based sampling, preserved existing JSON, frame-checkpoint resume,
JSON-only repair without media copying, invalid input, continued processing after
an individual failure, and actual portable FFmpeg extraction from a generated
tiny video. Vision inference is mocked; real-model description quality, latency
and GPU memory use remain unverified. No second real AI backend was started.

Missing completed SRT receipts now permit subtitle-only regeneration; matching
no-audio/no-speech receipts avoid repeated recognition. Added regressions passed.

The extended isolated WinForms fixture passed in Dark/Light, including saving
sampling values into fixture-only configuration, rejecting inverted min/max,
rendering the sampling group at reduced size, actual panel 03 tab parenting and
log retention, plus the existing thirty-batch scroll stability check. Sampling
screenshots were inspected in both themes. PowerShell parsing and git diff
whitespace checks passed. The user's running instance, actual configuration,
installed components and personal media were not changed by these checks.
