# UnitraMic — Unitra Virtual Audio Cable

In-kernel "Unitra Speaker" → "Unitra Microphone" cable: the app renders TTS
to the speaker end over plain WASAPI, games select the microphone end. No
user-mode driver API, no IOCTLs.

Port of two MIT projects (upstream attribution in `LICENSE` and
`THIRD_PARTY_NOTICES.md`):

- **VirtualDrivers/Virtual-Audio-Driver** — the SYSVAD-derived skeleton
  (endpoints, topology, WaveRT plumbing). Its public tree deliberately
  ships no loopback: the mic fills silence, render audio goes to a debug
  file sink gated OFF by default.
- **JannesP/AudioMirror** — the render→capture ring design
  (`Source/Utilities/RingBuffer.*`, stream pairing).

This is the SECOND execution of the port — the first (2026-08-18, built
clean, packaged, test-signed) lived only in a session scratchpad and was
lost to temp cleanup; only its built `.sys` survives
(`L:\GitHub\vmic-recovered\`). Hence in-tree this time.

## What the port changes (vs. the VAD skeleton)

- `Source/Utilities/RingBuffer.{h,cpp}` — AudioMirror's ring with three
  donor bugs fixed: `Put()` ran lockless against `Take()`; `Put()` never
  advanced its source pointer across a wrap (duplicated packet heads);
  overrun recovery advanced the read position by +1 byte, breaking frame
  alignment. The donor's dead byte-align staging path is dropped.
- `minwavertstream.*` — capture `WriteBytes` fills from the ring
  (silence for whatever the ring can't supply); render `ReadBytes` feeds
  the paired stream's ring; the `g_DoNotCreateDataFiles` gate that kept
  the render read path from ever running in a default install is removed
  from the loopback path (the file sink stays behind it).
- `minwavert.*` — capture streams are now cached in `m_SystemStreams`
  too (stock code tracked render only), and stream open/close wires or
  severs the pairing when each side has exactly one system stream.
- `adapter.cpp` — grabs both wave miniports during install and calls
  `SetPairedMiniport` once both endpoints exist.
- Synchronization: every `ReadBytes`/`WriteBytes` already runs under its
  stream's `m_PositionSpinLock`; unpairing takes the same lock, so a
  teardown can never race a paired DPC into freed memory. The ring is
  freed only after `ExDeleteTimer` + `KeFlushQueuedDpcs`.
- Format pinned to **48 kHz / 16-bit / stereo** on both ends
  (`speakerwavtable.h`, `micarraywavtable.h`) — no kernel SRC, and the
  ring is a byte pipe that must carry one format. The mic exposes the
  format in both RAW and DEFAULT processing modes.
- INF: OS decoration `NT$ARCH$.10.0...19041` (Win10 2004+ **and** Win11 —
  upstream's `...22000` was Win11-only), endpoints renamed
  "Unitra Speaker" / "Unitra Microphone", provider "Unitra".

## Build

VS2022 + WDK (`winget install Microsoft.WindowsWDK.10.0.22621`; the
standalone WDK.vsix is too old for VS2022 17.11+ — add the toolset as a VS
component: `vs_installer modify --add Component.Microsoft.Windows.DriverKit`).

```
msbuild VirtualAudioDriver.sln /p:Configuration=Release /p:Platform=x64 /p:SpectreMitigation=false
```

Output: `x64/Release/package/` (`.sys` + `.inf` + `.cat`, auto
test-signed by the WDK build).

## Load testing — Track C PASSED (2026-09-04)

Executed on a Gen2 Hyper-V VM (Win11 Pro 26200, Secure Boot off,
testsigning pre-armed in the offline BCD before first boot; provisioning
was fully scripted — DISM-apply the ISO's install.wim to a VHDX, inject
unattend + payload, no interactive setup). Results:

- `devcon install VirtualAudioDriver.inf ROOT\VirtualAudioDriver` →
  **Driver is running**, endpoints appear as
  "Speakers (Unitra Virtual Audio Cable)" /
  "Microphone Array (Unitra Virtual Audio Cable)".
- `tools/vmic-harness`: 1 kHz render → capture at **117.8 dB SNR**, rms
  0.35355 (= a 0.5-amplitude sine exactly — the cable is bit-exact),
  first-audio latency **~71 ms** (both WASAPI engine buffers + the ring's
  half-full priming), reproducible across runs. Both endpoints negotiated
  48 kHz stereo shared-mode.
- PnP install in test-signing mode still needs the signing cert in the
  machine Root + TrustedPublisher stores (export it from the .sys's
  Authenticode signature) or devcon fails on publisher trust.

Cosmetic follow-up: the MMDevice display names compose as
"<form factor> (<DeviceDesc>)" rather than the INF's KS FriendlyName —
if "Unitra Speaker"/"Unitra Microphone" are wanted verbatim, set the
endpoint names via the interface AddReg (`EP\0` properties).

A test-signed driver will not load with Secure Boot on. Production
requires EV cert + Microsoft attestation signing (select BOTH the 19041
and Win11 targets in Partner Center). Windows Sandbox cannot load kernel
drivers at all (no BCD store — verified empirically 2026-08-18).

See `docs/tts/VIRTUAL_MIC_VALIDATION.md` at the repo root for the full
validation record this port re-implements.
