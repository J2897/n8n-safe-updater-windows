#Requires -Version 5.1
<#
.SYNOPSIS
  Export/import n8n data (entities, workflows, credentials) + optional .n8n snapshot zip.

.DESCRIPTION
  Uses the installed `n8n` CLI. Temporarily sets N8N_USER_FOLDER to point n8n at the chosen data folder.

  Supports:
   - export:entities / import:entities  (broadest coverage)
   - export:workflow / import:workflow
   - export:credentials / import:credentials (encrypted backup or decrypted export)
   - snapshot zip of ".n8n" (database.sqlite, config, binaryData, nodes, etc.)
   - optional "bundle.zip" that contains entities/workflows/credentials/snapshot

.PARAMETER Action
  Export or Import. If omitted, you'll be prompted interactively.

.PARAMETER UserFolder
  Parent folder containing ".n8n\..." (you may also pass the ".n8n" folder itself).

.PARAMETER Path
  Export: output directory root for bundles.
  Import: folder (or bundle zip) to import from.
  Snapshot restore: either a snapshot zip, or a folder containing snapshot.n8n*.zip.

.EXAMPLE
  # Full export (entities + workflows backup + encrypted creds backup + snapshot zip) into ~/n8n-backup
  .\n8n-export-import.ps1 -Action Export -Preset Full

.EXAMPLE
  # Import entities from a bundle folder and assign to a project
  .\n8n-export-import.ps1 -Action Import -ImportEntities -Path C:\backups\bundle -ProjectId 123

.EXAMPLE
  # Restore the newest snapshot.n8n*.zip from a folder to the given UserFolder parent
  .\n8n-export-import.ps1 -Action Import -RestoreSnapshotZip -Path C:\backups -UserFolder C:\Users\me
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter(Mandatory = $false)]
  [ValidateSet('Export', 'Import')]
  [string]$Action = 'Export',

  # Parent folder containing ".n8n\database.sqlite" etc. (or pass the ".n8n" folder itself)
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias('UserFolderParent')]
  [string]$UserFolder = $HOME,

  # Where to write exports (or read bundles from, depending on Action)
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias('BundlePath')]
  [string]$Path = (Join-Path $HOME 'n8n-backup'),

  # Convenience presets (Export only)
  [Parameter(Mandatory = $false)]
  [ValidateSet('None', 'Full', 'WorkflowsOnly', 'CredentialsOnly', 'EntitiesOnly')]
  [string]$Preset = 'None',

  # Export selectors (if none chosen, script prompts)
  [switch]$Entities,
  [switch]$IncludeExecutionHistoryDataTables,
  [switch]$Workflows,
  [switch]$CredentialsEncrypted,
  [switch]$CredentialsDecrypted,
  [switch]$SnapshotZip,
  [switch]$BundleZip,

  # Import selectors (if none chosen, script prompts)
  [switch]$ImportEntities,
  [switch]$TruncateTables,
  [switch]$ImportWorkflows,
  [switch]$ImportCredentials,
  [switch]$RestoreSnapshotZip,

  # Import placement (n8n supports assigning to a project or user; not both)
  [string]$ProjectId,
  [string]$UserId,

  # Behavior
  [switch]$CloneFirst,      # clone ".n8n" to temp before export/snapshot
  [switch]$KeepClone,
  [switch]$Timestamp,
  [switch]$Force
)

Set-StrictMode -Version Latest

function Write-Ui {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Message = ''
  )

  if ($null -eq $Message) { $Message = '' }
  Write-Information -MessageData $Message -InformationAction Continue
}

function Assert-CommandAvailable {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Name
  )

  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found on PATH: $Name"
  }
}

function Get-FullPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath
  )

  if (Test-Path -LiteralPath $InputPath) {
    return (Resolve-Path -LiteralPath $InputPath).Path
  }

  # Allow non-existent targets (e.g., snapshot restore to a new folder)
  return [System.IO.Path]::GetFullPath($InputPath)
}

function Resolve-UserFolderParent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath
  )

  $full = Get-FullPath -InputPath $InputPath
  if ((Split-Path -Leaf $full) -ieq '.n8n') {
    return (Split-Path -Parent $full)
  }

  return $full
}

