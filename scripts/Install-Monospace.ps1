#requires -Version 5.1
[CmdletBinding()]
param([switch]$InstallForUser)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$fontToolboxRoot = Split-Path -Parent $PSScriptRoot
$fontLock = Get-Content -LiteralPath (Join-Path $fontToolboxRoot 'config\fonts.lock.json') -Raw | ConvertFrom-Json
$fontDirectory = Join-Path $fontToolboxRoot 'runtime\fonts'
$fontLogDirectory = Join-Path $fontToolboxRoot 'logs'
[void][IO.Directory]::CreateDirectory($fontDirectory)
[void][IO.Directory]::CreateDirectory($fontLogDirectory)
$fontLog = Join-Path $fontLogDirectory ('font-setup-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.log')

# Path: Exact downloaded file from the pinned upstream revision.
# Entry: Expected byte length and Git blob object hash, including its header.
# Exceptions: Integrity failures preserve the suspect file and abort installation.
function Test-PinnedFontFile {
    param([string]$Path, $Entry)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne $Entry.size_bytes) { throw "Unexpected font/license size: $Path" }
    $header = [Text.Encoding]::UTF8.GetBytes('blob ' + $bytes.Length + [char]0)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        [void]$sha.TransformBlock($header, 0, $header.Length, $header, 0)
        [void]$sha.TransformFinalBlock($bytes, 0, $bytes.Length)
        $digest = [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
        if ($digest -ne $Entry.git_blob_sha1) { throw "Pinned upstream object mismatch: $Path" }
    } finally { $sha.Dispose() }
}

Start-Transcript -LiteralPath $fontLog | Out-Null
try {
    $receipts = @()
    foreach ($entry in $fontLock.files) {
        if ([IO.Path]::GetFileName($entry.name) -ne $entry.name) { throw 'Font manifest contains an unsafe name.' }
        $destination = Join-Path $fontDirectory $entry.name
        if (-not [IO.File]::Exists($destination)) {
            $partial = $destination + '.part'
            if (-not [IO.File]::Exists($partial) -or (Get-Item -LiteralPath $partial).Length -ne $entry.size_bytes) {
                Write-Host ('Downloading private font/license: ' + $entry.name)
                & curl.exe --location --fail --retry 3 --connect-timeout 30 --continue-at - --output $partial ($fontLock.base_url + $entry.path)
                if ($LASTEXITCODE -ne 0) { throw "Font download failed; partial retained: $partial" }
            }
            Test-PinnedFontFile $partial $entry
            Move-Item -LiteralPath $partial -Destination $destination
        } else { Test-PinnedFontFile $destination $entry }
        $receipts += @{ name = $entry.name; git_blob_sha1 = $entry.git_blob_sha1; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
        Write-Host ('Verified: ' + $entry.name)
    }
    @{ family = $fontLock.family; revision = $fontLock.revision; files = $receipts; installed_for_user = [bool]$InstallForUser } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fontDirectory 'installation.json') -Encoding UTF8
    if ($InstallForUser) {
        Add-Type -AssemblyName System.Drawing
        $userFontDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows\Fonts'
        [void][IO.Directory]::CreateDirectory($userFontDirectory)
        $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        if (-not (Test-Path -LiteralPath $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
        foreach ($entry in $fontLock.files | Where-Object { $_.name.EndsWith('.ttf') }) {
            $privatePath = Join-Path $fontDirectory $entry.name
            $userPath = Join-Path $userFontDirectory $entry.name
            if ([IO.File]::Exists($userPath)) { Test-PinnedFontFile $userPath $entry }
            else { Copy-Item -LiteralPath $privatePath -Destination $userPath }
            $name = [IO.Path]::GetFileNameWithoutExtension($entry.name) + ' (TrueType)'
            $existing = Get-ItemProperty -LiteralPath $registryPath -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $existing -and $existing.$name -ine $userPath) { throw 'Existing user font registration preserved; conflicting path.' }
            New-ItemProperty -LiteralPath $registryPath -Name $name -Value $userPath -PropertyType String -Force | Out-Null
        }
        Write-Host 'Font registered for this Windows user only. Other apps may need reopening. No administrator privileges used.'
    } else { Write-Host 'Private font ready inside the toolbox. No Windows font installation or registry change.' }
} finally { Stop-Transcript | Out-Null }
