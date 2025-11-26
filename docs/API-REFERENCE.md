# ServerAuditToolkitV2 - API Reference & Developer Guide
**M-013: Code Documentation & API Docs**  
**Phase 3 Sprint 4 - Enhancement 3 of 4**

---

## 📚 Table of Contents
1. [Core Functions](#core-functions)
2. [M-001: Structured Logging](#m-001-structured-logging)
3. [M-003: Fallback Paths](#m-003-fallback-paths)
4. [M-004: Metadata Caching](#m-004-metadata-caching)
5. [M-005: Performance Profiling](#m-005-performance-profiling)
6. [M-007: Health Checks](#m-007-health-checks)
7. [M-008: Network Resilience](#m-008-network-resilience)
8. [M-009: Resource Monitoring](#m-009-resource-monitoring)
9. [M-010: Batch Processing](#m-010-batch-processing)
10. [M-011: Error Dashboard](#m-011-error-dashboard)

---

## Core Functions

### Invoke-ServerAudit
Main orchestrator function that drives the three-stage audit process.

```powershell
Invoke-ServerAudit `
    -ComputerName <string[]> `
    [-Collectors <string[]>] `
    [-DryRun] `
    [-MaxParallelJobs <int>] `
    [-SkipPerformanceProfile] `
    [-UseCollectorCache] `
    [-OutputPath <string>] `
    [-LogLevel <string>] `
    [-UseBatchProcessing] `
    [-BatchSize <int>] `
    [-PipelineDepth <int>]
```

**Parameters**:
- `ComputerName`: Target servers (required, pipeline support)
- `Collectors`: Specific collectors to run (optional, runs all if empty)
- `DryRun`: Show what will execute without running
- `MaxParallelJobs`: Override auto-detected parallelism (0=auto)
- `SkipPerformanceProfile`: Skip profiling, use conservative defaults
- `UseCollectorCache`: Load from cache if available
- `OutputPath`: Directory for results (default: ./audit_results)
- `LogLevel`: Verbosity level (Verbose, Information, Warning, Error)
- `UseBatchProcessing`: Enable batch mode for 50+ servers (M-010)
- `BatchSize`: Servers per batch (1-100, default 10)
- `PipelineDepth`: Concurrent batches (1-5, default 2)

**Returns**: `[PSObject]` Audit results with servers, summary, performance profiles

**Example**:
```powershell
$results = Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02"
$results.Summary | Format-Table
```

---

## M-001: Structured Logging

### Write-StructuredLog
Writes structured JSON-formatted log entries with automatic rotation.

```powershell
Write-StructuredLog `
    -Message <string> `
    [-Level <string>] `
    [-Properties <hashtable>] `
    [-ErrorDetails <string>] `
    [-SessionId <string>]
```

**Parameters**:
- `Message`: Log message text
- `Level`: Severity (Verbose, Information, Warning, Error) - default: Information
- `Properties`: Custom fields as hashtable
- `ErrorDetails`: Additional error context
- `SessionId`: Session identifier for correlation

**Example**:
```powershell
Write-StructuredLog -Message "Audit started" -Level Information `
    -Properties @{ ServerCount = 10; Duration = "2.5s" }
```

### Write-AuditLog
Legacy wrapper for structured logging with simplified syntax.

```powershell
Write-AuditLog -Message <string> [-Level <string>]
```

### Get-StructuredLogPath
Returns the current audit log file path.

```powershell
$logPath = Get-StructuredLogPath
```

### Invoke-LogRotation
Manually trigger log file rotation when size threshold is exceeded.

```powershell
Invoke-LogRotation [-MaxLogSizeBytes <int>]
```

**Parameters**:
- `MaxLogSizeBytes`: Rotation threshold (default: 10MB)

---

## M-003: Fallback Paths

### Invoke-CollectorWithFallback
Executes collector with automatic fallback chain (CIM → WMI → Partial).

```powershell
Invoke-CollectorWithFallback `
    -Server <string> `
    -CollectorName <string> `
    -CollectorScript <scriptblock> `
    [-TimeoutSeconds <int>]
```

**Parameters**:
- `Server`: Target server name
- `CollectorName`: Display name for logging
- `CollectorScript`: Scriptblock to execute
- `TimeoutSeconds`: Operation timeout (default: 60)

**Returns**: `[PSObject]` Result with Status (SUCCESS/PARTIAL/FAILED), Data, FallbackLevel

**Example**:
```powershell
$result = Invoke-CollectorWithFallback `
    -Server "SERVER01" `
    -CollectorName "Get-SystemInfo" `
    -CollectorScript { Get-CimInstance Win32_OperatingSystem }
```

---

## M-004: Metadata Caching

### Get-CollectorMetadata
Loads collector metadata with 5-minute TTL caching.

```powershell
Get-CollectorMetadata [-CacheOnly] [-SkipCache]
```

**Parameters**:
- `CacheOnly`: Return cached data only (no refresh)
- `SkipCache`: Force fresh load (bypass cache)

**Returns**: `[PSObject]` Metadata object with collectors array

**Example**:
```powershell
$metadata = Get-CollectorMetadata
$metadata.collectors | Where-Object { $_.psVersions -contains '7' }
```

### Clear-CollectorMetadataCache
Clears the in-memory metadata cache.

```powershell
Clear-CollectorMetadataCache
```

### Get-CollectorMetadataCacheStats
Returns cache statistics (hit rate, size, age).

```powershell
$stats = Get-CollectorMetadataCacheStats
$stats | Format-Table HitRate, CacheSize, AgeSeconds
```

---

## M-005: Performance Profiling

### New-PerformanceProfile
Generates performance profiling report with JSON and HTML outputs.

```powershell
New-PerformanceProfile `
    -AuditResults <object> `
    [-OutputPath <string>] `
    [-GenerateHTML]
```

**Parameters**:
- `AuditResults`: Output from Invoke-ServerAudit
- `OutputPath`: Directory for reports (default: ./audit_results)
- `GenerateHTML`: Generate interactive HTML report

**Returns**: `[PSObject]` Profile object with per-collector statistics

**Example**:
```powershell
$profile = New-PerformanceProfile -AuditResults $results -GenerateHTML
$profile.CollectorStats | Sort-Object ExecutionTime -Descending | Select-Object -First 5
```

---

## M-007: Health Checks

### Test-AuditPrerequisites
Pre-flight validation of server health (DNS, WinRM, network, credentials).

```powershell
Test-AuditPrerequisites `
    -ComputerName <string[]> `
    [-Port <int>] `
    [-Timeout <int>] `
    [-Parallel <bool>] `
    [-ThrottleLimit <int>]
```

**Parameters**:
- `ComputerName`: Servers to check
- `Port`: WinRM port to validate (default: 5985)
- `Timeout`: Check timeout seconds (default: 10)
- `Parallel`: Use parallel execution on PS7+ (default: true)
- `ThrottleLimit`: Max concurrent checks (default: 3)

**Returns**: `[PSObject]` Health report with summary, per-server health scores, issues, remediation suggestions

**Example**:
```powershell
$health = Test-AuditPrerequisites -ComputerName "SERVER01", "SERVER02"
if (-not $health.IsHealthy) {
    $health.Remediation | ForEach-Object { Write-Host "💡 $_" }
}
```

---

## M-008: Network Resilience

### Invoke-NetworkResilientConnection
Executes operation with DNS retry and WinRM session pooling.

```powershell
Invoke-NetworkResilientConnection `
    -Server <string> `
    -Operation <scriptblock> `
    [-DnsRetryAttempts <int>] `
    [-DnsRetryBackoff <string>] `
    [-SessionPoolTTL <int>]
```

**Parameters**:
- `Server`: Target server name
- `Operation`: Scriptblock to execute (receives PSSession)
- `DnsRetryAttempts`: DNS resolution retry count (default: 3)
- `DnsRetryBackoff`: Strategy - 'exponential' or 'linear' (default: exponential)
- `SessionPoolTTL`: Cache TTL in seconds (default: 600)

**Returns**: Operation result

**Example**:
```powershell
$result = Invoke-NetworkResilientConnection `
    -Server "SERVER01" `
    -Operation { param($session) Invoke-Command -Session $session { Get-Service } }
```

### Get-SessionPoolStatistics
Returns current session pool statistics.

```powershell
$stats = Get-SessionPoolStatistics
$stats | Format-Table ActiveSessions, CachedSessions, HitRate
```

### Clear-SessionPool
Clears the WinRM session pool cache.

```powershell
Clear-SessionPool
```

---

## M-009: Resource Monitoring

### Start-AuditResourceMonitoring
Begins background CPU/Memory monitoring with auto-throttling.

```powershell
Start-AuditResourceMonitoring `
    [-MaxParallelJobs <int>] `
    [-CpuThreshold <int>] `
    [-MemoryThreshold <int>] `
    [-MonitoringIntervalSeconds <int>]
```

**Parameters**:
- `MaxParallelJobs`: Maximum parallel jobs allowed (default: 3)
- `CpuThreshold`: CPU alert threshold % (default: 85)
- `MemoryThreshold`: Memory alert threshold % (default: 90)
- `MonitoringIntervalSeconds`: Check interval (default: 2)

**Returns**: `[PSObject]` Job object for monitoring

**Example**:
```powershell
$job = Start-AuditResourceMonitoring -MaxParallelJobs 4
```

### Get-AuditResourceStatus
Returns current resource status and throttling state.

```powershell
$status = Get-AuditResourceStatus
$status | Format-List CurrentCpuPercent, CurrentMemoryPercent, IsThrottled
```

### Stop-AuditResourceMonitoring
Stops resource monitoring and returns statistics.

```powershell
$stats = Stop-AuditResourceMonitoring
$stats | Format-Table TotalThrottleEvents, TotalRecoveryEvents, AverageCpuPercent
```

### Get-AuditResourceStatistics
Returns accumulated resource statistics.

```powershell
$stats = Get-AuditResourceStatistics
```

---

## M-010: Batch Processing

### Invoke-BatchAudit
Orchestrates batch processing for large server environments.

```powershell
Invoke-BatchAudit `
    -Servers <string[]> `
    -Collectors <object[]> `
    [-BatchSize <int>] `
    [-PipelineDepth <int>] `
    [-OutputPath <string>] `
    [-CheckpointInterval <int>] `
    [-ResultCallback <scriptblock>]
```

**Parameters**:
- `Servers`: Array of server names
- `Collectors`: Collector metadata objects
- `BatchSize`: Servers per batch (1-100, default: 10)
- `PipelineDepth`: Concurrent batches (1-5, default: 2)
- `OutputPath`: Batch results directory
- `CheckpointInterval`: Checkpoint every N batches (default: 5)
- `ResultCallback`: Optional scriptblock invoked per batch completion

**Returns**: `[PSObject]` Aggregated results with batch statistics

**Properties**:
- `TotalBatches`: Number of batches processed
- `TotalServers`: Total servers audited
- `SuccessfulBatches`: Completed batches
- `FailedBatches`: Failed batches
- `Duration`: Total execution time
- `AvgPerBatch`: Average time per batch
- `ThroughputServersPerMinute`: Processing rate
- `BatchResults`: Individual batch results

**Example**:
```powershell
$results = Invoke-BatchAudit `
    -Servers $servers `
    -Collectors $collectors `
    -BatchSize 20 `
    -PipelineDepth 3
Write-Host "Processed $($results.TotalServers) servers in $($results.Duration)s"
```

### Get-BatchCheckpoint
Retrieves checkpoint data for audit resumption.

```powershell
$checkpoint = Get-BatchCheckpoint `
    -BatchPath <string> `
    [-CheckpointNumber <int>]
```

### Get-BatchStatistics
Aggregates statistics from batch results.

```powershell
$stats = Get-BatchStatistics -BatchPath <string>
```

---

## M-011: Error Dashboard

### New-ErrorMetricsDashboard
Generates comprehensive error analysis dashboard.

```powershell
New-ErrorMetricsDashboard `
    -AuditResults <object> `
    [-OutputPath <string>] `
    [-GenerateHTML] `
    [-ExportJSON] `
    [-TrendingWindowDays <int>]
```

**Parameters**:
- `AuditResults`: Output from Invoke-ServerAudit
- `OutputPath`: Dashboard output directory (default: ./audit_results/dashboards)
- `GenerateHTML`: Create interactive HTML dashboard (default: true)
- `ExportJSON`: Export raw data to JSON (default: true)
- `TrendingWindowDays`: Historical window for trending (default: 30)

**Returns**: `[PSObject]` Dashboard object with analysis results

**Properties**:
- `TotalErrors`: Total error count
- `ErrorsByType`: Hashtable of error categories (Connectivity, DNS, Authentication, etc.)
- `ErrorsByCollector`: Per-collector error breakdown
- `ErrorsBySeverity`: Critical, High, Medium, Low counts
- `SuccessRate`: Overall success percentage
- `AffectedServers`: Array of servers with errors
- `Recommendations`: Prioritized action items
- `Files`: Generated report file paths

**Example**:
```powershell
$dashboard = New-ErrorMetricsDashboard -AuditResults $results
Write-Host "Success Rate: $($dashboard.SuccessRate)%"
$dashboard.Recommendations | ForEach-Object {
    Write-Host "[$($_.Severity)] $($_.Issue): $($_.Action)"
}
```

### Get-ErrorCategory
Categorizes error messages by type.

```powershell
$category = Get-ErrorCategory -ErrorMessage "Connection refused"
# Returns: "Connectivity"
```

**Categories** (9 types):
- Connectivity, DNS, Authentication, WinRM, Timeout, Memory, Collection, Validation, Parse, FileSystem, Other

### Get-ErrorSeverity
Classifies error severity level.

```powershell
$severity = Get-ErrorSeverity -ErrorMessage "Critical failure"
# Returns: "Critical"
```

**Levels** (4 tiers):
- Critical, High, Medium, Low

---

## Integration Examples

### Complete Audit with All Enhancements
```powershell
# Run audit with all optimizations
$results = Invoke-ServerAudit `
    -ComputerName (Get-Content servers.txt) `
    -UseBatchProcessing `
    -BatchSize 20 `
    -MaxParallelJobs 4 `
    -LogLevel Information

# Generate performance profile
$profile = New-PerformanceProfile -AuditResults $results -GenerateHTML

# Generate error dashboard
$dashboard = New-ErrorMetricsDashboard -AuditResults $results

# Display summary
Write-Host "Audited $($results.Summary.TotalServers) servers"
Write-Host "Success Rate: $($dashboard.SuccessRate)%"
Write-Host "Profile: $($profile.AverageFetchTimeSeconds)s avg"
```

### Large Environment with Checkpoint Recovery
```powershell
$servers = Get-Content large-environment.txt  # 500+ servers

$results = Invoke-ServerAudit `
    -ComputerName $servers `
    -UseBatchProcessing `
    -BatchSize 50 `
    -PipelineDepth 3 `
    -CheckpointInterval 10 `
    -OutputPath 'D:\audits\large_env'

# If interrupted, resume:
$checkpoint = Get-BatchCheckpoint -BatchPath 'D:\audits\large_env\batches'
if ($checkpoint) {
    $results = Invoke-BatchAudit `
        -Servers $checkpoint.RemainingServers `
        -Collectors $collectors
}
```

### Error Analysis Workflow
```powershell
# Run audit
$results = Invoke-ServerAudit -ComputerName $servers

# Analyze errors
$dashboard = New-ErrorMetricsDashboard -AuditResults $results

# Export dashboard
$dashboard.Files | ForEach-Object {
    if ($_ -match '.html') {
        Invoke-Item $_  # Open in browser
    }
}

# Process recommendations
$dashboard.Recommendations | Where-Object { $_.Severity -eq 'Critical' } | 
    ForEach-Object { Write-Host "⚠️  CRITICAL: $($_.Issue)" }
```

---

## Best Practices

### 1. Always Check Health First
```powershell
$health = Test-AuditPrerequisites -ComputerName $servers
if (-not $health.IsHealthy) {
    Write-Error "Health check failed: $($health.Issues -join '; ')"
    exit
}
```

### 2. Use Batch Processing for 50+ Servers
```powershell
if ($servers.Count -gt 50) {
    $results = Invoke-ServerAudit -ComputerName $servers -UseBatchProcessing
}
```

### 3. Monitor Resource Utilization
```powershell
$status = Get-AuditResourceStatus
if ($status.IsThrottled) {
    Write-Warning "Throttling active - consider reducing parallelism"
}
```

### 4. Always Generate Error Dashboard
```powershell
$dashboard = New-ErrorMetricsDashboard -AuditResults $results
if ($dashboard.TotalErrors -gt 0) {
    Write-Warning "$($dashboard.TotalErrors) errors detected"
    $dashboard.Recommendations | ForEach-Object { Write-Host "→ $($_.Action)" }
}
```

### 5. Archive Results with Metadata
```powershell
$archivePath = ".\audits\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
Copy-Item $results.OutputPath -Destination $archivePath -Recurse
```

---

## Troubleshooting

### High Error Rate
1. Check `Test-AuditPrerequisites` output for failed servers
2. Review `New-ErrorMetricsDashboard` recommendations
3. Check `Get-AuditResourceStatus` for throttling
4. Verify network connectivity with `Get-SessionPoolStatistics`

### Slow Performance
1. Check `New-PerformanceProfile` for slow collectors
2. Reduce `MaxParallelJobs` if resources constrained
3. Enable batch processing for 50+ servers
4. Check `Get-AuditResourceStatus` for CPU/Memory pressure

### Memory Issues
1. Enable `UseBatchProcessing` to stream results
2. Reduce `BatchSize` or `PipelineDepth`
3. Use checkpoints to process in stages
4. Monitor with `Get-AuditResourceStatistics`

---

**Documentation Last Updated**: November 26, 2025  
**API Version**: ServerAuditToolkitV2 v2.2.0  
**Status**: ✅ Production Ready
