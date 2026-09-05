# UnitraMic — Unitra Virtual Audio Cable

A kernel-mode virtual audio device for [Unitra](https://github.com/unitra-ai).
It exposes a paired **"Unitra Speaker"** (render endpoint) and **"Unitra
Microphone"** (capture endpoint): whatever the app renders to the speaker end
appears at the microphone end. The desktop client speaks synthesized
translations (TTS) to the speaker end over plain WASAPI; the user selects the
**Unitra Microphone** as their input in a game or voice-chat app, so teammates
hear the translation instead of the raw source language.

It does **not** touch the user's physical microphone — it adds a separate
virtual device that the user opts into per-application.

## Why a separate repo

This driver ships to end users as a **Microsoft-attestation-signed** kernel
package, on a signing pipeline (SignPath → Microsoft Partner Center) that is
distinct from the desktop app's release flow. Keeping it in its own repo means:

- driver builds and signs on its own cadence and secrets, without the app's CI;
- the signed `.sys`/`.cat`/`.inf` are consumed by the desktop client's
  installer as a versioned artifact, not rebuilt there;
- the MIT provenance (see `LICENSE` / `THIRD_PARTY_NOTICES.md`) stays clean and
  auditable in one place.

Porting notes and the divergence from the upstream skeletons are in
`README.upstream-notes.md`.

## Layout

| Path | What |
|------|------|
| `Source/` | Driver source (Main adapter, Filters/topology, Utilities/ring buffer) |
| `Package/` | The driver package project (produces `VirtualAudioDriver.inf/.sys/.cat`) |
| `VirtualAudioDriver.sln` | Solution for VS 2022 + WDK |
| `build.bat` | Local build helper |
| `install-dev.ps1` | **Dev-only** install on a test-signed machine (see below) |
| `.github/workflows/build-and-sign.yml` | Build + Microsoft attestation signing |
| `SIGNING.md` | How the signing pipeline is set up (SignPath + Partner Center) |

## Building locally

Requires **Visual Studio 2022** with the *Desktop C++* workload and the
**Windows Driver Kit (WDK)** matching your SDK.

```
msbuild VirtualAudioDriver.sln /p:Configuration=Release /p:Platform=x64
```

Output lands in `x64/Release/package/` (`.inf`, `.sys`, `.cat`). These are
git-ignored — release binaries come from CI, signed.

## Installing

### End users (production)

The desktop app's installer co-installs the **signed** driver silently (one UAC
prompt, no reboot). Nothing to do by hand.

### Developers (unsigned local build)

An unsigned/test-signed driver only loads on a machine in **test-signing mode**.
`install-dev.ps1` (run **as Administrator**) walks the two-phase flow: enable
test-signing → reboot → trust the local test cert → install via `devcon`.

```powershell
# from an elevated PowerShell, after a local Release build:
./install-dev.ps1
```

This path is for development only. See `SIGNING.md` for how production signing
removes the test-signing / reboot requirement entirely.

## License

MIT. This is a port of two MIT projects — **VirtualDrivers/Virtual-Audio-Driver**
and **JannesP/AudioMirror** — see `LICENSE` and `THIRD_PARTY_NOTICES.md`.
