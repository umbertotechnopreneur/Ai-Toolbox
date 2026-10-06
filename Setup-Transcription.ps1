[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$python = Join-Path $PSScriptRoot 'runtime\python\python.exe'
if (-not [IO.File]::Exists($python)) { throw 'Prepara prima la toolbox con Setup-Portable.ps1.' }
& $python -B -u (Join-Path $PSScriptRoot 'scripts\setup_transcription.py')
if ($LASTEXITCODE -ne 0) { throw 'Setup trascrizione fallito. Consulta logs/photo-organizer.' }
