# Standalone diagnostics/reset; works even before portable Python is installed.
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Reset')][string]$Mode = 'Info',
    [string]$ConfirmHash = '',
    [string]$ProtectedPathsJson = '[]'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$taskPrefix = $taskRoot + '\'
$taskLog = Join-Path $taskRoot ('logs\photo-organizer\ai-maintenance-' + [guid]::NewGuid().ToString('N') + '.log')
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $taskLog))

# Text: Diagnostic, deletion intent or outcome to persist before displaying.
# Exceptions: Unwritable logs abort maintenance.
function Write-MaintenanceLine {
    param([string]$Text)
    [IO.File]::AppendAllText($taskLog, ([datetime]::UtcNow.ToString('o') + ' ' + $Text + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [Console]::WriteLine($Text)
}

# Relative: One exact toolbox-relative path, never a wildcard or drive root.
# Exceptions: Escaped paths and reparse points fail closed, including ancestors.
function Get-MaintenancePath {
    param([string]$Relative)
    if ([IO.Path]::IsPathRooted($Relative)) { throw 'An absolute maintenance target is not allowed.' }
    $path = [IO.Path]::GetFullPath((Join-Path $taskRoot $Relative))
    if (-not $path.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Maintenance path escapes the toolbox.' }
    $probe = $path
    while ($true) {
        if (Test-Path -LiteralPath $probe) {
            if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Link/junction refused: ' + $probe) }
        }
        if ($probe -eq $taskRoot) { break }
        $probe = Split-Path -Parent $probe
        if (-not $probe) { throw 'Invalid maintenance ancestor.' }
    }
    return $path
}

# Return an explicit allowlist; shared Python, FFmpeg and fonts are never reset.
function Get-ManagedAiPaths {
    $paths = @('models/Qwen3-VL-4B', 'models/whisper-small', 'runtime/transcription',
        'cache/catalog', 'cache/pip-transcription', 'cache/huggingface-transcription',
        'downloads/transcription', 'temp/transcription')
    $lock = Get-Content -LiteralPath (Join-Path $taskRoot 'config\downloads.lock.json') -Raw | ConvertFrom-Json
    foreach ($package in $lock.downloads) {
        if ($package.PSObject.Properties.Name -contains 'backend') {
            if ($package.extract_to -notmatch '^runtime/llama-[A-Za-z0-9.-]+$' -or
                $package.destination -notmatch '^downloads/(llama|cudart)-[A-Za-z0-9.-]+\.zip$' -or
                $package.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Unexpected AI package path in download lock.' }
            $paths += @($package.extract_to, $package.destination, ($package.destination + '.part'), ('cache/extracted-' + $package.sha256 + '.json'))
        }
    }
    return @($paths | Sort-Object -Unique)
}

# Relative: One allowed component to enumerate using metadata only.
# Exceptions: Inaccessible or linked descendants invalidate the complete reset plan.
function Get-AiTree {
    param([string]$Relative)
    $path = Get-MaintenancePath $Relative
    $nodes = New-Object 'Collections.Generic.List[object]'
    $pending = New-Object 'Collections.Generic.Stack[string]'
    if (Test-Path -LiteralPath $path) { $pending.Push($path) }
    [long]$bytes = 0
    while ($pending.Count) {
        $current = $pending.Pop()
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Linked component refused: ' + $current) }
        $directory = [bool]$item.PSIsContainer
        $length = if ($directory) { 0 } else { [long]$item.Length }
        $nodes.Add([ordered]@{ relative = $item.FullName.Substring($taskPrefix.Length); directory = $directory; bytes = $length; modified = $item.LastWriteTimeUtc.Ticks })
        $bytes += $length
        if ($directory) {
            foreach ($child in [IO.Directory]::GetFileSystemEntries($current)) { $pending.Push($child) }
        }
    }
    return @{ relative = $Relative; path = $path; bytes = $bytes; nodes = @($nodes.ToArray() | Sort-Object { $_.relative }); present = ($nodes.Count -gt 0) }
}

# Trees: Fresh component metadata snapshots, including missing components.
function Get-AiPlanHash {
    param($Trees)
    $components = @($Trees | ForEach-Object { [ordered]@{ relative = $_.relative; nodes = $_.nodes } })
    $payload = ConvertTo-Json -InputObject ([ordered]@{ root = $taskRoot; components = $components }) -Depth 8 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

# Paths: Folder selections from both main-window workflows, kept outside reset targets.
# Trees: Exact components that would be removed.
# Exceptions: Overlap with a selected media/archive directory refuses the reset.
function Assert-ProtectedFolders {
    param($Paths, $Trees)
    foreach ($selection in $Paths) {
        if ([string]::IsNullOrWhiteSpace([string]$selection)) { continue }
        $protected = [IO.Path]::GetFullPath([string]$selection).TrimEnd('\')
        foreach ($tree in $Trees) {
            if (-not $tree.present) { continue }
            if ($tree.path -ieq $protected -or $tree.path.StartsWith($protected + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $protected.StartsWith($tree.path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw ('Selected media folder overlaps reset: ' + $protected) }
        }
    }
}

# Exceptions: Unknown process state or a live toolbox backend refuses removal; never kills processes.
function Assert-NoAiProcess {
    $processes = Get-CimInstance Win32_Process -OperationTimeoutSec 10 -ErrorAction Stop
    foreach ($process in $processes) {
        if ($process.ProcessId -eq $PID) { continue }
        $binary = [string]$process.ExecutablePath
        $command = [string]$process.CommandLine
        if ($process.Name -match '^(python|llama).*(\.exe)$' -and -not $binary -and -not $command) {
            throw ('Cannot identify active AI/Python process PID ' + $process.ProcessId + ': reset refused.')
        }
        if (($binary.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase) -and $process.Name -match '^(python|llama).*(\.exe)$') -or
            ($command.IndexOf($taskRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
             $command -match 'Setup-Portable|Setup-Transcription|setup_transcription|Ai-Maintenance\.ps1')) {
            throw ('Active toolbox process: ' + $process.Name + ' PID ' + $process.ProcessId + '. Close it before reset.')
        }
    }
}

try {
    Write-MaintenanceLine ('AI / MODELS | ' + [datetime]::UtcNow.ToString('u'))
    Write-MaintenanceLine ('Toolbox: ' + $taskRoot)
    Write-MaintenanceLine ('Log: ' + $taskLog)
    $trees = @(Get-ManagedAiPaths | ForEach-Object { Get-AiTree $_ })
    $planHash = Get-AiPlanHash $trees
    $present = @($trees | Where-Object { $_.present })
    $total = [long]0
    foreach ($tree in $present) { $total += $tree.bytes }
    $plan = @{ hash = $planHash; bytes = $total; paths = @($present | ForEach-Object { $_.path }) }
    Write-MaintenanceLine 'COMPONENTI AI (presenza su disco, non verifica checksum)'
    foreach ($tree in $trees) {
        $status = if ($tree.present) { '{0:N2} MiB | {1} elementi' -f ($tree.bytes / 1MB), $tree.nodes.Count } else { 'assente' }
        Write-MaintenanceLine ($tree.relative + ' | ' + $status)
    }
    Write-MaintenanceLine ('Totale componenti AI: {0:N2} GiB (dimensione logica; non spazio fisico allocato)' -f ($total / 1GB))
    if ($Mode -eq 'Reset') {
        if ($ConfirmHash -notmatch '^[0-9a-f]{64}$' -or $ConfirmHash -cne $planHash) { throw 'Inventory changed: refresh AI / Models and confirm again.' }
        Assert-ProtectedFolders ($ProtectedPathsJson | ConvertFrom-Json) $trees
        Assert-NoAiProcess
        foreach ($tree in $present) {
            # A fresh snapshot immediately before each removal prevents stale previews.
            $fresh = Get-AiTree $tree.relative
            if ((Get-AiPlanHash @($fresh)) -cne (Get-AiPlanHash @($tree))) { throw ('Component changed: ' + $tree.path) }
            Write-MaintenanceLine ('REMOVE INTENT: ' + $tree.path)
            foreach ($node in @($fresh.nodes | Sort-Object { $_.relative.Length } -Descending)) {
                $path = Get-MaintenancePath $node.relative
                if ($path -ine $tree.path -and -not $path.StartsWith($tree.path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Deletion escaped its exact component.' }
                if ($node.directory) { [IO.Directory]::Delete($path, $false) }
                else { [IO.File]::Delete($path) }
                Write-MaintenanceLine ('REMOVED: ' + $path)
            }
        }
        Write-MaintenanceLine 'RESET COMPLETATO: componenti AI eliminati definitivamente. Ripeti il setup per riscaricarli.'
        Write-MaintenanceLine 'Python, FFmpeg, font, configurazioni, log, input e output conservati.'
        exit 0
    }
    $config = Get-Content -LiteralPath (Join-Path $taskRoot 'config\toolbox.json') -Raw | ConvertFrom-Json
    $speech = Get-Content -LiteralPath (Join-Path $taskRoot 'config\transcription.json') -Raw | ConvertFrom-Json
    $lock = Get-Content -LiteralPath (Join-Path $taskRoot 'config\downloads.lock.json') -Raw | ConvertFrom-Json
    Write-MaintenanceLine ('FOTO: ' + $lock.model_id + ' | revisione ' + $lock.model_revision)
    Write-MaintenanceLine ('ENGINE: llama.cpp ' + $lock.runtime_release + ' | backend configurato ' + $config.engine_backend)
    Write-MaintenanceLine ('Modello: ' + $config.model_path + ' | projector: ' + $config.projector_path)
    Write-MaintenanceLine ('Endpoint: ' + $config.host + ':' + $config.port + ' (stato server non sondato)')
    Write-MaintenanceLine ('AUDIO: ' + $speech.engine + ' ' + $speech.engine_version + ' | ' + $speech.model_repository + ' | CPU int8')
    Write-MaintenanceLine ('Modello audio: ' + $speech.model_directory + ' | NPU non supportata')
    $speechReceiptPath = Get-MaintenancePath 'runtime/transcription/installation.json'
    if (Test-Path -LiteralPath $speechReceiptPath) {
        $installed = Get-Content -LiteralPath $speechReceiptPath -Raw | ConvertFrom-Json
        Write-MaintenanceLine ('Ricevuta audio: faster-whisper ' + $installed.engine_version + ' | modello ' + $installed.model_revision)
        Write-MaintenanceLine ('Pacchetti audio attivi: ' + $installed.packages_directory)
        if ($installed.packages_directory -match '^runtime[\\/]transcription[\\/]packages-[0-9]+$') {
            $packagesPath = Get-MaintenancePath $installed.packages_directory
            if (Test-Path -LiteralPath $packagesPath) {
                foreach ($packageFolder in @(Get-ChildItem -LiteralPath $packagesPath -Directory -Filter '*.dist-info')) {
                    if ($packageFolder.Name -match '^(av|ctranslate2|faster_whisper|numpy|onnxruntime|huggingface_hub)-') {
                        Write-MaintenanceLine ('Pacchetto presente: ' + $packageFolder.Name.Replace('.dist-info', ''))
                    }
                }
            }
        }
    } else { Write-MaintenanceLine 'Trascrizione: nessuna ricevuta di installazione locale.' }
    foreach ($relative in @('runtime/python', 'runtime/ffmpeg', 'runtime/fonts', 'logs/photo-organizer')) {
        $shared = Get-AiTree $relative
        Write-MaintenanceLine ('CONSERVATO: ' + $shared.path + ' | {0:N2} MiB' -f ($shared.bytes / 1MB))
    }
    try {
        foreach ($gpu in @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 10 -ErrorAction Stop)) {
            Write-MaintenanceLine ('GPU: ' + $gpu.Name + ' | driver ' + $gpu.DriverVersion)
        }
        foreach ($cpu in @(Get-CimInstance Win32_Processor -OperationTimeoutSec 10 -ErrorAction Stop)) {
            Write-MaintenanceLine ('CPU: ' + $cpu.Name + ' | thread ' + $cpu.NumberOfLogicalProcessors)
        }
        $system = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
        Write-MaintenanceLine ('RAM: {0:N2} GiB | disponibile {1:N2} GiB' -f ($system.TotalVisibleMemorySize / 1MB), ($system.FreePhysicalMemory / 1MB))
        $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($taskRoot))
        Write-MaintenanceLine ('DISCO: ' + $drive.Name + ' | libero {0:N2} GiB / {1:N2} GiB' -f ($drive.AvailableFreeSpace / 1GB), ($drive.TotalSize / 1GB))
    } catch { Write-MaintenanceLine ('Hardware/disco parzialmente non disponibile: ' + $_.Exception.Message) }
    Write-MaintenanceLine 'Nuclearizza elimina solo i componenti AI elencati; non disinstalla driver Windows.'
    Write-MaintenanceLine ('AI-MAINTENANCE-PLAN ' + ($plan | ConvertTo-Json -Compress -Depth 4))
} catch {
    Write-MaintenanceLine ('ERRORE: ' + $_.Exception.Message + ' | Reset interrotto; eventuali rimozioni precedenti sono nel log.')
    exit 1
}
