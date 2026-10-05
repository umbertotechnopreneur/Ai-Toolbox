# Window: App-owned rendered form, never a desktop capture.
# Name: Trusted smoke-test screenshot basename.
# Exceptions: Rendering/storage failures are surfaced as test failures.
function Save-SmokePreview {
    param([Windows.Forms.Form]$Window, [string]$Name)
    $Window.PerformLayout(); $Window.Refresh()
    $output = Join-Path $script:appRoot ('output\' + $Name + '.png')
    $bitmap = New-Object Drawing.Bitmap($Window.Width, $Window.Height)
    try {
        $Window.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
        $bitmap.Save($output, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    Write-Host ('DIALOG_PREVIEW_OK | ' + $Name + ' | ' + $output)
}

# Window: Smoke-test-only modal form.
# Name: Trusted filename, containing the form and theme under test.
function Enable-DialogSmokeCapture {
    param([Windows.Forms.Form]$Window, [string]$Name)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 450; $timer.Tag = $Window
    $Window.Tag = @{ SmokeName = $Name; SmokeTimer = $timer }
    $timer.Add_Tick({ param($sender, $eventArgs)
        $sender.Stop()
        $window = [Windows.Forms.Form]$sender.Tag
        try { Save-SmokePreview $window $window.Tag.SmokeName }
        catch { $script:state.SmokeError = $_.Exception.Message; Write-Host ('DIALOG_SMOKE_ERROR | ' + $script:state.SmokeError) }
        finally { $window.Close() }
    })
    $Window.Add_Shown({ param($sender, $eventArgs) $sender.Tag.SmokeTimer.Start() })
    $Window.Add_FormClosed({ param($sender, $eventArgs) $sender.Tag.SmokeTimer.Dispose() })
}

# Render both themes, About and Options without invoking setup, AI or cleanup.
# Exceptions: Dialog errors fail the test; preferences are restored without saving.
function Invoke-DialogSmokeTests {
    $previousTheme = $script:uiPreferences.Theme
    try {
        foreach ($theme in @('Light', 'Dark')) {
            $script:uiPreferences.Theme = $theme
            Set-AppAppearance $script:form
            Save-SmokePreview $script:form ('gui-main-' + $theme)
            $script:workspace.AutoScrollPosition = New-Object Drawing.Point(0, $script:workspace.DisplayRectangle.Height)
            Save-SmokePreview $script:form ('gui-cleanup-' + $theme)
            $script:workspace.AutoScrollPosition = New-Object Drawing.Point(0, 0)
            Show-ToolboxAbout
            Show-ToolboxOptions
        }
        if ($null -ne $script:state.SmokeError) { throw $script:state.SmokeError }
        Write-Host 'DIALOG_SMOKE_OK | Light/Dark | About | Options | Cleanup panel | No installers or original contents'
    } finally {
        $script:uiPreferences.Theme = $previousTheme
        Set-AppAppearance $script:form
    }
}
