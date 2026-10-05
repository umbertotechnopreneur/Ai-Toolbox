# Stack: Existing scrollable card stack, populated without any folder enumeration.
function Add-CleanupPanel {
    param([Windows.Forms.TableLayoutPanel]$Stack)
    $card = New-UiCard '04   Pulizia degli originali verificati'
    $script:cleanupSource = New-Object Windows.Forms.TextBox
    $script:cleanupTarget = New-Object Windows.Forms.TextBox
    $sourceBrowse = New-UiButton 'Sfoglia origine'
    $targetBrowse = New-UiButton 'Sfoglia target'
    Add-UiRow $card.Content (New-PathRow 'Originali da controllare' $script:cleanupSource $sourceBrowse)
    Add-UiRow $card.Content (New-PathRow 'Archivio con le copie conservate' $script:cleanupTarget $targetBrowse)
    $sourceBrowse.Add_Click({ try { Select-Directory $script:cleanupSource 'Originali da controllare' } catch { Show-UiError $_ } })
    $targetBrowse.Add_Click({ try { Select-Directory $script:cleanupTarget 'Archivio con copie conservate' } catch { Show-UiError $_ } })
    Add-UiRow $card.Content (New-UiLabel 'Prima i metadati, poi SHA-256. Un dubbio = originale conservato. Nessuna cancellazione di cartelle.' -Size 9 -Color $script:palette.Muted)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true; $actions.Dock = 'Top'
    $script:cleanupIndex = New-UiButton 'Indicizza target'
    $script:cleanupPreview = New-UiButton 'Simula pulizia'
    $script:cleanupApply = New-UiButton 'Cestino / Riprendi'
    $script:cleanupLimit = New-Object Windows.Forms.NumericUpDown
    $script:cleanupLimit.Minimum = 1; $script:cleanupLimit.Maximum = 500; $script:cleanupLimit.Value = 50
    $script:cleanupLimit.Width = 80; $script:cleanupLimit.AccessibleName = 'Massimo file per conferma'
    foreach ($control in @($script:cleanupIndex, $script:cleanupPreview, $script:cleanupApply, (New-UiLabel 'Max file:' -Size 9), $script:cleanupLimit)) {
        $actions.Controls.Add($control)
    }
    Add-UiRow $card.Content $actions
    $script:cleanupGrid = New-Object Windows.Forms.DataGridView
    $script:cleanupGrid.Dock = 'Top'; $script:cleanupGrid.Height = 180
    $script:cleanupGrid.ReadOnly = $true; $script:cleanupGrid.AllowUserToAddRows = $false
    $script:cleanupGrid.AllowUserToDeleteRows = $false; $script:cleanupGrid.RowHeadersVisible = $false
    $script:cleanupGrid.AutoSizeColumnsMode = 'Fill'; $script:cleanupGrid.SelectionMode = 'FullRowSelect'
    foreach ($column in @(@('original', 'Originale'), @('copy', 'Copia conservata'), @('method', 'Verifica'))) {
        [void]$script:cleanupGrid.Columns.Add($column[0], $column[1])
    }
    Add-UiRow $card.Content $script:cleanupGrid
    $script:cleanupSummary = New-UiLabel 'Simula prima di abilitare il Cestino. L''indice SQLite resta nel target, in .photo-cleanup.' -Size 9
    Add-UiRow $card.Content $script:cleanupSummary
    Add-UiRow $card.Content (New-UiLabel 'ATTENZIONE: OneDrive sincronizza anche le eliminazioni. Il Cestino non libera spazio finche non viene svuotato. Non e prevista eliminazione permanente.' -Size 9 -Color $script:palette.Amber)
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
