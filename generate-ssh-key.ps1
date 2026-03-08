[CmdletBinding()]
param(
  [string]$KeyName = "vps-hardening_ed25519",
  [string]$Comment = "$env:USERNAME@$env:COMPUTERNAME",
  [string]$KeyDir = "$env:USERPROFILE\.ssh",
  [ValidateSet("ed25519", "rsa")]
  [string]$Algorithm = "ed25519",
  [string]$FromExistingPrivateKey = "",
  [switch]$NoPassphrase,
  [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail($Message) {
  Write-Error $Message
  exit 1
}

function Ensure-SshKeygen {
  $cmd = Get-Command ssh-keygen -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Fail "ssh-keygen was not found. Install OpenSSH Client on Windows first."
  }
  return $cmd.Source
}

function Ensure-KeyDir($Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Remove-IfExists($Path) {
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }
}

function Write-PublicKeyArtifacts($PrivateKeyPath) {
  $pubPath = "$PrivateKeyPath.pub"
  $txtPath = "$PrivateKeyPath.pub.txt"

  if (-not (Test-Path -LiteralPath $pubPath)) {
    Fail "Public key file was not created: $pubPath"
  }

  $pubLine = (Get-Content -LiteralPath $pubPath -Raw -Encoding utf8).Trim()
  if ([string]::IsNullOrWhiteSpace($pubLine)) {
    Fail "Public key file is empty: $pubPath"
  }

  Set-Content -LiteralPath $txtPath -Value ($pubLine + [Environment]::NewLine) -Encoding utf8

  try {
    Set-Clipboard -Value $pubLine
    $clipboardStatus = "yes"
  } catch {
    $clipboardStatus = "no"
  }

  Write-Host ""
  Write-Host "Done."
  Write-Host "Private key: $PrivateKeyPath"
  Write-Host "Public key:  $pubPath"
  Write-Host "TXT copy:    $txtPath"
  Write-Host "Clipboard:   $clipboardStatus"
  Write-Host ""
  Write-Host "Paste the contents of the .pub or .pub.txt file into the server prompt."
}

function Generate-NewKey($SshKeygenPath, $PrivateKeyPath) {
  $pubPath = "$PrivateKeyPath.pub"
  $txtPath = "$PrivateKeyPath.pub.txt"

  if ((Test-Path -LiteralPath $PrivateKeyPath) -or (Test-Path -LiteralPath $pubPath) -or (Test-Path -LiteralPath $txtPath)) {
    if (-not $Overwrite) {
      Fail "Key files already exist. Use -Overwrite or choose another -KeyName."
    }
    Remove-IfExists $PrivateKeyPath
    Remove-IfExists $pubPath
    Remove-IfExists $txtPath
  }

  $args = @("-t", $Algorithm, "-C", $Comment, "-f", $PrivateKeyPath)
  if ($NoPassphrase) {
    $args += @("-N", "")
  }

  & $SshKeygenPath @args
  if ($LASTEXITCODE -ne 0) {
    Fail "ssh-keygen failed while generating a new key."
  }

  Write-PublicKeyArtifacts -PrivateKeyPath $PrivateKeyPath
}

function Export-ExistingPublicKey($SshKeygenPath, $PrivateKeyPath) {
  if (-not (Test-Path -LiteralPath $PrivateKeyPath)) {
    Fail "Private key not found: $PrivateKeyPath"
  }

  $pubPath = "$PrivateKeyPath.pub"
  $txtPath = "$PrivateKeyPath.pub.txt"

  if ((Test-Path -LiteralPath $pubPath) -or (Test-Path -LiteralPath $txtPath)) {
    if (-not $Overwrite) {
      Fail "Public key artifacts already exist. Use -Overwrite if you want to recreate them."
    }
    Remove-IfExists $pubPath
    Remove-IfExists $txtPath
  }

  $publicKey = & $SshKeygenPath -y -f $PrivateKeyPath
  if ($LASTEXITCODE -ne 0) {
    Fail "ssh-keygen failed while exporting the public key from the existing private key."
  }

  $publicKey = ($publicKey | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($publicKey)) {
    Fail "Exported public key is empty."
  }

  Set-Content -LiteralPath $pubPath -Value ($publicKey + [Environment]::NewLine) -Encoding ascii
  Write-PublicKeyArtifacts -PrivateKeyPath $PrivateKeyPath
}

$sshKeygen = Ensure-SshKeygen
Ensure-KeyDir -Path $KeyDir

if (-not [string]::IsNullOrWhiteSpace($FromExistingPrivateKey)) {
  Export-ExistingPublicKey -SshKeygenPath $sshKeygen -PrivateKeyPath $FromExistingPrivateKey
  exit 0
}

$privateKeyPath = Join-Path $KeyDir $KeyName
Generate-NewKey -SshKeygenPath $sshKeygen -PrivateKeyPath $privateKeyPath
