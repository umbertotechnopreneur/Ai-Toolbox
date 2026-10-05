# Ai-Toolbox working rules

- Keep paths relative to the toolbox; support a writable Windows x64 folder on any drive.
- Preserve original media. Default to simulation; use generated fixtures for tests.
- Do not hydrate a whole cloud archive or bundle user input inventories, outputs, logs or preferences.
- Review `KNOWN-ISSUES.md` before changes to cleanup. Never weaken source/target verification to pass a test.
- Setup, font installation, actual recycling and processing real media are separate from source edits and synthetic tests.
- Keep detailed logs independent of selected media directories.
- Missing requested fonts must fall back to an available Windows monospace family.
- Preserve unrelated local files and running jobs. Avoid package builds or app restarts while a user job is running.
- Run Python regression tests with the embedded interpreter after setup; validate PowerShell syntax for changed scripts.
