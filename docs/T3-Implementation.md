# Task T3: Optimized Collector Registry & Loader

## Overview

T3 refactors `Invoke-ServerAudit.ps1` as a **three-stage orchestrator**:

1. **DISCOVER** (T1): Filter collectors by PS version + OS
2. **PROFILE** (T2): Profile server capabilities and determine parallelism
3. **EXECUTE** (T3): Run collectors with adaptive parallelism and timeout management

## Three-Stage Execution Model

### Stage 1: DISCOVER
```
Load collector-metadata.json
  ↓
Filter by local PS version (T1)
  ↓
Filter by user selection (optional)
  ↓
Display compatible collectors
```

**Output**: `$auditSession.CompatibleCollectors` array

### Stage 2: PROFILE & EXECUTE
For each target server:
```
Get-ServerCapabilities (T2) → Detect CPU, RAM, disk, network
  ↓
Calculate parallelism budget (T2)
  ↓
Invoke-CollectorExecution (T3)
  ├─ Variant selection per collector
  ├─ Dependency validation
  ├─ Sequential or parallel execution
  └─ Timeout management
```

**Output**: Per-server results with execution metrics

### Stage 3: FINALIZE
```
Aggregate server results
  ↓
Calculate summary statistics
  ↓
Export to JSON, CSV
  ↓
Display summary report
```

## Core Functions

### `Invoke-ServerAudit` (Public)
Main entry point. Orchestrates all three stages.

**Parameters**:
- `ComputerName` — Target servers (pipeline-compatible)
- `Collectors` — Filter by name (optional)
- `DryRun` — Show what will execute without running
- `MaxParallelJobs` — Override auto-detected parallelism (0=auto)
- `SkipPerformanceProfile` — Skip T2 profiling for speed
- `OutputPath` — Where to export results

**Returns**: Structured audit results object

**Example**:
```powershell
# Dry-run to see what will execute
Invoke-ServerAudit -ComputerName "SERVER01" -DryRun

# Execute with auto-detected parallelism
$results = Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02"

# Manual parallelism override
$results = Invoke-ServerAudit -ComputerName "SERVER01" -MaxParallelJobs 4
```

### `Invoke-CollectorExecution` (Internal)
Orchestrates collector execution for a single server.

**Logic**:
- If PS 2.0 or Parallelism=1 → Sequential execution
- If PS 3+ and Parallelism>1 → Parallel via runspace pool

**Returns**: Array of collector results

### `Invoke-SingleCollector` (Internal)
Executes a single collector with:
- Variant selection (via T1)
- Dependency validation
- Timeout enforcement
- Error handling and recovery

### `Invoke-ParallelCollectors` (Internal)
Manages runspace pool for parallel execution (PS 3+).

**Features**:
- Job queueing
- Result collection with timeout
- Runspace cleanup

## Execution Flow with Example

```powershell
PS> Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02" -DryRun
```

### Console Output
```
=== ServerAuditToolkitV2 Orchestrator (T3) ===
Local PS Version: 5.1
STAGE 1: DISCOVER (Collector Compatibility)
  Loading collector metadata...
  Found 12 compatible collectors
  Compatible collectors:
    - Server Information (variants: 2.0, 4.0, 5.1, 7.0)
    - IIS Configuration (variants: 2.0, 4.0, 5.1, 7.0)
    - ... (more collectors)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Server: SERVER01
STAGE 2a: PROFILE (Server Capabilities, T2)
  Profiling SERVER01...
  Profile complete: Tier=High, Jobs=4, Timeout=60s
  Resource constraints detected:
    ⚠ High disk latency (52ms read)

STAGE 2b: EXECUTE (Run Collectors, T3)
  Using parallelism=4 jobs with 60s timeout per collector
  Running: Server Information... [OK - 3.2s]
  Running: IIS Configuration... [OK - 5.1s]
  Running: Windows Services... [OK - 2.8s]
  ... (more collectors)
Server audit complete in 18.5s: 12/12 collectors succeeded

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Server: SERVER02
STAGE 2a: PROFILE (Server Capabilities, T2)
  Profiling SERVER02...
  Profile complete: Tier=Medium, Jobs=2, Timeout=90s

STAGE 2b: EXECUTE (Run Collectors, T3)
  Using parallelism=2 jobs with 90s timeout per collector
  Running: Server Information... [OK - 4.5s]
  ... (more collectors)
Server audit complete in 25.3s: 12/12 collectors succeeded

STAGE 3: FINALIZE (Aggregate Results)
=== Audit Summary ===
Servers audited: 2
Successful: 2 | Failed: 0
Collectors executed: 24/24
Duration: 47.2s
Results exported to: C:\...\audit_results
```

