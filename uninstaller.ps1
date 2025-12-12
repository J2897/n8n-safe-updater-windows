<#
.SYNOPSIS
    Completely removes Node.js, npm, global modules, shims, caches, PATH entries,
    n8n, and N8N_* environment variables from a Windows system.

.DESCRIPTION
    Full reset script for creating a pristine environment before reinstalling
    Node.js and n8n.

    Features:
      • Removes all Node.js MSI installations (x86 & x64)
      • Removes manual/ZIP Node installs from standard locations
      • Removes npm, npx, corepack, and n8n global installs + shims
      • Removes global modules, caches, and REPL history
      • Removes Node/npm/n8n PATH entries safely (exact directory matches)
      • Detects and deletes all executables named node, npm, npx, corepack, or n8n
      • Backs up ~/.n8n before deleting it
      • Removes all persistent N8N_* environment variables (User + Machine)
      • Fully idempotent — safe to run repeatedly
      • Compatible with Windows PowerShell 5.1 and PowerShell 7+
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Full Uninstall: Node.js, npm, npx, corepack, n8n ==="

# ---------------------------------------------------------------
# ELEVATE TO ADMIN IF NEEDED
# ---------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$IsAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Re-launching with administrative privileges..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath
    )
    exit
}

# ---------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------
$NodeInstallDirs = @(
    "C:\Program Files\nodejs",
    "C:\Program Files (x86)\nodejs",
    "$env:LOCALAPPDATA\Programs\nodejs"
)

$NpmDirs = @(
    "$env:APPDATA\npm",
    "$env:APPDATA\npm-cache",
    "$env:USERPROFILE\.npm",
    "$env:USERPROFILE\.node-gyp",
    "$env:USERPROFILE\.node_repl_history"
)

$ShimNames = @(
    "node.cmd","node.ps1",
    "npm.cmd","npm.ps1",
    "npx.cmd","npx.ps1",
    "corepack.cmd","corepack.ps1",
    "n8n.cmd","n8n.ps1"
)

$ExecutableBaseNames = @("node","npm","npx","corepack","n8n")

$N8NDir = Join-Path $env:USERPROFILE ".n8n"

# ---------------------------------------------------------------
# HELPER: Query MSI uninstall entries for Node.js
# ---------------------------------------------------------------
function Get-NodeMSIEntries {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Node.js*" }
}

# ---------------------------------------------------------------
# HELPER: Collect shims anywhere in PATH (dedup dirs)
# ---------------------------------------------------------------
function Get-AllShims {
    $shims = @()

    $dirs = ($env:PATH -split ';' | Where-Object { $_ -ne '' }) |
            Sort-Object -Unique

    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            foreach ($name in $ShimNames) {
                $cand = Join-Path $dir $name
                if (Test-Path $cand) {
                    $shims += $cand
                }
            }
        }
    }

    return $shims
}

# ---------------------------------------------------------------
# HELPER: Collect all executables named node/npm/npx/corepack/n8n
# ---------------------------------------------------------------
function Get-StrayExecutables {
    $hits = @()

    foreach ($name in $ExecutableBaseNames) {
        $cmds = Get-Command $name -ErrorAction SilentlyContinue
        foreach ($cmd in $cmds) {
            if ($cmd.Source -and (Test-Path $cmd.Source)) {
                $hits += $cmd.Source
            }
        }
    }

    # Also check .exe in Node installation directories
    $extra = $NodeInstallDirs | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem $_ -Filter *.exe -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -in $ExecutableBaseNames } |
                Select-Object -ExpandProperty FullName
        }
    }

    return $hits + $extra
}

# ---------------------------------------------------------------
# STATE SUMMARY
# ---------------------------------------------------------------
function Show-SystemState {

    $msi      = Get-NodeMSIEntries
    $nodeDirs = $NodeInstallDirs | Where-Object { Test-Path $_ }
    $npmDirs  = $NpmDirs         | Where-Object { Test-Path $_ }
    $shims    = Get-AllShims
    $strays   = Get-StrayExecutables
    $n8n      = Test-Path $N8NDir

    # Coerce to arrays so Count is always numeric
    $msiCount      = @($msi).Count
    $nodeDirsCount = @($nodeDirs).Count
    $npmDirsCount  = @($npmDirs).Count
    $shimsCount    = @($shims).Count
    $straysCount   = @($strays).Count

    Write-Host ""
    Write-Host "=== System State Before Cleanup ==="
    Write-Host ("Node MSI entries:           {0}" -f $msiCount)
    Write-Host ("Node installation folders:  {0}" -f $nodeDirsCount)
    Write-Host ("npm-related folders:        {0}" -f $npmDirsCount)
    Write-Host ("PATH shims:                 {0}" -f $shimsCount)
    Write-Host ("Stray executables:          {0}" -f $straysCount)
    Write-Host (".n8n directory present:     {0}" -f $(if ($n8n) { "Yes" } else { "No" }))
    Write-Host "==================================="

    if ($msiCount -eq 0 -and
        $nodeDirsCount -eq 0 -and
        $npmDirsCount  -eq 0 -and
        $shimsCount    -eq 0 -and
        $straysCount   -eq 0 -and
        -not $n8n) {
        Write-Host "Nothing to remove. System already clean."
        exit
    }

    $ans = Read-Host "Proceed with full aggressive cleanup? (Y/N)"
    if ($ans -notmatch '^[Yy]$') {
        Write-Host "Aborted."
        exit
    }
}

