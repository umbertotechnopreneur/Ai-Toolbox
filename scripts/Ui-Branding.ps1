# Load small portable brand metadata; user profile folders are not runtime dependencies.
# Exceptions: Unsafe asset paths and non-HTTPS website links are refused.
function Initialize-AppBranding {
    $script:branding = [IO.File]::ReadAllText((Join-Path $script:appRoot 'config\branding.json')) | ConvertFrom-Json
    $website = [Uri]$script:branding.website_url
    if (-not $website.IsAbsoluteUri -or $website.Scheme -ne 'https' -or $website.UserInfo) { throw 'Invalid publisher website.' }
    $manifesto = [Uri]$script:branding.manifesto_url
    if (-not $manifesto.IsAbsoluteUri -or $manifesto.Scheme -ne 'https' -or $manifesto.UserInfo) { throw 'Invalid VibeWare manifesto URL.' }
    $iconPath = [IO.Path]::GetFullPath((Join-Path $script:appRoot $script:branding.icon_path))
    if (-not $iconPath.StartsWith($script:appRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Brand icon must stay in the toolbox.' }
    $vibeWareLogoPath = [IO.Path]::GetFullPath((Join-Path $script:appRoot $script:branding.vibeware_logo_path))
    if (-not $vibeWareLogoPath.StartsWith($script:appRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'VibeWare logo must stay in the toolbox.' }
    $script:brandIcon = $null
    if ([IO.File]::Exists($iconPath)) { $script:brandIcon = New-Object Drawing.Icon($iconPath) }
    $script:vibeWareLogo = $null
    if ([IO.File]::Exists($vibeWareLogoPath)) { $script:vibeWareLogo = [Drawing.Image]::FromFile($vibeWareLogoPath) }
}

# Opens only the configured HTTPS personal website, on an explicit link click.
# Exceptions: Browser startup failures are surfaced through the normal UI log.
function Open-PublisherWebsite {
    $website = [Uri]$script:branding.website_url
    if (-not $website.IsAbsoluteUri -or $website.Scheme -ne 'https' -or $website.UserInfo) { throw 'Invalid publisher website.' }
    Write-UiLog ('Sito autore: ' + $website.AbsoluteUri)
    Start-Process -FilePath $website.AbsoluteUri
}

# Opens the configured VibeWare manifesto URL only after an explicit user click.
# Exceptions: Browser startup failures are surfaced through the normal UI log.
function Open-VibeWareManifesto {
    $manifesto = [Uri]$script:branding.manifesto_url
    if (-not $manifesto.IsAbsoluteUri -or $manifesto.Scheme -ne 'https' -or $manifesto.UserInfo) { throw 'Invalid VibeWare manifesto URL.' }
    Write-UiLog ('Manifesto VibeWare: ' + $manifesto.AbsoluteUri)
    Start-Process -FilePath $manifesto.AbsoluteUri
}

# Returns a compact, monospace publisher credit and explicit website link.
function New-PublisherCredit {
    $credit = New-Object Windows.Forms.FlowLayoutPanel
    $credit.AutoSize = $true; $credit.Dock = 'Top'; $credit.WrapContents = $true
    $credit.BackColor = [Drawing.Color]::Transparent; $credit.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    $name = New-UiLabel ($script:branding.product_name + '  /  ' + $script:branding.publisher_name) -Size 9 -Color $script:palette.Muted
    $name.Dock = 'None'; $name.Margin = New-Object Windows.Forms.Padding(0, 0, 16, 0)
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = $script:branding.website_label; $link.AutoSize = $true
    $link.Font = New-AppFont 9 ([Drawing.FontStyle]::Bold)
    $link.Tag = 'brandlink'; $link.LinkBehavior = 'HoverUnderline'; $link.TabStop = $true
    $link.Margin = New-Object Windows.Forms.Padding(0); $link.AccessibleName = 'Apri il sito di Umberto Giacobbi'
    $link.Add_LinkClicked({ try { Open-PublisherWebsite } catch { Show-UiError $_ } })
    $credit.Controls.Add($name); $credit.Controls.Add($link)
    return $credit
}

# Returns the approved VibeWare logo at a fixed presentation size.
# Exceptions: Missing artwork leaves the About dialog functional without a logo.
function New-VibeWareLogo {
    if ($null -eq $script:vibeWareLogo) { return $null }
    $logo = New-Object Windows.Forms.PictureBox
    $logo.Image = $script:vibeWareLogo
    $logo.SizeMode = 'Zoom'
    $logo.Size = New-Object Drawing.Size(152, 152)
    $logo.Dock = 'None'
    $logo.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    $logo.AccessibleName = 'Logo VibeWare: floppy pixel art con monogramma VW'
    return $logo
}

# Returns a clickable link to the configured VibeWare manifesto URL.
# Exceptions: Browser failures are handled by the normal UI error reporter.
function New-VibeWareManifestoLink {
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = $script:branding.manifesto_label; $link.AutoSize = $true
    $link.Font = New-AppFont 9 ([Drawing.FontStyle]::Bold)
    $link.Tag = 'brandlink'; $link.LinkBehavior = 'HoverUnderline'; $link.TabStop = $true
    $link.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 6)
    $link.AccessibleName = 'Apri il manifesto VibeWare'
    $link.Add_LinkClicked({ try { Open-VibeWareManifesto } catch { Show-UiError $_ } })
    return $link
}

# Shows project identity and safety notes without accessing photos or starting AI.
# Exceptions: Form/font/asset failures are surfaced through the caller's UI log.
function Show-ToolboxAbout {
    $about = New-Object PhotoOrganizer.DpiForm
    $about.Text = 'Informazioni / ' + $script:branding.product_name
    $about.ClientSize = New-Object Drawing.Size(760, 560)
    $about.MinimumSize = New-Object Drawing.Size(620, 440)
    $about.AutoScroll = $true
    $about.StartPosition = 'CenterParent'; $about.Font = New-AppFont 10
    $about.ShowInTaskbar = $false
    if ($null -ne $script:brandIcon) { $about.Icon = [Drawing.Icon]$script:brandIcon.Clone() }
    $about.Add_HandleCreated({ param($sender, $eventArgs) Set-WindowTheme $sender })
    $body = New-UiTable
    $body.Dock = 'Top'; $body.Padding = New-Object Windows.Forms.Padding(24)
    $about.Controls.Add($body)
    $vibeWareLogo = New-VibeWareLogo
    if ($null -ne $vibeWareLogo) { Add-UiRow $body $vibeWareLogo }
    Add-UiRow $body (New-UiLabel $script:branding.product_name -Size 20 -Bold)
    Add-UiRow $body (New-UiLabel ('di ' + $script:branding.publisher_name) -Size 11)
    Add-UiRow $body (New-UiLabel ('Codice ' + $script:branding.code_style + '. Costruito con il supporto dell''AI.') -Size 12 -Bold)
    Add-UiRow $body (New-UiLabel 'Toolbox portabile per organizzare foto e media, conservare metadati e verificare le copie.' -Size 10)
    Add-UiRow $body (New-UiLabel 'Copia e analisi lasciano intatti gli originali. La pulizia richiede un piano verificato e una conferma esplicita.' -Size 9 -Color $script:palette.Muted)
    Add-UiRow $body (New-UiLabel 'Le classificazioni AI sono suggerimenti: controlla il risultato e mantieni un backup prima della pulizia. OneDrive sincronizza anche le eliminazioni.' -Size 9 -Color $script:palette.Amber)
    Add-UiRow $body (New-PublisherCredit)
    Add-UiRow $body (New-VibeWareManifestoLink)
    Add-UiRow $body (New-UiLabel 'VibeWare descrive il codice; non e una licenza. Prima della distribuzione verifica le licenze degli asset e delle dipendenze.' -Size 9 -Color $script:palette.Muted)
    $close = New-UiButton 'Chiudi'
    $close.DialogResult = 'OK'; $about.AcceptButton = $close; $about.CancelButton = $close
    Add-UiRow $body $close
    if ($script:dialogSmokeMode) { Enable-DialogSmokeCapture $about ('gui-about-' + $script:uiPreferences.Theme) }
    Set-AppAppearance $about
    try { [void]$about.ShowDialog($script:form) }
    finally {
        $aboutIcon = $about.Icon
        $about.Dispose()
        if ($null -ne $script:brandIcon -and $null -ne $aboutIcon) { $aboutIcon.Dispose() }
    }
}
