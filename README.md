# Dictation Mac

A native macOS dictation app in development. Hold a shortcut, speak, release, and get punctuated text in the app you were using. The initial focus is Brazilian Portuguese and English. The MVP prioritizes cloud transcription using an explicit opt-in and the user's API key; local processing remains a separate option.

**Status:** early development; no downloadable release. The menu-bar build records a clip on explicit Start/Stop (or the automatic stop at 30 s) and, only after you store your own OpenAI API key in the Keychain, authorize sending and confirm the first upload, sends it for transcription. That cloud path is covered by automated tests with fakes only; it has not yet been exercised against the real API.

- [Product roadmap and engineering plan (PT-BR)](docs/plan.md)
- [Cloud transcription: consent, key and status (PT-BR)](docs/cloud-transcription.md)
- [Public backlog](https://github.com/mruniverse/dictation-mac/issues)

## Reproduce the offline smoke test

On macOS, use Python 3, `whisper-cli`, `ffmpeg`, the installed Luciana pt-BR system voice, and a trusted local multilingual whisper.cpp model. Run `python3 Probes/whisper_smoke.py /path/to/ggml-small.bin`. The probe checks exact text and punctuation and confirms one model load per three-clip batch. It creates transient synthetic audio; do not publish those clips. Batch elapsed time is not interactive latency.

One non-negotiable baseline: dictating into a terminal must never run a command on your behalf. This repository is public; a redistribution license has not been selected.