Show-SystemState

# ---------------------------------------------------------------
# BACKUP ~/.n8n
# ---------------------------------------------------------------
function Backup-N8N {
    if (-not (Test-Path $N8NDir)) {
        Write-Host "No .n8n directory found. Skipping backup."
        return
    }

    Write-Host "Backing up ~/.n8n..."

    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupRoot = Join-Path $env:USERPROFILE "Desktop\n8n-backups"
    $zipPath    = Join-Path $backupRoot "n8n-backup-$timestamp.zip"
    $tempCopy   = Join-Path $env:TEMP "n8n-backup-$timestamp"

    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot | Out-Null
    }

    if (Test-Path $tempCopy) {
        Remove-Item $tempCopy -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempCopy | Out-Null

    try {
        Copy-Item "$N8NDir\*" $tempCopy -Recurse -Force
        Compress-Archive (Join-Path $tempCopy '*') $zipPath -Force
    }
    finally {
        Remove-Item $tempCopy -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host "Backup complete ($sizeMB MB) --> $zipPath"

    Write-Host "Removing .n8n directory..."
    Remove-Item $N8NDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# REMOVE COMPONENTS
# ---------------------------------------------------------------
function Remove-NodeMSI {
    Write-Host "Removing Node.js MSI installations..."

    foreach ($entry in Get-NodeMSIEntries) {
        $u = $entry.UninstallString
        if ($u -match '{[0-9A-Fa-f\-]+}') {
            $guid = [regex]::Match($u,'{[0-9A-Fa-f\-]+}').Value
            Write-Host "  Uninstalling: $guid"
            Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -Wait
        }
        elseif ($u) {
            Write-Host "  Running uninstall command: $u"
            Start-Process cmd.exe -ArgumentList "/c `"$u`"" -Wait
        }
    }
}

function Remove-Folders {
    Write-Host "Removing Node/npm folders..."

    foreach ($dir in ($NodeInstallDirs + $NpmDirs)) {
        if (Test-Path $dir) {
            Write-Host "  Deleting: $dir"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-Shims {
    Write-Host "Removing PATH shims..."

    foreach ($shim in (Get-AllShims | Sort-Object -Unique)) {
        Write-Host "  Removing shim: $shim"
        Remove-Item $shim -Force -ErrorAction SilentlyContinue
    }
}

function Remove-PathEntries {
    Write-Host "Cleaning PATH entries..."

    $targets = @(
        "C:\Program Files\nodejs",
        "C:\Program Files (x86)\nodejs",
        "$env:LOCALAPPDATA\Programs\nodejs",
        "$env:APPDATA\npm"
    )

    foreach ($scope in @("Machine","User")) {
        $path = [Environment]::GetEnvironmentVariable("Path",$scope)
        if (-not $path) { continue }

        $parts    = $path -split ';'
        $filtered = $parts | Where-Object { $_ -and ($targets -notcontains $_) }
        $new      = ($filtered -join ';')

        [Environment]::SetEnvironmentVariable("Path",$new,$scope)
        Write-Host "  Cleaned $scope PATH."
    }

    $env:PATH = (
        [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path","User")
    )
}

function Remove-N8NEnvVars {
    Write-Host "Removing N8N_* environment variables..."

    foreach ($scope in @("Machine","User")) {
        # GetEnvironmentVariables returns a hashtable of name -> value
        $vars = [Environment]::GetEnvironmentVariables($scope)

        $keysToRemove = @()
        foreach ($name in $vars.Keys) {
            if ($name -like 'N8N_*') {
                $keysToRemove += $name
            }
        }

        foreach ($name in $keysToRemove) {
            Write-Host "  Removing $scope variable: $name"
            [Environment]::SetEnvironmentVariable($name, $null, $scope)
        }
    }
}

function Remove-Executables {
    Write-Host "Removing stray executables..."

    foreach ($exe in (Get-StrayExecutables | Sort-Object -Unique)) {
        if (Test-Path $exe) {
            Write-Host "  Removing: $exe"
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-N8N {
    Write-Host "Removing n8n global install..."

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        try { npm uninstall -g n8n --quiet 2>$null } catch {}
    }

    $targets = @(
        "$env:APPDATA\npm\node_modules\n8n",
        "$env:APPDATA\npm\n8n.cmd",
        "$env:APPDATA\npm\n8n.ps1"
    )

    foreach ($p in $targets) {
        if (Test-Path $p) {
            Write-Host "  Deleting: $p"
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------
# EXECUTE FULL CLEANUP
# ---------------------------------------------------------------
Backup-N8N
Remove-N8N
Remove-NodeMSI
Remove-Folders
Remove-Shims
Remove-PathEntries
Remove-Executables
Remove-N8NEnvVars

Write-Host ""
Write-Host "All components removed."
Write-Host "System is clean and ready for fresh installation tests."
