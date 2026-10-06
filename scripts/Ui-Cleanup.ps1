# Stack: Existing scrollable card stack, populated without any folder enumeration.
function Add-CleanupPanel {
    param([Windows.Forms.TableLayoutPanel]$Stack)
    $card = New-UiCard '04   Pulizia degli originali verificati'
    $intro = New-UiLabel 'Facoltativo, dopo aver controllato le copie. Non serve per copiare o trascrivere.' -Size 9 -Color $script:palette.Muted
    $intro.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 20)
    Add-UiRow $card.Content $intro
    Add-UiRow $card.Content (New-UiLabel '1. Scegli le cartelle da confrontare' -Size 10 -Bold)
    $script:cleanupSource = New-Object Windows.Forms.TextBox
    $script:cleanupTarget = New-Object Windows.Forms.TextBox
    $sourceBrowse = New-UiButton 'Sfoglia...'
    $targetBrowse = New-UiButton 'Sfoglia...'
    $sourceBrowse.AccessibleName = 'Scegli la cartella degli originali da controllare'
    $targetBrowse.AccessibleName = 'Scegli l''archivio con le copie conservate'
    Add-UiRow $card.Content (New-PathRow 'Originali da controllare' $script:cleanupSource $sourceBrowse)
    Add-UiRow $card.Content (New-PathRow 'Archivio con le copie conservate' $script:cleanupTarget $targetBrowse)
    $sourceBrowse.Add_Click({ try { Select-Directory $script:cleanupSource 'Originali da controllare' } catch { Show-UiError $_ } })
    $targetBrowse.Add_Click({ try { Select-Directory $script:cleanupTarget 'Archivio con copie conservate' } catch { Show-UiError $_ } })
    $verificationTip = New-UiLabel 'Metadati e SHA-256 verificano le copie. Se c''e un dubbio, l''originale resta.' -Size 9 -Color $script:palette.Muted
    $verificationTip.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 22)
    Add-UiRow $card.Content $verificationTip
    Add-UiRow $card.Content (New-UiLabel '2. Prepara e simula' -Size 10 -Bold)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true; $actions.AutoSizeMode = 'GrowAndShrink'; $actions.Dock = 'Top'
    $actions.WrapContents = $true; $actions.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    $script:cleanupIndex = New-UiButton 'Indicizza target'
    $script:cleanupPreview = New-UiButton 'Simula pulizia' -Primary
    $script:cleanupApply = New-UiButton 'Cestino / Riprendi'
    $script:cleanupLimit = New-Object Windows.Forms.NumericUpDown
    $script:cleanupLimit.Minimum = 1; $script:cleanupLimit.Maximum = 500; $script:cleanupLimit.Value = 50
    $script:cleanupLimit.Width = 80; $script:cleanupLimit.AccessibleName = 'Massimo file per conferma'
    foreach ($control in @($script:cleanupIndex, $script:cleanupPreview)) {
        $actions.Controls.Add($control)
    }
    Add-UiRow $card.Content $actions
    $indexTip = New-UiLabel 'Indicizza aggiorna la cache nel target; Simula elenca i candidati senza eliminare file.' -Size 9 -Color $script:palette.Muted
    $indexTip.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    Add-UiRow $card.Content $indexTip
    # Keep the label and spinner together even when the action buttons wrap.
    $limitRow = New-UiTable -Columns 2
    $limitRow.ColumnStyles[0].SizeType = 'AutoSize'
    $limitRow.ColumnStyles[1].SizeType = 'Percent'; $limitRow.ColumnStyles[1].Width = 100
    $limitLabel = New-UiLabel 'File per conferma' -Size 9
    $limitLabel.Dock = 'None'; $limitLabel.Anchor = 'Left'
    $limitLabel.Margin = New-Object Windows.Forms.Padding(0, 6, 14, 6)
    $script:cleanupLimit.Anchor = 'Left'
    $script:cleanupLimit.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
    $limitRow.Controls.Add($limitLabel, 0, 0); $limitRow.Controls.Add($script:cleanupLimit, 1, 0)
    $limitRow.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 20)
    Add-UiRow $card.Content $limitRow
    Add-UiRow $card.Content (New-UiLabel '3. Controlla le copie trovate' -Size 10 -Bold)
    $script:cleanupGrid = New-Object Windows.Forms.DataGridView
    $script:cleanupGrid.Dock = 'Top'; $script:cleanupGrid.Height = 200
    $script:cleanupGrid.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 12)
    $script:cleanupGrid.ReadOnly = $true; $script:cleanupGrid.AllowUserToAddRows = $false
    $script:cleanupGrid.AllowUserToDeleteRows = $false; $script:cleanupGrid.RowHeadersVisible = $false
    $script:cleanupGrid.AutoSizeColumnsMode = 'Fill'; $script:cleanupGrid.SelectionMode = 'FullRowSelect'
    $script:cleanupGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
    $script:cleanupGrid.ColumnHeadersDefaultCellStyle.WrapMode = 'False'
    $script:cleanupGrid.ColumnHeadersDefaultCellStyle.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 8)
    $script:cleanupGrid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(6, 4, 6, 4)
    $script:cleanupGrid.AutoSizeRowsMode = 'DisplayedCellsExceptHeaders'
    $script:cleanupGrid.ScrollBars = 'Both'
    $script:cleanupGrid.AllowUserToResizeRows = $false
    $script:cleanupGrid.AccessibleName = 'Risultati della simulazione: originale, copia conservata e verifica'
    foreach ($column in @(@('original', 'Originale'), @('copy', 'Copia conservata'), @('method', 'Verifica'))) {
        [void]$script:cleanupGrid.Columns.Add($column[0], $column[1])
    }
    $script:cleanupGrid.Columns['original'].MinimumWidth = 180
    $script:cleanupGrid.Columns['copy'].MinimumWidth = 180
    $script:cleanupGrid.Columns['method'].MinimumWidth = 110
    $script:cleanupGrid.Columns['original'].FillWeight = 44
    $script:cleanupGrid.Columns['copy'].FillWeight = 44
    $script:cleanupGrid.Columns['method'].FillWeight = 12
    Add-UiRow $card.Content $script:cleanupGrid
    $script:cleanupSummary = New-UiLabel 'Nessuna simulazione eseguita. Il Cestino si abilita solo dopo la verifica.' -Size 9
    $script:cleanupSummary.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 22)
    Add-UiRow $card.Content $script:cleanupSummary
    Add-UiRow $card.Content (New-UiLabel '4. Conferma lo spostamento nel Cestino' -Size 10 -Bold)
    $recycleActions = New-Object Windows.Forms.FlowLayoutPanel
    $recycleActions.AutoSize = $true; $recycleActions.AutoSizeMode = 'GrowAndShrink'; $recycleActions.Dock = 'Top'
    $recycleActions.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 6)
    $recycleActions.Controls.Add($script:cleanupApply)
    $script:cleanupApply.Enabled = $false
    Add-UiRow $card.Content $recycleActions
    Add-UiRow $card.Content (New-UiLabel 'Solo file verificati, ricontrollati su conferma. Nessuna cartella o eliminazione permanente.' -Size 9 -Color $script:palette.Muted)
    $warning = New-UiLabel 'OneDrive sincronizza anche le eliminazioni. Il Cestino va svuotato per liberare spazio.' -Size 9 -Color $script:palette.Amber
    $warning.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 8)
    Add-UiRow $card.Content $warning
    $script:cleanupControls = @($script:cleanupSource, $script:cleanupTarget, $sourceBrowse, $targetBrowse, $script:cleanupIndex, $script:cleanupPreview, $script:cleanupLimit)
    $invalidate = { $script:state.CleanupPlan = $null; $script:cleanupApply.Enabled = $false }
    $script:cleanupSource.Add_TextChanged($invalidate); $script:cleanupTarget.Add_TextChanged($invalidate)
    $script:cleanupLimit.Add_ValueChanged($invalidate)
    $script:cleanupIndex.Add_Click({ try { Start-OrganizerWorkflow 'cleanup-index' } catch { Show-UiError $_ } })
    $script:cleanupPreview.Add_Click({ try { Start-OrganizerWorkflow 'cleanup-plan' } catch { Show-UiError $_ } })
    $script:cleanupApply.Add_Click({ try { Start-OrganizerWorkflow 'cleanup-apply' } catch { Show-UiError $_ } })
    Add-UiRow $Stack $card.Panel
}

