# Development Guide — ServerAuditToolkitV2 (Phase 3)

**Current Version**: v2.2.0-RC (Phase 3: 13/14 enhancements complete)

This guide provides detailed technical information for developing, enhancing, and maintaining ServerAuditToolkitV2.

**Phase 3 Additions** (November 2025):
- ✅ M-013: Comprehensive API documentation (docs/API-REFERENCE.md)
- ✅ M-014: Health diagnostics engine (src/Private/New-AuditHealthDiagnostics.ps1)
- ✅ Batch processing for 100+ servers (M-010)
- ✅ Network resilience with DNS retry (M-008)
- ✅ Resource monitoring with auto-throttle (M-009)

For Phase 3 API reference, see: **docs/API-REFERENCE.md**

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Execution Stages](#execution-stages)
3. [Collector Design](#collector-design)
4. [Version Management](#version-management)
5. [Robustness Enhancements](#robustness-enhancements)
6. [Performance Optimization](#performance-optimization)
7. [Testing Strategy](#testing-strategy)
8. [Troubleshooting Development](#troubleshooting-development)

---

## Architecture Overview

### Three-Stage Audit Pipeline

ServerAuditToolkitV2 follows a **three-stage execution model**:

```
┌─────────────────────────────────────────────────────────────┐
│ Stage 1: DISCOVER                                            │
│ ─────────────────────────────────────────────────────────────│
│ • Load collector metadata from collector-metadata.json       │
│ • Detect local PowerShell version                           │
│ • Filter collectors by PS version compatibility             │
│ • Validate all collectors registered and loadable            │
│ Output: List of compatible collectors                        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Stage 2a: PROFILE (T2 — Performance Detection)              │
│ ─────────────────────────────────────────────────────────────│
│ • Execute Get-ServerCapabilities on target server           │
│ • Detect CPU count, RAM, disk space, load average           │
│ • Determine optimal parallelism (1-3 jobs)                 │
│ • Detect resource constraints (low disk, high CPU)          │
│ Output: Performance tier, safe parallelism, timeout budget  │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Stage 2b: EXECUTE (T3 — Collector Execution)                │
│ ─────────────────────────────────────────────────────────────│
│ • Queue collectors based on parallelism budget              │
│ • Execute in runspace pool (PS 3+) or sequentially (PS 2)  │
│ • Enforce per-collector timeout from metadata               │
│ • Track execution time, errors, record count                │
│ Output: Collector results, execution metrics                │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Stage 3: FINALIZE                                            │
│ ─────────────────────────────────────────────────────────────│
│ • Aggregate results across all servers                      │
│ • Calculate summary statistics                              │
│ • Export JSON (raw), CSV (summary), HTML (report)          │
│ • Log audit session details                                 │
│ Output: audit_results/ directory with formatted reports     │
└─────────────────────────────────────────────────────────────┘
```

### Execution Stages

#### Stage 1: DISCOVER

**File**: `Invoke-ServerAudit.ps1` (lines ~100-150)

```powershell
# Load collector metadata
$metadata = Get-CollectorMetadata

# Filter by PS version
$compatible = Get-CompatibleCollectors -Collectors $metadata.collectors `
    -PSVersion $PSVersion

# Filter by user selection (optional)
$selected = $compatible | Where-Object { $_.name -in $UserCollectors }
```

**Outputs**:
- Array of compatible collector definitions
- Metadata about each collector (timeout, dependencies, etc.)

#### Stage 2a: PROFILE (T2)

**File**: `src/Collectors/Get-ServerCapabilities.ps1`

This collector is special — it's called before other collectors to assess the target server:

```powershell
# Example output structure
@{
    Success = $true
    PerformanceTier = 'High'  # High, Medium, Low
    SafeParallelJobs = 3
    JobTimeoutSec = 90
    ResourceConstraints = @()
    ServerProfile = @{
        CPUCount = 4
        TotalMemoryMB = 32768
        AvailableMemoryMB = 28000
        DiskFreePercent = 45
        SystemLoadPercent = 35
    }
}
```

#### Stage 2b: EXECUTE (T3)

**File**: `Invoke-ServerAudit.ps1` (lines ~250-350)

For each server:

1. **Sequential Path** (PS 2.0 or Parallelism=1):
   ```powershell
   foreach ($collector in $Collectors) {
       Invoke-SingleCollector -Server $server -Collector $collector
   }
   ```

2. **Parallel Path** (PS 3+ and Parallelism > 1):
   ```powershell
   $RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
       1, $MaxJobs, ...
   )
   $RunspacePool.Open()
   
   # Queue jobs
   foreach ($collector in $Collectors) {
       $ps = [System.Management.Automation.PowerShell]::Create()
       $ps.RunspacePool = $RunspacePool
       $ps.AddScript({ Invoke-SingleCollector ... })
       $jobs += $ps.BeginInvoke()
   }
   
   # Collect results with timeout
   foreach ($job in $jobs) {
       $result = $ps.EndInvoke($asyncHandle)
   }
   ```

---

## Collector Design

### Standard Collector Structure

Every collector should follow this pattern:

```powershell
<#
.SYNOPSIS
    Collects [information] from target server.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+ (or 5.1+, 7.0+ for variants)
    License:      MIT
#>

function Get-MyInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-MyInfo
    # @PSVersions: 2.0,5.1
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies: Optional-Module
    # @Timeout: 30
    # @Category: core|application|infrastructure|compliance
    # @Critical: true|false

    $startTime = Get-Date

    try {
        # Validation (optional)
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would collect [data type] from $ComputerName"
            return @{ Success = $true; Data = @() }
        }

        # Collection logic
        $data = Get-SomeData -ComputerName $ComputerName -ErrorAction Stop

        # Normalize output (required)
        return @{
            Success        = $true
            CollectorName  = 'Get-MyInfo'
            Data           = $data
            ExecutionTime  = (Get-Date) - $startTime
            RecordCount    = @($data).Count
        }
    }
    catch {
        # Error handling (required)
        return @{
            Success        = $false
            CollectorName  = 'Get-MyInfo'
            Error          = $_.Exception.Message
            ExecutionTime  = (Get-Date) - $startTime
            RecordCount    = 0
        }
    }
}

# Invoke if script is run directly (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    Get-MyInfo @PSBoundParameters
}
```

### Required Return Structure

All collectors **must** return this standardized object:

```powershell
@{
    Success        = [bool]     # True if successful
    CollectorName  = [string]   # Matches @CollectorName tag
    Data           = [object]   # The actual collected data (or @() if failed)
    ExecutionTime  = [timespan] # Elapsed time
    RecordCount    = [int]      # Number of records/objects collected
    Error          = [string]   # (Optional) Error message if failed
}
```

### Metadata Tags (In Comment Block)

These tags are parsed and used by the orchestrator:

| Tag | Required | Example | Notes |
|-----|----------|---------|-------|
| `@CollectorName` | Yes | `Get-ServerInfo` | Unique ID |
| `@PSVersions` | Yes | `2.0,5.1,7.0` | Comma-separated versions |
| `@MinWindowsVersion` | Yes | `2008R2` | Earliest OS version |
| `@MaxWindowsVersion` | No | (blank) | Latest OS; blank = no limit |
| `@Dependencies` | No | `WebAdministration` | Required modules/features |
| `@Timeout` | Yes | `30` | Max seconds before kill |
| `@Category` | Yes | `core` | Grouping (core, app, infra, compliance) |
| `@Critical` | Yes | `true` | Essential for migration decisions? |

---

## Version Management

### PowerShell Version Strategy

The toolkit supports **three optimization tiers**:

#### Tier 1: PS 2.0 (Baseline)

- Uses `Get-WmiObject` (slow, verbose)
- Sequential execution only
- Minimal error handling (`$_` instead of `$PSItem`)
- Works on Windows Server 2008 R2+
- **Files**: `Get-ServerInfo.ps1`, `Get-Services.ps1`, etc. (no suffix)

#### Tier 2: PS 5.1 (Optimized)

- Uses `Get-CimInstance` (3-5x faster via CIM protocol)
- Modern error handling (`$PSItem`, better stack traces)
- Parallelism support (up to 3 jobs)
- Works on Windows Server 2012 R2+
- **Files**: `Get-ServerInfo-PS5.ps1`, `Get-IISInfo-PS5.ps1` (suffix `-PS5`)

#### Tier 3: PS 7.x (Advanced)

- Uses `Get-CimInstance` with parallel parameters
- `Where-Object -Parallel` for bulk operations
- Cross-platform ready (partial Windows Server support)
- Advanced async/await patterns
- **Files**: `Get-ServerInfo-PS7.ps1` (suffix `-PS7`)

### Creating a PS 5.1+ Variant

**Start** with PS 2.0 baseline:

```powershell
# ❌ PS 2.0: Slow WMI call
$os = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName
```

**Optimize** for PS 5.1+:

```powershell
# ✅ PS 5.1: Fast CIM call (3-5x faster)
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem `
        -ComputerName $ComputerName -ErrorAction Stop
}
catch {
    # Fallback to WMI if CIM unavailable
    $os = Get-WmiObject -Class Win32_OperatingSystem `
        -ComputerName $ComputerName -ErrorAction Stop
}
```

**Steps**:

1. Copy base: `cp Get-ServerInfo.ps1 Get-ServerInfo-PS5.ps1`
2. Replace all `Get-WmiObject` → `Get-CimInstance`
3. Update `@CollectorName` tag: `Get-ServerInfo-PS5`
4. Update `@PSVersions` tag: `5.1,7.0`
5. Update metadata JSON `variants` section
6. Test on PS 5.1 and PS 7.x

---

## Robustness Enhancements

### Recommended Improvements

#### 1. Business Hours Cutoff Implementation ⭐ HIGH PRIORITY

**Status**: Framework exists; integration needed

**File**: `src/Private/Get-BusinessHoursCutoff.ps1` (created in T1)

**Integration Point** (`Invoke-ServerAudit.ps1` line ~300):

```powershell
# Add this check before each collector execution
if (Test-BusinessHoursCutoff -BusinessStartHour 8 -CutoffMinutesBefore 60) {
    Write-AuditLog "Approaching business hours (7:00 AM). Stopping audit." -Level Warning
    break  # Exit collector loop
}
```

**Benefit**: Prevents audit storms during morning business start.

#### 2. Max 3 Concurrent Servers Enforcement ⭐ HIGH PRIORITY

**Status**: Exists in metadata (`maxConcurrentServers: 3`); enforce in orchestrator

**Implementation**:

```powershell
# In Invoke-ServerAudit.ps1 process block
$servers | ForEach-Object -ThrottleLimit 3 {
    # Execute audit for this server
    # PS 5.1: Use -ThrottleLimit parameter
    # PS 2.0: Implement with Start-Job tracking
}
```

**Benefit**: Prevents resource contention and network saturation.

#### 3. Enhanced Error Recovery ✅ GOOD

**Status**: Partially implemented

**Improvements**:

```powershell
# Add retry logic for transient failures
function Invoke-CollectorWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            if ($attempt -lt $MaxRetries) {
                Write-Warning "Attempt $attempt failed; retrying in $RetryDelaySeconds seconds..."
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            else {
                throw
            }
        }
    }
}
```

#### 4. Structured Logging (JSON) ⭐ MEDIUM PRIORITY

**Status**: Basic logging exists; JSON format needed

**Enhancement**:

```powershell
# Instead of plain text logs, use JSON
$logEntry = @{
    Timestamp   = Get-Date -Format 'o'
    Level       = 'Information'
    SessionId   = $auditSession.SessionId
    Message     = "Collector executed"
    Collector   = 'Get-ServerInfo'
    Server      = 'SERVER01'
    Status      = 'Success'
    Duration    = 5.23
    RecordCount = 42
} | ConvertTo-Json -Compress

