# ServerAuditToolkitV2

> **Enterprise-grade Windows Server audit automation + document link intelligence for decommissioning and migration planning**

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![PowerShell](https://img.shields.io/badge/PowerShell-2.0%2B-brightgreen.svg)
![Status](https://img.shields.io/badge/Status-Production%20v2.1.1-brightgreen.svg)
![Latest](https://img.shields.io/badge/Latest-Phase%203%20%2B%20T2%20%2B%20T3-blue.svg)

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Architecture](#architecture)
4. [Supported Environments](#supported-environments)
5. [Installation](#installation)
6. [Usage](#usage)
7. [Collectors Reference](#collectors-reference)
8. [Output & Reporting](#output--reporting)
9. [Troubleshooting](#troubleshooting)
10. [Development](#development)

---

## Overview

**ServerAuditToolkitV2** is an **MSP-grade Windows Server auditing + document intelligence solution** designed to:

✅ **Discovery** — Inventory all critical infrastructure (IIS, SQL, Hyper-V, AD, services, apps, files)  
✅ **Compliance** — Detect PII, UK Financial data patterns, and governance gaps  
✅ **Document Intelligence** — Extract and validate hyperlinks from Office/PDF documents  
✅ **Migration Planning** — Classify workloads + identify path migration risks + broken links  
✅ **Decommissioning** — Assess dependencies and readiness for retirement  

### Key Features

- **PowerShell compatibility** — Core orchestrator retains a baseline of PS2-era compatibility for very old hosts, but many modern features (PowerShell classes, streaming writer, CIM-optimized collectors and parallel execution) require **PowerShell 5.1+**. For best performance and full feature set, **PowerShell 7.x is recommended**.
- **13 Production Collectors** (TIER 1-5) — Comprehensive infrastructure + compliance audit
- **Phase 3 Enhancements** (11/14 complete, 93%) — Structured logging, batch processing (100+ servers), network resilience, health diagnostics
- **TIER 6: Document Link Analysis Engine** — Extract links from Word/Excel/PowerPoint/PDF + validate with risk scoring
- **Version-optimized collectors** — PS 5.1+ CIM-based (3-5x faster), PS 7.x parallel-ready with 90% memory reduction
- **M-012 Streaming output** — JSONL writer, 90% peak memory reduction, streaming consolidation utilities
- **Zero-trust networking** — WinRM-based remote scanning, no stored credentials, DNS retry + session pooling
- **Intelligent execution** — Auto-detected parallelism, resource-aware throttling, per-collector timeouts
- **Rich reporting** — JSON (canonical), CSV, HTML exports, performance profiling, error dashboard, health diagnostics
- **Extensible architecture** — Drop-in collector template, comprehensive API reference, 100% backwards compatible

---

## Quick Start

### Prerequisites

- **Local admin privileges** on target servers OR **domain user** (if on DC)
- **WinRM enabled** on remote servers (`Enable-PSRemoting -Force`)
- **PowerShell**: Minimum **PowerShell 5.1** for full functionality; some legacy collectors can run on PS 2.0 but features such as PowerShell classes and streaming require 5.1+. **PowerShell 7.x is recommended** for best performance and parallel execution.
- **Network access** — Port 5985 (HTTP) or 5986 (HTTPS) for WinRM
- **Optional:** Document scanning path (UNC/local folder) for link analysis

> Note: If you must run on very old hosts (Server 2008 R2 with PS2), expect reduced functionality and slower, sequential execution. Wherever possible run the orchestrator from an admin workstation with PS 5.1+ or 7.x.

### 30-Second Start

```powershell
# 1. Clone repo
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
cd ServerAuditToolkitv2

# 2. Run server audit on local machine
.\Invoke-ServerAudit.ps1

# 3. Check results
Get-ChildItem .\audit_results -Filter *.json | Format-Table
```

### Audit a Single Remote Server

```powershell
# Dry-run (shows which collectors will execute)
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" -DryRun

# Execute audit (default: all collectors)
$results = .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"

# View results
$results.Servers[0] | Format-Table ComputerName, Success, ExecutionTimeSeconds
$results.Servers[0].Collectors | Format-Table Name, Status, ExecutionTimeSeconds, RecordCount
```

### Audit Multiple Servers (Max 3 Concurrent)

```powershell
# Audit 3 servers (runs 2 in parallel, auto-managed)
$results = .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01", "SERVER02", "SERVER03"

# View summary
$results.Servers | Select-Object ComputerName, Success, StartTime, EndTime
```

### Stream Large Audits (100+ Servers)

```powershell
# Enable M-012 streaming to keep memory under 100MB
$results = .\Invoke-ServerAudit.ps1 `
  -ComputerName $bigList `
  -UseBatchProcessing `
  -EnableStreaming `
  -StreamBufferSize 10 `
  -StreamFlushIntervalSeconds 30

# Results are written to JSONL incrementally
$results.Streaming.StreamFile | Get-Item | Select-Object FullName, Length

# Hydrate individual records on demand
$top10 = Read-StreamedResults -StreamFile $results.Streaming.StreamFile -MaxResults 10
```

### Document Link Analysis (NEW - T3 Engine)

```powershell
# Extract links from documents in a file share
$linkAudit = .\src\LinkAnalysis\Invoke-DocumentLinkAudit.ps1 `
    -Path "Z:\Shares\ProjectDocs" `
    -OutputPath ".\reports\links"

# View broken links (migration blockers)
$linkAudit.BrokenLinks | Where-Object { $_.RiskLevel -eq 'CRITICAL' } | 
    Select-Object Url, LinkType, PathRisk, Recommendation

# View migration risk assessment
$linkAudit.ValidationResults | Select-Object `
    @{N='LocalPaths';E={$_.LocalPaths}},
    @{N='UNCPaths';E={$_.UNCPaths}},
    @{N='HighRisk';E={$_.HighRisk}}
```

### Run Specific Collectors Only

```powershell
# Just IIS and SQL
$results = .\Invoke-ServerAudit.ps1 `
    -ComputerName "SERVER01" `
    -Collectors @("Get-IISInfo", "Get-SQLServerInfo")

# Results will only include those 2 collectors
```

### Use PS 5.1+ Optimized Variant

```powershell
# If running on PS 5.1 or 7.x, toolkit auto-selects optimized collectors
# No special flag needed — orchestrator detects your PS version

# Manual override (not recommended):
$results = .\Invoke-ServerAudit-PS5.ps1 -ComputerName "SERVER01"
```

---

## Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────┐
│  Administrator Workstation (DC or Admin Box)                │
│  Running PowerShell 2.0 / 5.1 / 7.x                        │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ├──→ .\Invoke-ServerAudit.ps1 (or -PS5 / -PS7)
                     │
                     ├─→ [T1] Detect PS version + load collectors
                     │
                     ├─→ [T2] Discover target server capabilities (CPU, RAM, disk)
                     │
                     ├─→ [T3] Optimize parallelism (max 3 concurrent, business hours aware)
                     │
                     └─→ [T4] Execute collectors in parallel
                            │
                            ├─ WinRM → SERVER01 (collector set for PS version)
                            ├─ WinRM → SERVER02
                            └─ WinRM → SERVER03
                                │
                                ├─ Get-ServerInfo-PS5.ps1
                                ├─ Get-IISInfo-PS5.ps1
                                ├─ Get-SQLServerInfo-PS5.ps1
                                ├─ Get-Services-PS5.ps1
                                └─ ... (12+ collectors)
                                │
                                └─→ JSON results → CSV / HTML reports
```

### Folder Structure

```
ServerAuditToolkitv2/
├── Invoke-ServerAudit.ps1           [Main orchestrator — PS 2.0 baseline]
├── Invoke-ServerAudit-PS5.ps1        [PS 5.1+ optimized orchestrator]
├── Invoke-ServerAudit-PS7.ps1        [PS 7.x advanced orchestrator]
│
├── src/
│   ├── Collectors/                   [All collector scripts]
│   │   ├── 00-System.ps1             [Base collectors — legacy compatible]
│   │   ├── 10-RolesFeatures.ps1
│   │   ├── 20-Network.ps1
│   │   ├── 30-Storage.ps1
│   │   ├── 40-ADDS.ps1
│   │   ├── 50-DHCP.ps1
│   │   ├── 60-IIS.ps1
│   │   ├── 70-HyperV.ps1
│   │   ├── 80-Certificates.ps1
│   │   ├── 85-DataDiscovery.ps1      [PII/Financial data pattern detection]
│   │   ├── 90-LocalAccounts.ps1
│   │   ├── 97-SQLServer.ps1
│   │   ├── 99-SharePoint.ps1
│   │   │
│   │   ├── Get-ServerInfo-PS5.ps1    [PS 5.1+ CIM-optimized variants]
│   │   ├── Get-IISInfo-PS5.ps1
│   │   ├── Get-SQLServerInfo-PS5.ps1
│   │   ├── Get-Services-PS5.ps1
│   │   │
│   │   ├── Collector-Template.ps1    [Template for new collectors]
│   │   ├── Get-CollectorMetadata.ps1 [Metadata loader + helpers]
│   │   └── collector-metadata.json   [Central registry of all collectors]
│   │
│   ├── Private/                      [Internal utility functions]
│   │   ├── Get-BusinessHoursCutoff.ps1     [1-hour-before-8AM logic]
│   │   ├── Invoke-ParallelCollectors.ps1   [Max 3 concurrent + timeout mgmt]
│   │   ├── Test-Prerequisites.ps1          [WinRM, RPC, credential validation]
│   │   └── Write-StructuredLog.ps1         [JSON logging]
│   │
│   └── ServerAuditToolkitV2.psd1    [Module manifest]
│
├── lib/                              [Shared utility functions (future)]
│   ├── Get-CollectorMetadata.ps1
│   ├── Export-AuditReport.ps1
│   └── ...
│
├── data/                             [Configuration files]
│   ├── audit-config.json             [Timeouts, concurrency, business hours]
│   └── collector-catalog.json        [Unified collector registry]
│
├── reports/                          [Output templates + generated reports]
│   ├── templates/
│   │   ├── report-schema.json        [Canonical audit output structure]
│   │   ├── report.html.template
│   │   └── report.csv.template
│   └── audit_results/                [Output directory after each run]
│       ├── SERVER01_audit_2025-11-21.json
│       ├── SERVER01_audit_2025-11-21.csv
│       └── SERVER01_audit_2025-11-21.html
│
├── tests/                            [Test suite]
│   ├── unit/
│   │   └── *.Tests.ps1
│   └── integration/
│       └── *.Integration.Tests.ps1
│
├── docs/
│   ├── ARCHITECTURE.md               [Detailed design decisions]
│   ├── QUICK-START.md                [Getting started guide]
│   ├── COLLECTORS-REFERENCE.md       [All collectors + fields]
│   ├── TROUBLESHOOTING.md            [Common issues + fixes]
│   ├── DEVELOPMENT.md                [How to add new collectors]
│   ├── T1-Implementation.md           [Version detection framework]
│   ├── T2-Implementation.md           [Performance profiling]
│   ├── T3-Implementation.md           [Orchestration optimization]
│   └── T4-Implementation.md           [PS 5.1+ optimized collectors]
│
├── .github/workflows/
│   ├── lint-all-versions.yml         [PSScriptAnalyzer for each PS version]
│   ├── test-all-versions.yml         [Unit + integration tests]
│   └── release.yml                   [Publish module to PSGallery]
│
├── LICENSE                           [MIT License — Tony Nash, inTEC Group]
├── README.md                         [This file]
└── CONTRIBUTING.md                   [Contribution guidelines]
```

---

## Supported Environments
### Windows Server Versions

| OS Version | PS 2.0 (legacy) | PS 4.0 | PS 5.1 | PS 7.x | Status |
|---|---:|---:|---:|---:|---|
| **Server 2008 R2** | ✅ Limited | ⚠️ Partial | ❌ Not supported | ❌ Not supported | Legacy (EOL) — run only for very old environments |
| **Server 2012 R2** | ❌ Not applicable | ✅ Yes | ✅ Yes | ❌ Limited | Baseline (upgrade recommended)
| **Server 2016** | ❌ Not applicable | ✅ Yes | ✅ Yes | ✅ Yes | Recommended — PS 5.1+ supported
| **Server 2019** | ❌ Not applicable | ✅ Yes | ✅ Yes | ✅ Yes | Recommended — PS 5.1+ supported
| **Server 2022** | ❌ Not applicable | ✅ Yes | ✅ Yes | ✅ Yes | Modern — PS 5.1+ / PS 7.x recommended |

### PowerShell Versions

| PS Version | Release | Collectors & Support | Performance | Notes |
|---|---:|---|---:|---|
| **PS 2.0** | 2009 | Legacy support only; very limited collector set on modern OSes | Sequential, slowest | Use only for constrained legacy hosts (Server 2008 R2); many features unavailable
| **PS 4.0** | 2013 | Baseline collectors; limited modern features | Sequential | Transitional — lacks classes/CIM optimizations available in 5.1+
| **PS 5.1** | 2016 | Full feature set for collectors (CIM, classes) | Good (~3-5x faster for CIM collectors) | Recommended minimum for full functionality
| **PS 7.x** | 2021+ | Best support: async, parallel execution, modern module ecosystem | Best (~5-10x faster overall) | Recommended for development and large-scale runs

### Recommended Configuration

- **Source**: Domain Controller or dedicated admin workstation
- **Target**: Windows Server 2012 R2+
- **PowerShell**: 5.1+ (auto-selects optimized collectors)
- **Networking**: WinRM port 5985 (HTTP) or 5986 (HTTPS)
- **Concurrency**: Max 3 servers at once (default; configurable)

---

## Installation

### Option 1: Direct Download (Recommended for MSPs)

```powershell
# Clone repo
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
cd ServerAuditToolkitv2

# Run immediately (no installation needed)
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
```

#### Import the module from a local clone

If you prefer to load the toolkit as a module (for auto-completion, dot-sourcing, or calling `Invoke-ServerAudit` like any other command), import it directly from the cloned folder:

```powershell
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
Set-Location .\ServerAuditToolkitv2

# Unblock files if SmartScreen tagged the download
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File

# Import the module manifest from disk (loads public functions + private helpers)
Import-Module (Join-Path $PWD 'ServerAuditToolkitV2.psd1') -Force

# Verify the module is available and list exported commands
Get-Module ServerAuditToolkitV2
Get-Command -Module ServerAuditToolkitV2

# Now run the orchestrator via the module command name
Invoke-ServerAudit -ComputerName 'SERVER01' -DryRun
```

> Tip: Run the import inside the same PowerShell session you plan to use for audits. If you move the toolkit folder, re-import using the new path or export it with `Save-Module` to a location in `$env:PSModulePath`.

### Option 2: PowerShell Gallery (Future)

```powershell
Install-Module -Name ServerAuditToolkitV2 -Repository PSGallery

# Import module
Import-Module ServerAuditToolkitV2

# Run orchestrator
Invoke-ServerAudit -ComputerName "SERVER01"
```

### Option 3: Azure Function App (Future)

Trigger audits via REST API for managed scanning across multiple servers.

---

### Testing & Development

- **Recommended dev environment**: Work from an admin workstation with **PowerShell 7.x** (or 5.1 when testing legacy compatibility), Git, and a modern editor like VS Code.
- **Pester (tests)**: The project uses Pester v5 for the test suite. Install locally with:

```powershell
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser
```

- **Run tests** (from project root):

```powershell
# Run all tests
Invoke-Pester -Path .\tests

# Run a single test file
Invoke-Pester -Path .\tests\Phase3-Sprint4-M012.Tests.ps1
```

- **Execution policy**: When developing or running locally you may need to allow script execution for the session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

- **Static analysis**: `PSScriptAnalyzer` rules are included in CI; run locally with:

```powershell
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\src -Recurse
```

> Tip: Run tests inside an elevated (Administrator) PowerShell session where WinRM endpoints will be available and file write permissions for `audit_results` are granted.

## Usage

### Module install & import

This repository contains a PowerShell module layout with `ServerAuditToolkitV2.psd1` and `ServerAuditToolkitV2.psm1` at the repository root, with implementation scripts under the `src` folder. If `Import-Module ServerAuditToolkitV2` fails with "module not found", follow one of these options:

- Install locally using the included installer script (recommended for local testing):

```powershell
# From the repository root on the target machine
.\Install-LocalModule.ps1 -Force

# Then import by name
Import-Module ServerAuditToolkitV2
```

- Or import directly from the module manifest if you prefer not to copy the module into a `PSModulePath` location:

```powershell
Import-Module 'C:\full\path\to\ServerAuditToolkitV2.psd1'
```

Notes:

- If your Documents folder is redirected to OneDrive or another location, the user module path will be under that redirected Documents path. The installer script detects redirected `Documents` and installs into the correct location.
- Before making this module public (PowerShell Gallery), ensure any internal `devnotes` or sensitive files are excluded from publication.

Uninstalling the locally installed module

If you used `Install-LocalModule.ps1` (now located in the repository root) to install the module for local testing, you can remove it with the included uninstall helper:

```powershell
# From the repository root on the target machine
.\Uninstall-LocalModule.ps1 -Force

# Or run interactively without -Force to confirm before deletion
.\Uninstall-LocalModule.ps1
```

The uninstall script detects redirected `Documents` locations (OneDrive) and will remove the `ServerAuditToolkitV2` folder from the appropriate user modules path. It also attempts to `Remove-Module` from the current session.


### Basic Audit (Local Machine)

```powershell
.\Invoke-ServerAudit.ps1
```

**Output**:
```
ComputerName     Success ExecutionTimeSeconds
────────────────────────────────────────────
MYSERVER01       True    47
```

### Audit Remote Server (Single)

```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
```

### Audit Multiple Servers (Parallel, Max 3)

```powershell
$servers = @("SERVER01", "SERVER02", "SERVER03")
.\Invoke-ServerAudit.ps1 -ComputerName $servers
```

**Behavior**:
- Runs max 3 concurrent WinRM sessions
- Auto-throttles if more than 3 servers provided
- Enforces per-collector timeout (default: 30-90s per collector)
- Stops execution if business-hours cutoff reached (1hr before 8 AM)

### Dry-Run (Validate Setup)

```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" -DryRun
```

**Output**:
```
[DRY-RUN] Local PowerShell version: 5.1
[DRY-RUN] Collectors to execute:
  ✓ Get-ServerInfo-PS5
  ✓ Get-IISInfo-PS5
  ✓ Get-SQLServerInfo-PS5
  ... (9 more)
[DRY-RUN] Total: 12 collectors
```

### Run Specific Collectors Only

```powershell
.\Invoke-ServerAudit.ps1 `
    -ComputerName "SERVER01" `
    -Collectors @("Get-ServerInfo", "Get-IISInfo", "Get-Services")
```

### Override PS Version (Advanced)

```powershell
# Force PS 5.1 collectors (not PS 7.x even if running on PS 7.x)
.\Invoke-ServerAudit-PS5.ps1 -ComputerName "SERVER01"

# Force PS 2.0 collectors (legacy)
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
```

### Custom Configuration

```powershell
# Set custom output path
.\Invoke-ServerAudit.ps1 `
    -ComputerName "SERVER01" `
    -OutputPath "C:\Audits\Q4-2025"

# Set log level
.\Invoke-ServerAudit.ps1 `
    -ComputerName "SERVER01" `
    -LogLevel "Verbose"
```

### Batch Audit Multiple Servers (Sequential)

```powershell
$servers = Get-Content "servers.txt"  # One server per line

$results = @()
foreach ($server in $servers) {
    $audit = .\Invoke-ServerAudit.ps1 -ComputerName $server
    $results += $audit.Servers[0]
    Start-Sleep -Seconds 5  # Stagger audits
}

$results | Export-Csv "audit_summary_2025-11-21.csv"
```

---

## Collectors Reference

### TIER 1-5: Infrastructure & Compliance Collectors (13 Total)

**TIER 1: Core Discovery**
| Collector | Purpose | Fields |
|---|---|---|
| Get-ServerInfo | OS baseline, hardware specs | CPU, RAM, uptime, disk, network |
| Get-Services | Running/installed services | Name, state, startup type, binary path |
| Get-InstalledApps | Software inventory | Name, version, vendor, install date |
| Get-ServerRoles | Windows roles & features | Feature name, state, installed date |

**TIER 2: Infrastructure**
| Collector | Purpose | Fields |
|---|---|---|
| Get-ShareInfo | File shares and permissions | Share name, path, size, NTFS ACL, quotas |
| Get-LocalAccounts | Users, groups, privileges | Account name, type, group membership, RID |

**TIER 3: Applications**
| Collector | Purpose | Fields |
|---|---|---|
| Get-IISInfo | IIS sites and bindings | Site name, app pools, SSL certs, app versions |
| Get-SQLServerInfo | SQL instances and databases | Instance name, databases, jobs, backups |
| Get-ExchangeInfo | Exchange Server configuration | DAG config, databases, transport rules |

**TIER 4: Compliance & Discovery**
| Collector | Purpose | Detects |
|---|---|---|
| Data-Discovery-PII | PII pattern detection | SSN, credit card, email, DOB |
| Data-Discovery-FinancialUK | UK Financial data patterns | IBAN, sort codes, UK NI numbers |
| Data-Discovery-HeatMap | Data classification by access | HOT (accessed <7d), WARM, COOL |

**TIER 5: Operations**
| Collector | Purpose | Fields |
|---|---|---|
| Get-ScheduledTasks | Critical scheduled tasks | Task name, trigger, action, last run |
| Get-CertificateInfo | SSL/TLS certificate inventory | Thumbprint, subject, expiry, CA, renewal |

### TIER 6: Document Link Analysis Engine (NEW - T3)

**Extract Links from Office & PDF**
```powershell
Extract-DocumentLinks
├─ Input:  Word (.docx, .docm), Excel (.xlsx, .xlsm), PowerPoint (.pptx, .pptm), PDF
├─ Output: Structured link objects with classification
├─ LinkTypes: 
│   ├─ ExternalURL       (http://, https://)      → UNKNOWN risk
│   ├─ Email             (mailto:)                 → LOW risk
│   ├─ UNCPath           (\\server\share)          → LOW risk (migration-safe)
│   ├─ LocalPath         (C:\, D:\)                → HIGH risk (will break post-migration)
│   ├─ LocalExcelFile    (C:\...\*.xlsx)           → HIGH risk (requires mapping)
│   ├─ InternalAnchor    (#reference)              → LOW risk
│   └─ RelativePath      (../folder/file)          → MEDIUM risk
└─ PathRisk: HIGH|LOW|UNKNOWN (migration impact signal)
```

**Validate Links with Risk Scoring**
```powershell
Test-DocumentLinks
├─ HTTP/HTTPS:       Invoke-WebRequest with timeout
├─ File Paths:       Test-Path (UNC, local, SMB)
├─ Email:            Pattern validation
├─ Caching:          24-hour TTL JSON file
└─ Risk Scoring:
    ├─ CRITICAL:     Broken external URLs
    ├─ HIGH:         Hardcoded local paths (LocalPath, LocalExcelFile)
    ├─ MEDIUM:       Timeouts, unknown status
    └─ LOW:          Valid links, UNC paths
```

**Orchestrate & Report**
```powershell
Invoke-DocumentLinkAudit
├─ Phase 1: Scan documents (Word, Excel, PowerPoint, PDF)
├─ Phase 2: Validate all unique links (with caching)
├─ Phase 3: Risk score and classify
├─ Phase 4: Generate HTML + CSV + JSON reports
└─ Output:
    ├─ Migration Risk Assessment (UNC vs hardcoded paths)
    ├─ Broken Links (remediation needed)
    ├─ Path Classification (safe vs risky)
    └─ Per-document validation results
```

**PDF Extraction: Tiered Implementation**
- **Tier 1:** iText7 library (robust, page-aware link extraction) ← Optimal
- **Tier 2:** Regex text extraction (best-effort fallback)
- **Tier 3:** Graceful degradation (never fails, returns empty)

---

### Full List (By Prefix)

```
00-System.ps1              System info, OS, hardware
10-RolesFeatures.ps1       Windows roles and features installed
20-Network.ps1             Network adapters, routes, DNS clients
30-Storage.ps1             Disks, volumes, RAID, quotas
40-ADDS.ps1                Active Directory info
45-DNS.ps1                 DNS zones and records
50-DHCP.ps1                DHCP scopes and leases
55-SMB.ps1                 SMB shares, permissions, quotas
60-IIS.ps1                 IIS sites, app pools, bindings
65-Print.ps1               Print servers and printers
70-HyperV.ps1              Hyper-V hosts and VMs
80-Certificates.ps1        SSL certificates and expiry
85-DataDiscovery.ps1       PII and financial data patterns (GDPR, FCA)
85-ScheduledTasks.ps1      Critical scheduled tasks
86-LOBSignatures.ps1       Line-of-business application signatures
90-LocalAccounts.ps1       Local users and groups
95-Printers.ps1            Network printers
96-Exchange.ps1            Exchange Server config
97-SQLServer.ps1           SQL Server instances and databases
98-WSUS.ps1                WSUS server config
99-SharePoint.ps1          SharePoint farms and web applications
```

---

## Output & Reporting

### Output Formats

All audit results are saved to `audit_results/` (or custom path):

```
audit_results/
├── SERVER01_audit_2025-11-21T14-30-45.json   [Canonical format]
├── SERVER01_audit_2025-11-21T14-30-45.csv    [Spreadsheet-friendly]
├── SERVER01_audit_2025-11-21T14-30-45.html   [Executive summary + charts]
└── audit_manifest_2025-11-21.json             [Index of all audits]
```

### JSON Structure (Canonical)

```json
{
  "auditId": "audit-2025-11-21-SERVER01-abc123",
  "timestamp": "2025-11-21T14:30:45Z",
  "computerName": "SERVER01",
  "operatingSystem": "Windows Server 2019 Standard (Build 17763)",
  "powerShellVersion": "5.1.19041",
  "executionTimeSeconds": 47,
  "businessHoursCutoffApplied": false,
  "collectors": {
    "Get-ServerInfo": {
      "status": "Success",
      "executionTimeSeconds": 5,
      "recordCount": 1,
      "data": {
        "computerName": "SERVER01",
        "osVersion": "Windows Server 2019 Standard",
        "installDate": "2022-03-15T00:00:00Z",
        "systemUptime": "365d:14h:30m",
        "processorCount": 4,
        "processorModel": "Intel Xeon E5-2680",
        "totalMemoryMB": 32768,
        "networkAdapters": [
          {
            "name": "Ethernet",
            "ipAddress": "192.168.1.50",
            "gateway": "192.168.1.1",
            "dhcpEnabled": false,
            "speed": "1000 Mbps"
          }
        ]
      }
    },
    "Get-IISInfo": {
      "status": "Success",
      "executionTimeSeconds": 8,
      "recordCount": 3,
      "data": {
        "installed": true,
        "version": "10.0",
        "sites": [
          {
            "name": "Default Web Site",
            "state": "Started",
            "bindings": [
              { "protocol": "http", "port": 80, "hostname": "example.com" }
            ]
          }
        ]
      }
    },
    "85-DataDiscovery": {
      "status": "Success",
      "executionTimeSeconds": 245,
      "recordCount": 42,
      "data": {
        "piiDetected": true,
        "patterns": [
          {
            "type": "SSN",
            "count": 8,
            "paths": ["C:\\ShareName\\HR\\..."]
          },
          {
            "type": "UK_IBAN",
            "count": 5,
            "paths": ["C:\\ShareName\\Finance\\..."]
          }
        ]
      }
    }
  },
  "summary": {
    "totalCollectors": 12,
    "successCount": 12,
    "failureCount": 0,
    "skippedCount": 0,
    "recommendations": [
      "PII detected on file shares — recommend data classification and encryption",
      "Server is eligible for Azure migration — 4 CPU, 32 GB RAM, good performance profile"
    ]
  }
}
```

### CSV Format (Quick Analysis)

```csv
ServerName,Collector,Status,ExecutionTime,RecordCount,Notes
SERVER01,Get-ServerInfo,Success,5,1,"4 CPU, 32 GB RAM, Windows Server 2019"
SERVER01,Get-IISInfo,Success,8,3,"3 websites, 2 SSL certificates"
SERVER01,Get-SQLServerInfo,Success,12,2,"SQL 2019 Standard, 2 databases"
SERVER01,85-DataDiscovery,Success,245,42,"⚠️ PII detected: 8 SSN, 5 IBAN"
SERVER01,Summary,Success,47,12,"✓ Audit complete"
```

### HTML Report (Executive Summary)

- Server overview card
- Collector execution timeline (Gantt chart)
- Critical findings (PII, compliance gaps)
- Service inventory table
- Application versions
- Migration readiness score
- Decommissioning checklist

---

## Troubleshooting

### Problem: "Access Denied" on Remote Server

**Symptoms**:
```
Invoke-ServerAudit : Failed to connect to SERVER01
Error: Access is denied. (Exception from HRESULT: 0x80070005)
```

**Solutions**:
1. Verify WinRM is enabled on target:
   ```powershell
   Invoke-Command -ComputerName SERVER01 -ScriptBlock { Get-Service WinRM }
   ```

2. Add your user to target's local Administrators group:
   ```powershell
   Add-LocalGroupMember -Group Administrators -Member "DOMAIN\YourUser"
   ```

3. Use explicit credentials:
   ```powershell
   $cred = Get-Credential
   .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" -Credential $cred
   ```

### Problem: Timeout Exceeded

**Symptoms**:
```
Collector 'Get-SQLServerInfo' exceeded timeout of 90 seconds
```

**Solutions**:
1. Increase timeout for that collector in `audit-config.json`
2. Check server CPU/disk (may be overloaded)
3. Run during off-hours
4. Skip that collector:
   ```powershell
   .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
       -Collectors @("Get-ServerInfo", "Get-IISInfo")
   ```

### Problem: Business Hours Cutoff Triggered

**Symptoms**:
```
[WARNING] Approaching business hours (7:00 AM). Stopping execution.
Only 3 of 12 collectors completed.
```

**Solutions**:
1. Run audit before 7:00 AM (1 hour before 8:00 AM business start)
2. Modify business hours in `audit-config.json`:
   ```json
   {
     "businessHours": {
       "startHour": 8,
       "cutoffMinutesBefore": 60
     }
   }
   ```

### Problem: Collector Not Found

**Symptoms**:
```
Collector 'Get-CustomInfo' not found in metadata
```

**Solutions**:
1. Check collector name matches `collector-metadata.json`
2. Verify collector file exists in `src/Collectors/`
3. Validate metadata registration:
   ```powershell
   Get-CollectorMetadata | Select-Object -ExpandProperty collectors | 
       Where-Object { $_.name -eq 'Get-ServerInfo' }
   ```

### Problem: PII Detection Not Working

**Symptoms**:
```
85-DataDiscovery completed but found no patterns
```

**Solutions**:
1. Verify patterns are enabled in `audit-config.json`
2. Check share access (collector needs read on all shares)
3. Run with elevated privileges:
   ```powershell
   Start-Process powershell -Verb RunAs
   .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
   ```

### Need Help?

- 📖 See `docs/TROUBLESHOOTING.md` for detailed solutions
- 🐛 Report issues on GitHub: https://github.com/tonynash74/ServerAuditToolkitv2/issues
- 💬 Start a discussion: https://github.com/tonynash74/ServerAuditToolkitv2/discussions

---

## Development

### Creating a New Collector

1. **Copy template**:
   ```powershell
   Copy-Item src/Collectors/Collector-Template.ps1 `
       src/Collectors/Get-MyCollector.ps1
   ```

2. **Update metadata tags** (embedded in script):
   ```powershell
   # @CollectorName: Get-MyCollector
   # @PSVersions: 2.0,4.0,5.1,7.0
   # @MinWindowsVersion: 2008R2
   # @MaxWindowsVersion:
   # @Dependencies: ModuleNameIfAny
   # @Timeout: 30
   # @Category: core|application|infrastructure
   # @Critical: true|false
   ```

3. **Implement collector logic**:
   ```powershell
   function Get-MyCollector {
       try {
           $data = Get-SomeInfo -ComputerName $ComputerName
           return @{
               Success = $true
               Data = $data
           }
       }
       catch {
           return @{
               Success = $false
               Error = $_.Exception.Message
           }
       }
   }
   ```

4. **Create PS 5.1+ variant** (optional):
   ```powershell
   # Copy to Get-MyCollector-PS5.ps1
   # Replace Get-WmiObject with Get-CimInstance
   # Use modern error handling ($PSItem vs $_)
   ```

5. **Register in metadata**:
   Edit `src/Collectors/collector-metadata.json`:
   ```json
   {
     "name": "Get-MyCollector",
     "displayName": "My Collector",
     "description": "...",
     "variants": {
       "2.0": "Get-MyCollector.ps1",
       "5.1": "Get-MyCollector-PS5.ps1"
     }
   }
   ```

6. **Test**:
   ```powershell
   .\Invoke-ServerAudit.ps1 -ComputerName $env:COMPUTERNAME `
       -Collectors @("Get-MyCollector") -DryRun
   ```

See `docs/DEVELOPMENT.md` for full guidelines.

---

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Code style & standards
- PR process
- Testing requirements
- License agreement

---

## License

**MIT License**

Copyright © 2025 **Tony Nash**, **inTEC Group**

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, modify, and distribute it, subject to the conditions in the LICENSE file.

---

## Support & Roadmap

### Current Status (v2.1.1 - PRODUCTION READY)

**T1: Foundation** ✅ Complete
- ✅ Version detection & metadata framework
- ✅ PS 2.0 / 5.1 / 7.x compatibility layer

**T2: Collector Suite** ✅ Complete
- ✅ 13 Production Collectors (TIER 1-5)
- ✅ Executive Reporting Engine (HTML/CSV/JSON)
- ✅ 2,500+ LOC, 45+ functions
- ✅ Comprehensive documentation

**T3: Document Link Analysis** ✅ Complete
- ✅ Extract links from Word/Excel/PowerPoint/PDF
- ✅ Validate links with 24-hour caching
- ✅ Risk scoring (CRITICAL/HIGH/MEDIUM/LOW)
- ✅ UNC path detection (migration-safe vs hardcoded local paths)
- ✅ PDF extraction (iText7 + regex fallback)
- ✅ Migration Risk Assessment reporting

### Roadmap (Future Sprints)

- Unified Orchestrator: Merge PS 2.0/4.0/5.1/7.x entry points into a single orchestrator that detects local and remote PowerShell versions per target, then selects the appropriate collector variants dynamically. Deprecate version-specific scripts after parity.

- 📋 **T4 (In Progress):** Migration Decisions Engine
  - ✅ Phase 1: Core analysis engine (Analyze-MigrationReadiness.ps1)
  - ✅ Phase 2: Integration & reporting (Invoke-MigrationDecisions.ps1, New-MigrationReport.ps1)
  - 🔄 Phase 3: Advanced features (dependency mapping, cost modeling, link remediation)
  - Mines T1-T3 data to recommend optimal migration destinations
  - Workload classification (web, database, file server, etc.)
  - Readiness scoring (0-100) with component breakdown
  - 3+ destination options with TCO comparison
  - Remediation plans (critical → nice-to-have)
  - Migration timeline estimates
  - Executive HTML reports

- 📊 **Sprint 5:** Advanced Analytics
  - Dependency mapping (which servers/services depend on which)
  - Application relationship graphing
  - Cost estimation models

- ☁️ **Sprint 6:** Cloud Readiness
  - Azure migration scoring
  - AWS workload classification
  - Hybrid architecture recommendations

- 🔄 **Sprint 7:** Automation Playbooks
  - Pre-migration validation scripts
  - Link remediation automation
  - Post-migration validation checks

- 📱 **Sprint 8:** API & Dashboards
  - REST API for remote triggering
  - Azure Function wrapper
  - Real-time monitoring dashboard

---

## Contact

- **GitHub**: https://github.com/tonynash74/ServerAuditToolkitv2
- **Author**: Tony Nash
- **Organization**: inTEC Group

---

**Last Updated**: November 27, 2025  
**Version**: 2.1.1 (T2 + T3 Complete)  
**Status**: Production Ready  
**Total LOC**: 4,200+ (collectors + reporting + link analysis)  
**Total Functions**: 45+  
**Documentation**: 1,500+ lines
