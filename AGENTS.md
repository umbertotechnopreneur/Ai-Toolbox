# Ai-Toolbox working rules

- Keep paths relative to the toolbox; support a writable Windows x64 folder on any drive.
- Preserve original media. Default to simulation; use generated fixtures for tests.
- Do not hydrate a whole cloud archive or bundle user input inventories, outputs, logs or preferences.
- Review `KNOWN-ISSUES.md` before changes to cleanup. Never weaken source/target verification to pass a test.
- Setup, font installation, actual recycling and processing real media are separate from source edits and synthetic tests.
- Keep detailed logs independent of selected media directories.
- Missing requested fonts must fall back to an available Windows monospace family.
- Preserve unrelated local files and running jobs. Avoid package builds or app restarts while a user job is running.
- Do not run tests or validation checks, or create branches or worktrees, unless Umberto explicitly requests the specific action. If any of these actions are needed, ask for authorization before proceeding.
- Work on the current branch by default. When tests are authorized, use the embedded interpreter for Python regression tests; validate PowerShell syntax only when validation is authorized.