## Parallelism Decision Tree

```
MaxParallelJobs > 0?
  ├─ YES → Use specified value (user override)
  └─ NO → Continue

PerformanceProfile successful?
  ├─ YES → Use T2-detected SafeParallelJobs
  └─ NO → Continue

Defaults?
  └─ Use conservative: 1 job, 60s timeout
```

## Timeout Strategy

| Scenario | Timeout | Rationale |
|----------|---------|-----------|
| Local PS2 (seq) | 120s per collector | Legacy systems slower |
| Local PS5+ (1 job) | 60s per collector | Single job, modern PS |
| Parallel (4 jobs) | 45-60s per collector | Multiple concurrent jobs |
| Remote WinRM | +20s buffer | Network latency |

**Overall timeout** = (Avg collector time × Count) / Parallelism + 30% buffer

## Dry-Run Mode

`-DryRun` flag shows what will execute without actually running collectors.

Useful for:
- Validating configuration before large audits
- Planning parallelism on unfamiliar servers
- Testing collector selection logic

**Example**:
```powershell
# Check compatibility on legacy server
Invoke-ServerAudit -ComputerName "LEGACY_2008R2" -DryRun
```

## Export Format

### JSON (Raw Data)
```
audit_20251119_143215.json
```
Contains all metadata, collector data, timing, errors.

### CSV (Summary)
```
audit_summary_20251119_143215.csv
```
Per-server summary with success rate and execution time.

### Log File
```
$env:TEMP\SAT_{SessionId}.log
```
Timestamped entries for troubleshooting.

## Caching Behavior (T2 Integration)

Server profiles are cached for 24 hours:
- First audit of "SERVER01" → profiles fresh (5-10s overhead)
- Second audit of "SERVER01" within 24h → instant cache hit
- After 24h → automatic fresh profile

To force re-profiling:
```powershell
Get-ServerCapabilities -ComputerName "SERVER01" -UseCache:$false
```

## Performance Characteristics

### Single Server, Local Execution
- PS 2.0 (sequential): ~30-45s for 12 collectors
- PS 5.1 (auto parallelism): ~15-25s for 12 collectors
- PS 5.1 (4 parallel jobs): ~10-18s for 12 collectors

### Multi-Server Audit
Sequential server iteration:
- 5 servers × 20s avg = ~100s total
- Profile caching reduces overhead on 2nd+ servers

## Troubleshooting

**Q: Audit is slow even with parallelism enabled**

A: Check resource constraints:
```powershell
$cap = Get-ServerCapabilities -ComputerName "SERVER01" -UseCache:$false
$cap.ResourceConstraints
```

**Q: Some collectors timeout**

A: Increase timeout:
```powershell
Invoke-ServerAudit -ComputerName "SERVER01" -MaxParallelJobs 1
```

This forces sequential execution with longer timeouts.

**Q: Can I run a subset of collectors?**

A: Yes:
```powershell
Invoke-ServerAudit `
    -ComputerName "SERVER01" `
    -Collectors @("Get-ServerInfo", "Get-IISInfo", "Get-SQLServerInfo")
```

## Testing T3

```powershell
# Test 1: Dry-run
Invoke-ServerAudit -ComputerName $env:COMPUTERNAME -DryRun

# Test 2: Full audit
$results = Invoke-ServerAudit -ComputerName $env:COMPUTERNAME
$results.Summary | Format-Table

# Test 3: Specific collectors
$results = Invoke-ServerAudit `
    -ComputerName $env:COMPUTERNAME `
    -Collectors @("Get-ServerInfo", "Get-Services")

# Test 4: Override parallelism
$results = Invoke-ServerAudit `
    -ComputerName $env:COMPUTERNAME `
    -MaxParallelJobs 1

# Test 5: Skip profiling
$results = Invoke-ServerAudit `
    -ComputerName $env:COMPUTERNAME `
    -SkipPerformanceProfile
```

---