# Shared portable preferences. Nothing in this file runs an installer while loading.

# Kind: UI, stdout, stderr or child lifecycle event.
# Text: Original event text; never image data or credentials.
# Exceptions: A log storage failure is surfaced rather than silently dropping events.
function Write-AppSessionLog {
    param([string]$Kind, [string]$Text)
    $record = @{ time_utc = [datetime]::UtcNow.ToString('o'); kind = $Kind; text = $Text }
    [IO.File]::AppendAllText($script:guiLogPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

# Family: One installed or privately loaded font family.
# Exceptions: Unavailable fonts return false, without triggering installation.
function Test-MonospaceFamily {
    param([Drawing.FontFamily]$Family)
    $bitmap = New-Object Drawing.Bitmap(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = $null
    try {
        $font = New-Object Drawing.Font($Family, 12)
        $widths = @('iiiiiiii', 'WWWWWWWW', '00000000') | ForEach-Object {
            $graphics.MeasureString($_, $font, 1000, [Drawing.StringFormat]::GenericTypographic).Width
        }
        return ([Math]::Abs($widths[0] - $widths[1]) -lt 0.25 -and [Math]::Abs($widths[0] - $widths[2]) -lt 0.25)
    } catch { return $false }
    finally { if ($null -ne $font) { $font.Dispose() }; $graphics.Dispose(); $bitmap.Dispose() }
}

# Rebuild the runtime font choices from this machine and app-owned private fonts.
# Exceptions: Invalid font files or missing usable families are surfaced to the caller.
function Refresh-AppFonts {
    $fontDirectory = Join-Path $script:appRoot 'runtime\fonts'
    if ([IO.Directory]::Exists($fontDirectory)) {
        foreach ($file in Get-ChildItem -LiteralPath $fontDirectory -Filter '*.ttf' -File) {
            if (-not $script:registeredFonts.ContainsKey($file.FullName)) {
                [void][PhotoOrganizer.Native]::AddFontResourceEx($file.FullName, 0x10, [IntPtr]::Zero)
                $script:privateFonts.AddFontFile($file.FullName)
                $script:registeredFonts[$file.FullName] = $true
            }
        }
    }
    $installed = New-Object Drawing.Text.InstalledFontCollection
    try {
        $script:monoFamilies = @{}
        foreach ($family in @($installed.Families) + @($script:privateFonts.Families)) {
            if (Test-MonospaceFamily $family) { $script:monoFamilies[$family.Name] = $family }
        }
        # Private families and installed families are retained for the UI lifetime.
        $script:installedFontCollections += $installed
        $script:preferredFontMissing = -not $script:monoFamilies.ContainsKey($script:uiPreferences.FontName)
        if (-not $script:preferredFontMissing) { $script:activeFontName = $script:uiPreferences.FontName }
        else {
            $script:activeFontName = @('Consolas', 'Cascadia Mono', 'Courier New') | Where-Object { $script:monoFamilies.ContainsKey($_) } | Select-Object -First 1
            if (-not $script:activeFontName) { $script:activeFontName = $script:monoFamilies.Keys | Sort-Object | Select-Object -First 1 }
            if (-not $script:activeFontName) {
                $fallbackFamily = [Drawing.FontFamily]::GenericMonospace
                $script:monoFamilies[$fallbackFamily.Name] = $fallbackFamily
                $script:activeFontName = $fallbackFamily.Name
            }
        }
    } catch { $installed.Dispose(); throw }
}

# Load portable preferences and fonts; do not probe GPUs or install prerequisites.
# Exceptions: Configuration/font loading failures stop startup without triggering setup.
function Initialize-UiPreferences {
    $script:uiPreferences = @{ FontName = 'JetBrainsMono NFM'; Theme = 'Light'; AutoInstallMissingFont = $true }
    $path = Join-Path $script:appRoot 'config\ui-options.json'
    if ([IO.File]::Exists($path)) {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        foreach ($key in @('FontName', 'Theme', 'AutoInstallMissingFont')) {
            if ($saved.PSObject.Properties.Name -contains $key) { $script:uiPreferences[$key] = $saved.$key }
        }
    }
    if ($script:uiPreferences.Theme -notin @('Light', 'Dark')) { $script:uiPreferences.Theme = 'Light' }
    # Earlier releases saved the download name rather than the font's internal family name.
    if ($script:uiPreferences.FontName -eq 'JetBrainsMono Nerd Font Mono') { $script:uiPreferences.FontName = 'JetBrainsMono NFM' }
    $script:registeredFonts = @{}
    $script:fontCache = @{}
    $script:installedFontCollections = @()
    $script:privateFonts = New-Object Drawing.Text.PrivateFontCollection
    Refresh-AppFonts
}

# Size: Point size, independent of monitor DPI.
# Style: Requested weight, using the selected monospace family.
# Missing or unusable requested fonts fall back to a Windows monospace font.
function New-AppFont {
    param([single]$Size = 10, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular)
    $family = $script:monoFamilies[$script:activeFontName]
    if ($null -eq $family) {
        foreach ($fallbackName in @('Consolas', 'Cascadia Mono', 'Courier New')) {
            if ($script:monoFamilies.ContainsKey($fallbackName)) {
                $script:activeFontName = $fallbackName; $family = $script:monoFamilies[$fallbackName]; break
            }
        }
        if ($null -eq $family) { $family = [Drawing.FontFamily]::GenericMonospace; $script:activeFontName = $family.Name }
    }
    if (-not $family.IsStyleAvailable($Style)) { $Style = [Drawing.FontStyle]::Regular }
    $key = '{0}|{1}|{2}' -f $family.Name, $Size, [int]$Style
    if (-not $script:fontCache.ContainsKey($key)) {
        try { $script:fontCache[$key] = New-Object Drawing.Font($family, $Size, $Style) }
        catch { $script:fontCache[$key] = New-Object Drawing.Font('Consolas', $Size, $Style) }
    }
    return $script:fontCache[$key]
}

# Window: Existing app-owned form, themed independently of Windows preferences.
function Set-WindowTheme {
    param([Windows.Forms.Form]$Window)
    if (-not $Window.IsHandleCreated) { return }
    $darkValue = [int]($script:uiPreferences.Theme -eq 'Dark')
    try {
        if ([PhotoOrganizer.Native]::DwmSetWindowAttribute($Window.Handle, 20, [ref]$darkValue, 4) -ne 0) {
            [void][PhotoOrganizer.Native]::DwmSetWindowAttribute($Window.Handle, 19, [ref]$darkValue, 4)
        }
    } catch { } # Older Windows builds retain their normal non-client title bar.
}

# Control: Root of the existing form/control tree; no worker restart is involved.
# Exceptions: Invalid/disposed controls are surfaced to the owning UI workflow.
function Set-AppAppearance {
    # Nested: internal traversal; only the outer call requests a full repaint.
    param([Windows.Forms.Control]$Control, [switch]$Nested)
    $Control.SuspendLayout()
    try {
    if ($Control -is [Windows.Forms.Form]) { Set-WindowTheme $Control }
    $dark = $script:uiPreferences.Theme -eq 'Dark'
    $surface = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#1C2635' } else { '#FFFFFF' }))
    $canvas = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#111923' } else { '#F2F6FA' }))
    $ink = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#E7EEF8' } else { '#172E49' }))
    $muted = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#B0C0D4' } else { '#60738A' }))
    $border = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#43536A' } else { '#CFDBE8' }))
    $script:palette.Ink = $ink; $script:palette.Muted = $muted; $script:palette.Canvas = $canvas
    $font = New-AppFont $Control.Font.SizeInPoints $Control.Font.Style
    if (-not [object]::ReferenceEquals($Control.Font, $font)) { $Control.Font = $font }
    if ($Control -is [PhotoOrganizer.CardPanel]) {
        $Control.BackColor = $canvas; $Control.FillColor = $surface; $Control.BorderColor = $border
    } elseif ($Control.Tag -eq 'header') { $Control.BackColor = $script:palette.Navy }
    elseif ($Control.Tag -eq 'console') { $Control.BackColor = [Drawing.Color]::Black; $Control.ForeColor = [Drawing.Color]::Gainsboro }
    elseif ($Control -is [Windows.Forms.LinkLabel]) {
        $Control.LinkColor = if ($dark) { $script:palette.Cyan } else { $script:palette.Navy }
        $Control.ActiveLinkColor = $script:palette.Cyan; $Control.VisitedLinkColor = $Control.LinkColor
    } elseif ($Control -is [Windows.Forms.Label]) {
        if ($Control.Tag -eq 'ink') { $Control.ForeColor = $ink }
        elseif ($Control.Tag -eq 'muted') { $Control.ForeColor = $muted }
    } elseif ($Control -is [Windows.Forms.Button]) {
        $Control.BackColor = if ($Control.Tag -eq 'primary') { $script:palette.Cyan } else { $surface }
        $Control.ForeColor = if ($Control.Tag -eq 'primary') { $script:palette.Navy } else { $ink }
        $Control.FlatAppearance.BorderColor = $border
    } elseif ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $surface; $Control.GridColor = $border
        $Control.EnableHeadersVisualStyles = $false
        foreach ($style in @($Control.DefaultCellStyle, $Control.ColumnHeadersDefaultCellStyle, $Control.RowHeadersDefaultCellStyle)) {
            $style.BackColor = $surface; $style.ForeColor = $ink; $style.Font = New-AppFont 9
            $style.SelectionBackColor = $script:palette.Navy; $style.SelectionForeColor = [Drawing.Color]::White
        }
    } elseif ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.ComboBox] -or
        $Control -is [Windows.Forms.CheckBox] -or $Control -is [Windows.Forms.NumericUpDown] -or $Control.Tag -eq 'surface') {
        $Control.BackColor = $surface; $Control.ForeColor = $ink
    } elseif ($Control -is [Windows.Forms.Form] -or ($Control -is [Windows.Forms.Panel] -and -not ($Control -is [Windows.Forms.TableLayoutPanel]))) {
        $Control.BackColor = $canvas; $Control.ForeColor = $ink
    }
    foreach ($child in $Control.Controls) { Set-AppAppearance $child -Nested }
    } finally { $Control.ResumeLayout($false) }
    if (-not $Nested) { $Control.PerformLayout(); $Control.Invalidate($true) }
}

