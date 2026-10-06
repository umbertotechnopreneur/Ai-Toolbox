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
    $script:uiPreferences = @{ FontName = 'JetBrainsMono NFM'; Theme = 'System'; AutoInstallMissingFont = $true }
    $path = Join-Path $script:appRoot 'config\ui-options.json'
    if ([IO.File]::Exists($path)) {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        foreach ($key in @('FontName', 'Theme', 'AutoInstallMissingFont')) {
            if ($saved.PSObject.Properties.Name -contains $key) { $script:uiPreferences[$key] = $saved.$key }
        }
    }
    if ($script:uiPreferences.Theme -notin @('System', 'Light', 'Dark')) { $script:uiPreferences.Theme = 'System' }
    $script:effectiveTheme = Get-AppTheme
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

# Resolve explicit Light/Dark choices or the current user's Windows application theme.
# Unavailable Windows personalization settings fall back to Light.
function Get-AppTheme {
    if ($script:uiPreferences.Theme -ne 'System') { return $script:uiPreferences.Theme }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize')
        if ($null -ne $key -and [int]$key.GetValue('AppsUseLightTheme', 1) -eq 0) { return 'Dark' }
    } catch { } # A restricted or absent registry key should not interrupt the GUI.
    finally { if ($null -ne $key) { $key.Dispose() } }
    return 'Light'
}

# Control: child whose container background must match the actual parent surface.
function Get-ParentSurfaceColor {
    param([Windows.Forms.Control]$Control)
    $parent = $Control.Parent
    while ($null -ne $parent) {
        if ($parent -is [PhotoOrganizer.CardPanel]) { return $parent.FillColor }
        if ($parent.BackColor.A -eq 255) { return $parent.BackColor }
        $parent = $parent.Parent
    }
    return $script:palette.Canvas
}

