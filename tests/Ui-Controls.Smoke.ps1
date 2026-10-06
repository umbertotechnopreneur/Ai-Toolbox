# Render controls in an isolated fixture without starting the actual app or any AI job.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$script:appRoot = Join-Path $sourceRoot ('temp\ui-controls-fixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $script:appRoot 'config'))
foreach ($name in @('toolbox.json', 'transcription.json', 'downloads.lock.json', 'video-description.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot ('config\' + $name)) -Destination (Join-Path $script:appRoot ('config\' + $name))
}
[void][IO.Directory]::CreateDirectory((Join-Path $script:appRoot 'scripts'))
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Ai-Maintenance.ps1') -Destination (Join-Path $script:appRoot 'scripts\Ai-Maintenance.ps1')
[void][IO.Directory]::CreateDirectory((Join-Path $script:appRoot 'models\whisper-small'))
[IO.File]::WriteAllText((Join-Path $script:appRoot 'models\whisper-small\model.bin'), 'synthetic fixture')
$script:guiLogPath = Join-Path $script:appRoot 'fixture.log'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'Photo-Organizer.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$native = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public sealed class DpiForm') }, $true)
Add-Type -TypeDefinition $native.Value -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Core
Add-Type -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public sealed class FixtureSilentForm : Form {
    public Size LogicalMinimumSize { get; set; }
    public FixtureSilentForm() {
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams value = base.CreateParams; value.ExStyle |= 0x08000000; return value; }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing
foreach ($name in @('New-UiLabel', 'New-UiTable', 'Add-UiRow', 'New-UiCard', 'New-UiButton', 'New-PathRow', 'New-MetricCell', 'Write-UiLog', 'Flush-UiLog')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $sourceRoot 'scripts\Ui-Options.ps1')
. (Join-Path $sourceRoot 'scripts\Ui-Paths.ps1')
. (Join-Path $sourceRoot 'scripts\Ui-Cleanup.ps1')
. (Join-Path $sourceRoot 'scripts\Ui-Branding.ps1')
$script:palette = @{ Ink = [Drawing.Color]::White; Muted = [Drawing.Color]::Gray; Green = [Drawing.Color]::Green;
    Amber = [Drawing.Color]::Orange; Red = [Drawing.Color]::Red; Cyan = [Drawing.Color]::Cyan; Navy = [Drawing.Color]::FromArgb(17, 41, 65); Canvas = [Drawing.Color]::Black }
$script:monoFamilies = @{ Consolas = New-Object Drawing.FontFamily('Consolas') }
$script:activeFontName = 'Consolas'; $script:fontCache = @{}
$script:uiPreferences = @{ FontName = 'Consolas'; Theme = 'Dark'; AutoInstallMissingFont = $false }
$script:brandIcon = $null
$script:vibeWareLogo = New-Object Drawing.Bitmap(32, 32)
$script:branding = Get-Content -LiteralPath (Join-Path $sourceRoot 'config\branding.json') -Raw | ConvertFrom-Json
$script:dialogSmokeMode = $false
$script:state = @{ Worker = $null; CleanupPlan = $null; LogBuffer = New-Object Text.StringBuilder; LastLogFlush = [datetime]::MinValue; Mode = 'run' }
$script:sourceBox = New-PathCombo @(); $script:destinationBox = New-PathCombo @()
$script:cleanupSource = New-Object Windows.Forms.TextBox; $script:cleanupTarget = New-Object Windows.Forms.TextBox
$script:pathHistory = @{ Sources = @(); Destinations = @() }
$script:form = New-Object FixtureSilentForm
$script:form.ShowInTaskbar = $false; $script:form.Opacity = 0
$script:form.ClientSize = New-Object Drawing.Size(960, 480)

# Control: subtree to create/layout without displaying or activating its form.
function Initialize-FixtureControls {
    param([Windows.Forms.Control]$Control)
    $null = $Control.Handle
    foreach ($child in $Control.Controls) { Initialize-FixtureControls $child }
    $Control.PerformLayout()
}

# Control: settings subtree whose dropdowns must fit their content tables.
# Exceptions: clipped controls or wrong dark palette fail the fixture.
function Assert-FixtureControls {
    param([Windows.Forms.Control]$Control)
    if ($Control -is [Windows.Forms.ComboBox]) {
        if ($Control -isnot [PhotoOrganizer.ThemeComboBox]) { throw 'Settings combo is not themed.' }
        if ($script:uiPreferences.Theme -eq 'Dark' -and $Control.BackColor.GetBrightness() -gt 0.3) { throw 'Dark combo has a light background.' }
        if ($Control.Bottom -gt $Control.Parent.ClientSize.Height) { throw ('Clipped combo: ' + $Control.Text) }
        $sample = New-Object Drawing.Bitmap($Control.Width, $Control.Height)
        try {
            $Control.DrawToBitmap($sample, (New-Object Drawing.Rectangle(0, 0, $sample.Width, $sample.Height)))
            if ($script:uiPreferences.Theme -eq 'Dark' -and $sample.GetPixel($sample.Width - 6, 4).GetBrightness() -gt 0.3) { throw 'Combo arrow has a light surface.' }
        } finally { $sample.Dispose() }
        $sample = New-Object Drawing.Bitmap(180, 32)
        $graphics = [Drawing.Graphics]::FromImage($sample)
        try {
            $bounds = New-Object Drawing.Rectangle(0, 0, 180, 32)
            $paintEvent = New-Object Windows.Forms.DrawItemEventArgs($graphics, $Control.Font, $bounds, 0, [Windows.Forms.DrawItemState]::Selected)
            $paint = [PhotoOrganizer.ThemeComboBox].GetMethod('OnDrawItem', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$paint.Invoke($Control, [object[]]@($paintEvent.PSObject.BaseObject))
            if ($sample.GetPixel(1, 1).ToArgb() -ne $Control.SelectionColor.ToArgb()) { throw 'Dropdown selected-item theme is incorrect.' }
        } finally { $graphics.Dispose(); $sample.Dispose() }
    }
    foreach ($child in $Control.Controls) { Assert-FixtureControls $child }
}

# Dialog: actual settings dialog constructed from the source under test.
# Tabs: existing pages; prevent the first-visit handler from starting inventory here.
function Invoke-FixtureDialog {
    param($Dialog, $Tabs)
    $operation.InventoryVisited = $true
    $Dialog.ShowInTaskbar = $false; $Dialog.Opacity = 0
    $Dialog.Show()
    [Windows.Forms.Application]::DoEvents()
    Initialize-FixtureControls $Dialog
    for ($index = 0; $index -lt $Tabs.TabCount; $index++) {
        $captionWidth = [Windows.Forms.TextRenderer]::MeasureText($Tabs.TabPages[$index].Text, $Tabs.Font,
            [Drawing.Size]::Empty, [Windows.Forms.TextFormatFlags]'SingleLine,NoPrefix,NoPadding').Width
        if ($captionWidth -gt $Tabs.GetTabRect($index).Width) { throw 'Truncated tab caption.' }
    }
    foreach ($page in $Tabs.TabPages) {
        $Tabs.SelectedTab = $page
        Initialize-FixtureControls $Dialog
        [Windows.Forms.Application]::DoEvents()
        Assert-FixtureControls $page
        $bitmap = New-Object Drawing.Bitmap($Dialog.Width, $Dialog.Height)
        try {
            $Dialog.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $name = ($page.Text -replace '[^A-Za-z0-9]', '-')
            $bitmap.Save((Join-Path $script:appRoot ('settings-' + $script:uiPreferences.Theme + '-' + $name + '.png')))
        } finally { $bitmap.Dispose() }
    }
    $Dialog.ClientSize = New-Object Drawing.Size(650, 560)
    foreach ($page in $Tabs.TabPages) {
        $Tabs.SelectedTab = $page
        Initialize-FixtureControls $Dialog
        [Windows.Forms.Application]::DoEvents()
        Assert-FixtureControls $page
    }
    # Exercise the real ProcessWorker/timer/console binding, but never click Reset.
    $Tabs.SelectedTab = $aiModelsTab
    $aiModelsRefresh.PerformClick()
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while ($null -ne $operation.Worker -and $wait.Elapsed.TotalSeconds -lt 45) {
        [Windows.Forms.Application]::DoEvents()
        [Threading.Thread]::Sleep(20)
    }
    if ($null -ne $operation.Worker) { throw 'Fixture inventory did not complete.' }
    if ($operation.Exit -ne 0 -or $null -eq $operation.Plan) { throw ('Fixture inventory failed: ' + $aiModelsConsole.Text) }
    if (-not $aiModelsReset.Enabled) { throw 'Fresh fixture inventory did not enable its reset button.' }
    foreach ($path in $operation.Plan.paths) {
        if (-not $path.StartsWith($script:appRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'UI reset plan escaped fixture.' }
    }
    if (-not [IO.File]::Exists((Join-Path $script:appRoot 'models\whisper-small\model.bin'))) { throw 'Inventory removed its fixture model.' }
    $Tabs.SelectedTab = $setupTab
    $setupTab.ScrollControlIntoView($videoSection.Parent)
    Initialize-FixtureControls $Dialog
    foreach ($numeric in @($videoMinimum, $videoMaximum, $videoInterval)) {
        if ($numeric.Right -gt $numeric.Parent.ClientSize.Width -or $numeric.Bottom -gt $numeric.Parent.ClientSize.Height) { throw 'Video sampling control is clipped.' }
        if ($script:uiPreferences.Theme -eq 'Dark' -and $numeric.BackColor.GetBrightness() -gt 0.3) { throw 'Video sampling control has a light background.' }
    }
    $bitmap = New-Object Drawing.Bitmap($Dialog.Width, $Dialog.Height)
    try {
        $Dialog.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
        $bitmap.Save((Join-Path $script:appRoot ('settings-' + $script:uiPreferences.Theme + '-Video-sampling.png')))
    } finally { $bitmap.Dispose() }
    $savedSampling = [IO.File]::ReadAllText($videoConfigPath)
    $videoMinimum.Value = 8; $videoMaximum.Value = 4
    $save.PerformClick()
    if ([IO.File]::ReadAllText($videoConfigPath) -ne $savedSampling) { throw 'Invalid sample limits were saved.' }
    $videoMinimum.Value = 4; $videoMaximum.Value = 24; $videoInterval.Value = 45
    $save.PerformClick()
    $savedSampling = [IO.File]::ReadAllText($videoConfigPath) | ConvertFrom-Json
    if ($savedSampling.min_frames -ne 4 -or $savedSampling.max_frames -ne 24 -or $savedSampling.seconds_per_frame -ne 45) { throw ('Sampling settings were not saved: ' + $console.Text) }
    $Dialog.Hide()
}

# Replace only the modal presentation in this process, keeping production source unchanged.
$optionsAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'scripts\Ui-Options.ps1'), [ref]$tokens, [ref]$errors)
$optionsDefinition = $optionsAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ToolboxOptions' }, $true)
$definition = $optionsDefinition.Extent.Text.Replace('try { [void]$dialog.ShowDialog($script:form) }', 'try { Invoke-FixtureDialog $dialog $tabs }')
$definition = $definition.Replace('New-Object PhotoOrganizer.DpiForm', 'New-Object FixtureSilentForm')
. ([scriptblock]::Create($definition))
foreach ($theme in @('Dark', 'Light')) {
    $script:uiPreferences.Theme = $theme
    Show-ToolboxOptions
}

# Construct only the actual panel 03 source block; no main startup or job handlers run.
$mainText = [IO.File]::ReadAllText((Join-Path $sourceRoot 'Photo-Organizer.ps1'))
$activityStart = $mainText.IndexOf('$activity = New-UiCard ''03   Attività''')
$activityEnd = $mainText.IndexOf('Add-CleanupPanel $stack', $activityStart)
if ($activityStart -lt 0 -or $activityEnd -lt 0) { throw 'Panel 03 fixture boundaries not found.' }
$activityBlock = $mainText.Substring($activityStart, $activityEnd - $activityStart)
foreach ($theme in @('Dark', 'Light')) {
    $script:uiPreferences.Theme = $theme
    $stack = New-UiTable
    $script:form.Controls.Add($stack)
    . ([scriptblock]::Create($activityBlock))
    Set-AppAppearance $script:form
    Initialize-FixtureControls $script:form
    if ($activityTabs.TabCount -ne 2) { throw 'Panel 03 must have two tabs.' }
    if ($script:logBox.Parent -ne $logTab -or $script:logBox.Dock -ne 'Fill') { throw 'Log is not hosted in its separate full-size tab.' }
    if ($script:phaseLabel.Parent -ne $progressContent) { throw 'Progress controls escaped their tab.' }
    if ($script:logBox.BackColor -ne [Drawing.Color]::Black) { throw 'Panel 03 terminal lost its black background.' }
    $script:logBox.AppendText('synthetic panel 03 log')
    foreach ($page in $activityTabs.TabPages) {
        $activityTabs.SelectedTab = $page
        Initialize-FixtureControls $script:form
        if ($script:logBox.Text -ne 'synthetic panel 03 log') { throw 'Switching tabs discarded log text.' }
        $bitmap = New-Object Drawing.Bitmap($activity.Panel.Width, $activity.Panel.Height)
        try {
            $activity.Panel.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $bitmap.Save((Join-Path $script:appRoot ('panel03-' + $theme + '-' + $page.Text + '.png')))
        } finally { $bitmap.Dispose() }
    }
    $script:form.Controls.Remove($stack)
    $stack.Dispose()
}

$script:workspace = New-Object PhotoOrganizer.StableScrollPanel
$script:workspace.Size = New-Object Drawing.Size(900, 400)
$script:workspace.AutoScroll = $true
$script:form.Controls.Add($script:workspace)
$stack = New-UiTable
$script:workspace.Controls.Add($stack)
$script:logBox = New-Object Windows.Forms.RichTextBox
$script:logBox.Height = 148; $script:logBox.Dock = 'Top'; $script:logBox.ReadOnly = $true
$script:logBox.MaxLength = [int]::MaxValue; $script:logBox.WordWrap = $false
$script:logBox.ScrollBars = 'Both'; $script:logBox.Tag = 'console'
Add-UiRow $stack $script:logBox
Add-CleanupPanel $stack
$script:form.Show()
[Windows.Forms.Application]::DoEvents()
Initialize-FixtureControls $script:form
$script:workspace.AutoScrollPosition = New-Object Drawing.Point(0, 200)
$before = $script:workspace.AutoScrollPosition
if ($before.Y -ge 0) { throw 'Scroll fixture is not actually scrolled.' }
for ($iteration = 0; $iteration -lt 30; $iteration++) {
    [void]$script:state.LogBuffer.AppendLine(('synthetic log ' + ('x' * 5000)))
    Flush-UiLog -Force
    [Windows.Forms.Application]::DoEvents()
    if ($script:workspace.AutoScrollPosition -ne $before) { throw 'Outer viewport moved during log append.' }
    if (-not $script:logBox.ReadOnly) { throw 'Log editing remained enabled after append.' }
}
if ($script:logBox.TextLength -gt 110000) { throw 'Log trimming did not bound the control text.' }
$script:activeFontName = 'unavailable-fixture-font'
$fallback = New-AppFont 10
if ($script:activeFontName -ne 'Consolas') { throw 'Missing-font fallback did not select Windows monospace.' }
Write-Output ('UI_CONTROLS_OK | Dark/Light settings pages, native helpers and 30 log batches | ' + $script:appRoot)
$script:form.Dispose()
$script:vibeWareLogo.Dispose()