# InstallMissingFont: Boot-time, private-app font setup only; never full AI setup.
# Exceptions: Setup is logged and surfaced; closing the dialog never kills an installer.
function Show-ToolboxOptions {
    param([switch]$InstallMissingFont)
    if ($null -ne $script:state.Worker) { throw 'Attendi la conclusione del lavoro prima del setup.' }
    $dialog = New-Object PhotoOrganizer.DpiForm
    if ($null -ne $script:brandIcon) { $dialog.Icon = [Drawing.Icon]$script:brandIcon.Clone() }
    $dialog.Add_HandleCreated({ param($sender, $eventArgs) Set-WindowTheme $sender })
    $dialog.Text = 'Opzioni / Setup portabile'
    $dialog.ClientSize = New-Object Drawing.Size(820, 680)
    $dialog.MinimumSize = New-Object Drawing.Size(650, 560)
    $dialog.StartPosition = 'CenterParent'; $dialog.Font = New-AppFont 10
    $layout = New-UiTable
    $layout.Dock = 'Fill'; $layout.AutoSize = $false; $layout.Padding = New-Object Windows.Forms.Padding(20)
    $dialog.Controls.Add($layout)
    $header = New-UiTable
    Add-UiRow $header (New-UiLabel 'OPZIONI' -Size 16 -Bold)
    Add-UiRow $header (New-PublisherCredit)
    Add-UiRow $layout $header
    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $appearanceTab = New-Object Windows.Forms.TabPage
    $appearanceTab.Text = 'Aspetto'; $appearanceTab.AutoScroll = $true; $appearanceTab.Tag = 'surface'
    $setupTab = New-Object Windows.Forms.TabPage
    $setupTab.Text = 'Setup'; $setupTab.AutoScroll = $true; $setupTab.Tag = 'surface'
    [void]$tabs.TabPages.Add($appearanceTab); [void]$tabs.TabPages.Add($setupTab)
    $body = New-UiTable
    $body.Dock = 'Top'; $body.Padding = New-Object Windows.Forms.Padding(16)
    $appearanceTab.Controls.Add($body)
    $setupBody = New-UiTable
    $setupBody.Dock = 'Top'; $setupBody.Padding = New-Object Windows.Forms.Padding(16)
    $setupTab.Controls.Add($setupBody)
    Add-UiRow $layout $tabs
    $layout.RowStyles[$layout.RowCount - 1].SizeType = 'Percent'; $layout.RowStyles[$layout.RowCount - 1].Height = 100
    Add-UiRow $body (New-UiLabel 'Font monospace installati o privati della toolbox' -Size 9)
    $fontChoice = New-Object Windows.Forms.ComboBox
    $fontChoice.DropDownStyle = 'DropDownList'; $fontChoice.Dock = 'Top'
    foreach ($name in ($script:monoFamilies.Keys | Sort-Object)) { [void]$fontChoice.Items.Add($name) }
    $fontChoice.SelectedItem = $script:activeFontName
    Add-UiRow $body $fontChoice
    $themeChoice = New-Object Windows.Forms.ComboBox
    $themeChoice.DropDownStyle = 'DropDownList'; $themeChoice.Dock = 'Top'
    [void]$themeChoice.Items.AddRange([object[]]@('Light', 'Dark')); $themeChoice.SelectedItem = $script:uiPreferences.Theme
    Add-UiRow $body (New-UiLabel 'Tema' -Size 9); Add-UiRow $body $themeChoice
    $backendChoice = New-Object Windows.Forms.ComboBox
    $backendChoice.DropDownStyle = 'DropDownList'; $backendChoice.Dock = 'Top'
    [void]$backendChoice.Items.AddRange([object[]]@('Auto', 'CUDA', 'Vulkan', 'CPU'))
    $backendChoice.SelectedItem = 'Auto'
    $toolboxConfigPath = Join-Path $script:appRoot 'config\toolbox.json'
    $engineConfig = [IO.File]::ReadAllText($toolboxConfigPath) | ConvertFrom-Json
    if ($engineConfig.PSObject.Properties.Name -contains 'engine_backend') {
        $selection = $backendChoice.Items | Where-Object { $_ -ieq $engineConfig.engine_backend } | Select-Object -First 1
        if ($selection) { $backendChoice.SelectedItem = $selection }
    }
    Add-UiRow $setupBody (New-UiLabel 'Motore AI locale' -Size 11 -Bold)
    Add-UiRow $setupBody (New-UiLabel 'Auto, NVIDIA CUDA, Intel/AMD Vulkan oppure CPU. NPU non supportata.' -Size 9)
    Add-UiRow $setupBody $backendChoice
    $autoFont = New-Object Windows.Forms.CheckBox
    $autoFont.Text = 'Prepara il font privato all''avvio se manca'; $autoFont.AutoSize = $false; $autoFont.Dock = 'Top'; $autoFont.Height = 44
    $autoFont.Checked = [bool]$script:uiPreferences.AutoInstallMissingFont
    Add-UiRow $body $autoFont
    $userFont = New-Object Windows.Forms.CheckBox
    $userFont.Text = 'Installa il font anche per l''utente Windows (facoltativo)'; $userFont.AutoSize = $false; $userFont.Dock = 'Top'; $userFont.Height = 44
    Add-UiRow $body $userFont
    $models = New-Object Windows.Forms.CheckBox
    $models.Text = 'Includi modelli AI nel setup (~3,1 GiB se mancanti)'; $models.AutoSize = $false; $models.Dock = 'Top'; $models.Height = 44
    $models.Checked = $true; Add-UiRow $setupBody $models
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.Dock = 'Top'
    $installFont = New-UiButton 'Installa font'
    $setup = New-UiButton 'Prepara questa macchina' -Primary
    $buttons.Controls.Add($installFont)
    Add-UiRow $body $buttons
    $setupButtons = New-Object Windows.Forms.FlowLayoutPanel
    $setupButtons.AutoSize = $true; $setupButtons.Dock = 'Top'; $setupButtons.Controls.Add($setup)
    Add-UiRow $setupBody $setupButtons
    Add-UiRow $setupBody (New-UiLabel 'Runtime, modelli e log rimangono nella toolbox. I driver GPU sono gestiti separatamente.' -Size 9 -Color $script:palette.Muted)
    $consolePanel = New-UiTable
    $consolePanel.AutoSize = $false; $consolePanel.Dock = 'Fill'; $consolePanel.Height = 145
    Add-UiRow $consolePanel (New-UiLabel 'ATTIVITA SETUP' -Size 9 -Bold)
    $console = New-Object Windows.Forms.TextBox
    $console.Multiline = $true; $console.ReadOnly = $true; $console.ScrollBars = 'Both'
    $console.WordWrap = $false; $console.Dock = 'Fill'; $console.Height = 170; $console.Tag = 'console'
    Add-UiRow $consolePanel $console
    $consolePanel.RowStyles[$consolePanel.RowCount - 1].SizeType = 'Percent'; $consolePanel.RowStyles[$consolePanel.RowCount - 1].Height = 100
    Add-UiRow $layout $consolePanel
    $layout.RowStyles[$layout.RowCount - 1].SizeType = 'Absolute'; $layout.RowStyles[$layout.RowCount - 1].Height = 145
    $footer = New-Object Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Fill'; $footer.AutoSize = $true; $footer.WrapContents = $false
    $footer.FlowDirection = 'RightToLeft'; $footer.Padding = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $save = New-UiButton 'Applica' -Primary
    $cancel = New-UiButton 'Annulla'
    $footer.Controls.Add($save); $footer.Controls.Add($cancel)
    Add-UiRow $layout $footer
    $dialog.AcceptButton = $save; $dialog.CancelButton = $cancel
    $cancel.Add_Click({ $dialog.Close() })
    $operation = @{ Worker = $null; Exit = $null; Font = $false; TimerBusy = $false }
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 100
    $start = {
        param([bool]$FontOnly)
        if ($null -ne $operation.Worker) { return }
        $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File')
        if ($FontOnly) {
            $arguments += Join-Path $script:appRoot 'scripts\Install-Monospace.ps1'
            if ($userFont.Checked) { $arguments += '-InstallForUser' }
        } else {
            $message = 'Preparare i requisiti nella toolbox? Il setup puo scaricare i modelli (~3,1 GiB) e i runtime mancanti. Non modifica i driver.'
            if ([Windows.Forms.MessageBox]::Show($dialog, $message, 'Setup su richiesta', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
            $arguments += @((Join-Path $script:appRoot 'Setup-Portable.ps1'), '-Backend', [string]$backendChoice.SelectedItem)
            if (-not $models.Checked) { $arguments += '-NoModels' }
        }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = ($arguments | ForEach-Object { [PhotoOrganizer.Native]::QuoteArgument($_) }) -join ' '
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $info.WorkingDirectory = $script:appRoot
        $portableTemp = Join-Path $script:appRoot 'temp'
        [void][IO.Directory]::CreateDirectory($portableTemp)
        $info.EnvironmentVariables['TEMP'] = $portableTemp; $info.EnvironmentVariables['TMP'] = $portableTemp
        # PowerShell 7 hosts can pass a PSModulePath without Windows PowerShell's standard modules.
        $info.EnvironmentVariables['PSModulePath'] = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
        $worker = New-Object PhotoOrganizer.ProcessWorker
        try { $worker.Start($info) } catch { $worker.Dispose(); throw }
        $operation.Worker = $worker; $operation.Exit = $null; $operation.Font = $FontOnly
        foreach ($control in @($installFont, $setup, $save, $cancel, $userFont, $models, $backendChoice)) { $control.Enabled = $false }
        $console.AppendText('Avvio: ' + $info.Arguments + [Environment]::NewLine)
        Write-AppSessionLog 'setup_start' $info.Arguments
        $timer.Start()
    }
    $installFont.Add_Click({ try { & $start $true } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $setup.Add_Click({ try { & $start $false } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $timer.Add_Tick({ param($sender, $eventArgs)
        if ($null -eq $operation.Worker -or $operation.TimerBusy) { return }
        $operation.TimerBusy = $true
        try {
        $line = $null; $count = 0
        while ($count -lt 100 -and $operation.Worker.TryTake([ref]$line)) {
            Write-AppSessionLog ('setup_' + $line.Kind) $line.Text
            if ($line.Kind -eq 'exit') { $operation.Exit = [int]$line.Text }
            else {
                if ($console.TextLength -gt 150000) { $console.Text = $console.Text.Substring($console.TextLength - 100000) }
                $console.AppendText($line.Text + [Environment]::NewLine); $console.ScrollToCaret()
            }
            $count++
        }
        if ($null -ne $operation.Exit -and $operation.Worker.IsCompleted) {
            $sender.Stop(); $operation.Worker.Dispose(); $operation.Worker = $null
            $console.AppendText('Uscita: ' + $operation.Exit + [Environment]::NewLine)
            foreach ($control in @($installFont, $setup, $save, $cancel, $userFont, $models, $backendChoice)) { $control.Enabled = $true }
            if ($operation.Font -and $operation.Exit -eq 0) {
                Refresh-AppFonts
                $fontChoice.Items.Clear()
                foreach ($name in ($script:monoFamilies.Keys | Sort-Object)) { [void]$fontChoice.Items.Add($name) }
                # The installer prepares this bundled family, not an arbitrary missing preference.
                $bundledFamily = $script:privateFonts.Families | Where-Object { $_.Name -like 'JetBrainsMono*' -and $script:monoFamilies.ContainsKey($_.Name) } | Select-Object -First 1
                $selectedFamily = if ($null -ne $bundledFamily) { $bundledFamily.Name } else { $script:activeFontName }
                $fontChoice.SelectedItem = $selectedFamily
                $script:activeFontName = [string]$fontChoice.SelectedItem
                if ($InstallMissingFont) {
                    $script:uiPreferences.FontName = $script:activeFontName
                    $script:preferredFontMissing = $false
                    [IO.File]::WriteAllText((Join-Path $script:appRoot 'config\ui-options.json'), ($script:uiPreferences | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
                }
                Set-AppAppearance $dialog; Set-AppAppearance $script:form
            } elseif (-not $operation.Font -and $operation.Exit -eq 0 -and -not $models.Checked) {
                $script:aiOption.Checked = $false
                Write-UiLog 'Setup senza modelli: AI disattivata. Copia, metadati e pulizia sono disponibili.'
            }
        }
        } catch {
            $sender.Stop()
            Write-AppSessionLog 'setup_ui_error' ($_.Exception.Message + ' | ' + $_.ScriptStackTrace)
            $console.AppendText('Errore: ' + $_.Exception.Message + [Environment]::NewLine)
            if ($null -ne $operation.Worker -and $operation.Worker.IsCompleted) { $operation.Worker.Dispose(); $operation.Worker = $null }
            if ($null -eq $operation.Worker) { foreach ($control in @($installFont, $setup, $save, $cancel, $userFont, $models, $backendChoice)) { $control.Enabled = $true } }
        } finally { $operation.TimerBusy = $false }
    })
    $save.Add_Click({
        try {
            $script:uiPreferences.FontName = [string]$fontChoice.SelectedItem
            $script:uiPreferences.Theme = [string]$themeChoice.SelectedItem
            $script:uiPreferences.AutoInstallMissingFont = $autoFont.Checked
            $script:activeFontName = $script:uiPreferences.FontName
            [IO.File]::WriteAllText((Join-Path $script:appRoot 'config\ui-options.json'), ($script:uiPreferences | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
            # Read the latest config after setup rather than undoing its changes.
            $latest = [IO.File]::ReadAllText($toolboxConfigPath) | ConvertFrom-Json
            $latest | Add-Member -NotePropertyName engine_backend -NotePropertyValue ([string]$backendChoice.SelectedItem).ToLowerInvariant() -Force
            [IO.File]::WriteAllText($toolboxConfigPath, ($latest | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            Set-AppAppearance $script:form
            Write-UiLog ('Preferenze salvate: ' + $script:activeFontName + ' / ' + $script:uiPreferences.Theme + ' / ' + $latest.engine_backend)
            $dialog.Close()
        } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) }
    })
    $dialog.Add_FormClosing({ param($sender, $eventArgs)
        if ($null -ne $operation.Worker) {
            $eventArgs.Cancel = $true
            $console.AppendText('Attendi la conclusione del setup. I download parziali permettono la ripresa.' + [Environment]::NewLine)
        }
    })
    if ($InstallMissingFont) { $dialog.Add_Shown({ try { & $start $true } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } }) }
    if ($script:dialogSmokeMode) { Enable-DialogSmokeCapture $dialog ('gui-options-' + $script:uiPreferences.Theme) }
    Set-AppAppearance $dialog
    try { [void]$dialog.ShowDialog($script:form) }
    finally {
        $timer.Stop(); $timer.Dispose()
        $dialogIcon = $dialog.Icon
        $dialog.Dispose()
        if ($null -ne $script:brandIcon -and $null -ne $dialogIcon) { $dialogIcon.Dispose() }
    }
}
