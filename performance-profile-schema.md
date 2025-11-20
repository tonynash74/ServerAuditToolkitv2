# Server Performance Profile Schema

## Overview

Performance profiles are cached JSON files stored in `$env:TEMP\ServerAuditToolkit\Profiles\`.
Each profile is named `{ComputerName}-profile.json` and is valid for **24 hours**.

## Schema

```json
{
  "ComputerName": "SERVER01",
  "Timestamp": "2025-11-19 14:32:15.123",
  "Success": true,
  "CPUCores": 4,
  "CPUCoresLogical": 4,
  "CPUCoresPhysical": 2,
  "CPUModel": "Intel(R) Xeon(R) CPU E5-2620 v2 @ 2.10GHz",
  "CPUSpeedGHz": 2.1,
  "RAMTotalMB": 8192,
  "RAMAvailableMB": 4096,
  "RAMUsagePercent": 50.0,
  "DiskReadLatencyMs": 5.2,
  "DiskWriteLatencyMs": 8.1,
  "DiskAverageFreePercent": 25.5,
  "NetworkLatencyMs": 2,
  "NetworkConnectivity": "Online",
  "LoadAveragePercent": 35.0,
  "PerformanceTier": "Medium",
  "SafeParallelJobs": 2,
  "JobTimeoutSec": 90,
  "OverallTimeoutSec": 450,
  "ResourceConstraints": [
    "Low disk space (25% free)"
  ],
  "ProfiledAt": "2025-11-19 14:32:15.123",
  "CachedResult": false,
  "Errors": [],
  "Warnings": []
}
```

## Field Definitions

### Hardware Detection
- **CPUCoresLogical**: Total logical processors (hyperthreading included)
- **CPUCoresPhysical**: Physical core count
- **CPUModel**: CPU name from WMI
- **CPUSpeedGHz**: Max clock speed in GHz

### Memory
- **RAMTotalMB**: Total installed RAM in megabytes
- **RAMAvailableMB**: Currently available RAM
- **RAMUsagePercent**: Percentage of RAM in use (0-100)

### Storage
- **DiskReadLatencyMs**: Average disk read latency in milliseconds (from perfmon)
- **DiskWriteLatencyMs**: Average disk write latency
- **DiskAverageFreePercent**: Free space on C: drive as percentage

### Network
- **NetworkLatencyMs**: ICMP ping round-trip time (0 for localhost)
- **NetworkConnectivity**: 'Online' | 'Unreachable' | 'Unknown'

### Performance Metrics
- **LoadAveragePercent**: Current CPU load as percentage of capacity
- **PerformanceTier**: 'Low' | 'Medium' | 'High' | 'VeryHigh'
  - **Low**: ≤1 parallel job (minimal resources)
  - **Medium**: 2-4 parallel jobs (basic server)
  - **High**: 4-8 parallel jobs (modern server)
  - **VeryHigh**: 8+ parallel jobs (high-performance server)

### Parallelism Budget
- **SafeParallelJobs**: Recommended concurrent audit jobs
- **JobTimeoutSec**: Per-collector timeout in seconds
- **OverallTimeoutSec**: Total audit timeout in seconds
- **ResourceConstraints**: Array of bottlenecks identified

### Metadata
- **CachedResult**: Whether this was from cache (true) or freshly profiled (false)
- **Errors**: Array of errors encountered during profiling
- **Warnings**: Array of non-fatal warnings

## Calculation Logic

### SafeParallelJobs

Starting from CPU core count:
- 1-2 cores → 1 job
- 3-4 cores → 2 jobs
- 5-8 cores → 4 jobs
- 9+ cores → cores/2 (capped at 8)

Then adjusted down if:
- RAM < 2GB → -1 job
- RAM usage > 80% → -1 job
- Disk free < 10% → -1 job
- Disk read latency > 50ms → -1 job
- Remote + network latency > 100ms → force 1 job
- System load > 60% → -1 job

Minimum: always ≥ 1 job.

### JobTimeoutSec

Based on performance tier:
- **Low**: 120 seconds (2 min)
- **Medium**: 90 seconds (1.5 min)
- **High**: 60 seconds (1 min)
- **VeryHigh**: 45 seconds

### OverallTimeoutSec

Calculated as:
```
BaseTime = (EstimatedCollectorTime × CollectorCount) / SafeParallelJobs
Overall = BaseTime × 1.3 (30% buffer) + 60 (startup buffer)
```

Default estimate: 7 collectors × 20 seconds each = 140 base seconds.

Example: Medium tier (2 jobs)
```
BaseTime = (20 × 7) / 2 = 70 seconds
Overall = (70 × 1.3) + 60 = 151 seconds ≈ 2.5 minutes
```

## Cache Invalidation

Profiles are considered stale after **24 hours**. 

To force re-profiling:
```powershell
# Option 1: Delete cache file manually
Remove-Item "$env:TEMP\ServerAuditToolkit\Profiles\SERVER01-profile.json"

# Option 2: Use -UseCache:$false in Get-ServerCapabilities
$cap = Get-ServerCapabilities -ComputerName "SERVER01" -UseCache:$false
```

## Example Usage

```powershell
# Profile a server
$capabilities = Get-ServerCapabilities -ComputerName "SERVER01"

# Check parallelism budget
Write-Host "Safe parallel jobs: $($capabilities.SafeParallelJobs)"
Write-Host "Performance tier: $($capabilities.PerformanceTier)"

# Use in orchestrator
$maxJobs = $capabilities.SafeParallelJobs
$timeout = $capabilities.JobTimeoutSec

# If constraints exist, log them
if ($capabilities.ResourceConstraints.Count -gt 0) {
    Write-Warning "Resource constraints detected:"
    $capabilities.ResourceConstraints | ForEach-Object { Write-Warning "  - $_" }
}
```

## Troubleshooting

**Issue**: Profile shows 1 job but server seems capable

**Causes**:
- Server under high load (>60%)
- Low available RAM
- Slow disk (latency > 50ms)
- High network latency (remote audits)
- Insufficient disk free space

**Solution**: Check `$capabilities.ResourceConstraints` array.

---