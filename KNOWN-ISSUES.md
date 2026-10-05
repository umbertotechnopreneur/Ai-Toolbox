# Known issues — 5 October 2026

## Intermittent cleanup target-cache invalidation test

During the GUI/font/log redraw update, the first full Python regression run failed `CleanupTests.test_changed_target_with_restored_size_mtime_invalidates_cache`: after changing a retained copy to different bytes and restoring its size/mtime, a subsequent preview reported one match instead of zero. The isolated 23-test cleanup suite and a second full 85-test run passed.

This intermittent failure remains unresolved. Investigate Windows change-time/fingerprint granularity and hash-cache reuse before relying on Panel 04 to recycle real originals. No real originals were recycled during these checks. GUI copy-only behavior is a separate workflow.

Evidence: test source `tests/test_cleanup_processed.py`, cache fingerprint and target hash implementation in `scripts/cleanup_processed.py`. Do not weaken or delete the regression test to make the suite pass.
