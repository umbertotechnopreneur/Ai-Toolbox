# Values: recent paths; comparisons are case-insensitive and no folders are enumerated.
function Get-RecentPaths {
    param($Values)
    $result = New-Object 'Collections.Generic.List[string]'
    foreach ($value in @($Values)) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { continue }
        try { $path = [IO.Path]::GetFullPath($value.Trim().Trim('"')) } catch { continue }
        if ($path.Length -gt [IO.Path]::GetPathRoot($path).Length) { $path = $path.TrimEnd([char[]]'\/') }
        if (-not @($result | Where-Object { $_ -ieq $path }).Count) { $result.Add($path) }
        if ($result.Count -ge 20) { break }
    }
    return $result.ToArray()
}

# Load local history without visiting remembered source/destination directories.
function Initialize-PathHistory {
    $script:pathHistory = @{ Source = ''; Destination = ''; Sources = @(); Destinations = @() }
    $script:pathHistoryWarning = ''
    $path = Join-Path $script:appRoot 'config\path-history.json'
    if (-not [IO.File]::Exists($path)) { return }
    try {
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('Source', 'Destination')) {
            if ($saved.PSObject.Properties.Name -contains $key -and $saved.$key -is [string]) { $script:pathHistory[$key] = $saved.$key }
        }
        foreach ($key in @('Sources', 'Destinations')) {
            if ($saved.PSObject.Properties.Name -contains $key) { $script:pathHistory[$key] = @(Get-RecentPaths $saved.$key) }
        }
    } catch { $script:pathHistoryWarning = 'Cronologia percorsi illeggibile: preservata; uso valori vuoti.' }
}

# Persist flushed preferences atomically, preserving the previous file as a backup.
# Exceptions: filesystem errors preserve existing preferences and are reported by the caller.
function Save-PathHistory {
    if ($script:smokeMode -or $script:workflowTestMode) { return }
    $path = Join-Path $script:appRoot 'config\path-history.json'
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $stream = New-Object IO.StreamWriter($temporary, $false, (New-Object Text.UTF8Encoding($false)))
    try {
        $stream.Write(($script:pathHistory | ConvertTo-Json -Depth 4))
        $stream.Flush(); $stream.BaseStream.Flush($true)
    } finally { $stream.Dispose() }
    if ([IO.File]::Exists($path)) {
        $backup = if ($script:pathHistoryWarning) { $path + '.corrupt-' + [guid]::NewGuid().ToString('N') } else { $path + '.bak' }
        [IO.File]::Replace($temporary, $path, $backup)
    } else { [IO.File]::Move($temporary, $path) }
    $script:pathHistoryWarning = ''
}

# Combo: editable path field whose current text survives an item refresh.
# Values: recent paths, most recent first.
function Set-PathComboItems {
    param([Windows.Forms.ComboBox]$Combo, $Values)
    $text = $Combo.Text
    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        foreach ($path in @(Get-RecentPaths $Values)) { [void]$Combo.Items.Add($path) }
        $Combo.Text = $text
    } finally { $Combo.EndUpdate() }
}

# Values: suggestions drawn only from the MRU list, never from a filesystem crawl.
function New-PathCombo {
    param($Values)
    $combo = New-Object PhotoOrganizer.PathComboBox
    $combo.DropDownStyle = 'DropDown'; $combo.FlatStyle = 'Flat'
    $combo.AutoCompleteMode = 'SuggestAppend'; $combo.AutoCompleteSource = 'ListItems'
    $combo.MaxDropDownItems = 12; $combo.IntegralHeight = $false; $combo.DropDownHeight = 260
    Set-PathComboItems $combo $Values
    return $combo
}

