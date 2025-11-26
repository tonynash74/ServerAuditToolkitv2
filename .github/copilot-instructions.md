# ServerAuditToolkitV2 - AI Coding Agent Instructions

## Project Context

**ServerAuditToolkitV2** is an MSP-grade Windows Server audit automation + cloud migration planning system. It discovers infrastructure, detects compliance risks, analyzes document links, and provides AI-driven cloud migration recommendations.

### Delivery Phases (Completed)

- **T1**: Version detection framework (PS 2.0 → 7.x compatibility)
- **T2**: 13 production collectors (system, IIS, SQL, AD, compliance, file shares)
- **T3**: Document link analysis engine (extract/validate links from Office/PDF)
- **T4**: PowerShell 5.1+ & 7.x optimized collector variants (3-5x faster via CIM)
- **T5**: Migration decision engine (workload classification, readiness scoring, destination recommendations, TCO estimation)

---

## Architecture Essentials

### Three-Layer Design

```
┌─ Orchestrator Layer ─────────────────────────┐
│ Invoke-ServerAudit.ps1 (main entry)          │
│ └─ T1: Detects PS version                    │
│    └─ T2: Profiles target server             │
│       └─ T4: Selects optimized collectors    │
├─ Collector Layer (TIER 1-6) ──────────────────┤
│ 13 collectors (T2) + variants (T4)           │
│ - Core (system, services, apps)              │
│ - Infrastructure (storage, network, ADDS)    │
│ - Applications (IIS, SQL, Exchange)          │
│ - Compliance (PII, financial patterns)       │
│ - Document analysis (link extraction/tests)  │
├─ Analysis Layer (T5) ──────────────────────────┤
│ Analyze-MigrationReadiness.ps1               │
│ - Workload classification                    │
│ - Readiness scoring (0-100)                  │
│ - Migration blocker detection                │
│ - Cloud destination recommendation           │
│ - TCO estimation & remediation planning      │
└──────────────────────────────────────────────┘
```

### Key Design Principles

1. **Version Polymorphism**: Scripts auto-select best variant for running PowerShell version
   - PS 2.0: Baseline (WMI, Get-WmiObject)
   - PS 5.1+: CIM optimized (3-5x faster)
   - PS 7.x: Async/parallel ready

2. **Collector Metadata Registry**: `src/Collectors/collector-metadata.json` drives all discovery and variant selection

3. **Max 3 Concurrent Sessions**: Orchestrator throttles to 3 WinRM sessions to avoid target server overload

4. **Business Hours Cutoff**: Stops execution 1 hour before 8 AM (preserves morning availability)

---

## Critical Developer Workflows

### Running Audits

```powershell
# Dry-run (shows collectors for your PS version + target OS)
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" -DryRun

# Execute audit (all compatible collectors)
$results = .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"

# Specific collectors only
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
    -Collectors @("Get-ServerInfo", "Get-IISInfo")

# Force PS 5.1 variant (even if running on PS 7.x)
.\Invoke-ServerAudit-PS5.ps1 -ComputerName "SERVER01"

# Batch audit (3 concurrent, auto-managed)
$servers = @("SRV1", "SRV2", "SRV3")
$results = .\Invoke-ServerAudit.ps1 -ComputerName $servers
```

### Testing

```powershell
# Run PSScriptAnalyzer (enforces linting across PS versions)
Invoke-PSScriptAnalyzer -Path "src/" -Settings "PSScriptAnalyzerSettings.psd1"

# Run unit tests (Pester v5+)
Invoke-Pester -Path "tests/unit" -PassThru

# Integration tests (requires WinRM + test servers)
Invoke-Pester -Path "tests/integration" -PassThru
```

### Building & Deploying

```powershell
# Module build (generates .psd1 manifest, validates structure)
. .\build.ps1

# Pack for PSGallery (future)
Publish-Module -Path ".\ServerAuditToolkitV2" -Repository PSGallery
```

---

## Code Patterns & Conventions

### Collector Structure

