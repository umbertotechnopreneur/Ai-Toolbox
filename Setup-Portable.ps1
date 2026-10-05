[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CUDA', 'Vulkan', 'CPU')][string]$Backend = 'Auto',
    [switch]$NoModels
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$toolboxRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$rootPrefix = $toolboxRoot.TrimEnd('\') + '\'
$downloadLock = Get-Content -LiteralPath (Join-Path $toolboxRoot 'config\downloads.lock.json') -Raw | ConvertFrom-Json

# Parameter RelativePath: a package-owned path below this portable toolbox.
# Exceptions: throws if the computed path escapes the toolbox directory.
function Get-ToolboxPath {
    param([string]$RelativePath)
    $targetPath = [IO.Path]::GetFullPath((Join-Path $toolboxRoot $RelativePath))
    if (-not $targetPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the toolbox: $targetPath"
    }
    return $targetPath
}

# Parameter Package: an official URL and SHA-256 from the pinned download lock.
# Exceptions: throws on failed download or checksum mismatch, preserving the file.
function Get-VerifiedPackage {
    param($Package)
    $targetPath = Get-ToolboxPath $Package.destination
    $parentPath = Split-Path -Parent $targetPath
    New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    if (Test-Path -LiteralPath $targetPath) {
        $existingHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -ne $Package.sha256) {
            throw "Existing package has an unexpected checksum; left untouched: $targetPath"
        }
        Write-Host "Already verified: $($Package.name)"
        return $targetPath
    }

    $partialPath = $targetPath + '.part'
    if (Test-Path -LiteralPath $partialPath) {
        $partialHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($partialHash -eq $Package.sha256) {
            # An interruption between download completion and activation is resumable too.
            Move-Item -LiteralPath $partialPath -Destination $targetPath
            return $targetPath
        }
    }
    Write-Host "Downloading only toolbox dependencies: $($Package.name)"
    & curl.exe --progress-bar --show-error --location --fail --retry 3 --connect-timeout 30 --continue-at - --output $partialPath $Package.url
    if ($LASTEXITCODE -ne 0) {
        throw "Download failed; partial file is retained for resume: $partialPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Package.sha256) {
        throw "Checksum mismatch; package was not activated: $partialPath"
    }
    Move-Item -LiteralPath $partialPath -Destination $targetPath
    return $targetPath
}

New-Item -ItemType Directory -Path (Get-ToolboxPath 'cache'), (Get-ToolboxPath 'logs'), (Get-ToolboxPath 'output'), (Get-ToolboxPath 'temp') -Force | Out-Null
if (-not [Environment]::Is64BitOperatingSystem) { throw 'This distribution requires Windows x64.' }
$setupLog = Get-ToolboxPath ('logs\setup-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.log')
Start-Transcript -LiteralPath $setupLog | Out-Null
try {
    # Hardware discovery is performed only when the user explicitly invokes setup.
    $selectedBackend = $Backend.ToLowerInvariant()
    if ($selectedBackend -eq 'auto') {
        $selectedBackend = 'cpu'
        try {
            $adapterNames = @((Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop).Name)
            if (@($adapterNames | Where-Object { $_ -match 'NVIDIA' }).Count -gt 0) { $selectedBackend = 'cuda' }
            elseif (@($adapterNames | Where-Object { $_ -match 'Intel|AMD|Radeon' }).Count -gt 0) { $selectedBackend = 'vulkan' }
        } catch { Write-Host 'GPU detection unavailable; installing CPU fallback.' }
    }
    Write-Host "Selected backend: $selectedBackend (CPU fallback always included). GPU drivers are not installed."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$verifiedPackages = @()
foreach ($package in $downloadLock.downloads) {
    if ($package.PSObject.Properties.Name -contains 'backend') {
        if ($package.backend -notin @($selectedBackend, 'cpu')) { continue }
    }
    if ($NoModels -and $package.destination.StartsWith('models/')) { continue }
    $packagePath = Get-VerifiedPackage $package
    if ($package.PSObject.Properties.Name -contains 'extract_to') {
        $extractPath = Get-ToolboxPath $package.extract_to
        $receiptPath = Get-ToolboxPath ('cache\extracted-' + $package.sha256 + '.json')
        $needsExtraction = -not (Test-Path -LiteralPath $receiptPath)
        if (-not $needsExtraction) {
            $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
            try {
                foreach ($entry in $archive.Entries) {
                    $entryPath = [IO.Path]::GetFullPath((Join-Path $extractPath $entry.FullName))
                    if (-not $entryPath.StartsWith($extractPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cached archive member.' }
                    if ($entry.Name -and (-not [IO.File]::Exists($entryPath) -or (Get-Item -LiteralPath $entryPath).Length -ne $entry.Length)) { $needsExtraction = $true }
                }
            } finally { $archive.Dispose() }
        }
        if ($needsExtraction) {
            # Validate every archive member before any extraction can overwrite runtime files.
            $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
            try {
                foreach ($entry in $archive.Entries) {
                    $entryPath = [IO.Path]::GetFullPath((Join-Path $extractPath $entry.FullName))
                    $extractPrefix = $extractPath.TrimEnd('\') + '\'
                    if (-not $entryPath.StartsWith($extractPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Archive member escapes extraction directory: $($entry.FullName)"
                    }
                }
            } finally {
                $archive.Dispose()
            }
            Expand-Archive -LiteralPath $packagePath -DestinationPath $extractPath -Force
            @{name=$package.name; sha256=$package.sha256; extracted_to=$package.extract_to} |
                ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
        }
    }
    $verifiedPackages += @{name=$package.name; sha256=$package.sha256; path=$package.destination}
}
Copy-Item -LiteralPath (Get-ToolboxPath 'config\python313._pth') -Destination (Get-ToolboxPath 'runtime\python\python313._pth') -Force
if (-not (Test-Path -LiteralPath (Get-ToolboxPath 'runtime\ffmpeg\ffprobe.exe'))) {
    $probes = @(Get-ChildItem -LiteralPath (Get-ToolboxPath 'runtime\ffmpeg-package') -Filter 'ffprobe.exe' -File -Recurse)
    if ($probes.Count -ne 1) { throw 'Expected exactly one ffprobe in the verified package.' }
    New-Item -ItemType Directory -Path (Get-ToolboxPath 'runtime\ffmpeg') -Force | Out-Null
    Copy-Item -LiteralPath $probes[0].FullName -Destination (Get-ToolboxPath 'runtime\ffmpeg\ffprobe.exe')
}
$configPath = Get-ToolboxPath 'config\toolbox.json'
$portableConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$portableConfig | Add-Member -NotePropertyName engine_backend -NotePropertyValue $Backend.ToLowerInvariant() -Force
$portableConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
@{schema_version=1; installed_at_utc=[DateTime]::UtcNow.ToString('o'); packages=$verifiedPackages} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-ToolboxPath 'cache\installation.json') -Encoding UTF8
Write-Host 'Portable setup ready. No PATH, registry, services or global Python packages were changed.'
if ($NoModels) { Write-Host 'Metadata/copy/cleanup ready. AI models omitted; disable AI until a full setup is completed.' }
} finally { Stop-Transcript | Out-Null }
