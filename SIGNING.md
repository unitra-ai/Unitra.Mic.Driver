# Signing & distribution

The UnitraMic driver is kernel-mode. On Windows 10 1607+ (and always with
Secure Boot on) a kernel driver only loads on end-user machines if it carries a
**Microsoft signature** obtained through **Partner Center attestation**. Our
own EV certificate is *not* enough on its own; it authenticates the submission.
Production signing is therefore a different path from the developer
test-signing flow in `install-dev.ps1`.

## The two signing paths

| | Dev (test-signed) | Production |
|---|---|---|
| Who signs | local WDK test cert | Microsoft (attestation) |
| Loads on other PCs | only in test-signing mode | yes, everywhere |
| Test-signing / reboot | required | **not** required |
| Cert in Root/TrustedPublisher | required | **not** required |
| How installed | `install-dev.ps1` / the desktop app's dev rule set | the desktop app, one UAC prompt |

Attestation (not full WHQL/HLK) is the right tier for a software-only virtual
audio device: no hardware lab tests, and we do not need Windows Update
distribution (the desktop app bundles the package).

## What we have (2026-09-28)

- **EV code-signing certificate**: SSL.com, order `co-f41lb40n352`, subject
  `O=UNITRA INC.` (Falls Church, VA; DUNS-matched), RSA-3072, valid
  2026-09-28 -> 2027-09-28, key held in **SSL.com eSigner** (cloud HSM). No
  token, no key on any machine. Signing = SSL.com CodeSignTool with the
  account user name / password / credential id / TOTP secret.
- **Partner Center**: Hardware Developer Program enrollment for
  UNITRA INC. (sellerId 96070610) submitted 2026-09-13 via zhen@unitra.ai.
  Blocked on two Microsoft-side steps until now: business verification, and
  **Manage certificates** (upload a `.bin` signed with the EV cert). Both are
  in the runbook below.

## Pipeline

```
push / tag  ->  build (windows-2022, WDK 26100 preinstalled)
            ->  x64\Release\package + .pdb
            ->  dist\UnitraMic.cab           (make-attestation-cab.ps1)
            ->  EV-signed CAB via eSigner    (sslcom/esigner-codesign)   [needs vars.ESIGNER_ENABLED]
            ->  artifact + DRAFT release on tags
human       ->  Partner Center: Submit new hardware, upload the EV-signed CAB
            ->  download the Microsoft-signed package
            ->  scripts/publish-signed-release.ps1  (signtool /kp gate, GitHub release asset)
desktop app ->  scripts/fetch-unitra-mic-driver.ps1 pins the tag, bundles the asset,
                installs it from Settings with one UAC prompt (crates/unitra-mic-setup)
```

`.github/workflows/build-and-sign.yml` is the CI half. Everything Partner
Center-facing is a portal action; the Hardware Dashboard API can automate it
later, once the first signed release exists.

### Repo configuration

| Kind | Name | Value |
|------|------|-------|
| var | `ESIGNER_ENABLED` | `true` once the four secrets exist |
| secret | `ES_USERNAME` | SSL.com account user name |
| secret | `ES_PASSWORD` | SSL.com account password |
| secret | `ES_CREDENTIAL_ID` | eSigner credential id (`scripts/esigner-sign.ps1 -Credentials`) |
| secret | `ES_TOTP_SECRET` | eSigner TOTP secret (shown once at eSigner enrollment) |

Until `ESIGNER_ENABLED` is set the `sign` job is skipped and CI only builds.

## Runbook: first signed release

Everything that touches an account is done by the account holder; the scripts
read credentials from the environment and never print them.

1. **Enroll the certificate in eSigner** (SSL.com account, order
   `co-f41lb40n352` -> *eSigner* -> enroll). Choose a signing PIN, scan the
   TOTP QR in an authenticator app **and keep the TOTP secret text**: it is
   `ES_TOTP_SECRET`. Then get the credential id:
   ```powershell
   $env:ES_USERNAME='...'; $env:ES_PASSWORD='...'
   pwsh scripts/esigner-sign.ps1 -Credentials
   ```
