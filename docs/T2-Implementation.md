# Task T2: Server Performance Profiler

## Overview

T2 introduces **adaptive parallelism** by profiling server capabilities and calculating safe job budgets.

After T1 detects *which* collectors are compatible, T2 determines *how many* collectors can run in parallel without overloading the server.

## Files Delivered

### 1. `Get-ServerCapabilities.ps1`
Core profiler with sub-functions:
- `Get-ServerCapabilities` — Main entry point; profiles and caches results
- `Get-ProcessorInfo` — Detect CPU cores, model, speed
- `Get-RAMInfo` — Detect total/available RAM and usage
- `Get-DiskPerformance` — Detect disk I/O latency and free space
- `Test-NetworkConnectivity` — Test ICMP ping latency
- `Get-SystemLoad` — Get current CPU load percentage
- `Calculate-ParallelismBudget` — Calculate safe job count and timeouts

### 2. `performance-profile-schema.md`
Schema and calculation logic for cached profiles.

## Key Concepts

### Performance Tiers

| Tier | SafeParallelJobs | Per-Job Timeout | Use Case |
|------|------------------|-----------------|----------|
| **Low** | 1 | 120s | ≤2 CPU cores, <4GB RAM, disk/network constrained |
| **Medium** | 2-4 | 90s | 4 cores, 4-8GB RAM, baseline infrastructure |
| **High** | 4-8 | 60s | 8+ cores, 8GB+ RAM, modern servers |
| **VeryHigh** | 8+ | 45s | 16+ cores, 16GB+ RAM, high-performance |

### Resource Constraints

Profile detection identifies bottlenecks:
- **Low CPU cores** (≤2) → Reduce parallelism
- **Low RAM** (<2GB) or high usage (>80%) → Reduce parallelism
- **Low disk free** (<10%) → Reduce parallelism
- **High disk latency** (>50ms) → Reduce parallelism
- **High network latency** (>100ms on remote) → Force 1 job
- **High system load** (>60%) → Reduce parallelism

## Usage Examples

### Basic Profiling

```powershell
# Profile localhost
$cap = Get-ServerCapabilities

Write-Host "Performance Tier: $($cap.PerformanceTier)"
Write-Host "Safe Parallel Jobs: $($cap.SafeParallelJobs)"
Write-Host "Per-Job Timeout: $($cap.JobTimeoutSec)s"
Write-Host "Overall Timeout: $($cap.OverallTimeoutSec)s"
```

### Check Constraints

```powershell
$cap = Get-ServerCapabilities -ComputerName "SERVER01"

if ($cap.ResourceConstraints.Count -gt 0) {
    Write-Warning "Constraints detected:"
    $cap.ResourceConstraints | ForEach-Object { Write-Warning "  $_" }
}
```

### Force Fresh Profile

```powershell
# Skip cache, re-profile
$cap = Get-ServerCapabilities -ComputerName "SERVER01" -UseCache:$false
```

### Remote Profiling

```powershell
$cred = Get-Credential
$cap = Get-ServerCapabilities -ComputerName "SERVER01" -Credential $cred

# Check if network latency is an issue
if ($cap.NetworkLatencyMs -gt 100) {
    Write-Warning "High network latency detected. Audit will be slower."
}
```

## Integration with T1 & T3

### T1 → T2 Flow

```
Invoke-ServerAudit (T3 orchestrator)
  ↓
Get-CollectorMetadata (T1)
  → Filter compatible collectors
  ↓
Get-ServerCapabilities (T2)
  → Profile CPU, RAM, disk, network
  → Calculate parallelism budget
  ↓
Execute collectors (with T2 parameters)
```

### T2 Parameters to T3

`Get-ServerCapabilities` returns:
- `SafeParallelJobs` → Used for concurrent job count in T3
- `JobTimeoutSec` → Per-collector timeout in T3
- `OverallTimeoutSec` → Total audit timeout in T3
- `PerformanceTier` → For reporting and logging
- `ResourceConstraints` → For warnings and decision-making

## Caching Behavior

Profiles are automatically cached for **24 hours**:
- First run: profiles fresh (5-10 seconds)
- Second run within 24 hours: returns cached profile instantly
- After 24 hours: automatic re-profile on next run

Cache location: `$env:TEMP\ServerAuditToolkit\Profiles\{ComputerName}-profile.json`

## Testing T2

```powershell
# Test 1: Profile localhost
$cap = Get-ServerCapabilities
Write-Host "Parallelism budget: $($cap.SafeParallelJobs) jobs"

# Test 2: Detect CPU
$cpu = Get-ProcessorInfo
Write-Host "CPUs: $($cpu.LogicalCores) logical, $($cpu.PhysicalCores) physical"

# Test 3: Detect RAM
$ram = Get-RAMInfo
Write-Host "RAM: $($ram.TotalMB)MB total, $($ram.UsagePercent)% used"

# Test 4: Detect disk
$disk = Get-DiskPerformance
Write-Host "Disk latency: $($disk.ReadLatencyMs)ms read, $($disk.WriteLatencyMs)ms write"

# Test 5: Network test
$net = Test-NetworkConnectivity
Write-Host "Network: $($net.Connectivity), $($net.LatencyMs)ms latency"

# Test 6: Cache behavior
$cap1 = Get-ServerCapabilities -UseCache:$true
# Call again — should return cached result
$cap2 = Get-ServerCapabilities -UseCache:$true
Write-Host "Cached: $($cap2.CachedResult)"
```

## Troubleshooting

**Q: Why does my high-performance server get 1 parallel job?**

A: Check `$cap.ResourceConstraints`. Common causes:
- Server under heavy load (check `LoadAveragePercent`)
- Slow disk I/O (check `DiskReadLatencyMs` > 50ms)
- Insufficient available RAM (check `RAMUsagePercent` > 80%)
- Low free disk space (check `DiskAverageFreePercent` < 10%)

**Q: How do I force a specific parallelism level?**

A: Pass `-MaxParallelJobs` to `Invoke-ServerAudit`:
```powershell
Invoke-ServerAudit -ComputerName "SERVER01" -MaxParallelJobs 4
```
This overrides T2 profiling.

**Q: Can I disable profiling to save time?**

A: Yes, use `-SkipPerformanceProfile`:
```powershell
Invoke-ServerAudit -ComputerName "SERVER01" -SkipPerformanceProfile
```
This uses conservative defaults (1 job, 60s timeout).

---