<#
.SYNOPSIS
    Safe, idempotent, fully automated Node.js + n8n updater for Windows.

.DESCRIPTION
    Installs or updates Node.js and n8n to the newest safe versions that match
    n8n's engine requirements. Creates backups of ~/.n8n before making changes,
    validates installations, and safely repairs both User and Machine PATHs.

    Features:
      • Automatic Node.js version selection based on n8n metadata
      • Automatic n8n installation/update
      • Reliable PATH repair (no npm calls required)
      • Full backup system with timestamped .zip output
      • Safe elevation handling
      • Fully idempotent — safe to run repeatedly
      • Windows PowerShell 5.1 and PowerShell 7+ compatible

.NOTES
    Author:  J2897
    Refined: ChatGPT 5.1 (OpenAI)
    Version: 2025 Polished Edition
#>

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------
# ADMIN ELEVATION
# ---------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$IsAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Re-launching with administrative privileges..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    )
    exit
}

Write-Host "=== n8n Safe Updater for Windows ==="

# ---------------------------------------------------------------
# UTILITIES
# ---------------------------------------------------------------
function Try-Command {
    param([string]$Cmd)
    try { Invoke-Expression $Cmd 2>$null } catch { $null }
}

function Get-Json {
    param([string]$Url)
    try {
        (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Failed to fetch JSON from $Url"
        exit 1
    }
}

# ---------------------------------------------------------------
# NODE UNINSTALL
# ---------------------------------------------------------------
function Uninstall-Node {
    Write-Host "Removing existing Node.js..."

    $unKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $products = Get-ItemProperty -Path $unKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Node.js*" }

    foreach ($p in $products) {
        $uninst = $p.UninstallString

        if ($uninst -match '{[0-9A-Fa-f\-]+}') {
            $guid = [regex]::Match($uninst, '{[0-9A-Fa-f\-]+}').Value
            Start-Process msiexec.exe -Wait -ArgumentList "/x $guid /quiet /norestart"
        }
        elseif ($uninst) {
            Start-Process cmd.exe -Wait -ArgumentList "/c `"$uninst`""
        }
    }

    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------
# NODE INSTALL
# ---------------------------------------------------------------
function Install-Node {
    param([string]$Version)

    $clean = $Version.TrimStart('v')
    $msiUrl  = "https://nodejs.org/dist/v$clean/node-v$clean-x64.msi"
    $msiPath = Join-Path $env:TEMP "node-v$clean-x64.msi"

    Write-Host "Installing Node $Version..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msiPath`" /quiet /norestart"
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# NODE PATH RESOLUTION
# ---------------------------------------------------------------
function Resolve-NodeInstallPath {
    foreach ($loc in @(
        "C:\Program Files\nodejs",
        "$env:LOCALAPPDATA\Programs\nodejs"
    )) {
        if (Test-Path (Join-Path $loc "node.exe")) {
            return $loc
        }
    }
    return $null
}

# ---------------------------------------------------------------
# REPAIR PATH (PATCH 1 APPLIED)
# ---------------------------------------------------------------
function Repair-Path {
    param([string]$NodeDir)

    # Expected npm global locations
    $npmBin   = Join-Path $env:APPDATA "npm"
    $npmCache = Join-Path $env:APPDATA "npm-cache"

    # Ensure both directories exist
    if (-not (Test-Path $npmBin)) {
        New-Item -ItemType Directory -Path $npmBin -Force | Out-Null
    }
    if (-not (Test-Path $npmCache)) {
        New-Item -ItemType Directory -Path $npmCache -Force | Out-Null
    }

    # Helper to append new path elements uniquely
    $addUnique = {
        param($existing, $new)
        $parts = $existing -split ';' | Where-Object { $_ -ne '' }
        if ($parts -notcontains $new) { ($parts + $new) -join ';' } else { $existing }
    }

    # User PATH
    $pUser = [Environment]::GetEnvironmentVariable("Path","User")
    $pUserNew = $addUnique.Invoke($pUser, $npmBin)
    [Environment]::SetEnvironmentVariable("Path", $pUserNew, "User")

    # Machine PATH
    $pMach = [Environment]::GetEnvironmentVariable("Path","Machine")
    $pMachNew = $addUnique.Invoke($pMach, $NodeDir)
    [Environment]::SetEnvironmentVariable("Path", $pMachNew, "Machine")

    # npm bin FIRST (fixes shim creation)
    $env:PATH = "$npmBin;$pUserNew;$pMachNew"
}

# ---------------------------------------------------------------
# INSTALL n8n (PATCH 3 APPLIED)
# ---------------------------------------------------------------
function Install-N8N {
    param([string]$Version)

    Write-Host "Installing n8n@$Version..."

    $npmRoot  = Join-Path $env:APPDATA "npm"
    $npmCache = Join-Path $env:APPDATA "npm-cache"

    if (-not (Test-Path $npmRoot))  { New-Item -ItemType Directory -Path $npmRoot  -Force | Out-Null }
    if (-not (Test-Path $npmCache)) { New-Item -ItemType Directory -Path $npmCache -Force | Out-Null }

    Write-Host "Running: npm install -g n8n@$Version (raw mode)"
    $npmOutput = cmd.exe /c "npm install -g n8n@$Version 2>&1"
    Write-Host $npmOutput

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: npm failed to install n8n."
        exit 1
    }

    Write-Host "Rebuilding npm shims..."
    $rebuild = cmd.exe /c "npm rebuild -g 2>&1"
    Write-Host $rebuild

    $exe = Join-Path $npmRoot "n8n.cmd"
    if (-not (Test-Path $exe)) {
        Write-Host "ERROR: n8n executable not found after installation."
        exit 1
    }

    $resolved = Try-Command "& `"$exe`" --version"
    if ($resolved.Trim() -ne $Version) {
        Write-Host "ERROR: n8n version mismatch (expected $Version, got $resolved)."
        exit 1
    }

    Write-Host "Installed n8n $resolved"
}

# ---------------------------------------------------------------
# BACKUP (unchanged)
# ---------------------------------------------------------------
function Backup-N8N {
    $n8nDir = Join-Path $env:USERPROFILE ".n8n"
    if (-not (Test-Path $n8nDir)) {
        Write-Host "No n8n data directory found – nothing to back up."
        return
    }

    Write-Host "Creating backup of n8n data..."

    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupRoot = Join-Path $env:USERPROFILE "Desktop\n8n-backups"
    $zipPath    = Join-Path $backupRoot "n8n-backup-$timestamp.zip"
    $tempCopy   = Join-Path $env:TEMP     "n8n-backup-$timestamp"

    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot | Out-Null
    }

    if (Test-Path $tempCopy) {
        Remove-Item $tempCopy -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempCopy | Out-Null

    try {
        Copy-Item "$n8nDir\*" $tempCopy -Recurse -Force
        Compress-Archive -Path $tempCopy -DestinationPath $zipPath -Force
    }
    finally {
        if (Test-Path $tempCopy) {
            Remove-Item $tempCopy -Recurse -Force
        }
    }

    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host "Backup complete ($sizeMB MB) -> $zipPath"
}

# ---------------------------------------------------------------
# MEMORY CHECK
# ---------------------------------------------------------------
$ramFree = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue
Write-Host "Free RAM: $([math]::Round($ramFree)) MB"

if ($ramFree -lt 800) {
    Write-Host "Applying safe Node heap limit..."
    $env:NODE_OPTIONS = "--max-old-space-size=1536"
}

# ---------------------------------------------------------------
# BACKUP BEFORE ANY CHANGES
# ---------------------------------------------------------------
Backup-N8N

# ---------------------------------------------------------------
# BLOCK nvm4w
# ---------------------------------------------------------------
if (Test-Path "C:\nvm4w") {
    Write-Host "ERROR: C:\nvm4w interferes with Node MSI installs."
    exit 1
}

# ---------------------------------------------------------------
# FETCH n8n METADATA
# ---------------------------------------------------------------
$n8nMeta   = Get-Json "https://registry.npmjs.org/n8n/latest"
$latestN8n = $n8nMeta.version
$nodeReq   = $n8nMeta.engines.node

Write-Host "Latest n8n: $latestN8n"
Write-Host "Node requirement: $nodeReq"

# ---------------------------------------------------------------
# PARSE NODE ENGINE requirement
# ---------------------------------------------------------------
$minMatch = [regex]::Match($nodeReq, '(>=|>)\s*(\d+(\.\d+)*)')
$maxMatch = [regex]::Match($nodeReq, '(<=|<)\s*(\d+(?:\.\d+){0,2}(?:\.x)?)')

$minOp   = $minMatch.Groups[1].Value
$minNode = $minMatch.Groups[2].Value

$maxOp   = $maxMatch.Groups[1].Value
$maxNode = $maxMatch.Groups[2].Value
if ($maxNode -match '\.x$') {
    $maxNode = $maxNode -replace '\.x$', '.99.99'
}

# ---------------------------------------------------------------
# FETCH NODE INDEX & SELECT SAFE VERSION
# ---------------------------------------------------------------
$nodeIndex = Get-Json "https://nodejs.org/dist/index.json"

$candidates = $nodeIndex | Where-Object {
    $v = $_.version.TrimStart('v')
    if ($v -match '-') { return $false }
    if (-not ($_.files -contains "win-x64-msi")) { return $false }

    try {
        $ver   = [version]$v
        $minOK = if ($minOp -eq '>=') { $ver -ge [version]$minNode } else { $ver -gt [version]$minNode }
        $maxOK = if ($maxOp -eq '<=') { $ver -le [version]$maxNode } else { $ver -lt [version]$maxNode }
        $minOK -and $maxOK
    } catch { $false }
}

$lts    = $candidates | Where-Object { $_.lts }
$chosen = if ($lts) {
    $lts | Sort-Object { [version]($_.version.TrimStart('v')) } -Descending | Select-Object -First 1
} else {
    $candidates | Sort-Object { [version]($_.version.TrimStart('v')) } -Descending | Select-Object -First 1
}

$targetNode = $chosen.version
Write-Host "Selected Node: $targetNode"

# ---------------------------------------------------------------
# INSTALL OR UPDATE NODE
# ---------------------------------------------------------------
$currentNode = Try-Command "node -v"

$needNode = $true
if ($currentNode) {
    try {
        $verCurrent = [version]$currentNode.TrimStart('v')
        $verTarget  = [version]$targetNode.TrimStart('v')

        if ($verCurrent -eq $verTarget) {
            $needNode = $false
        }
    } catch {
        $needNode = $true
    }
}

if ($needNode) {
    Uninstall-Node
    Install-Node $targetNode
} else {
    Write-Host "Node.js is already the required version ($currentNode) — skipping reinstall."
}

# ---------------------------------------------------------------
# VALIDATE NODE INSTALL & FIX PATH BEFORE npm CALLS (PATCH 2)
# ---------------------------------------------------------------
$nodeDir = Resolve-NodeInstallPath
if (-not $nodeDir) {
    Write-Host "ERROR: Node installation not found after MSI install."
    exit 1
}

# Make node.exe immediately available
$env:PATH = "$nodeDir;$env:PATH"

# Full PATH repair
Repair-Path $nodeDir

$installedNode = Try-Command "node -v"
$installedNpm  = Try-Command "npm -v"

if (-not $installedNode) {
    Write-Host "ERROR: Node not visible after PATH repair."
    exit 1
}

if (-not $installedNpm) {
    Write-Host "ERROR: npm not visible after PATH repair."
    exit 1
}

Write-Host "Node: $installedNode"
Write-Host "npm:  $installedNpm"

# ---------------------------------------------------------------
# INSTALL / UPDATE n8n
# ---------------------------------------------------------------
$currentN8n = Try-Command "n8n --version"

if ($currentN8n) {
    if ($currentN8n.Trim() -ne $latestN8n) {
        Install-N8N $latestN8n
    } else {
        Write-Host "n8n is already up-to-date."
    }
} else {
    Install-N8N $latestN8n
}

Write-Host ""
Write-Host "SUCCESS: n8n $latestN8n installed on Node $installedNode"
Write-Host "Use launch-n8n.ps1 to start n8n."