Every collector follows this template (`src/Collectors/Collector-Template.ps1`):

```powershell
# Metadata comments (parsed by Get-CollectorMetadata)
# @CollectorName: Get-MyInfo
# @PSVersions: 2.0,4.0,5.1,7.0
# @MinWindowsVersion: 2008R2
# @Timeout: 30
# @Category: core|application|infrastructure
# @Critical: true|false

function Get-MyInfo {
    param([string]$ComputerName = $env:COMPUTERNAME)
    try {
        $data = Get-Something -ComputerName $ComputerName
        return @{
            Success = $true
            Data = $data
            ExecutionTimeSeconds = [math]::Round((Get-Date - $startTime).TotalSeconds, 2)
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            ExecutionTimeSeconds = [math]::Round((Get-Date - $startTime).TotalSeconds, 2)
        }
    }
}
```

### Variant Naming Convention

- Base collector: `Get-ServerInfo.ps1` (PS 2.0 compatible)
- PS 5.1+ variant: `Get-ServerInfo-PS5.ps1` (CIM-based, modern error handling)
- PS 7.x variant: `Get-ServerInfo-PS7.ps1` (async/parallel ready, future)

**Variant Selection Logic**:
```powershell
Local PS: 5.1 → Loads Get-ServerInfo-PS5.ps1
Local PS: 7.x → Loads Get-ServerInfo-PS7.ps1 (if exists, else PS5)
Local PS: 2.0 → Loads Get-ServerInfo.ps1
```

### CIM vs WMI in PS 5.1+ Variants

**Replace**:
```powershell
# OLD (PS 2.0 WMI)
Get-WmiObject -Class Win32_LogicalDisk -ComputerName $ComputerName

# NEW (PS 5.1+ CIM)
Get-CimInstance -ClassName Win32_LogicalDisk -ComputerName $ComputerName
```

**Benefits**: 3-5x faster, better error handling, timeout management, persistent connections

### Error Handling Standards

**PS 5.1+**: Use `$PSItem` instead of `$_`

```powershell
try {
    # operation
}
catch [System.ComponentModel.Win32Exception] {
    # Access denied, timeout, connection issues
    Write-Error "WinRM connection failed: $($PSItem.Message)"
}
catch [System.Management.Automation.CommandNotFoundException] {
    # Cmdlet not available on target
    Write-Warning "SQL Server not installed on $ComputerName"
}
catch {
    # Generic fallback
    Write-Error $PSItem.Exception.Message
}
```

### Output Structure

All collectors return structured output:

```powershell
@{
    Success = $true|$false
    Data = @{ ... } | $null
    Error = "error message" | $null
    ExecutionTimeSeconds = [float]
    RecordCount = [int]
}
```

Orchestrator aggregates into canonical JSON:
```json
{
  "auditId": "audit-2025-11-21-SERVER01-abc123",
  "computerName": "SERVER01",
  "collectors": {
    "Get-ServerInfo": {
      "status": "Success|Failed|Timeout|Skipped",
      "executionTimeSeconds": 5.2,
      "recordCount": 1,
      "data": { ... }
    }
  },
  "summary": { "totalCollectors": 12, "successCount": 12 }
}
```

---

## T5: Migration Decision Engine Integration

### Core Functions (in `src/Analysis/Analyze-MigrationReadiness.ps1`)

1. **Invoke-WorkloadClassification** (115 LOC)
   - Input: Audit JSON from T2
   - Output: Workload type (web, database, file, DC, etc.), confidence score
   - Logic: Detects IIS/SQL/AD/Exchange/Hyper-V

2. **Invoke-ReadinessScoring** (180 LOC)
   - Input: Audit JSON
   - Output: 0-100 readiness score + 5 component scores
   - Components: Server Health (25%), App Compatibility (25%), Data Readiness (25%), Network (15%), Compliance (10%)

3. **Find-MigrationBlockers** (190 LOC)
   - Input: Audit JSON
   - Output: Critical blockers (unsupported OS, incompatible apps, license restrictions)
   - Ranks by severity + provides mitigation

