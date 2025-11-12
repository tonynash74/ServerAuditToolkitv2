# ServerAuditToolkitV2

## Project docs

-  **[RUNBOOK.md](./RUNBOOK.md)**  How to set up, run, and interpret outputs
-  **[DEVELOPERS.md](./DEVELOPERS.md)**  Coding standards (PS2-safe), collectors, rules, report wiring, and contrib guide

> Tip: The runbook also covers outputs like 
eport_<timestamp>.html, 
eport_data_<timestamp>.html, per-area CSVs, and the
> new timestamped logs: sat_<timestamp>.log and console_<timestamp>.txt.

> A productionâ€‘ready, modular PowerShell toolkit that inventories Windows Server (latest â†’ 2012 R2/PowerShell 4.0) and generates a migrationâ€‘readiness report.

- **Readâ€‘only** collectors (IIS, Hyperâ€‘V, DHCP, DNS, SMB, Storage, Network, Certificates, AD DS, Scheduled Tasks, Local Accounts)
- **Backâ€‘compat aware**: prefers modern cmdlets, falls back to WMI/`netsh`/`appcmd`/other supported methods when modules are missing
- **Fast**: runspace pool parallelism, lean objects (hashtables), perâ€‘area CSVs + Bootstrap HTML report

---

## Contents