function Assert-N8nUserFolder {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Parent
  )

  $n8nDir = Join-Path -Path $Parent -ChildPath '.n8n'
  if (-not (Test-Path -LiteralPath $n8nDir -PathType Container)) {
    throw "n8n folder not found: $n8nDir"
  }
}

function New-Directory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Invoke-RobocopyMirror {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Source,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Destination
  )

  $args = @($Source, $Destination, '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS')
  $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -gt 7) {
    throw "robocopy failed with exit code $($proc.ExitCode)"
  }
}

function New-N8nClone {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Parent
  )

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
  $dstParent = Join-Path -Path $tempRoot -ChildPath "n8n-clone-$stamp"

  $srcN8n = Join-Path -Path $Parent -ChildPath '.n8n'
  $dstN8n = Join-Path -Path $dstParent -ChildPath '.n8n'

  New-Directory -Path $dstN8n

  if (Get-Command -Name 'robocopy.exe' -ErrorAction SilentlyContinue) {
    Invoke-RobocopyMirror -Source $srcN8n -Destination $dstN8n
  }
  else {
    Copy-Item -Path (Join-Path -Path $srcN8n -ChildPath "*") -Destination $dstN8n -Recurse -Force
  }

  return $dstParent
}

function Invoke-N8nCli {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  Write-Verbose ("n8n " + ($Arguments -join ' '))

  # Capture output so we can surface context on failure without polluting the pipeline on success.
  $out = & n8n @Arguments 2>&1
  $exitCode = $LASTEXITCODE

  foreach ($line in $out) {
    if ($null -ne $line) { Write-Verbose ($line.ToString()) }
  }

  if ($exitCode -ne 0) {
    $tail = ($out | Select-Object -Last 30 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($tail) {
      throw "n8n exited with code $exitCode.`n$tail"
    }
    throw "n8n exited with code $exitCode."
  }
}

function Stamp-Name {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Base
  )

  if (-not $Timestamp) { return $Base }
  return '{0}.{1}' -f $Base, (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Select-ExportPreset {
  [CmdletBinding()]
  param()

  if ($Preset -eq 'None') { return }

  switch ($Preset) {
    'Full'          { $script:Entities = $true; $script:Workflows = $true; $script:CredentialsEncrypted = $true; $script:SnapshotZip = $true }
    'EntitiesOnly'  { $script:Entities = $true }
    'WorkflowsOnly' { $script:Workflows = $true }
    'CredentialsOnly' { $script:CredentialsEncrypted = $true }
    default { }
  }
}

function Invoke-N8nExportMenu {
  [CmdletBinding()]
  param()

  Clear-Host
	Write-Ui ""
  Write-Ui "Export options:"
  Write-Ui "  1) Full (entities + workflows backup + creds backup + snapshot zip)"
  Write-Ui "  2) Entities only"
  Write-Ui "  3) Workflows only"
  Write-Ui "  4) Credentials only (encrypted)"
  Write-Ui "  5) Credentials only (decrypted)"
  Write-Ui "  6) Snapshot zip only"
  Write-Ui "  7) Quit"

  switch (Read-Host "Selection [1-7]") {
    '1' { return 'Full' }
    '2' { return 'EntitiesOnly' }
    '3' { return 'WorkflowsOnly' }
    '4' { return 'CredentialsOnlyEnc' }
    '5' { return 'CredentialsOnlyDec' }
    '6' { return 'SnapshotOnly' }
    default { return $null }
  }
}

function Invoke-N8nImportMenu {
  [CmdletBinding()]
  param()

  Clear-Host
	Write-Ui ""
  Write-Ui "Import options:"
  Write-Ui "  1) Entities (from entities dir)"
  Write-Ui "  2) Workflows (from workflows file/dir)"
  Write-Ui "  3) Credentials (from credentials file/dir)"
  Write-Ui "  4) Restore snapshot zip to .n8n (target = -UserFolder)"
  Write-Ui "  5) Quit"

  switch (Read-Host "Selection [1-5]") {
    '1' { return 'Entities' }
    '2' { return 'Workflows' }
    '3' { return 'Credentials' }
    '4' { return 'SnapshotZip' }
    default { return $null }
  }
}

function Invoke-N8nActionMenu {
  [CmdletBinding()]
  param()

  Clear-Host
	Write-Ui ""
  Write-Ui "Mode:"
  Write-Ui "  1) Export"
  Write-Ui "  2) Import"
  Write-Ui "  3) Quit"

  switch (Read-Host "Selection [1-3]") {
    '1' { return 'Export' }
    '2' { return 'Import' }
    default { return $null }
  }
}

function New-ExportBundleRoot {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BasePath
  )

  $root = Get-FullPath -InputPath $BasePath
  $bundle = Join-Path -Path $root -ChildPath (Stamp-Name -Base 'bundle')

  if ($PSCmdlet.ShouldProcess($bundle, 'Create export bundle folder')) {
    New-Directory -Path $root
    New-Directory -Path $bundle
  }

  return $bundle
}

function Export-Entities {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot
  )

  $outDir = Join-Path -Path $BundleRoot -ChildPath 'entities'
  $args = @('export:entities', "--outputDir=$outDir")
  if ($IncludeExecutionHistoryDataTables) { $args += '--includeExecutionHistoryDataTables=true' }

  if ($PSCmdlet.ShouldProcess($outDir, 'Export entities')) {
    New-Directory -Path $outDir
    Invoke-N8nCli -Arguments $args
  }

  return $outDir
}