4. **Get-MigrationDestinations** (220 LOC)
   - Input: Workload type, audit data
   - Output: Ranked 3-5 options (Azure IaaS/PaaS/Hybrid/On-Prem) with confidence scores
   - Rationale: "Web servers → App Service", "DB servers → Azure SQL", etc.

5. **Invoke-CostEstimation** (155 LOC)
   - Input: Destination, audit data, region, labor rate
   - Output: Monthly breakdown + first-year TCO
   - Components: Compute, storage, networking, licensing, labor, risk adjustment

6. **Build-RemediationPlan** (140 LOC)
   - Input: Audit JSON
   - Output: Tasks categorized (Critical, Important, Nice-to-Have)

7. **New-RemediationPlan** (200 LOC)
   - Input: Destination, audit data
   - Output: Gap analysis with effort estimates

8. **Estimate-MigrationTimeline** (125 LOC)
   - Input: Audit data, blocker count, complexity
   - Output: Phase-gated timeline (12-24 weeks), adjusted for complexity

### Usage

```powershell
# Phase 1: Generate decision JSON
$decision = . .\src\Analysis\Analyze-MigrationReadiness.ps1 -AuditFile "audit.json"

# Phase 2: Generate executive report (future)
$report = New-ExecutiveSummary -Decision $decision -IncludeBusinessCase

# Phase 3: Deploy remediation (future)
Deploy-RemediationPlan -RemediationPlan $decision.remediationPlan
```

---

## Integration Points

### T2 → T5 Data Flow

```
T2 Audit JSON (from Invoke-ServerAudit.ps1)
├─ ServerInfo (CPU, RAM, uptime)
├─ IISInfo (websites, bindings, certs)
├─ SQLServerInfo (instances, databases)
├─ Services (running services, startup type)
├─ ShareInfo (file share size/access)
├─ CertificateInfo (SSL certificates, expiry)
├─ InstalledApps (software inventory)
├─ DataDiscovery (PII/financial patterns)
└─ DocumentLinkAnalysis (hardcoded paths, broken links)
   │
   ↓
T5 Analyze-MigrationReadiness.ps1
├─ Invoke-WorkloadClassification
│  └─ Returns: workload type, key apps, confidence
├─ Invoke-ReadinessScoring
│  └─ Returns: 0-100 score + component breakdown
├─ Find-MigrationBlockers
│  └─ Returns: Critical issues + mitigations
├─ Get-MigrationDestinations
│  └─ Returns: Ranked 3-5 options with justification
├─ Invoke-CostEstimation
│  └─ Returns: TCO breakdown for each destination
├─ Build-RemediationPlan
│  └─ Returns: Categorized tasks
└─ Estimate-MigrationTimeline
   └─ Returns: Phase breakdown + total weeks
   │
   ↓
Decision JSON (input to Phase 2: Decision Optimization)
```

---

## Project-Specific Conventions

### File Organization

```
src/
├─ Collectors/           # All 13 collectors + variants + metadata
│  ├─ 00-System.ps1
│  ├─ Get-ServerInfo-PS5.ps1
│  ├─ collector-metadata.json
│  └─ Collector-Template.ps1
├─ Analysis/             # T5 migration decision engine
│  ├─ Analyze-MigrationReadiness.ps1 (main, 1,534 LOC)
│  ├─ Invoke-MigrationDecisions.ps1 (Phase 2 orchestrator, future)
│  └─ New-MigrationReport.ps1 (executive reporting, future)
├─ Private/              # Internal utilities (not exported)
│  ├─ Invoke-ParallelCollectors.ps1
│  ├─ Get-BusinessHoursCutoff.ps1
│  └─ Test-Prerequisites.ps1
└─ ServerAuditToolkitV2.psd1  # Module manifest
docs/
├─ README.md             # User guide (14K lines)
├─ DEVELOPMENT.md        # How to add collectors
├─ T4-Implementation.md  # Optimized variant patterns
├─ T5-ARCHITECTURE-OVERVIEW.md  # Complete T5 design
└─ T5-Phase-*.md        # Phase delivery docs

tests/
├─ unit/
│  ├─ Collectors.Tests.ps1
│  └─ Analysis.Tests.ps1
└─ integration/
   └─ EndToEnd.Integration.Tests.ps1
```

