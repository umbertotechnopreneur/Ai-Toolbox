# Runtime helper: compiled only when the user explicitly applies a confirmed plan.
[CmdletBinding()]
param([switch]$Confirmed)
$ErrorActionPreference = 'Stop'
if (-not $Confirmed -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'A confirmed cleanup plan and STA host are required.'
}
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -Path (Join-Path $PSScriptRoot 'Recycle-Verified.cs')
while ($null -ne ($requestLine = [Console]::ReadLine())) {
    try {
        $request = ConvertFrom-Json -InputObject $requestLine
        if ($request.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid SHA-256.' }
        $recyclePath = [PhotoCleanup.Native]::Recycle([string]$request.path, [string]$request.source, [string]$request.sha256)
        $result = @{ recycled = $true; recycle_path = $recyclePath; source = [string]$request.path }
    } catch {
        $result = @{ recycled = $false; error = $_.Exception.Message }
    }
    [Console]::WriteLine(($result | ConvertTo-Json -Compress))
}
