# n8n-export-import.ps1 usage guide

This script helps you **export** and **import** n8n data using the installed `n8n` CLI, and (optionally) create/restore a **snapshot zip** of your `.n8n` folder.

It works in two styles:
- **Interactive**: run it with no arguments and pick options from menus.
- **Non-interactive**: pass flags (handy for repeatable backups).

---

## What “UserFolder” means

n8n stores data under a hidden folder named `.n8n`.

This script’s `-UserFolder` parameter should be the **parent directory that contains `.n8n`**.

Example (Windows):

- Your data is at: `C:\Users\you\.n8n\database.sqlite`
- Then use: `-UserFolder C:\Users\you`

The script temporarily sets `N8N_USER_FOLDER` so `n8n` reads/writes the chosen data location, then restores your environment variable when it exits.

---

## Output layout (exports)

By default, exports go to:

- `-Path` (default: `~/n8n-backup`)
- Inside it, a bundle folder is created:
  - `bundle` (or `bundle.YYYYMMDD-HHMMSS` if `-Timestamp` is used)

A typical “Full” export bundle contains:

- `entities\` (directory)
- `workflows\` (directory)
- `credentials\` (directory; **encrypted** backup)
- `snapshot.n8n.zip` (zip of the `.n8n` folder)

If you add `-BundleZip`, you also get:

- `bundle.zip` (a zip containing the whole bundle folder)

---

## Quick start (interactive)

### Export (backup)
```powershell
./n8n-export-import.ps1
```
1) Choose **Export**  
2) Pick an export option (e.g. **Full**)  
3) The script prints where it wrote the bundle

### Import (restore/migrate)
```powershell
./n8n-export-import.ps1
```
1) Choose **Import**  
2) Pick what to import (entities/workflows/credentials) or restore a snapshot zip  
3) Point `-Path` at your bundle folder (or a bundle zip, if supported by your version)

---

## Common non-interactive examples

### Full backup to a specific folder (timestamped)
```powershell
./n8n-export-import.ps1 `
  -Action Export `
  -Preset Full `
  -UserFolder $HOME `
  -Path "$HOME\n8n-backup" `
  -Timestamp `
  -BundleZip
```

### Entities only (optionally include execution-history tables)
```powershell
./n8n-export-import.ps1 -Action Export -Entities -IncludeExecutionHistoryDataTables -Timestamp
```

### Workflows only
```powershell
./n8n-export-import.ps1 -Action Export -Workflows -Timestamp
```

### Credentials export (encrypted backup)
```powershell
./n8n-export-import.ps1 -Action Export -CredentialsEncrypted -Timestamp
```

### Credentials export (decrypted JSON)
Decrypted exports include secrets in plaintext.
```powershell
./n8n-export-import.ps1 -Action Export -CredentialsDecrypted -Timestamp
```

### Import entities from a bundle folder
```powershell
./n8n-export-import.ps1 -Action Import -ImportEntities -Path "C:\backups\bundle"
```

### Import workflows (assign to a project OR user)
```powershell
./n8n-export-import.ps1 -Action Import -ImportWorkflows -Path "C:\backups\bundle" -ProjectId 123
# or: -UserId 456
```

### Import credentials (assign to a project OR user)
```powershell
./n8n-export-import.ps1 -Action Import -ImportCredentials -Path "C:\backups\bundle" -ProjectId 123
```

### Restore a snapshot zip to `.n8n`
Snapshot restore replaces the target `.n8n` folder (it will rename the existing one to a timestamped `.bak.*` folder).
Stop n8n before doing this so files aren’t locked.

```powershell
./n8n-export-import.ps1 `
  -Action Import `
  -RestoreSnapshotZip `
  -Path "C:\backups\snapshot.n8n.20251215-120000.zip" `
  -UserFolder "C:\Users\you"
```

If `-Path` is a **folder**, the script can pick the **newest** `snapshot.n8n*.zip` inside it.

---

## Safety features

- Supports `-WhatIf` / `-Confirm` (uses PowerShell `ShouldProcess`).
- `-Force` allows overwriting certain existing output files (like `snapshot.n8n.zip`, `bundle.zip`, `credentials.decrypted.json`).

---

## Parameter reference (cheat sheet)

- `-Action Export|Import`  
  If omitted, you’ll be prompted interactively.

- `-UserFolder <path>`  
  Parent folder containing `.n8n`.

- `-Path <path>`  
  Export: where to create the bundle folder.  
  Import: bundle folder (and for snapshot restore: either a snapshot zip or a folder containing snapshot zips).

- `-Preset None|Full|WorkflowsOnly|CredentialsOnly|EntitiesOnly`  
  Convenience preset for exports.

Export switches:
- `-Entities`
- `-IncludeExecutionHistoryDataTables`
- `-Workflows`
- `-CredentialsEncrypted`
- `-CredentialsDecrypted`
- `-SnapshotZip`
- `-BundleZip`

Import switches:
- `-ImportEntities`
- `-TruncateTables` (entities import only)
- `-ImportWorkflows`
- `-ImportCredentials`
- `-RestoreSnapshotZip`

Placement:
- `-ProjectId <id>` (workflows/credentials import)
- `-UserId <id>` (workflows/credentials import)  
  Use one or the other, not both.

Behavior:
- `-CloneFirst` (export side only; clones `.n8n` to temp and exports from the clone)
- `-KeepClone`
- `-Timestamp`
- `-Force`
