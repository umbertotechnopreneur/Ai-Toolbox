[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('doctor','serve','catalog','test')]
    [string]$Command = 'doctor',
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ToolArguments
)

$ErrorActionPreference = 'Stop'
$portablePython = Join-Path $PSScriptRoot 'runtime\python\python.exe'
if (-not (Test-Path -LiteralPath $portablePython)) { throw 'Run Setup-Portable.ps1 first.' }
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$previousBytecodeSetting = $env:PYTHONDONTWRITEBYTECODE
$launcherLogDirectory = Join-Path $PSScriptRoot 'logs'
[void][IO.Directory]::CreateDirectory($launcherLogDirectory)
[void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'temp'))
$launcherLog = Join-Path $launcherLogDirectory ('toolbox-' + $Command + '-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.log')
Start-Transcript -LiteralPath $launcherLog | Out-Null
try {
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:TEMP = Join-Path $PSScriptRoot 'temp'
    $env:TMP = $env:TEMP
    if ($Command -eq 'test') {
        & $portablePython -B -m unittest discover -s (Join-Path $PSScriptRoot 'tests') -v
    } else {
        & $portablePython -B (Join-Path $PSScriptRoot 'scripts\ai_toolbox.py') $Command @ToolArguments
    }
    $toolExitCode = $LASTEXITCODE
} finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    $env:PYTHONDONTWRITEBYTECODE = $previousBytecodeSetting
    Stop-Transcript | Out-Null
}
exit $toolExitCode
