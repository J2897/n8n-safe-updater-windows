# **n8n Safe Updater for Windows**

### _2025 Polished Edition_

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5398c0.svg)](https://learn.microsoft.com/powershell/)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D6.svg)](https://www.microsoft.com/windows)
[![n8n](https://img.shields.io/badge/n8n-latest-FF4D6D.svg)](https://n8n.io/)

A fully automated, idempotent PowerShell script that safely installs or updates **Node.js** and **n8n** on Windows.

It always selects the newest mutually compatible versions and repairs the environment so both tools work reliably — even after broken upgrades.

## Why this script exists

Updating **Node.js** on Windows often breaks **n8n**, because:

* n8n only supports specific Node.js LTS ranges
* npm global bin paths frequently become corrupted
* MSI-based Node.js installers leave stale PATH entries behind
* Failed updates can overwrite important n8n data
* Windows does not regenerate npm shims reliably under certain conditions

This script eliminates all of those problems by enforcing a clean, validated, fully automated upgrade path.

## Features

* Automatically selects the newest **Node.js** version allowed by n8n’s `engines.node` requirement
* Fully removes any existing MSI-installed Node.js before reinstalling cleanly
* Downloads and installs the correct official Node.js MSI silently
* Creates timestamped `.zip` backups of `~/.n8n` on your Desktop before making changes
* Repairs both **User** and **Machine** PATH entries (puts npm’s global bin first to fix shim creation issues)
* Installs or updates global `n8n` with complete output and post-install validation
* Detects and blocks `C:\nvm4w`, which breaks MSI-based Node.js installs
* Idempotent design — safe to run repeatedly or after every new n8n release
* Compatible with Windows PowerShell 5.1 and PowerShell 7+

## Requirements

* Windows 10, Windows 11, or Windows Server 2016+
* Administrative privileges (the script will self-elevate if needed)
* Internet access to fetch Node.js and n8n metadata

## Quick Start

1. Download the script:

   ```powershell
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/J2897/n8n-safe-updater-windows/main/n8n-safe-updater.ps1" -OutFile "n8n-safe-updater.ps1"
   ```

2. Run it:

   * Right-click the file → **Run with PowerShell**, *or*
   * Open an elevated PowerShell session and run:

      ```powershell
      ./n8n-safe-updater.ps1
      ```

The script will automatically:

* Back up your current n8n data
* Install the correct Node.js version
* Install or update n8n
* Validate the installation and show a final success summary

## After running

Start n8n the usual way:

```cmd
n8n start
```

## Backup location

Backups are stored here:

```cmd
%USERPROFILE%\Desktop\n8n-backups\n8n-backup-YYYY-MM-DD_HH-mm-ss.zip
```

Each backup is self-contained and timestamped so you can keep multiple versions safely.

## Troubleshooting

|Issue                                                  |Solution                                                                                           |
|-------------------------------------------------------|---------------------------------------------------------------------------------------------------|
|`ERROR: npm failed to install n8n.`                    |Make sure `%APPDATA%\npm` and `%APPDATA%\npm-cache` exist and are writable, then re-run the script.|
|`ERROR: Node installation not found after MSI install.`|Something blocked the Node.js installer. Temporarily disable antivirus, then re-run the updater.   |

## Credits

* **J2897** — original author and maintainer
* **ChatGPT (2025)** — refinement, debugging, and reliability improvements

## License

This project is distributed under the **GNU General Public License v3.0 (GPLv3)**.
See the [LICENSE](LICENSE) file for full details.
