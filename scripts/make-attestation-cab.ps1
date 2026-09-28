<#
.SYNOPSIS
  Pack the built driver into the CAB that Partner Center attestation signing takes.

.DESCRIPTION
  Microsoft's submission format (learn.microsoft.com, "Attestation sign
  Windows drivers"): one CAB, no files at the root, one sub-folder per driver
  package containing the .inf, the .sys, the .pdb (used by Microsoft's crash
  analysis) and the .cat (used for company verification only -- Microsoft
  regenerates it). Built with MakeCab from a DDF; paths must be drive-letter
  paths, never UNC.

  The CAB this produces is UNSIGNED. Sign it with the EV certificate
  (scripts/esigner-sign.ps1) before uploading it to Partner Center.

.PARAMETER PackageDir
  Directory with VirtualAudioDriver.{inf,sys} + virtualaudiodriver.cat.
  Default: x64\Release\package.

.PARAMETER PdbPath
  Path to VirtualAudioDriver.pdb. Default: the first one under x64\Release.

.PARAMETER OutDir
  Where UnitraMic.cab is written. Default: dist\.

.OUTPUTS
  The full path of the CAB.
#>
[CmdletBinding()]
param(
  [string]$PackageDir,
  [string]$PdbPath,
  [string]$OutDir,
  [string]$CabName = 'UnitraMic.cab',
  # Folder name inside the CAB; Partner Center shows it as the package name.
  [string]$FolderName = 'UnitraMic'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $PackageDir) { $PackageDir = Join-Path $root 'x64\Release\package' }
if (-not $OutDir)     { $OutDir = Join-Path $root 'dist' }
if (-not $PdbPath) {
  $PdbPath = (Get-ChildItem (Join-Path $root 'x64\Release'), (Join-Path $root 'Source\Main\x64\Release') `
    -Filter 'VirtualAudioDriver.pdb' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
$PackageDir = (Resolve-Path $PackageDir).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$inf = Join-Path $PackageDir 'VirtualAudioDriver.inf'
$sys = Join-Path $PackageDir 'VirtualAudioDriver.sys'
$cat = Get-ChildItem $PackageDir -Filter '*.cat' | Select-Object -First 1
foreach ($p in $inf, $sys) { if (-not (Test-Path $p)) { throw "missing $p" } }
if (-not $cat) { throw "no .cat in $PackageDir" }
if (-not $PdbPath -or -not (Test-Path $PdbPath)) { throw "VirtualAudioDriver.pdb not found (build first)" }
foreach ($p in $PackageDir, $OutDir, $PdbPath) {
  if ($p -like '\\*') { throw "MakeCab rejects UNC paths: $p" }
}

# The INF is the contract Microsoft reads; print the version we are about to
# submit so a stale build is caught before it costs a submission slot.
$ver = (Select-String -Path $inf -Pattern '^\s*DriverVer\s*=\s*(.+)$' | Select-Object -First 1)
if ($ver) { Write-Host "DriverVer: $($ver.Matches[0].Groups[1].Value.Trim())" }

$ddf = Join-Path $OutDir 'UnitraMic.ddf'
@"
; UnitraMic attestation submission
.OPTION EXPLICIT
.Set CabinetFileCountThreshold=0
.Set FolderFileCountThreshold=0
.Set FolderSizeThreshold=0
.Set MaxCabinetSize=0
.Set MaxDiskFileCount=0
.Set MaxDiskSize=0
.Set CompressionType=MSZIP
.Set Cabinet=on
.Set Compress=on
.Set CabinetNameTemplate=$CabName
.Set DiskDirectoryTemplate=$OutDir
.Set DestinationDir=$FolderName
"$inf"
"$sys"
"$($cat.FullName)"
"$PdbPath"
"@ | Set-Content -Path $ddf -Encoding ASCII

$cabPath = Join-Path $OutDir $CabName
if (Test-Path $cabPath) { Remove-Item $cabPath -Force }
Push-Location $OutDir
try {
  & makecab.exe /F $ddf
  if ($LASTEXITCODE -ne 0) { throw "makecab failed ($LASTEXITCODE)" }
} finally { Pop-Location }
# MakeCab leaves setup.inf / setup.rpt next to the CAB.
Remove-Item (Join-Path $OutDir 'setup.inf'), (Join-Path $OutDir 'setup.rpt') -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $cabPath)) { throw "expected $cabPath" }
Write-Host "CAB: $cabPath ($((Get-Item $cabPath).Length) B)"
Write-Host 'Contents:'
# Full path: a Git Bash PATH would otherwise resolve `expand` to coreutils.
& "$env:SystemRoot\System32\expand.exe" -D $cabPath | Where-Object { $_ -match '\\' } | ForEach-Object { Write-Host "  $_" }
Write-Output $cabPath
