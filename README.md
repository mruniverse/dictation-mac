# Dictation Mac

A native macOS dictation app in development. Hold a shortcut, speak, release, and get punctuated text in the app you were using. The initial focus is Brazilian Portuguese and English. The MVP prioritizes cloud transcription using an explicit opt-in and the user's API key; local processing remains a separate option.

**Status:** early development; no downloadable release. The menu-bar build records a clip on explicit Start/Stop (or the automatic stop at 30 s). Cloud transcription requires an OpenAI API key; loading a saved key is a separate, explicit action once per app run. Launching, recording, opening menus and sending never look up or read the Keychain. Sending also requires consent and confirmation of the first upload. Automated cloud tests use fake transport only; there has been no verified speech-to-text round trip against the real API. The latest physical capture opened the system-default line input and captured silence; selecting and testing the active mic is still pending. Text is currently previewed/copied, not inserted into other apps.

- [Product roadmap and engineering plan (PT-BR)](docs/plan.md)
- [Cloud transcription: consent, key and status (PT-BR)](docs/cloud-transcription.md)
- [Public backlog](https://github.com/mruniverse/dictation-mac/issues)

## Reproduce the offline smoke test

On macOS, use Python 3, `whisper-cli`, `ffmpeg`, the installed Luciana pt-BR system voice, and a trusted local multilingual whisper.cpp model. Run `python3 Probes/whisper_smoke.py /path/to/ggml-small.bin`. The probe checks exact text and punctuation and confirms one model load per three-clip batch. It creates transient synthetic audio; do not publish those clips. Batch elapsed time is not interactive latency.

One non-negotiable baseline: dictating into a terminal must never run a command on your behalf. This repository is public; a redistribution license has not been selected.