function Export-Workflows {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot
  )

  $outDir = Join-Path -Path $BundleRoot -ChildPath 'workflows'
  if ($PSCmdlet.ShouldProcess($outDir, 'Export workflows (backup)')) {
    New-Directory -Path $outDir
    Invoke-N8nCli -Arguments @('export:workflow', '--backup', "--output=$outDir")
  }

  return $outDir
}

function Export-CredentialsEncrypted {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot
  )

  $outDir = Join-Path -Path $BundleRoot -ChildPath 'credentials'
  if ($PSCmdlet.ShouldProcess($outDir, 'Export credentials (encrypted backup)')) {
    New-Directory -Path $outDir
    Invoke-N8nCli -Arguments @('export:credentials', '--backup', "--output=$outDir")
  }

  return $outDir
}

function Export-CredentialsDecrypted {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot
  )

  $outFile = Join-Path -Path $BundleRoot -ChildPath (Stamp-Name -Base 'credentials.decrypted.json')
  if ((Test-Path -LiteralPath $outFile) -and -not $Force) { throw "Exists: $outFile (use -Force to overwrite)" }

  if ($PSCmdlet.ShouldProcess($outFile, 'Export credentials (decrypted)')) {
    Invoke-N8nCli -Arguments @('export:credentials', '--all', '--pretty', '--decrypted', "--output=$outFile")
  }

  return $outFile
}

function Export-SnapshotZip {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EffectiveUserFolder
  )

  $zipPath = Join-Path -Path $BundleRoot -ChildPath (Stamp-Name -Base 'snapshot.n8n.zip')
  if ((Test-Path -LiteralPath $zipPath) -and -not $Force) { throw "Exists: $zipPath (use -Force to overwrite)" }

  $src = Join-Path -Path $EffectiveUserFolder -ChildPath '.n8n'
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "Not found: $src" }

  if ($PSCmdlet.ShouldProcess($zipPath, 'Create snapshot zip of .n8n')) {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop }
    Compress-Archive -Path $src -DestinationPath $zipPath -Force
  }

  return $zipPath
}

function Zip-Bundle {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BundleRoot
  )

  $zipPath = Join-Path -Path (Split-Path -Parent $BundleRoot) -ChildPath ((Split-Path -Leaf $BundleRoot) + '.zip')
  if ((Test-Path -LiteralPath $zipPath) -and -not $Force) { throw "Exists: $zipPath (use -Force to overwrite)" }

  if ($PSCmdlet.ShouldProcess($zipPath, 'Zip entire bundle')) {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop }
    Compress-Archive -Path $BundleRoot -DestinationPath $zipPath -Force
  }

  return $zipPath
}