### Naming Patterns

- Functions: `Invoke-*`, `Get-*`, `Set-*`, `New-*`, `Find-*`, `Build-*`, `Estimate-*`
- Private functions: Prefix with `_` or use in separate `Private/` module
- Variables: `$camelCase` (following PowerShell convention)
- Parameters: `$PascalCase`

### Code Quality Gates

- **PSScriptAnalyzer**: Must pass (settings in `PSScriptAnalyzerSettings.psd1`)
- **Pester Tests**: Unit + integration tests required for new functions
- **Documentation**: Every collector needs @help comment block
- **Logging**: All functions must support `-Verbose` and structured logging

---

## Common Tasks & Solutions

### Adding a New Collector

1. Copy `src/Collectors/Collector-Template.ps1`
2. Implement core logic (WMI-based for PS 2.0 compatibility)
3. Create PS 5.1+ variant (`-PS5.ps1` suffix) using CIM
4. Register in `src/Collectors/collector-metadata.json`
5. Add unit tests to `tests/unit/Collectors.Tests.ps1`
6. Test: `.\Invoke-ServerAudit.ps1 -DryRun`

### Optimizing a Collector

1. Profile current: `Measure-Command { . .\Get-ServerInfo.ps1 }`
2. Replace WMI with CIM: `Get-CimInstance` instead of `Get-WmiObject`
3. Add PS 5.1+ variant (typically 50-70% faster)
4. Test both variants: Run on PS 2.0 + PS 5.1
5. Update metadata with both variants

### Testing Against Multiple Servers

```powershell
# Dry-run to validate collector selection
@("SRV1", "SRV2", "SRV3") | % {
    "Testing $_..." 
    .\Invoke-ServerAudit.ps1 -ComputerName $_ -DryRun
}

# Execute with inline error handling
$failed = @()
@("SRV1", "SRV2", "SRV3") | % {
    try {
        $result = .\Invoke-ServerAudit.ps1 -ComputerName $_ -ErrorAction Stop
        "$_ completed: $($result.Servers[0].ExecutionTimeSeconds)s"
    }
    catch {
        $failed += $_
    }
}
$failed | % { "FAILED: $_" }
```

---

## Decision Tree for Code Changes

**Adding a field to existing collector?**
- Update collector function + output structure
- Create PS 5.1+ variant with same field
- Update `collector-metadata.json` schema version

**New collector?**
- Use `Collector-Template.ps1`
- Implement both PS 2.0 + PS 5.1+ variants
- Register in metadata
- Add tests

**New analysis function (T5)?**
- Add to `src/Analysis/Analyze-MigrationReadiness.ps1`
- Document with inline examples (copy style from existing functions)
- Test with sample audit JSON files from `tests/samples/`

**Performance issue?**
- Profile first: `Measure-Command`
- Replace WMI → CIM
- Consider parallel processing (PS 7+)
- Add PS 5.1+ variant

---

## References & Key Files

- **Entry Point**: `Invoke-ServerAudit.ps1` (779 LOC, orchestrator)
- **Collector Registry**: `src/Collectors/collector-metadata.json`
- **T5 Decision Engine**: `src/Analysis/Analyze-MigrationReadiness.ps1` (1,534 LOC)
- **Main Module**: `ServerAuditToolkitV2.psd1`
- **Linting Config**: `PSScriptAnalyzerSettings.psd1`
- **User Guide**: `README.md`
- **Design Docs**: `docs/T5-ARCHITECTURE-OVERVIEW.md`

---

**Last Updated**: November 26, 2025  
**Current State**: T1-T5 Complete (Production Ready)  
**Branch**: `t4-phase1-core-engine` (main development)
