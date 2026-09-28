<#
.SYNOPSIS
  Build the UnitraMic driver package (Release|x64) for an attestation submission.

.DESCRIPTION
  Wraps msbuild for the solution with the settings a submission build needs:
  Release, x64, Spectre-mitigated libraries not required (the GitHub runner
  image does not ship them), and no test signing of the catalog -- Microsoft
  regenerates the .cat during attestation, so a test signature would only be
  thrown away. Output lands in x64\Release\package\ plus the .pdb next to it
  in x64\Release\ (the .pdb goes into the submission CAB for crash analysis).

  Works on a developer machine with Visual Studio 2022 + the WDK extension and
  on the GitHub windows-2022 image (WDK 10.1.26100 preinstalled).

.PARAMETER Platform
  x64 (default) or ARM64.
#>
[CmdletBinding()]
param(
  [ValidateSet('x64', 'ARM64')]
  [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sln  = Join-Path $root 'VirtualAudioDriver.sln'

$msbuild = (Get-Command msbuild -ErrorAction SilentlyContinue).Source
if (-not $msbuild) {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($vs) { $msbuild = Join-Path $vs 'MSBuild\Current\Bin\MSBuild.exe' }
  }
}
if (-not $msbuild -or -not (Test-Path $msbuild)) {
  throw 'MSBuild not found (install Visual Studio 2022 with the WDK extension)'
}

Write-Host "msbuild: $msbuild"
& $msbuild $sln `
  /p:Configuration=Release `
  /p:Platform=$Platform `
  /p:SpectreMitigation=false `
  /p:SignMode=Off `
  /m /v:m /nologo
if ($LASTEXITCODE -ne 0) { throw "msbuild failed ($LASTEXITCODE)" }

$pkg = Join-Path $root "$Platform\Release\package"
foreach ($f in 'VirtualAudioDriver.inf', 'VirtualAudioDriver.sys', 'virtualaudiodriver.cat') {
  if (-not (Test-Path (Join-Path $pkg $f))) { throw "expected $f in $pkg" }
}
# The driver project writes its PDB into its own intermediate dir, not the
# solution-level output folder.
$pdb = Get-ChildItem (Join-Path $root "Source\Main\$Platform\Release"), (Join-Path $root "$Platform\Release") `
  -Filter 'VirtualAudioDriver.pdb' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pdb) { throw "VirtualAudioDriver.pdb not found under Source\Main\$Platform\Release" }
# Keep a copy next to the package so CI artifacts and the CAB step find it in one place.
Copy-Item $pdb.FullName (Join-Path $root "$Platform\Release\VirtualAudioDriver.pdb") -Force

Write-Host "package: $pkg"
Get-ChildItem $pkg -File | ForEach-Object { Write-Host ("  {0,-28} {1,10} B" -f $_.Name, $_.Length) }
Write-Host ("  {0,-28} {1,10} B  ({2})" -f $pdb.Name, $pdb.Length, $pdb.DirectoryName)
