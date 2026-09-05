# Signing & distribution

The UnitraMic driver is kernel-mode. On Windows 10 1607+ (and always with
Secure Boot on) a kernel driver only loads on end-user machines if it carries a
**Microsoft signature** obtained through the **Hardware Dev Center / Partner
Center**. Our own certificate — even an EV cert — is *not* enough on its own; it
is only used to authenticate the submission. So production signing is a
different path from the developer test-signing flow in `install-dev.ps1`.

## The two signing paths

| | Dev (test-signed) | Production (this pipeline) |
|---|---|---|
| Who signs | local WDK test cert | Microsoft (attestation) |
| Loads on other PCs | only in test-signing mode | yes, everywhere |
| Test-signing / reboot | required | **not** required |
| Cert in Root/TrustedPublisher | required | **not** required |
| How installed | `install-dev.ps1` | app installer, silent + one UAC |

We use **attestation signing** (not full WHQL/HLK): for a software-only virtual
audio device it is the right tier — no hardware lab tests, and it does not need
Windows Update distribution.

## Pipeline: SignPath → Microsoft attestation

`.github/workflows/build-and-sign.yml` builds the driver, then on a tag or a
manual run submits the package to **SignPath**, which:

1. signs the submission CAB with the configured code-signing certificate,
2. submits it to the Microsoft attestation portal (Partner Center),
3. returns the Microsoft-signed `.sys` / `.cat` (+ `.inf`), which the workflow
   uploads and attaches to the GitHub release.

### One-time setup

1. **Make the repo public.** SignPath's free **Foundation** program signs
   **open-source** projects only. This repo is MIT (see `LICENSE`), so it
   qualifies — but the free tier requires a public repo. (A paid SignPath plan
   removes that requirement if the driver must stay private.)
2. **Enroll the project with SignPath** (https://signpath.org for Foundation /
   https://signpath.io for commercial). Confirm the plan includes **Windows
   driver attestation signing**, not just Authenticode — this is the one thing
   to verify before relying on the free tier.
3. **Link Microsoft Partner Center.** Attestation requires a Partner Center
   (Hardware) account; SignPath submits on its behalf. If SignPath Foundation
   provides the certificate, follow their Partner Center linking guide;
   otherwise supply an **EV code-signing certificate** for SignPath to use.
4. **Create the SignPath project + artifact configuration + signing policy.**
   The artifact configuration describes the driver package (`.sys`+`.inf`+
   `.cat`); the signing policy is the attestation policy.
5. **Add repo secrets / variables** (Settings → Secrets and variables →
   Actions):

   | Kind | Name | Value |
   |------|------|-------|
   | secret | `SIGNPATH_API_TOKEN` | SignPath CI user API token |
   | var | `SIGNPATH_ORGANIZATION_ID` | organization GUID |
   | var | `SIGNPATH_PROJECT_SLUG` | e.g. `unitra-mic` |
   | var | `SIGNPATH_SIGNING_POLICY_SLUG` | attestation policy, e.g. `release-signing` |
   | var | `SIGNPATH_ARTIFACT_CONFIG_SLUG` | driver artifact config slug |

   Until `SIGNPATH_ORGANIZATION_ID` is set, the `sign` job is skipped and CI
   just builds — safe to merge the pipeline before the account exists.

### Cutting a signed release

```
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds, signs via attestation, and attaches the signed package to
the `v0.1.0` GitHub release.

## Consuming the signed driver from the desktop client

The desktop client should **not** rebuild the driver. It pulls a pinned signed
release (the `UnitraMic-signed-x64` artifact / release asset) and its installer
runs, elevated:

```
pnputil /add-driver VirtualAudioDriver.inf /install
```

Because it is a root-enumerated software device, creating the devnode uses
`devcon install ... ROOT\VirtualAudioDriver` (or the `SwDeviceCreate` API). No
test-signing, no reboot — the Microsoft signature is trusted out of the box.

## Status / TODO

- [ ] Make repo public (required for SignPath Foundation)
- [ ] Enroll SignPath project; confirm **driver attestation** is included
- [ ] Link Partner Center (or provide EV cert to SignPath)
- [ ] Add the secrets/vars above
- [ ] Wire the desktop installer to fetch + install the signed release