# Window: Existing app-owned form, using the resolved application theme.
function Set-WindowTheme {
    param([Windows.Forms.Form]$Window)
    if (-not $Window.IsHandleCreated) { return }
    $darkValue = [int]($script:effectiveTheme -eq 'Dark')
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
    if (-not $Nested) { $script:effectiveTheme = Get-AppTheme }
    if ($Control -is [Windows.Forms.Form]) { Set-WindowTheme $Control }
    $dark = $script:effectiveTheme -eq 'Dark'
    $surface = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#1C2635' } else { '#FFFFFF' }))
    $canvas = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#111923' } else { '#F2F6FA' }))
    $ink = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#E7EEF8' } else { '#172E49' }))
    $muted = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#B0C0D4' } else { '#60738A' }))
    $border = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#43536A' } else { '#CFDBE8' }))
    $script:palette.Ink = $ink; $script:palette.Muted = $muted; $script:palette.Canvas = $canvas
    $script:palette.Green = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#65DBAF' } else { '#147D61' }))
    $script:palette.Amber = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#F3C46A' } else { '#9B6414' }))
    $script:palette.Red = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#FF929A' } else { '#B23C45' }))
    $font = New-AppFont $Control.Font.SizeInPoints $Control.Font.Style
    if (-not [object]::ReferenceEquals($Control.Font, $font)) { $Control.Font = $font }
    if ($Control.Tag -eq 'settings-page') {
        $Control.BackColor = $canvas; $Control.ForeColor = $ink
    } elseif ($Control -is [PhotoOrganizer.CardPanel]) {
        $Control.BackColor = $canvas; $Control.FillColor = $surface; $Control.BorderColor = $border
    } elseif ($Control.Tag -eq 'header') { $Control.BackColor = $script:palette.Navy }
    elseif ($Control.Tag -eq 'console') { $Control.BackColor = [Drawing.Color]::Black; $Control.ForeColor = [Drawing.Color]::Gainsboro }
    elseif ($Control -is [Windows.Forms.LinkLabel]) {
        $Control.ForeColor = $ink
        $Control.LinkColor = if ($dark) { $script:palette.Cyan } else { $script:palette.Navy }
        $Control.ActiveLinkColor = $script:palette.Cyan; $Control.VisitedLinkColor = $Control.LinkColor
    } elseif ($Control -is [Windows.Forms.Label]) {
        if ($Control.Tag -eq 'ink') { $Control.ForeColor = $ink }
        elseif ($Control.Tag -eq 'muted') { $Control.ForeColor = $muted }
        elseif ($Control.Tag -eq 'green') { $Control.ForeColor = $script:palette.Green }
        elseif ($Control.Tag -eq 'amber') { $Control.ForeColor = $script:palette.Amber }
        elseif ($Control.Tag -eq 'red') { $Control.ForeColor = $script:palette.Red }
        elseif ($Control.Tag -ne 'fixed') { $Control.ForeColor = $ink }
    } elseif ($Control -is [Windows.Forms.Button]) {
        $Control.BackColor = if ($Control.Tag -eq 'primary') { $script:palette.Cyan } else { Get-ParentSurfaceColor $Control }
        $Control.ForeColor = if ($Control.Tag -eq 'primary') { $script:palette.Navy } else { $ink }
        $Control.FlatAppearance.BorderColor = $border
        if ($Control -is [PhotoOrganizer.ThemeButton]) {
            $Control.DisabledTextColor = if ($Control.Tag -eq 'primary') { $script:palette.Navy } else { $muted }
        }
        if ($Control.Tag -ne 'primary') {
            $Control.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#2C3D52' } else { '#EAF1F8' }))
            $Control.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml($(if ($dark) { '#364B64' } else { '#DCE8F3' }))
        }
    } elseif ($Control -is [Windows.Forms.CheckBox]) {
        $Control.BackColor = Get-ParentSurfaceColor $Control; $Control.ForeColor = $ink
        if ($Control -is [PhotoOrganizer.ThemeCheckBox]) { $Control.DisabledTextColor = $muted }
    } elseif ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $surface; $Control.GridColor = $border
        $Control.EnableHeadersVisualStyles = $false
        foreach ($style in @($Control.DefaultCellStyle, $Control.ColumnHeadersDefaultCellStyle, $Control.RowHeadersDefaultCellStyle)) {
            $style.BackColor = $surface; $style.ForeColor = $ink; $style.Font = New-AppFont 9
            $style.SelectionBackColor = $script:palette.Navy; $style.SelectionForeColor = [Drawing.Color]::White
        }
    } elseif ($Control -is [PhotoOrganizer.ThemeTabControl]) {
        $Control.CanvasColor = $canvas; $Control.SurfaceColor = $surface; $Control.BorderColor = $border
        $Control.MutedColor = $muted; $Control.AccentColor = $script:palette.Cyan
        $Control.BackColor = $canvas; $Control.ForeColor = $ink
    } elseif ($Control -is [PhotoOrganizer.ThemeComboBox]) {
        $Control.BackColor = $surface; $Control.ForeColor = $ink
        $Control.SelectionColor = $script:palette.Navy; $Control.DisabledTextColor = $muted
    } elseif ($Control -is [Windows.Forms.TextBox] -or $Control -is [Windows.Forms.ComboBox] -or
        $Control -is [Windows.Forms.CheckBox] -or $Control -is [Windows.Forms.NumericUpDown] -or $Control.Tag -eq 'surface') {
        $Control.BackColor = $surface; $Control.ForeColor = $ink
    } elseif ($Control -is [Windows.Forms.FlowLayoutPanel] -or $Control -is [Windows.Forms.PictureBox]) {
        $Control.BackColor = Get-ParentSurfaceColor $Control; $Control.ForeColor = $ink
    } elseif ($Control -is [Windows.Forms.Form] -or ($Control -is [Windows.Forms.Panel] -and -not ($Control -is [Windows.Forms.TableLayoutPanel]))) {
        $Control.BackColor = $canvas; $Control.ForeColor = $ink
    }
    foreach ($child in $Control.Controls) { Set-AppAppearance $child -Nested }
    } finally { $Control.ResumeLayout($true) }
    if (-not $Nested) { $Control.PerformLayout(); $Control.Invalidate($true) }
}

