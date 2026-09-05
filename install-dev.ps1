# DEV-ONLY install of a locally built (test-signed) UnitraMic driver.
# Run ELEVATED. Two-phase because test-signing needs a reboot:
#   1st run -> enable test-signing -> REBOOT
#   2nd run -> trust the build's test cert + install via devcon
#
# Production end users never run this: the shipped driver is Microsoft
# attestation-signed and installed silently by the app. See SIGNING.md.
#
# Uninstall:  devcon remove ROOT\VirtualAudioDriver

$ErrorActionPreference = 'Stop'

$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { Write-Host 'Run as Administrator.' -ForegroundColor Red; exit 1 }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg  = Join-Path $here 'x64\Release\package'
$inf  = Join-Path $pkg 'VirtualAudioDriver.inf'
$sys  = Join-Path $pkg 'VirtualAudioDriver.sys'
if (-not (Test-Path $inf)) {
    Write-Host "No built package at $pkg. Build first:" -ForegroundColor Red
    Write-Host '  msbuild VirtualAudioDriver.sln /p:Configuration=Release /p:Platform=x64'
    exit 1
}

$devcon = (Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Tools' -Recurse `
    -Filter devcon.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $devcon) { Write-Host 'devcon.exe not found (install the WDK).' -ForegroundColor Red; exit 1 }

# Phase 1: test-signing
if (-not (bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes')) {
    Write-Host '== Enabling test-signing ==' -ForegroundColor Cyan
    bcdedit /set testsigning on | Out-Null
    Write-Host 'REBOOT, then run this script again.' -ForegroundColor Yellow
    exit 0
}

# Phase 2: trust the build's embedded test cert, then install
Write-Host '== Trusting build test certificate ==' -ForegroundColor Cyan
$cert = (Get-AuthenticodeSignature $sys).SignerCertificate
if (-not $cert) { Write-Host 'Driver .sys is not signed; check the build.' -ForegroundColor Red; exit 1 }
$cer = Join-Path $env:TEMP 'unitramic-testcert.cer'
[IO.File]::WriteAllBytes($cer, $cert.Export('Cert'))
certutil -addstore -f Root $cer | Out-Null
certutil -addstore -f TrustedPublisher $cer | Out-Null

Write-Host '== Installing (devcon, ROOT devnode) ==' -ForegroundColor Cyan
& $devcon install $inf 'ROOT\VirtualAudioDriver'
if ($LASTEXITCODE -ne 0) { Write-Host "devcon returned $LASTEXITCODE" -ForegroundColor Red; exit 1 }

Start-Sleep -Seconds 2
Get-PnpDevice -FriendlyName '*Unitra*' -ErrorAction SilentlyContinue |
    Format-Table -AutoSize FriendlyName, Status, Class
Write-Host 'Done. Look for the Unitra microphone/speaker in Windows Sound settings.' -ForegroundColor Green