- [Compatibility](#compatibility)
- [Security & Permissions](#security--permissions)
- [Install](#install)
- [Quick start](#quick-start)
- [Usage](#usage)
  - [Targeting multiple servers](#targeting-multiple-servers)
  - [Controlling parallelism](#controlling-parallelism)
  - [Where outputs go](#where-outputs-go)
  - [What gets collected](#what-gets-collected)
- [Troubleshooting](#troubleshooting)
- [Performance tips](#performance-tips)
- [Testing & CI](#testing--ci)
- [Repo layout](#repo-layout)
- [Contributing](#contributing)
- [License](#license)

---

## Compatibility

- **Targets:** Windows Server 2025/2022/2019/2016 and **2012 R2**
- **PowerShell:** Designed for **Windows PowerShell 4.0+** (works on 5.1). No PowerShell 7 required.
- **Remoting:** Uses PowerShell Remoting (WinRM). If remoting is disabled, run **locally** on each server
  or enable remoting (`Enable-PSRemoting -Force`) per your policy.

> The toolkit automatically picks the best available method on each host (modern modules first; safe fallbacks otherwise).

---

## Security & Permissions

- Collectors are **read only**. No configuration changes are performed.
- Run the audit under an account that has **local administrator** rights on target servers (required for some areas like IIS/Hyper V/SMB ACLs/netsh queries).
- Remote file access to `\\<server>\ADMIN$` is used by a few fallbacks (e.g., DHCP `netsh` export). Ensure it's accessible to your admin account.
- Reports and CSVs contain sensitive infra details (IPs, shares, accounts). **Handle outputs securely.**

---

## Install

```powershell
# 1) Clone the repo
git clone https://github.com/YourOrg/ServerAuditToolkitV2.git
cd ServerAuditToolkitV2

# 2) (Optional) Unblock scripts if downloaded from the internet
Get-ChildItem -Recurse -File | Unblock-File

# 3) Run from an elevated Windows PowerShell console (4.0+ / 5.1)
```

No global install is required. The entry point script imports the module from `./src` locally.

---

## Quick start

Audit the **local** server and write outputs to `./out`:

```powershell
# From repo root
.\src\Invoke-ServerAudit.ps1 -Verbose
```

Audit **multiple remote servers** (current user context via WinRM):

```powershell
.\src\Invoke-ServerAudit.ps1 -ComputerName srv1,srv2,srv3 -Verbose
```

Disable parallelism (useful on lowâ€‘spec hosts or when debugging):

```powershell
.\src\Invoke-ServerAudit.ps1 -ComputerName srv1,srv2 -NoParallel -Verbose
```

Change the output directory:

```powershell
.\src\Invoke-ServerAudit.ps1 -OutDir C:\Temp\SATV2 -Verbose
```

> By default, the toolkit uses PowerShell remoting with your current credentials. If crossâ€‘domain/isolated environments prevent this, run the toolkit **locally** on each target with an admin account.

---

## Usage

### Targeting multiple servers
- Pass a commaâ€‘separated list to `-ComputerName`.
- All collectors run in parallel (runspace pool) across the list. Some servers may finish sooner than others; progress is emitted via `-Verbose`.

### Controlling parallelism
- Use `-NoParallel` to run collectors serially (diagnostics, constrained systems).
- The default throttle equals `max(2, processor cores)`. Adjusting the throttle is possible in `src/Private/Parallel.ps1` if you need stricter control in very large estates.

### Where outputs go

After each run youâ€™ll get:

```
out/
  data_YYYYMMDD_HHMMSS.json      # full structured dataset
  summary_YYYYMMDD_HHMMSS.md     # human readable summary
  report_YYYYMMDD_HHMMSS.html    # Bootstrap report (open in a browser)
  csv/
    iis_sites.csv                # IIS sites
    iis_pools.csv                # IIS app pools
    hyperv_vms.csv               # Hyperâ€‘V VMs
    smb_shares.csv               # SMB shares
    smb_ntfs_top.csv             # topâ€‘level NTFS ACLs for shares
    certificates.csv             # machine cert stores (selected stores)
    network_adapters.csv         # adapters + IPs + DNS + gateway
    storage_volumes.csv          # volumes (size, free, health)
    storage_disks.csv            # disks (model, bus, health)
    local_users.csv              # local users
    local_groups.csv             # local groups
    local_group_members.csv      # local group membership (capped)
```

### What gets collected

Each collector returns a hashtable keyed by server for speed & easy merging.

| Collector | What it gathers | Preferred method | Fallback(s) |
|---|---|---|---|
| System | OS/version/build, uptime, hardware, CPU, memory | `Win32_*` WMI | â€” |
| Roles & Features | Installed/available roles & features | `Get-WindowsFeature` | `Win32_ServerFeature` (installed only) |
| Network | NICs, IPs, gateways, DNS, routes, firewall profiles | `NetTCPIP`/`NetLbfo` | `Win32_NetworkAdapterConfiguration`, `ipconfig`, `route`, `netsh`, `netstat` |
| Storage | Disks/partitions/volumes, BitLocker, Dedup (if present) | `Storage` + `BitLocker`/`Deduplication` | `Win32_*`, `manage-bde` |
| AD DS | Forest/domain modes, DCs, FSMO, SYSVOL type | `ActiveDirectory` | .NET `DirectoryServices`, `netdom`, `nltest` |
| DNS | Zones, forwarders | `DnsServer` | WMI `root\MicrosoftDNS` |
| DHCP | Scopes, options, lease counts | `DhcpServer` | `netsh dhcp server export` (temp file) |
| IIS | Sites, bindings, pools, http.sys SSL | `WebAdministration` | `appcmd.exe` XML |
| Hyperâ€‘V | VMs, NICs, disks, switches | `Hyperâ€‘V` | WMI `root\virtualization(\v2)` |
| SMB | Shares + topâ€‘level NTFS ACLs | `SmbShare` + `Get-Acl` | `Win32_Share`, `net share` |
| Certificates | Selected LocalMachine stores + http.sys SSL | `cert:` provider | â€” |
| Scheduled Tasks | Tasks, state, next/last run | `ScheduledTasks` | `schtasks /Query /V /FO CSV` |
| Local Accounts | Users, groups, membership | `LocalAccounts` | `Win32_UserAccount`/`Win32_Group`, `net localgroup` |

---

## Troubleshooting

**Access denied / RPC server unavailable**
- Ensure the account you run as is a **local admin** on each target.
- Check WinRM: service running, firewall rules, and listener in place. If allowed in your environment, on the target run `Enable-PSRemoting -Force`.

**DHCP fallback export fails**
- The fallback writes an interim XML under `\\<server>\ADMIN$\Temp`. Ensure `ADMIN$` is reachable and your account has permissions.

**IIS or Hyperâ€‘V collectors return empty**
- If role modules arenâ€™t present, the tool uses `appcmd` (IIS) or WMI (Hyperâ€‘V). On roleâ€‘less servers, these will naturally be empty.

**Report opens without styling**
- The HTML references Bootstrap via CDN. If your environment is offline, the report still renders content; to make it fully selfâ€‘contained, consider enabling a future "singleâ€‘file" mode (see Issues).

**Large estates (hundreds of servers)**
- Run from a jump host close to targets.
- Consider splitting the `-ComputerName` list into batches.
- Use `-NoParallel` if endpoints are resourceâ€‘constrained or you see throttling by security tools.

---

## Performance tips

- The toolkit uses a **runspace pool** for concurrency. You can tune the throttle in `src/Private/Parallel.ps1`.
- Some collectors cap heavy enumerations (e.g., topâ€‘level NTFS ACLs, scheduled tasks). Adjust caps in collector parameters if needed.
- Temporary data is kept in inâ€‘memory **hashtables** to avoid unnecessary object overhead.

---

## Testing & CI

Run unit tests (Pester v5):

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

Static analysis (PSScriptAnalyzer):

```powershell
Invoke-ScriptAnalyzer -Path .\src -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
```

GitHub Actions CI is included under `.github/workflows/ci.yml` (lint + tests on Windows).

---

## Repo layout

```
ServerAuditToolkitV2/
â”œâ”€ src/
â”‚  â”œâ”€ ServerAuditToolkitV2.psd1        # module manifest
â”‚  â”œâ”€ ServerAuditToolkitV2.psm1        # module (orchestrator + exports)
â”‚  â”œâ”€ Invoke-ServerAudit.ps1           # entry point script
â”‚  â”œâ”€ Private/                         # helpers
â”‚  â”‚   â”œâ”€ Logging.ps1
â”‚  â”‚   â”œâ”€ Parallel.ps1
â”‚  â”‚   â”œâ”€ Capability.ps1
â”‚  â”‚   â””â”€ Report.ps1                   # CSV exports + Bootstrap HTML
â”‚  â””â”€ Collectors/                      # modular collectors (Get-SAT*)
â”‚      â”œâ”€ 00-System.ps1
â”‚      â”œâ”€ 10-RolesFeatures.ps1
â”‚      â”œâ”€ 20-Network.ps1
â”‚      â”œâ”€ 30-Storage.ps1
â”‚      â”œâ”€ 40-ADDS.ps1
â”‚      â”œâ”€ 45-DNS.ps1
â”‚      â”œâ”€ 50-DHCP.ps1
â”‚      â”œâ”€ 55-SMB.ps1
â”‚      â”œâ”€ 60-IIS.ps1
â”‚      â”œâ”€ 70-HyperV.ps1
â”‚      â”œâ”€ 80-Certificates.ps1
â”‚      â”œâ”€ 85-ScheduledTasks.ps1
â”‚      â””â”€ 90-LocalAccounts.ps1
â”œâ”€ tests/                              # Pester tests
â”‚  â”œâ”€ Unit/
â”‚  â””â”€ Integration/
â”œâ”€ out/                                # generated artifacts (gitignored)
â”œâ”€ .github/workflows/ci.yml
â”œâ”€ PSScriptAnalyzerSettings.psd1
â”œâ”€ .gitignore
â”œâ”€ LICENSE
â””â”€ README.md
```

---

## Contributing

Issues and PRs are welcome. Please run Pester tests and ScriptAnalyzer locally before submitting. For larger changes, open an issue to discuss design first.

---

## License

MIT @ YourOrg