# Source: Canonical selected input directory.
# Target: Canonical selected retained-copy directory.
# Exceptions: Changed or absent preview cannot authorize deletion.
function Confirm-CleanupPlan {
    param([string]$Source, [string]$Target)
    $plan = $script:state.CleanupPlan
    if ($null -eq $plan -or $plan.SourceSelection -ine $Source -or $plan.TargetSelection -ine $Target) {
        throw 'Esegui prima Simula pulizia per queste esatte cartelle.'
    }
    $message = 'Spostare nel Cestino al massimo {0} originali verificati? Ogni file viene ricontrollato. I file dubbi restano. OneDrive sincronizza le eliminazioni. Target: {1}' -f $plan.matched, $Target
    return [Windows.Forms.MessageBox]::Show($script:form, $message, 'Conferma piano di pulizia', 'YesNo', 'Warning', 'Button2') -eq 'Yes'
}

# Event: One SHA-256-proven preview candidate; never a deletion instruction.
function Add-CleanupMatch {
    param($Event)
    [void]$script:cleanupGrid.Rows.Add([object[]]@([string](Get-EventValue $Event 'source_relative' ''), [string](Get-EventValue $Event 'target_relative' ''), [string](Get-EventValue $Event 'method' 'SHA-256')))
}

# Summary: Optional-field-safe backend result, including pause and index-only modes.
function Update-CleanupSummary {
    param($Summary)
    $mode = [string](Get-EventValue $Summary 'mode' '')
    $text = 'Target indicizzato: {0} | Candidati: {1} | Nel Cestino: {2} | Conservati: {3} | Gia completati: {4} | Non controllati: {5} | Errori: {6}' -f
        (Get-EventValue $Summary 'indexed' 0), (Get-EventValue $Summary 'matched' 0), (Get-EventValue $Summary 'deleted' 0),
        (Get-EventValue $Summary 'kept' 0), (Get-EventValue $Summary 'already_done' 0), (Get-EventValue $Summary 'remaining' 0), (Get-EventValue $Summary 'errors' 0)
    $script:cleanupSummary.Text = $text; $script:summaryLabel.Text = $text
    if ((Get-EventValue $Summary 'uncertain' 0) -gt 0) {
        $script:cleanupSummary.Text += ' | Ricevute incomplete: controllo manuale obbligatorio.'
        $script:summaryLabel.Text = $script:cleanupSummary.Text
    }
    if ($mode -eq 'cleanup-plan' -and (Get-EventValue $Summary 'ready_for_review' $false) -and -not (Get-EventValue $Summary 'stopped' $false)) {
        # Keep selected junction spellings for UI comparison; Python validates canonical roots.
        $Summary | Add-Member -NotePropertyName SourceSelection -NotePropertyValue (Resolve-DirectoryText $script:cleanupSource.Text) -Force
        $Summary | Add-Member -NotePropertyName TargetSelection -NotePropertyValue (Resolve-DirectoryText $script:cleanupTarget.Text) -Force
        $script:state.CleanupPlan = $Summary
    } elseif ($mode -eq 'cleanup-apply' -and (Get-EventValue $Summary 'ready_for_review' $false)) { $script:state.CleanupPlan = $null }
    Write-UiLog $text 'PULIZIA'
}