# Source: currently selected source, including blank text.
# Destination: currently selected destination, including blank text.
# Exceptions: preference failures are reported by the owning UI event.
function Remember-PathSelection {
    param([string]$Source, [string]$Destination)
    if ($script:smokeMode -or $script:workflowTestMode) { return }
    $script:pathHistory.Source = $Source.Trim()
    $script:pathHistory.Destination = $Destination.Trim()
    $script:pathHistory.Sources = @(Get-RecentPaths (@($Source) + @($script:pathHistory.Sources)))
    $script:pathHistory.Destinations = @(Get-RecentPaths (@($Destination) + @($script:pathHistory.Destinations)))
    Save-PathHistory
    $customized = $script:state.DestinationCustomized
    $script:state.SettingDestination = $true
    try {
        Set-PathComboItems $script:sourceBox $script:pathHistory.Sources
        Set-PathComboItems $script:destinationBox $script:pathHistory.Destinations
    } finally { $script:state.SettingDestination = $false; $script:state.DestinationCustomized = $customized }
}

# Tabs: options tabs; history edits are committed only by Applica.
function Add-PathSettingsTab {
    param([Windows.Forms.TabControl]$Tabs)
    $tab = New-Object Windows.Forms.TabPage
    $tab.Text = 'Percorsi'; $tab.Tag = 'settings-page'; $tab.AutoScroll = $true
    [void]$Tabs.TabPages.Add($tab)
    $body = New-UiTable
    $body.Tag = 'settings-page'; $body.Padding = New-Object Windows.Forms.Padding(20)
    $tab.Controls.Add($body)
    $heading = New-UiLabel 'Percorsi e cronologia' -Size 12 -Bold
    $heading.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    Add-UiRow $body $heading
    $hint = New-UiLabel 'Fino a 20 percorsi per elenco. Applica salva, Annulla scarta le modifiche.' -Size 9 -Color $script:palette.Muted
    $hint.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 22)
    Add-UiRow $body $hint
    $controls = @{}
    foreach ($kind in @('Source', 'Destination')) {
        $sectionTitle = if ($kind -eq 'Source') { 'Sorgenti recenti' } else { 'Destinazioni recenti' }
        $sectionHint = if ($kind -eq 'Source') { 'Scegli o scrivi la cartella da leggere nella finestra principale.' } else { 'Scegli o scrivi la cartella in cui rigenerare l''archivio.' }
        $section = New-SettingsSection $body $sectionTitle $sectionHint
        $values = if ($kind -eq 'Source') { $script:pathHistory.Sources } else { $script:pathHistory.Destinations }
        $combo = New-PathCombo $values
        $combo.Text = if ($kind -eq 'Source') { $script:sourceBox.Text } else { $script:destinationBox.Text }
        $combo.Dock = 'Top'; $controls[$kind] = $combo
        $combo.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
        Add-UiRow $section $combo
        $buttons = New-Object Windows.Forms.FlowLayoutPanel
        $buttons.AutoSize = $true; $buttons.Dock = 'Top'
        $buttons.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
        $remove = New-UiButton 'Rimuovi dall''elenco'; $clear = New-UiButton 'Svuota elenco'
        # Associate controls directly, avoiding event closures over the loop variable.
        $remove.Tag = $combo; $clear.Tag = $combo
        $remove.Add_Click({ param($sender, $eventArgs)
            $choice = $sender.Tag; $text = $choice.Text
            for ($index = $choice.Items.Count - 1; $index -ge 0; $index--) {
                if ([string]$choice.Items[$index] -ieq $text) { $choice.Items.RemoveAt($index) }
            }
            $choice.Text = $text
        })
        $clear.Add_Click({ param($sender, $eventArgs)
            $choice = $sender.Tag; $text = $choice.Text; $choice.Items.Clear(); $choice.Text = $text
        })
        $buttons.Controls.Add($remove); $buttons.Controls.Add($clear)
        Add-UiRow $section $buttons
    }
    $privacy = New-UiLabel 'Rimuovere una voce dalla cronologia non elimina la cartella o i suoi file.' -Size 9 -Color $script:palette.Muted
    $privacy.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 8)
    Add-UiRow $body $privacy
    return $controls
}
