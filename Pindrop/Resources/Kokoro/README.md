# Kokoro TTS bundled assets

These two files are bundled into `NautPin.app` (well, `Pindrop.app` until target rename) at build time and loaded by `KokoroSwift` at runtime. They are **gitignored** because the model weights file is too big for direct Forgejo / GitHub commit.

## Files

| File | Size | Source | Purpose |
|---|---|---|---|
| `kokoro-v1_0.safetensors` | ~312 MB | [`prince-canuma/Kokoro-82M`](https://huggingface.co/prince-canuma/Kokoro-82M) on HuggingFace | Kokoro-82M model weights (bf16 safetensors) |
| `voices.npz` | ~14 MB | [`mlalma/KokoroTestApp`](https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz) git-lfs | Voice style embeddings — 28 English voices bundled into one npz |

## Fresh-checkout setup

On a clean clone (single command):

```bash
just fetch-kokoro
```

Or manually:

```bash
mkdir -p Pindrop/Resources/Kokoro
curl -L -o Pindrop/Resources/Kokoro/kokoro-v1_0.safetensors \
  "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors"
curl -L -o Pindrop/Resources/Kokoro/voices.npz \
  "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz"
```

Then build normally with `just build`.

## Voices included

American Female (af_*): heart, bella, nicole, aoede, kore, sarah, nova, sky, alloy, jessica, river
American Male (am_*): michael, fenrir, puck, echo, eric, liam, onyx, santa, adam
British Female (bf_*): emma, isabella, alice, lily
British Male (bm_*): george, fable, lewis, daniel

28 English voices total. No German voices in Kokoro base pack — German text is routed to Apple's `AVSpeechSynthesizer` (Anna, Markus, etc.) by `TTSEngineRouter`.

## License

The Kokoro-82M model weights are released under Apache 2.0 by [@hexgrad](https://huggingface.co/hexgrad/Kokoro-82M). Voice style files derived from the same release.
