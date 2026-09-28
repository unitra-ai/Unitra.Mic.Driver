<#
.SYNOPSIS
  Turn the Microsoft-signed package downloaded from Partner Center into the
  GitHub release asset the desktop client bundles.

.DESCRIPTION
  Partner Center hands back a zip with the attestation-signed driver
  (Microsoft-signed .sys + regenerated .cat + the .inf). This script

    1. extracts it and verifies, with signtool, that the .sys passes the
       KERNEL-MODE policy (/kp) and that the catalog validates it -- the same
       gate the desktop client's fetch script applies, so a wrong file can
       never be published;
    2. packs VirtualAudioDriver.inf/.sys + virtualaudiodriver.cat into
       UnitraMic-signed-x64.zip;
    3. creates (or updates) the GitHub release for -Tag and uploads the asset.

  The desktop client pins the tag in scripts/fetch-unitra-mic-driver.ps1
  ($PinnedTag) and bundles the asset into every installer.

.PARAMETER SignedZip
  The zip downloaded from the Partner Center submission page.

.PARAMETER Tag
  Release tag, e.g. v0.1.0. Must match the INF DriverVer's version.

.PARAMETER Repo
  GitHub repo. Default unitra-ai/Unitra.Mic.Driver.

.PARAMETER DryRun
  Verify and pack, but do not touch GitHub.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string]$SignedZip,
  [Parameter(Mandatory = $true)] [string]$Tag,
  [string]$Repo = 'unitra-ai/Unitra.Mic.Driver',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe not found (Windows SDK); cannot verify the Microsoft signature' }

$work = Join-Path $dist ("signed-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  Expand-Archive -Path $SignedZip -DestinationPath $work -Force
  $inf = Get-ChildItem $work -Recurse -Filter 'VirtualAudioDriver.inf' | Select-Object -First 1
  $sys = Get-ChildItem $work -Recurse -Filter 'VirtualAudioDriver.sys' | Select-Object -First 1
  $cat = Get-ChildItem $work -Recurse -Filter '*.cat' | Select-Object -First 1
  if (-not ($inf -and $sys -and $cat)) { throw 'zip does not contain VirtualAudioDriver.inf + .sys + a .cat' }

  # ---- the gate: kernel-mode policy ---------------------------------------
  & $signtool.FullName verify /kp /v $sys.FullName 2>&1 | Where-Object { $_ -match 'Issued to|Issued by|Successfully|Error' } | ForEach-Object { Write-Host "  $_" }
  if ($LASTEXITCODE -ne 0) { throw "$($sys.Name) does NOT pass signtool verify /kp: this is not an attestation-signed driver" }
  & $signtool.FullName verify /kp /q /c $cat.FullName $sys.FullName
  if ($LASTEXITCODE -ne 0) { throw "catalog $($cat.Name) does not validate $($sys.Name) under the kernel policy" }
  $issuer = (& $signtool.FullName verify /kp /v $sys.FullName 2>&1 | Select-String 'Issued by:' | Select-Object -First 1)
  if ($issuer -and $issuer -notmatch 'Microsoft') {
    throw "unexpected signer on $($sys.Name): $issuer"
  }

  # ---- DriverVer vs tag ----------------------------------------------------
  $ver = (Select-String -Path $inf.FullName -Pattern '^\s*DriverVer\s*=\s*[^,]+,\s*([0-9.]+)' | Select-Object -First 1)
  $infVersion = if ($ver) { $ver.Matches[0].Groups[1].Value } else { '?' }
  Write-Host "INF DriverVer version: $infVersion  (tag $Tag)"
  $tagVersion = $Tag.TrimStart('v')
  if ($infVersion -ne '?' -and -not $infVersion.StartsWith($tagVersion)) {
    Write-Warning "tag $Tag does not match INF version $infVersion -- publishing anyway; bump one of them if this was not intended"
  }

  # ---- asset --------------------------------------------------------------
  $stage = Join-Path $work 'UnitraMic-signed-x64'
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Copy-Item $inf.FullName (Join-Path $stage 'VirtualAudioDriver.inf')
  Copy-Item $sys.FullName (Join-Path $stage 'VirtualAudioDriver.sys')
  Copy-Item $cat.FullName (Join-Path $stage 'virtualaudiodriver.cat')
  $asset = Join-Path $dist 'UnitraMic-signed-x64.zip'
  if (Test-Path $asset) { Remove-Item $asset -Force }
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $asset
  $sha = (Get-FileHash $asset -Algorithm SHA256).Hash
  Write-Host "asset: $asset"
  Write-Host "sha256: $sha"
  Set-Content -Path "$asset.sha256" -Value "$sha  UnitraMic-signed-x64.zip"

  if ($DryRun) { Write-Host 'Dry run: not publishing.'; return }

  # ---- release ------------------------------------------------------------
  & gh release view $Tag --repo $Repo *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating release $Tag"
    & gh release create $Tag --repo $Repo --title "UnitraMic $Tag" `
      --notes "Microsoft attestation-signed UnitraMic virtual audio driver (INF DriverVer $infVersion). Verified with signtool verify /kp." `
      $asset "$asset.sha256"
  } else {
    Write-Host "Uploading to existing release $Tag"
    & gh release upload $Tag --repo $Repo --clobber $asset "$asset.sha256"
  }
  if ($LASTEXITCODE -ne 0) { throw "gh release failed ($LASTEXITCODE)" }
  Write-Host "Published. Next: bump `$PinnedTag in the desktop client's scripts/fetch-unitra-mic-driver.ps1 to $Tag and set repo var UNITRA_REQUIRE_MIC_DRIVER=1."
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
