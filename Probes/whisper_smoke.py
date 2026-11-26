"""Local pt-BR Whisper smoke. Requires whisper-cli, ffmpeg and macOS voice Luciana."""
import argparse
import re
import subprocess
import tempfile
import time
from pathlib import Path

PHRASES = (
    "A reunião começa amanhã.",
    "Você pode revisar o relatório?",
    "Que ótima notícia!",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    args = parser.parse_args()
    model = args.model.expanduser().resolve(strict=True)
    if not model.is_file():
        parser.error("model must be a regular file")
    with tempfile.TemporaryDirectory(prefix="dictation-smoke-") as directory:
        root = Path(directory)
        wavs = []
        for i, phrase in enumerate(PHRASES):
            aiff, wav = root / f"{i}.aiff", root / f"{i}.wav"
            subprocess.run(["say", "-v", "Luciana", "-o", str(aiff), phrase],
                           check=True, timeout=30)
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(aiff),
                            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)],
                           check=True, timeout=30)
            wavs.append(str(wav))
        for run in range(1, 4):
            started = time.monotonic()
            result = subprocess.run(
                ["whisper-cli", "-ng", "-t", "4", "-l", "pt", "-m", str(model), "-nt", *wavs],
                check=True, timeout=120, capture_output=True, text=True,
            )
            elapsed = time.monotonic() - started
            actual = tuple(line.strip() for line in result.stdout.splitlines() if line.strip())
            if actual != PHRASES:
                raise SystemExit(f"Batch {run}: expected {PHRASES!r}, got {actual!r}")
            matches = re.findall(r"load time\s*=\s*([\d.]+) ms", result.stderr)
            loads = result.stderr.count("loading model from")
            if loads != 1 or len(matches) != 1:
                raise SystemExit(f"Batch {run}: expected one model load, got {loads}")
            print(f"Batch {run}: {len(actual)}/{len(PHRASES)} exact; wall {elapsed:.2f} s; model load {matches[0]} ms", flush=True)


if __name__ == "__main__":
    main()
