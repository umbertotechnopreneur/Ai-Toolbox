# Attribution

Creator: [Umberto Giacobbi](https://umbertogiacobbi.biz). Original project source is licensed under [MIT](LICENSE).

VibeWare = Human intent, AI, and plenty of tokens ;-)

OpenAI Codex assisted implementation, review and documentation in this workflow. This does not assert that every contribution was individually reviewed or that AI output is guaranteed correct. Other contributors may use different AI tools and models.

## Branding

The approved VibeWare floppy artwork is copied from the creator's [VibeWare brand project](https://github.com/umbertotechnopreneur/VibeWare). The app icon is derived from that artwork by `scripts/Build-VibeWareIcon.ps1`. See `assets/branding/vibeware/PROMPTS.md` for the original visual-generation prompts. MIT does not grant trademark rights.

The historical third-party blue folder icon is excluded from Git; public redistribution permission for it was not established.

## Dependencies downloaded by setup

Dependency binaries and models are not stored in this source repository. Their own copyright and license terms apply independently of this project's MIT license. Preserve package license files when redistributing a prepared portable installation.

- [Python](https://www.python.org/) — embedded Windows runtime.
- [Pillow](https://pillow.readthedocs.io/) — image metadata and previews.
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — local inference engine.
- [Qwen3-VL-4B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF) — vision/language model and projector.
- [FFmpeg](https://ffmpeg.org/) and the [Gyan Windows builds](https://www.gyan.dev/ffmpeg/builds/) — ffprobe metadata extraction; inspect the downloaded build's license/configuration before redistribution.
- [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) / [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) — optional private monospace fonts. Setup retains their downloaded license notices.

Exact package URLs, versions and integrity values are recorded in `config/downloads.lock.json` and `config/fonts.lock.json`.

Planned manifesto URL: https://umbertogiacobbi.biz/vibeware. Its publication is not confirmed by this repository.