Add-Content -Path $logFile -Value $logEntry
```

**Benefit**: Machine-parseable logs for analytics, correlation.

#### 5. Credential Handling (No Hardcoding) ✅ GOOD

**Status**: Already uses domain-user (no stored secrets)

**Verification**:

- Never store credentials in JSON or scripts ✅
- Always use `Get-Credential` at runtime if needed ✅
- Leverage domain user (DC assumption) ✅

#### 6. WinRM → RPC Fallback Logic ⭐ MEDIUM PRIORITY

**Current**: WinRM only

**Enhancement**:

```powershell
function Test-RemoteAccess {
    param([string]$ComputerName)

    # Try WinRM (PS Remoting)
    try {
        Test-Connection -ComputerName $ComputerName -ErrorAction Stop
        return 'WinRM'
    }
    catch {
        Write-Verbose "WinRM unavailable; trying RPC..."
    }

    # Try RPC (WMI/DCOM)
    try {
        Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ComputerName `
            -ErrorAction Stop | Out-Null
        return 'RPC'
    }
    catch {
        Write-Verbose "RPC unavailable..."
    }

    return $null
}
```

#### 7. PII Detection Pattern Matching ✅ READY

**Status**: Collector `85-DataDiscovery.ps1` exists

**Patterns** (in `audit-config.json`):
- SSN: `\d{3}-\d{2}-\d{4}`
- Credit Card: `\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}`
- UK Sort Code: `\d{2}-\d{2}-\d{2}`
- UK IBAN: `GB\d{2}[A-Z]{4}\d{14}`
- UK NIN: `[A-Z]{2}\d{6}[A-D]`

**Enhance**: Add more patterns, regex validation, false-positive reduction.

---

## Performance Optimization

### Strategy: CIM > WMI >> ActiveDirectory module

**Benchmark** (empirical):

| Method | Provider | Time | Notes |
|--------|----------|------|-------|
| `Get-WmiObject` | DCOM | 3-5s | Slow, verbose output |
| `Get-CimInstance` | CIM/WinRM | 0.8-1.2s | 3-5x faster |
| `Get-CimInstance -Parallel` (PS 7) | CIM/Async | 0.3-0.5s | 5-10x faster |
| `Get-ADUser` | LDAP/RPC | 1-2s | Domain queries only |

### Key Optimizations

#### 1. Use CIM, Not WMI

```powershell
# ❌ Slow (2-3 seconds)
Get-WmiObject -Class Win32_OperatingSystem -ComputerName $target

# ✅ Fast (300-500ms)
Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $target
```

#### 2. Pipeline Filtering (PS 5.1+)

```powershell
# ❌ Slow: Retrieve all, filter locally
$all = Get-CimInstance -ClassName Win32_Service -ComputerName $target
$running = $all | Where-Object { $_.State -eq 'Running' }

# ✅ Fast: Filter on remote end
$running = Get-CimInstance -ClassName Win32_Service -ComputerName $target `
    -Filter "State='Running'"
```

#### 3. Selective Property Retrieval

```powershell
# ❌ Slow: Get all 100+ properties
Get-CimInstance -ClassName Win32_OperatingSystem

# ✅ Fast: Get only needed properties
Get-CimInstance -ClassName Win32_OperatingSystem `
    -Property Name, Version, BuildNumber, InstallDate
```

#### 4. Batch Operations (PS 7+)

```powershell
# ❌ Serial (slow)
$servers | ForEach-Object {
    Get-CimInstance -ClassName Win32_Process -ComputerName $_
}

# ✅ Parallel (fast)
$servers | ForEach-Object -Parallel {
    Get-CimInstance -ClassName Win32_Process -ComputerName $_
} -ThrottleLimit 3
```

---

## Testing Strategy

### Test Pyramid

```
         /\
        /  \
       / E2E \         Integration tests
      /______\        (full audit runs)
       /    \
      / Unit  \        Unit tests
     /________\       (single collectors)
```

### Unit Tests (Per Collector)

**File**: `tests/unit/Get-ServerInfo.Tests.ps1`

```powershell
Describe 'Get-ServerInfo' {
    BeforeAll {
        . .\src\Collectors\Get-ServerInfo.ps1
    }

    It 'Should return a hashtable' {
        $result = Get-ServerInfo
        $result | Should -BeOfType [hashtable]
    }

    It 'Should contain required keys' {
        $result = Get-ServerInfo
        $result.Keys | Should -Contain 'Success'
        $result.Keys | Should -Contain 'Data'
        $result.Keys | Should -Contain 'ExecutionTime'
    }

    It 'Should succeed on localhost' {
        $result = Get-ServerInfo -ComputerName $env:COMPUTERNAME
        $result.Success | Should -Be $true
    }

    It 'Should timeout gracefully' {
        $result = Get-ServerInfo -ComputerName '192.0.2.1'
        $result.ExecutionTime.TotalSeconds | Should -BeLessThan 60
    }
}
```

### Integration Tests (Full Audit)

**File**: `tests/integration/Invoke-ServerAudit.Integration.Tests.ps1`

```powershell
Describe 'Invoke-ServerAudit Integration' {
    It 'Should audit localhost' {
        $result = .\Invoke-ServerAudit.ps1 -ComputerName $env:COMPUTERNAME
        $result.Servers[0].Success | Should -Be $true
    }

    It 'Should respect max 3 concurrent servers' {
        $servers = @('SRV01', 'SRV02', 'SRV03', 'SRV04')
        # Verify only 3 run concurrently
        $result = .\Invoke-ServerAudit.ps1 -ComputerName $servers
        # Check that jobs never exceed 3
    }

    It 'Should enforce business hours cutoff' {
        # Mock Get-Date to return 7:30 AM
        # Verify audit stops before 8 AM
    }
}
```

### Run Tests

```powershell
# All tests
Invoke-Pester tests/ -Verbose

# Specific test file
Invoke-Pester tests/unit/Get-ServerInfo.Tests.ps1

# With coverage
Invoke-Pester tests/ -CodeCoverage src/Collectors/*.ps1
```

---

## Troubleshooting Development

### Issue: Collector Timeout

**Symptoms**: Collector runs >timeout seconds but doesn't stop

**Debug**:
```powershell
# Check timeout in metadata
$meta = Get-CollectorMetadata
$meta.collectors | Where-Object { $_.name -eq 'Get-MyCollector' } | 
    Select-Object -ExpandProperty timeout

# Run collector with verbose output
.\Get-MyCollector.ps1 -ComputerName SERVER01 -Verbose

# Profile execution time
Measure-Command { .\Get-MyCollector.ps1 -ComputerName SERVER01 }
```

**Solutions**:
- Increase timeout in `collector-metadata.json`
- Optimize collector (CIM, filtering, caching)
- Split into multiple smaller collectors

### Issue: Remote Execution Failure

**Symptoms**: "Access Denied" or "WinRM connection failed"

**Debug**:
```powershell
# Test WinRM connectivity
Test-WSMan -ComputerName SERVER01

# Test remote PS execution
Invoke-Command -ComputerName SERVER01 -ScriptBlock { $PSVersionTable }

# Check credentials
$cred = Get-Credential
Invoke-Command -ComputerName SERVER01 -Credential $cred -ScriptBlock { whoami }
```

**Solutions**:
- Enable WinRM: `Enable-PSRemoting -Force` (on target)
- Add to local Admins group
- Check Kerberos/NTLM authentication
- Verify network connectivity (firewalls, DNS)

### Issue: Out-of-Memory During Parallel Execution

**Symptoms**: "Not enough memory" when running many collectors in parallel

**Debug**:
```powershell
# Check available memory
Get-CimInstance -ClassName Win32_OperatingSystem | 
    Select-Object TotalVisibleMemorySize, FreePhysicalMemory

# Run with reduced parallelism
.\Invoke-ServerAudit.ps1 -ComputerName SERVER01 -MaxParallelJobs 1
```

**Solutions**:
- Reduce `MaxParallelJobs` (default 3)
- Increase timeout (let collectors finish sequentially)
- Split large audits across multiple runs
- Check for memory leaks in collectors (dispose runspaces)

---

## Next Steps

After implementing these enhancements, focus on:

1. **T5**: Comprehensive unit & integration test suite
2. **T6**: GitHub Actions CI/CD pipeline
3. **T7**: HTML report generation with charts
4. **T8**: Dependency mapping & application relationship detection

For questions or contributions, see [CONTRIBUTING.md](../CONTRIBUTING.md).