function Import-EntitiesFrom {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EntitiesDir
  )

  if (-not (Test-Path -LiteralPath $EntitiesDir -PathType Container)) { throw "Not found: $EntitiesDir" }

  $args = @('import:entities', "--inputDir=$EntitiesDir")
  if ($TruncateTables) { $args += '--truncateTables=true' }

  if ($PSCmdlet.ShouldProcess($EntitiesDir, 'Import entities')) {
    Invoke-N8nCli -Arguments $args
  }
}

function Import-WorkflowsFrom {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath
  )

  if (-not (Test-Path -LiteralPath $InputPath)) { throw "Not found: $InputPath" }

  $args = @('import:workflow', "--input=$InputPath")
  if (Test-Path -LiteralPath $InputPath -PathType Container) { $args += '--separate' }

  if ($ProjectId) { $args += "--projectId=$ProjectId" }
  if ($UserId)    { $args += "--userId=$UserId" }

  if ($PSCmdlet.ShouldProcess($InputPath, 'Import workflows')) {
    Invoke-N8nCli -Arguments $args
  }
}

function Import-CredentialsFrom {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath
  )

  if (-not (Test-Path -LiteralPath $InputPath)) { throw "Not found: $InputPath" }

  $args = @('import:credentials', "--input=$InputPath")
  if (Test-Path -LiteralPath $InputPath -PathType Container) { $args += '--separate' }

  if ($ProjectId) { $args += "--projectId=$ProjectId" }
  if ($UserId)    { $args += "--userId=$UserId" }

  if ($PSCmdlet.ShouldProcess($InputPath, 'Import credentials')) {
    Invoke-N8nCli -Arguments $args
  }
}

function Restore-SnapshotZipToUserFolder {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SnapshotZipPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetUserFolderParent
  )

  if (-not (Test-Path -LiteralPath $SnapshotZipPath -PathType Leaf)) {
    throw "Snapshot zip not found: $SnapshotZipPath"
  }

  $targetParent = Get-FullPath -InputPath $TargetUserFolderParent
  $targetN8n = Join-Path -Path $targetParent -ChildPath '.n8n'

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupName = ".n8n.bak.$stamp"
  $backupN8n = Join-Path -Path $targetParent -ChildPath $backupName

  $backupCreated = $false

  if ($PSCmdlet.ShouldProcess($targetParent, 'Restore snapshot zip to .n8n')) {
    New-Directory -Path $targetParent

    if (Test-Path -LiteralPath $targetN8n) {
      Rename-Item -LiteralPath $targetN8n -NewName $backupName -ErrorAction Stop
      $backupCreated = $true
    }

    try {
      Expand-Archive -LiteralPath $SnapshotZipPath -DestinationPath $targetParent -Force
    }
    catch {
      # Attempt to roll back to the backup if extraction failed.
      if ($backupCreated -and (Test-Path -LiteralPath $backupN8n) -and -not (Test-Path -LiteralPath $targetN8n)) {
        try { Rename-Item -LiteralPath $backupN8n -NewName '.n8n' -ErrorAction Stop } catch { }
      }
      throw
    }
  }

  [pscustomobject]@{
    SnapshotZip      = $SnapshotZipPath
    TargetUserFolder = $targetParent
    BackupCreated    = $backupCreated
    BackupPath       = $(if ($backupCreated) { $backupN8n } else { $null })
  }
}

function Get-ImportRoot {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TempRoot
  )

  if (Test-Path -LiteralPath $InputPath -PathType Container) {
    return (Resolve-Path -LiteralPath $InputPath).Path
  }

  if (Test-Path -LiteralPath $InputPath -PathType Leaf -and $InputPath -match '\.zip$') {
    $expanded = Join-Path -Path $TempRoot -ChildPath ("n8n-bundle-expand-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($PSCmdlet.ShouldProcess($expanded, 'Expand bundle zip to temp folder')) {
      New-Directory -Path $expanded
      Expand-Archive -LiteralPath $InputPath -DestinationPath $expanded -Force
    }
    $script:ExpandedImportPath = $expanded
    return $expanded
  }

  if ($InputPath -match '\.zip$') {
    # allow non-resolved zip paths (validate later)
    $resolvedZip = Get-FullPath -InputPath $InputPath
    if (-not (Test-Path -LiteralPath $resolvedZip -PathType Leaf)) {
      throw "Zip not found: $resolvedZip"
    }
    return (Get-ImportRoot -InputPath $resolvedZip -TempRoot $TempRoot)
  }

  throw "Not found: $InputPath"
}