2. **Partner Center -> Manage certificates.** Download the signable `.bin`
   from https://partner.microsoft.com/en-us/dashboard/account/v3/managecertificates,
   sign it, upload the signed copy:
   ```powershell
   $env:ES_CREDENTIAL_ID='...'; $env:ES_TOTP_SECRET='...'   # or answer the OTP prompt
   pwsh scripts/esigner-sign.ps1 .\Signable.bin
   ```
   This is what ties the EV certificate to the Partner Center account. It
   needs business verification to be complete (Account settings -> Legal
   info -> Vetting).
3. **Build + pack + EV-sign the submission** (CI on a tag does the same):
   ```powershell
   pwsh scripts/build-release.ps1
   pwsh scripts/make-attestation-cab.ps1          # -> dist\UnitraMic.cab
   pwsh scripts/esigner-sign.ps1 .\dist\UnitraMic.cab   # -> dist\signed\UnitraMic.cab
   ```
4. **Submit**: Partner Center -> Hardware -> *Submit new hardware*. Product
   name `UnitraMic <version>`, upload `dist\signed\UnitraMic.cab`, leave both
   test-signing boxes unchecked, requested signatures: **Windows 10 x64
   (19041 and later)** and **Windows 11 x64** -- the INF's
   `NT$ARCH$.10.0...19041` decoration covers both; missing Windows 11 here is
   how the upstream fork shipped Win11-only. Submit. Typical turnaround is
   minutes to a few hours.
5. **Publish**: download the signed package from the submission page and
   ```powershell
   pwsh scripts/publish-signed-release.ps1 -SignedZip .\<download>.zip -Tag v0.1.0
   ```
   The script refuses anything that does not pass `signtool verify /kp`
   (kernel-mode policy), packs `UnitraMic-signed-x64.zip`, and creates the
   GitHub release.
6. **Desktop client**: bump `$PinnedTag` in
   `scripts/fetch-unitra-mic-driver.ps1` to the tag, set the repo variable
   `UNITRA_REQUIRE_MIC_DRIVER=1` so a missing asset fails a release build, and
   ship. The app's release rule set (`crates/unitra-mic-setup`) installs only
   Microsoft-signed packages, so a wrong asset cannot reach a user's kernel.

### Subsequent releases

Bump `DriverVer` (stampinf does it from the build date + version in the
project), tag `vX.Y.Z`, let CI produce the EV-signed CAB (draft release), do
steps 4-6.

## Consuming the signed driver from the desktop client

The desktop client never rebuilds the driver. `scripts/fetch-unitra-mic-driver.ps1`
downloads the `UnitraMic-signed-x64` asset of the pinned tag, verifies it with
`signtool verify /kp`, and stages it under `resources/drivers/UnitraMic/` for
bundling. At run time `unitra-mic-setup.exe` (elevated, one UAC prompt)
classifies the package signature again, refuses anything but a Microsoft
signature in release builds, and installs it with SetupDi/newdev: root-
enumerated software device, no test-signing, no reboot.

## Decision record (2026-09-05): first-class, own attestation-signed driver

Chosen after ruling out the alternatives:

- **No driverless path.** Windows has a user-mode virtual *camera* framework
  but no virtual-*microphone* equivalent; a system-visible mic endpoint needs
  a kernel driver. Injecting into the real mic needs a capture APO, itself a
  signed, INF-installed driver component.
- **The app's cert doesn't transfer.** The desktop app is signed with Azure
  Trusted Signing, which cannot sign kernel drivers and is not an EV
  substitute for Partner Center.
- **Free SignPath Foundation is not enough.** It issues OV/Authenticode only;
  kernel attestation needs an EV cert. (The upstream fork parent uses it and
  still ships "requires test signing".)
- **Cloud EV over a token.** eSigner issues in days, needs no courier, and
  drives CI directly; a YubiKey cannot serve GitHub-hosted runners.
