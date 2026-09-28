<#
.SYNOPSIS
  Sign a file with Unitra's SSL.com EV code-signing certificate via eSigner (cloud).

.DESCRIPTION
  Uses SSL.com's CodeSignTool (pinned release, downloaded once into
  %LOCALAPPDATA%\unitra\CodeSignTool) so the private key never leaves
  SSL.com's HSM. Used for the two EV signatures the driver pipeline needs:

    1. the Partner Center "Manage certificates" .bin (proves we own the cert);
    2. the attestation submission CAB (dist\UnitraMic.cab).

  Credentials come ONLY from the environment and are never printed:

    ES_USERNAME       SSL.com account user name
    ES_PASSWORD       SSL.com account password
    ES_CREDENTIAL_ID  eSigner signing credential id (from `credentials`)
    ES_TOTP_SECRET    eSigner TOTP secret for unattended signing (optional;
                      without it CodeSignTool prompts for the one-time code
                      from the authenticator app)

  In GitHub Actions the same job is done by sslcom/esigner-codesign; this
  script is the local equivalent for the manual Partner Center steps.

.PARAMETER Path
  File to sign (.cab, .bin, .sys, .exe, .dll, .msi ...).

.PARAMETER OutDir
  Directory for the signed copy. Default: <file dir>\signed\.

.PARAMETER Credentials
  Only list the eSigner credential ids for this account and exit (the value
  for ES_CREDENTIAL_ID).

.OUTPUTS
  Full path of the signed file.
#>
[CmdletBinding(DefaultParameterSetName = 'Sign')]
param(
  [Parameter(ParameterSetName = 'Sign', Mandatory = $true, Position = 0)]
  [string]$Path,
  [Parameter(ParameterSetName = 'Sign')]
  [string]$OutDir,
  [Parameter(ParameterSetName = 'List')]
  [switch]$Credentials
)

$ErrorActionPreference = 'Stop'

# ---- pinned CodeSignTool -----------------------------------------------------
$ToolVersion = 'v1.3.2'
$ToolUrl     = "https://github.com/SSLcom/CodeSignTool/releases/download/$ToolVersion/CodeSignTool-$ToolVersion-windows.zip"
$ToolRoot    = Join-Path $env:LOCALAPPDATA "unitra\CodeSignTool\$ToolVersion"

function Get-CodeSignTool {
  $bat = Get-ChildItem $ToolRoot -Filter 'CodeSignTool.bat' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($bat) { return $bat.FullName }
  New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
  $zip = Join-Path $ToolRoot 'CodeSignTool.zip'
  Write-Host "Downloading CodeSignTool $ToolVersion (about 200 MB, once)"
  Invoke-WebRequest -Uri $ToolUrl -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $ToolRoot -Force
  Remove-Item $zip -Force
  $bat = Get-ChildItem $ToolRoot -Filter 'CodeSignTool.bat' -Recurse | Select-Object -First 1
  if (-not $bat) { throw "CodeSignTool.bat not found after extracting $ToolUrl" }
  return $bat.FullName
}

function Require-Env([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($v)) { throw "$name is not set (see script help)" }
  return $v
}

$tool = Get-CodeSignTool
$toolDir = Split-Path -Parent $tool
$user = Require-Env 'ES_USERNAME'
$pass = Require-Env 'ES_PASSWORD'

# CodeSignTool.bat must run from its own directory (relative jar paths).
Push-Location $toolDir
try {
  if ($Credentials) {
    & $tool get_credential_ids "-username=$user" "-password=$pass"
    if ($LASTEXITCODE -ne 0) { throw "get_credential_ids failed ($LASTEXITCODE)" }
    return
  }

  $file = (Resolve-Path $Path).Path
  if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $file) 'signed' }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $OutDir = (Resolve-Path $OutDir).Path
  $cred = Require-Env 'ES_CREDENTIAL_ID'
  $totp = [Environment]::GetEnvironmentVariable('ES_TOTP_SECRET')

  $args = @(
    'sign',
    "-username=$user",
    "-password=$pass",
    "-credential_id=$cred",
    "-input_file_path=$file",
    "-output_dir_path=$OutDir"
  )
  if (-not [string]::IsNullOrWhiteSpace($totp)) { $args += "-totp_secret=$totp" }

  Write-Host "Signing $(Split-Path -Leaf $file) with eSigner credential ...$($cred.Substring([Math]::Max(0, $cred.Length - 4)))"
  # Never echo $args: it carries the password.
  & $tool @args
  if ($LASTEXITCODE -ne 0) { throw "CodeSignTool sign failed ($LASTEXITCODE)" }

  $signed = Join-Path $OutDir (Split-Path -Leaf $file)
  if (-not (Test-Path $signed)) { throw "expected signed output at $signed" }

  # Independent check with signtool when the SDK is present: the signature
  # must verify under the default policy and carry an SSL.com EV chain.
  $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
  if ($signtool) {
    & $signtool.FullName verify /pa /v $signed 2>&1 | Where-Object { $_ -match 'Issued to|Issued by|Successfully|Error' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "signtool verify /pa failed on $signed" }
  } else {
    Write-Warning 'signtool.exe not found; skipping independent verification'
  }
  Write-Host "Signed: $signed"
  Write-Output $signed
}
finally { Pop-Location }