# -------- Main --------

$oldEnvN8nUserFolder = $env:N8N_USER_FOLDER
$oldErrorActionPreference = $ErrorActionPreference
$script:ClonePath = $null
$script:ExpandedImportPath = $null

try {
  $ErrorActionPreference = 'Stop'
  Assert-CommandAvailable -Name 'n8n'

  if ($ProjectId -and $UserId) { throw "Use either -ProjectId or -UserId, not both." }
  if ($CredentialsEncrypted -and $CredentialsDecrypted) { throw "Use either -CredentialsEncrypted or -CredentialsDecrypted, not both." }

  $actionWasPassed = $PSBoundParameters.ContainsKey('Action')
  if (-not $actionWasPassed) {
    $picked = Invoke-N8nActionMenu
    if (-not $picked) { Write-Ui "Bye."; return }
    $Action = $picked
  }

  # Prevent accidental cross-action flags
  if ($Action -eq 'Export' -and ($ImportEntities -or $ImportWorkflows -or $ImportCredentials -or $RestoreSnapshotZip -or $TruncateTables -or $ProjectId -or $UserId)) {
    throw "Import-related parameters were provided while -Action Export is selected."
  }
  if ($Action -eq 'Import' -and ($Entities -or $Workflows -or $CredentialsEncrypted -or $CredentialsDecrypted -or $SnapshotZip -or $BundleZip -or $IncludeExecutionHistoryDataTables -or ($Preset -ne 'None') -or $CloneFirst -or $KeepClone)) {
    throw "Export-related parameters were provided while -Action Import is selected."
  }

  $resolvedUserFolder = Resolve-UserFolderParent -InputPath $UserFolder

  # Export needs an existing .n8n. Import via CLI also needs one, but snapshot restore can create it.
  if ($Action -eq 'Export' -or -not $RestoreSnapshotZip) {
    Assert-N8nUserFolder -Parent $resolvedUserFolder
  }

  $effectiveUserFolder = $resolvedUserFolder
  if ($Action -eq 'Export' -and $CloneFirst) {
    if ($PSCmdlet.ShouldProcess($resolvedUserFolder, 'Clone .n8n for export')) {
      $script:ClonePath = New-N8nClone -Parent $resolvedUserFolder
      $effectiveUserFolder = $script:ClonePath
    }
  }

  $env:N8N_USER_FOLDER = $effectiveUserFolder

  if ($Action -eq 'Export') {
    Select-ExportPreset

    $anyExport =
      $Entities -or
      $Workflows -or
      $CredentialsEncrypted -or
      $CredentialsDecrypted -or
      $SnapshotZip

    if (-not $anyExport) {
      $sel = Invoke-N8nExportMenu
      if (-not $sel) { Write-Ui "No export selected."; return }

      switch ($sel) {
        'Full'              { $Entities = $true; $Workflows = $true; $CredentialsEncrypted = $true; $SnapshotZip = $true }
        'EntitiesOnly'      { $Entities = $true }
        'WorkflowsOnly'     { $Workflows = $true }
        'CredentialsOnlyEnc' { $CredentialsEncrypted = $true }
        'CredentialsOnlyDec' { $CredentialsDecrypted = $true }
        'SnapshotOnly'      { $SnapshotZip = $true }
        default { }
      }
    }

    $bundleRoot = New-ExportBundleRoot -BasePath $Path

    $outputs = @()
    if ($Entities)             { $outputs += Export-Entities -BundleRoot $bundleRoot }
    if ($Workflows)            { $outputs += Export-Workflows -BundleRoot $bundleRoot }
    if ($CredentialsEncrypted) { $outputs += Export-CredentialsEncrypted -BundleRoot $bundleRoot }
    if ($CredentialsDecrypted) { $outputs += Export-CredentialsDecrypted -BundleRoot $bundleRoot }
    if ($SnapshotZip)          { $outputs += Export-SnapshotZip -BundleRoot $bundleRoot -EffectiveUserFolder $effectiveUserFolder }

    $bundleZipPath = $null
    if ($BundleZip) { $bundleZipPath = Zip-Bundle -BundleRoot $bundleRoot }

    [pscustomobject]@{
      Action              = 'Export'
      SourceUserFolder    = $resolvedUserFolder
      EffectiveUserFolder = $effectiveUserFolder
      BundleRoot          = $bundleRoot
      Outputs             = $outputs
      BundleZip           = $bundleZipPath
      ClonePath           = $script:ClonePath
    }

    return
  }

  # ----- Import -----

  $anyImport = $ImportEntities -or $ImportWorkflows -or $ImportCredentials -or $RestoreSnapshotZip
  if (-not $anyImport) {
    $sel = Invoke-N8nImportMenu
    if (-not $sel) { Write-Ui "No import selected."; return }

    switch ($sel) {
      'Entities'    { $ImportEntities = $true }
      'Workflows'   { $ImportWorkflows = $true }
      'Credentials' { $ImportCredentials = $true }
      'SnapshotZip' { $RestoreSnapshotZip = $true }
      default { }
    }
  }

  if ($RestoreSnapshotZip) {
    # If -Path is a .zip, use it. If it's a folder, pick the newest snapshot.n8n*.zip inside it.
    $zip = $null

    if ($Path) {
      if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop

        if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
          $zip = $item.FullName
        }
        elseif ($item.PSIsContainer) {
          $candidates = Get-ChildItem -LiteralPath $item.FullName -Filter 'snapshot.n8n*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending
          if ($candidates) { $zip = $candidates[0].FullName }
        }
      }
      elseif ($Path -match '\.zip$') {
        # Allow a direct zip path that hasn't been resolved yet; we'll validate below.
        $zip = $Path
      }
    }

    while (-not $zip -or -not (Test-Path -LiteralPath $zip)) {
      $zip = Read-Host 'Path to snapshot zip'
      if (-not $zip) { Write-Ui 'No snapshot selected.'; return }
    }

    $zip = (Resolve-Path -LiteralPath $zip).Path
    $result = Restore-SnapshotZipToUserFolder -SnapshotZipPath $zip -TargetUserFolderParent $resolvedUserFolder
    $result
    return
  }

  # For non-snapshot imports, allow -Path to be a folder or a bundle zip.
  $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
  $root = Get-ImportRoot -InputPath $Path -TempRoot $tempRoot

  if ($ImportEntities) {
    $entitiesDir = Join-Path -Path $root -ChildPath 'entities'
    Import-EntitiesFrom -EntitiesDir $entitiesDir
  }

  if ($ImportWorkflows) {
    $wf = Join-Path -Path $root -ChildPath 'workflows'
    if (-not (Test-Path -LiteralPath $wf)) { $wf = Read-Host 'Path to workflow file or directory' }
    Import-WorkflowsFrom -InputPath $wf
  }

  if ($ImportCredentials) {
    $cr = Join-Path -Path $root -ChildPath 'credentials'
    if (-not (Test-Path -LiteralPath $cr)) { $cr = Read-Host 'Path to credentials file or directory' }
    Import-CredentialsFrom -InputPath $cr
  }

  [pscustomobject]@{
    Action           = 'Import'
    TargetUserFolder = $resolvedUserFolder
    UsedRoot         = $root
    ProjectId        = $ProjectId
    UserId           = $UserId
  }
}
finally {
  # Restore process state
  $ErrorActionPreference = $oldErrorActionPreference

  if ($null -eq $oldEnvN8nUserFolder) {
    Remove-Item -Path Env:N8N_USER_FOLDER -ErrorAction SilentlyContinue
  }
  else {
    $env:N8N_USER_FOLDER = $oldEnvN8nUserFolder
  }

  if ($script:ExpandedImportPath) {
    try { Remove-Item -LiteralPath $script:ExpandedImportPath -Recurse -Force -ErrorAction Stop } catch { }
  }

  if ($script:ClonePath -and -not $KeepClone) {
    try { Remove-Item -LiteralPath $script:ClonePath -Recurse -Force -ErrorAction Stop } catch { }
  }
}
