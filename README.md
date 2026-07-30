# AllGet Auto-Update

An automated, intelligent, background app & package updater for Windows 10 & 11 built on top of **WinGet**, **Chocolatey**, **Scoop**, **npm**, **yarn**, **bun**, and **PowerShell / WPF**. It checks for updates in the background with **seamless silent execution**, postpones updates for active foreground applications to prevent work disruption, and prompts users with a native WinUI 3 styled dialog when an app is running in the background.

---

## 1-Click Installation & Uninstallation

Simply **double-click** either:

- **`Install.cmd`** to **Install**
- **`Uninstall.cmd`** to **Uninstall**

### How it works:

1. Double-clicking automatically triggers Windows Administrator (UAC) elevation.
2. Registers or removes the seamless silent background task in Windows Task Scheduler automatically.
3. Holds the window open so you can clearly see the success message.
4. Zero terminal commands, flags, or manual steps required!

---

## Directory Structure

```
AllGet Auto-Update/
├── Install.cmd                 # [1-CLICK INSTALLER] Double-click to install automatically
├── Uninstall.cmd               # [1-CLICK UNINSTALLER] Double-click to remove task cleanly
├── allget-autoupdate.ps1       # Core Auto-Update Orchestrator Engine
├── config.json                 # Global configuration & ignore rules (auto-generated if missing)
├── README.md                   # Project Documentation
├── setup/                      # Setup & installation components
│   ├── setup.ps1               # Installer logic & interactive CLI menu
│   ├── Run-Hidden.vbs          # Seamless silent launcher (SW_HIDE)
│   ├── Install.vbs             # Internal UAC installer helper
│   └── Uninstall.vbs           # Internal UAC uninstaller helper
├── src/                        # Core runtime modules
│   ├── Config.ps1              # Config loader & environment setup
│   ├── Helpers.ps1             # Logging, process checking & toast notifications
│   ├── SystemChecks.ps1        # Battery, network (metered), and CPU load verification
│   ├── Update-Packages.ps1     # Multi-package manager update handlers
│   └── Dialog.ps1              # Modern WinUI 3 styled WPF prompt dialog
├── config/                     # Task Scheduler templates
│   └── AllGet Auto-Update.xml  # Scheduled Task XML export
├── tests/                      # Developer test & preview scripts
│   ├── Test-WinUIDialog.ps1    # WinUI 3 prompt preview script
│   └── Test-RunHidden.vbs      # Silent launcher test script
└── logs/                       # Auto-Update log directory (git-ignored)
    ├── autoupdate.log          # Persistent activity and status log file
    └── pending-updates.json    # State tracking file for delayed package updates
```

---

## Advanced Features & Command-Line Usage

| File / Command                               | Description                                                |
| :------------------------------------------- | :--------------------------------------------------------- |
| `Install.cmd`                                | **Double-click** to install automatically                  |
| `Uninstall.cmd`                              | **Double-click** to uninstall automatically                |
| `.\setup\setup.ps1`                          | Interactive PowerShell setup & maintenance menu            |
| `powershell -File .\setup\setup.ps1 -Test`   | Runs a manual live auto-update check in the console        |
| `powershell -File .\setup\setup.ps1 -TestUI` | Previews the WinUI 3 notification & countdown timer prompt |

---

## Key Features

1. **Multi-Package Manager Support**: Seamlessly updates software installed via **WinGet**, **Chocolatey**, **Scoop**, **npm**, **yarn**, and **bun** (if installed on the system).
2. **Seamless Silent Execution**: Uses `wscript.exe` running `setup\Run-Hidden.vbs` to hide the PowerShell terminal window completely from process startup.
3. **Smart Active-App Detection**: Automatically skips apps that are actively open and visible in the foreground to avoid interrupting user work.
4. **Adaptive WinUI 3 Dialog**: If an app is running silently in the background, a modern WinUI 3 styled prompt opens with automatic Light/Dark theme adaptation and Windows accent color integration.
5. **Configurable System & Network Awareness**: Configurable checks to postpone updates on metered connections, low battery, or high CPU load.
6. **Update Delay / Postponement**: Option to postpone installing discovered updates by a custom duration up to 7 days for stability.
7. **Unified JSON Configuration**: Global configuration file (`config.json`) for ignore patterns, system check thresholds, and update delay rules.
8. **Comprehensive Logging**: Detailed records stored in `logs\autoupdate.log`.

---

## Configuration (`config.json`)

To customize system checks, enable update delays, or prevent specific applications from updating automatically across any package manager, edit `config.json` in the root folder:

```json
{
  "systemChecks": {
    "skipOnMeteredConnection": true,
    "minBatteryLevel": 50,
    "maxCpuLoad": 80
  },
  "delayUpdates": {
    "enabled": false,
    "days": 7
  },
  "ignoredPatterns": [
    "^Microsoft\\.Edge",
    "^Microsoft\\.OneDrive",
    "^Microsoft\\.Teams",
    "^Microsoft\\.WindowsStore",
    "^Microsoft\\.Defender"
  ]
}
```

### Options:

- **`skipOnMeteredConnection`**: Set to `true` to pause updates when on a metered network connection.
- **`minBatteryLevel`**: Minimum required battery percentage when unplugged (set to `0` to disable).
- **`maxCpuLoad`**: Maximum allowed average CPU load percentage before postponing updates (set to `0` or `100` to disable).
- **`delayUpdates.enabled`**: Set to `true` to delay installing newly discovered updates.
- **`delayUpdates.days`**: Number of days to postpone installation after an update is first discovered (default: `7`).
- **`ignoredPatterns`**: Array of Regex patterns to ignore specific packages across WinGet, Chocolatey, Scoop, npm, yarn, and bun.
