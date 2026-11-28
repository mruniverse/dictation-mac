# Dictation Mac

Dictation Mac aims to let you hold a shortcut, speak, release, and get punctuated text in the app you were using. The initial focus is Brazilian Portuguese and English. The MVP prioritizes cloud transcription using an explicit opt-in and the user's API key; local processing remains a separate option.

**Status:** early development; no downloadable release. The menu-bar build has manual Start/Stop and an optional global hold-to-talk shortcut, off at every launch. Manual Stop or its 30 s limit may send only after explicit OpenAI authorization and first-send confirmation; with the shortcut enabled, release before 25 s submits only after authorization, while the deadline discards without sending. Transcripts are previewed/copied explicitly; this build does not type into other apps. [Input selection](https://github.com/mruniverse/dictation-mac/issues/11) is covered by automated tests, but recording with a non-default device still needs a hardware test. No real speech-to-text round trip with the OpenAI API has been verified.

Global hotkey scenarios such as modifier release order and Secure Input still need physical testing. Automated cloud tests use a fake transport.

- [Product roadmap and engineering plan (PT-BR)](docs/plan.md)
- [Cloud transcription: consent, key and status (PT-BR)](docs/cloud-transcription.md)
- [Public backlog](https://github.com/mruniverse/dictation-mac/issues)

## Reproduce the offline smoke test

On macOS, use Python 3, `whisper-cli`, `ffmpeg`, the installed Luciana pt-BR system voice, and a trusted local multilingual whisper.cpp model. Run `python3 Probes/whisper_smoke.py /path/to/ggml-small.bin`. The probe checks exact text and punctuation and confirms one model load per three-clip batch. It creates transient synthetic audio; do not publish those clips. Batch elapsed time is not interactive latency.

One non-negotiable baseline: dictating into a terminal must never run a command on your behalf. This repository is public; a redistribution license has not been selected.