# Parent: Settings page receiving an independently spaced group.
# Title: Short heading describing one family of controls.
# Hint: Single explanatory line displayed below the heading.
function New-SettingsSection {
    param([Windows.Forms.TableLayoutPanel]$Parent, [string]$Title, [string]$Hint)
    $card = New-UiCard $Title
    $card.Panel.Padding = New-Object Windows.Forms.Padding(22, 20, 22, 24)
    $card.Panel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 18)
    if ($Hint) {
        $tip = New-UiLabel $Hint -Size 9 -Color $script:palette.Muted
        $tip.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
        Add-UiRow $card.Content $tip
    }
    Add-UiRow $Parent $card.Panel
    return $card.Content
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
    $dialog.ClientSize = New-Object Drawing.Size(880, 720)
    $dialog.MinimumSize = New-Object Drawing.Size(650, 560)
    $dialog.LogicalMinimumSize = New-Object Drawing.Size(650, 560)
    $dialog.StartPosition = 'CenterParent'; $dialog.Font = New-AppFont 10
    $layout = New-UiTable
    $layout.Dock = 'Fill'; $layout.AutoSize = $false; $layout.Padding = New-Object Windows.Forms.Padding(20)
    $dialog.Controls.Add($layout)
    $header = New-UiTable -Columns 2
    $header.ColumnStyles[0].SizeType = 'AutoSize'
    $header.ColumnStyles[1].SizeType = 'Percent'; $header.ColumnStyles[1].Width = 100
    $logo = New-VibeWareLogo -Size 64
    $logo.Margin = New-Object Windows.Forms.Padding(0, 0, 16, 8)
    $header.Controls.Add($logo, 0, 0)
    $headerText = New-UiTable
    Add-UiRow $headerText (New-UiLabel 'VIBEWARE / OPZIONI' -Size 16 -Bold)
    Add-UiRow $headerText (New-PublisherCredit)
    $header.Controls.Add($headerText, 1, 0)
    Add-UiRow $layout $header
    $tabs = New-Object PhotoOrganizer.ThemeTabControl
    $tabs.Dock = 'Fill'; $tabs.Multiline = $true
    $tabs.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 8)
    $appearanceTab = New-Object Windows.Forms.TabPage
    $appearanceTab.Text = 'Aspetto'; $appearanceTab.AutoScroll = $true; $appearanceTab.Tag = 'settings-page'
    $setupTab = New-Object Windows.Forms.TabPage
    $setupTab.Text = 'Setup'; $setupTab.AutoScroll = $true; $setupTab.Tag = 'settings-page'
    [void]$tabs.TabPages.Add($appearanceTab); [void]$tabs.TabPages.Add($setupTab)
    $pathChoices = Add-PathSettingsTab $tabs
    $aiModelsTab = New-Object Windows.Forms.TabPage
    $aiModelsTab.Text = 'AI / Models'; $aiModelsTab.Tag = 'surface'
    [void]$tabs.TabPages.Add($aiModelsTab)
    $aiModelsBody = New-UiTable
    $aiModelsBody.Dock = 'Fill'; $aiModelsBody.AutoSize = $false
    $aiModelsBody.Tag = 'surface'; $aiModelsBody.Padding = New-Object Windows.Forms.Padding(18)
    $aiModelsTab.Controls.Add($aiModelsBody)
    Add-UiRow $aiModelsBody (New-UiLabel 'Modelli, engine e risorse locali' -Size 11 -Bold)
    Add-UiRow $aiModelsBody (New-UiLabel 'Aggiorna legge solo metadati locali. Nuclearizza rimuove i componenti AI riscaricabili.' -Size 9 -Color $script:palette.Muted)
    $aiModelsActions = New-Object Windows.Forms.FlowLayoutPanel
    $aiModelsActions.Dock = 'Top'; $aiModelsActions.AutoSize = $true
    $aiModelsActions.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 12)
    $aiModelsRefresh = New-UiButton 'Aggiorna inventario' -Primary
    $aiModelsReset = New-UiButton 'Nuclearizza...'
    $aiModelsReset.Enabled = $false
    $aiModelsActions.Controls.Add($aiModelsRefresh); $aiModelsActions.Controls.Add($aiModelsReset)
    Add-UiRow $aiModelsBody $aiModelsActions
    $aiModelsConsole = New-Object Windows.Forms.RichTextBox
    $aiModelsConsole.Dock = 'Fill'; $aiModelsConsole.ReadOnly = $true; $aiModelsConsole.WordWrap = $false
    $aiModelsConsole.ScrollBars = 'Both'; $aiModelsConsole.Tag = 'console'; $aiModelsConsole.DetectUrls = $false
    $aiModelsConsole.Text = 'Premi Aggiorna inventario per leggere modelli, engine, driver, RAM e spazio della toolbox.'
    $aiModelsConsole.AccessibleName = 'Inventario AI testuale, selezionabile e copiabile'
    Add-UiRow $aiModelsBody $aiModelsConsole
    $aiModelsBody.RowStyles[$aiModelsBody.RowCount - 1].SizeType = 'Percent'; $aiModelsBody.RowStyles[$aiModelsBody.RowCount - 1].Height = 100
    $body = New-UiTable
    $body.Tag = 'settings-page'
    $body.Dock = 'Top'; $body.Padding = New-Object Windows.Forms.Padding(20)
    $appearanceTab.Controls.Add($body)
    $setupBody = New-UiTable
    $setupBody.Tag = 'settings-page'
    $setupBody.Dock = 'Top'; $setupBody.Padding = New-Object Windows.Forms.Padding(20)
    $setupTab.Controls.Add($setupBody)
    Add-UiRow $layout $tabs
    $layout.RowStyles[$layout.RowCount - 1].SizeType = 'Percent'; $layout.RowStyles[$layout.RowCount - 1].Height = 100
    $themeSection = New-SettingsSection $body 'Tema' 'Sistema segue Windows; Light e Dark mantengono una scelta manuale.'
    $fontSection = New-SettingsSection $body 'Carattere monospace' 'Font installati o privati; se manca il preferito, usa un monospace Windows disponibile.'
    $fontInstallSection = New-SettingsSection $body 'Disponibilita del font' 'Il font privato rimane nella toolbox; l''installazione per Windows e facoltativa.'
    $photoSection = New-SettingsSection $setupBody 'Catalogazione delle foto' 'Auto, NVIDIA CUDA, Intel/AMD Vulkan o CPU. NPU non supportata.'
    $speechSection = New-SettingsSection $setupBody 'Trascrizione audio e video' 'Whisper locale su CPU Intel/AMD: genera SRT a fianco dei media, senza CUDA o NPU.'
    $fontChoice = New-Object PhotoOrganizer.ThemeComboBox
    $fontChoice.DropDownStyle = 'DropDownList'; $fontChoice.Dock = 'Top'
    foreach ($name in ($script:monoFamilies.Keys | Sort-Object)) { [void]$fontChoice.Items.Add($name) }
    $fontChoice.SelectedItem = $script:activeFontName
    Add-UiRow $fontSection $fontChoice
    $themeChoice = New-Object PhotoOrganizer.ThemeComboBox
    $themeChoice.DropDownStyle = 'DropDownList'; $themeChoice.Dock = 'Top'
    [void]$themeChoice.Items.AddRange([object[]]@('Sistema', 'Light', 'Dark'))
    $themeChoice.SelectedItem = if ($script:uiPreferences.Theme -eq 'System') { 'Sistema' } else { $script:uiPreferences.Theme }
    Add-UiRow $themeSection $themeChoice
    $backendChoice = New-Object PhotoOrganizer.ThemeComboBox
    $backendChoice.DropDownStyle = 'DropDownList'; $backendChoice.Dock = 'Top'
    [void]$backendChoice.Items.AddRange([object[]]@('Auto', 'CUDA', 'Vulkan', 'CPU'))
    $backendChoice.SelectedItem = 'Auto'
    $toolboxConfigPath = Join-Path $script:appRoot 'config\toolbox.json'
    $engineConfig = [IO.File]::ReadAllText($toolboxConfigPath) | ConvertFrom-Json
    if ($engineConfig.PSObject.Properties.Name -contains 'engine_backend') {
        $selection = $backendChoice.Items | Where-Object { $_ -ieq $engineConfig.engine_backend } | Select-Object -First 1
        if ($selection) { $backendChoice.SelectedItem = $selection }
    }
    Add-UiRow $photoSection (New-UiLabel 'Motore AI' -Size 10 -Bold)
    Add-UiRow $photoSection $backendChoice
    Add-UiRow $photoSection (New-UiLabel 'Auto seleziona il motore durante il setup, in base alla macchina.' -Size 9 -Color $script:palette.Muted)
    $autoFont = New-Object PhotoOrganizer.ThemeCheckBox
    $autoFont.Text = 'Prepara il font privato all''avvio se manca'; $autoFont.AutoSize = $false; $autoFont.Dock = 'Top'; $autoFont.Height = 44
    $autoFont.Checked = [bool]$script:uiPreferences.AutoInstallMissingFont
    Add-UiRow $fontInstallSection $autoFont
    $userFont = New-Object PhotoOrganizer.ThemeCheckBox
    $userFont.Text = 'Rendi il font disponibile anche alle altre app Windows'; $userFont.AutoSize = $false; $userFont.Dock = 'Top'; $userFont.Height = 44
    Add-UiRow $fontInstallSection $userFont
    $models = New-Object PhotoOrganizer.ThemeCheckBox
    $models.Text = 'Includi modelli AI nel setup (~3,1 GiB se mancanti)'; $models.AutoSize = $false; $models.Dock = 'Top'; $models.Height = 44
    $models.Checked = $true; Add-UiRow $photoSection $models
    Add-UiRow $photoSection (New-UiLabel 'Disattiva per installare solo i requisiti, senza scaricare i modelli foto.' -Size 9 -Color $script:palette.Muted)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $true; $buttons.Dock = 'Top'
    $installFont = New-UiButton 'Installa font'
    $setup = New-UiButton 'Prepara questa macchina' -Primary
    $buttons.Controls.Add($installFont)
    Add-UiRow $fontInstallSection $buttons
    $setupButtons = New-Object Windows.Forms.FlowLayoutPanel
    $setupButtons.AutoSize = $true; $setupButtons.Dock = 'Top'; $setupButtons.Controls.Add($setup)
    $installSpeech = New-UiButton 'Installa trascrizione'
    Add-UiRow $photoSection $setupButtons
    Add-UiRow $photoSection (New-UiLabel 'Installa i componenti selezionati; non avvia l''elaborazione delle foto.' -Size 9 -Color $script:palette.Muted)
    $speechButtons = New-Object Windows.Forms.FlowLayoutPanel
    $speechButtons.AutoSize = $true; $speechButtons.Dock = 'Top'; $speechButtons.Controls.Add($installSpeech)
    Add-UiRow $speechSection $speechButtons
    Add-UiRow $speechSection (New-UiLabel 'Scarica modello e requisiti su richiesta; non trascrive file durante il setup.' -Size 9 -Color $script:palette.Muted)
    $videoSection = New-SettingsSection $setupBody 'Descrizione video / Fotogrammi' 'Opt-in nella finestra principale. JSON separato; un fotogramma alla volta, nessuna analisi audio.'
    $videoConfigPath = Join-Path $script:appRoot 'config\video-description.json'
    $videoConfig = [IO.File]::ReadAllText($videoConfigPath) | ConvertFrom-Json
    $videoChoices = New-UiTable 3
    $videoMinimum = New-Object Windows.Forms.NumericUpDown
    $videoMaximum = New-Object Windows.Forms.NumericUpDown
    $videoInterval = New-Object Windows.Forms.NumericUpDown
    $videoMinimum.Minimum = 1; $videoMinimum.Maximum = 120; $videoMinimum.Value = $videoConfig.min_frames
    $videoMaximum.Minimum = 1; $videoMaximum.Maximum = 120; $videoMaximum.Value = $videoConfig.max_frames
    $videoInterval.Minimum = 1; $videoInterval.Maximum = 3600; $videoInterval.DecimalPlaces = 1; $videoInterval.Value = $videoConfig.seconds_per_frame
    $videoIndex = 0
    foreach ($choice in @(@{ Label = 'Min fotogrammi'; Control = $videoMinimum }, @{ Label = 'Max fotogrammi'; Control = $videoMaximum }, @{ Label = 'Secondi / campione'; Control = $videoInterval })) {
        $column = New-UiTable
        $column.Margin = New-Object Windows.Forms.Padding(0, 4, 16, 12)
        Add-UiRow $column (New-UiLabel $choice.Label -Size 9)
        $choice.Control.Dock = 'Top'
        Add-UiRow $column $choice.Control
        $videoChoices.Controls.Add($column, $videoIndex, 0)
        $videoIndex++
    }
    Add-UiRow $videoSection $videoChoices
    Add-UiRow $videoSection (New-UiLabel 'Numero = durata / secondi per campione, entro min e max. Default: 4–24, ogni 30 s.' -Size 9 -Color $script:palette.Muted)
    Add-UiRow $setupBody (New-UiLabel 'Tutto resta nella toolbox. I driver GPU sono gestiti separatamente.' -Size 9 -Color $script:palette.Muted)
    $activityTab = New-Object Windows.Forms.TabPage
    $activityTab.Text = 'Attività setup'; $activityTab.Tag = 'surface'
    [void]$tabs.TabPages.Add($activityTab)
    $consolePanel = New-UiTable
    $consolePanel.Tag = 'surface'; $consolePanel.Padding = New-Object Windows.Forms.Padding(12)
    $consolePanel.AutoSize = $false; $consolePanel.Dock = 'Fill'
    $activityTab.Controls.Add($consolePanel)
    Add-UiRow $consolePanel (New-UiLabel 'ATTIVITA SETUP' -Size 9 -Bold)
    Add-UiRow $consolePanel (New-UiLabel 'Qui compaiono download e installazioni. Il testo si puo selezionare e copiare.' -Size 9 -Color $script:palette.Muted)
    $console = New-Object Windows.Forms.RichTextBox
    $console.Multiline = $true; $console.ReadOnly = $true; $console.ScrollBars = 'Both'
    $console.WordWrap = $false; $console.Dock = 'Fill'; $console.Height = 170; $console.Tag = 'console'
    $console.DetectUrls = $false; $console.HideSelection = $false; $console.BorderStyle = 'FixedSingle'
    $console.AccessibleName = 'Terminale setup: seleziona e copia il testo; scorri per leggere le righe complete'
    Add-UiRow $consolePanel $console
    $consolePanel.RowStyles[$consolePanel.RowCount - 1].SizeType = 'Percent'; $consolePanel.RowStyles[$consolePanel.RowCount - 1].Height = 100
    # Add breathing room only to the settings fields, not to the dense terminal.
    foreach ($section in @($themeSection, $fontSection, $fontInstallSection, $photoSection, $speechSection)) {
        foreach ($field in $section.Controls) {
            $bottom = if ($field -is [Windows.Forms.Label] -and $field.Tag -eq 'muted') { 22 } elseif ($field -is [Windows.Forms.Label]) { 10 } elseif ($field -is [Windows.Forms.FlowLayoutPanel]) { 8 } else { 12 }
            $field.Margin = New-Object Windows.Forms.Padding(0, 4, 0, $bottom)
        }
    }
    $footer = New-Object Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Fill'; $footer.AutoSize = $true; $footer.WrapContents = $false
    $footer.FlowDirection = 'RightToLeft'; $footer.Padding = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $save = New-UiButton 'Applica' -Primary
    $cancel = New-UiButton 'Annulla'
    $footer.Controls.Add($save); $footer.Controls.Add($cancel)
    Add-UiRow $layout $footer
    $dialog.AcceptButton = $save; $dialog.CancelButton = $cancel
    $cancel.Add_Click({ $dialog.Close() })
    $operation = @{ Worker = $null; Exit = $null; Font = $false; Speech = $false; TimerBusy = $false; Maintenance = ''; Console = $console; Plan = $null; InventoryVisited = $false }
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 100
    $start = {
        param([bool]$FontOnly, [bool]$SpeechOnly = $false, [string]$Maintenance = '', [string]$ResetHash = '')
        if ($null -ne $operation.Worker) { return }
        $tabs.SelectedTab = if ($Maintenance) { $aiModelsTab } else { $activityTab }
        $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File')
        $operation.Maintenance = $Maintenance
        $operation.Console = $console
        if (-not $Maintenance) { $operation.Plan = $null }
        if ($Maintenance) {
            $tabs.SelectedTab = $aiModelsTab; $operation.Console = $aiModelsConsole
            $arguments += @((Join-Path $script:appRoot 'scripts\Ai-Maintenance.ps1'), '-Mode', $Maintenance)
            if ($Maintenance -eq 'Info') { $aiModelsConsole.Clear(); $operation.Plan = $null }
            if ($Maintenance -eq 'Reset') {
                $protected = @($script:sourceBox.Text, $script:destinationBox.Text, $script:cleanupSource.Text,
                    $script:cleanupTarget.Text, $pathChoices.Source.Text, $pathChoices.Destination.Text)
                $arguments += @('-ConfirmHash', $ResetHash, '-ProtectedPathsJson', (ConvertTo-Json -InputObject $protected -Compress))
                $operation.Plan = $null
            }
        } elseif ($FontOnly) {
            $arguments += Join-Path $script:appRoot 'scripts\Install-Monospace.ps1'
            if ($userFont.Checked) { $arguments += '-InstallForUser' }
        } elseif ($SpeechOnly) {
            $message = 'Preparare la trascrizione locale? Scarica Whisper small multilingua (circa 500 MB) e pacchetti Python isolati nella toolbox. Nessun audio o video viene elaborato durante il setup. CPU Intel/AMD; NPU non usata.'
            if ([Windows.Forms.MessageBox]::Show($dialog, $message, 'Setup trascrizione su richiesta', 'YesNo', 'Question', 'Button2') -ne 'Yes') { return }
            $arguments += (Join-Path $script:appRoot 'Setup-Transcription.ps1')
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
        $operation.Worker = $worker; $operation.Exit = $null; $operation.Font = $FontOnly; $operation.Speech = $SpeechOnly
        foreach ($control in @($installFont, $setup, $installSpeech, $save, $cancel, $userFont, $models, $backendChoice, $aiModelsRefresh, $aiModelsReset)) { $control.Enabled = $false }
        $operation.Console.AppendText('Avvio: ' + $info.Arguments + [Environment]::NewLine)
        Write-AppSessionLog 'setup_start' $info.Arguments
        $timer.Start()
    }
    $installFont.Add_Click({ try { & $start $true } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $setup.Add_Click({ try { & $start $false } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $installSpeech.Add_Click({ try { & $start $false $true } catch { $console.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $aiModelsRefresh.Add_Click({ try { & $start $false $false 'Info' } catch { $aiModelsConsole.AppendText($_.Exception.Message + [Environment]::NewLine) } })
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedTab -eq $aiModelsTab -and -not $operation.InventoryVisited -and $null -eq $operation.Worker) {
            $operation.InventoryVisited = $true
            try { & $start $false $false 'Info' } catch { $aiModelsConsole.AppendText($_.Exception.Message + [Environment]::NewLine) }
        }
    })
    $aiModelsReset.Add_Click({
        try {
            if ($null -ne $operation.Worker -or $null -eq $operation.Plan) { return }
            $plan = $operation.Plan
            $message = 'Eliminare definitivamente i componenti AI elencati nell''inventario? Circa {0:N2} GiB logici. Python, FFmpeg, font, driver Windows, foto, output, configurazioni e log restano. Per usare di nuovo l''AI devi ripetere il setup.' -f ($plan.bytes / 1GB)
            if ([Windows.Forms.MessageBox]::Show($dialog, $message, 'Nuclearizza AI: anteprima', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
            $confirm = "Questi sono gli esatti percorsi da eliminare, senza Cestino:`r`n`r`n" + (@($plan.paths) -join "`r`n") + "`r`n`r`nConfermi? Operazione irreversibile."
            if ([Windows.Forms.MessageBox]::Show($dialog, $confirm, 'Conferma finale: rimozione permanente', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
            & $start $false $false 'Reset' ([string]$plan.hash)
        } catch { $aiModelsConsole.AppendText($_.Exception.Message + [Environment]::NewLine) }
    })
    $timer.Add_Tick({ param($sender, $eventArgs)
        if ($null -eq $operation.Worker -or $operation.TimerBusy) { return }
        $operation.TimerBusy = $true
        try {
        $terminal = $operation.Console
        $line = $null; $count = 0
        $consoleBatch = New-Object Text.StringBuilder
        while ($count -lt 100 -and $operation.Worker.TryTake([ref]$line)) {
            Write-AppSessionLog ('setup_' + $line.Kind) $line.Text
            if ($line.Kind -eq 'exit') { $operation.Exit = [int]$line.Text }
            elseif ($operation.Maintenance -eq 'Info' -and $line.Text.StartsWith('AI-MAINTENANCE-PLAN ')) {
                $operation.Plan = $line.Text.Substring('AI-MAINTENANCE-PLAN '.Length) | ConvertFrom-Json
            } else {
                [void]$consoleBatch.AppendLine($line.Text)
            }
            $count++
        }
        if ($consoleBatch.Length -gt 0) {
            [PhotoOrganizer.Native]::AppendLogBatch($terminal, $consoleBatch.ToString(), 150000, 100000, $true)
        }
        if ($null -ne $operation.Exit -and $operation.Worker.IsCompleted) {
            $sender.Stop(); $operation.Worker.Dispose(); $operation.Worker = $null
            $terminal.AppendText('Uscita: ' + $operation.Exit + [Environment]::NewLine)
            foreach ($control in @($installFont, $setup, $installSpeech, $save, $cancel, $userFont, $models, $backendChoice, $aiModelsRefresh)) { $control.Enabled = $true }
            $aiModelsReset.Enabled = ($operation.Exit -eq 0 -and $null -ne $operation.Plan -and @($operation.Plan.paths).Count -gt 0)
            if ($operation.Maintenance -eq 'Reset') {
                # A partial reset also requires setup; keep copy-only controls usable.
                $script:aiOption.Checked = $false; $script:transcribeOption.Checked = $false
                if ($null -ne $script:videoDescriptionOption) { $script:videoDescriptionOption.Checked = $false }
            }
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
            } elseif (-not $operation.Maintenance -and -not $operation.Font -and -not $operation.Speech -and $operation.Exit -eq 0 -and -not $models.Checked) {
                $script:aiOption.Checked = $false
                Write-UiLog 'Setup senza modelli: AI disattivata. Copia, metadati e pulizia sono disponibili.'
            }
        }
        } catch {
            $sender.Stop()
            Write-AppSessionLog 'setup_ui_error' ($_.Exception.Message + ' | ' + $_.ScriptStackTrace)
            $operation.Console.AppendText('Errore: ' + $_.Exception.Message + [Environment]::NewLine)
            if ($null -ne $operation.Worker -and $operation.Worker.IsCompleted) { $operation.Worker.Dispose(); $operation.Worker = $null }
            $operation.Plan = $null; $aiModelsReset.Enabled = $false
            if ($null -eq $operation.Worker) { foreach ($control in @($installFont, $setup, $installSpeech, $save, $cancel, $userFont, $models, $backendChoice, $aiModelsRefresh)) { $control.Enabled = $true } }
        } finally { $operation.TimerBusy = $false }
    })
    $save.Add_Click({
        try {
            if ($videoMinimum.Value -gt $videoMaximum.Value) { throw 'Il minimo fotogrammi non puo superare il massimo.' }
            $script:pathHistory.Source = $pathChoices.Source.Text.Trim()
            $script:pathHistory.Destination = $pathChoices.Destination.Text.Trim()
            $script:pathHistory.Sources = @(Get-RecentPaths @($pathChoices.Source.Items))
            $script:pathHistory.Destinations = @(Get-RecentPaths @($pathChoices.Destination.Items))
            if ($script:pathHistory.Source -ine $script:sourceBox.Text) {
                $script:pathHistory.Sources = @(Get-RecentPaths (@($script:pathHistory.Source) + $script:pathHistory.Sources))
            }
            if ($script:pathHistory.Destination -ine $script:destinationBox.Text) {
                $script:pathHistory.Destinations = @(Get-RecentPaths (@($script:pathHistory.Destination) + $script:pathHistory.Destinations))
            }
            Save-PathHistory
            $script:state.SettingDestination = $true
            try {
                Set-PathComboItems $script:sourceBox $script:pathHistory.Sources
                Set-PathComboItems $script:destinationBox $script:pathHistory.Destinations
                $script:sourceBox.Text = $script:pathHistory.Source
                $script:destinationBox.Text = $script:pathHistory.Destination
            } finally { $script:state.SettingDestination = $false }
            $script:state.DestinationCustomized = -not [string]::IsNullOrWhiteSpace($script:destinationBox.Text)
            $videoConfig.min_frames = [int]$videoMinimum.Value
            $videoConfig.max_frames = [int]$videoMaximum.Value
            $videoConfig.seconds_per_frame = [double]$videoInterval.Value
            [IO.File]::WriteAllText($videoConfigPath, ($videoConfig | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
            $script:uiPreferences.FontName = [string]$fontChoice.SelectedItem
            $script:uiPreferences.Theme = if ($themeChoice.SelectedItem -eq 'Sistema') { 'System' } else { [string]$themeChoice.SelectedItem }
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
            $operation.Console.AppendText('Attendi la conclusione dell''operazione in corso.' + [Environment]::NewLine)
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
