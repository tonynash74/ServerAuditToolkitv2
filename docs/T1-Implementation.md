# Task T1: PowerShell Version Detection & Tagging Framework

## Overview

T1 introduces a **metadata-driven collector system** that enables:
- Runtime detection of optimal collectors based on PowerShell and Windows versions
- Graceful fallback to lower PS versions if modern variants unavailable
- Dependency validation before collector execution
- Foundation for T2 (performance profiling) and T3 (optimized orchestration)

## Files Delivered

### 1. `collector-metadata.json`
Central registry of all collectors with:
- **Compatibility tags**: PS versions, Windows OS range, dependencies
- **Variants**: Different implementations for different PS versions
- **Performance metadata**: Timeout, estimated execution time, criticality

**Usage:**
```powershell
$metadata = Get-CollectorMetadata
$metadata.collectors | Select-Object name, psVersions, minWindowsVersion
```

### 2. `Get-CollectorMetadata.ps1`
Core metadata loader with helper functions:
- `Get-CollectorMetadata` — Load metadata from JSON
- `Get-CompatibleCollectors` — Filter by PS version
- `Get-CompatibleCollectorsByOS` — Filter by Windows version
- `Get-CollectorVariant` — Get best variant for environment
- `Test-CollectorDependencies` — Validate prerequisites
- `Get-WindowsVersionFromBuild` — Detect OS from build number
- `Get-CollectorSummary` — Show collector overview

**Usage:**
```powershell
# Load and filter
$metadata = Get-CollectorMetadata
$compatible = Get-CompatibleCollectors -Collectors $metadata.collectors -PSVersion '5.1'

# Get optimal variant
$collector = $compatible[0]
$variant = Get-CollectorVariant -Collector $collector -PSVersion '5.1'
# Returns: "Get-ServerInfo-PS5.ps1"

# Test dependencies
Test-CollectorDependencies -Collector $collector
```

### 3. `Collector-Template.ps1`
Template for creating new collectors with:
- Metadata tags embedded in comment block
- Standardized error handling
- Timeout management
- Result structure compliance

**Tags to customize:**
```powershell
# @CollectorName: Get-YourCollectorName
# @PSVersions: 2.0,4.0,5.1,7.0
# @MinWindowsVersion: 2008R2
# @MaxWindowsVersion:
# @Dependencies: ModuleName1,ModuleName2
# @Timeout: 30
# @Category: core|application|infrastructure
# @Critical: true|false
```

### 4. Updated `Invoke-ServerAudit.ps1`
Enhanced orchestrator that:
- Detects local PS version
- Loads and filters compatible collectors
- Validates dependencies before execution
- Runs collectors and aggregates results
- Supports dry-run mode

**Usage:**
```powershell
# Dry-run: show which collectors will execute
Invoke-ServerAudit -ComputerName "SERVER01" -DryRun

# Execute audit
$results = Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02"

# Run specific collectors only
$results = Invoke-ServerAudit -ComputerName "SERVER01" -Collectors @("Get-ServerInfo", "Get-Services")
```

## Creating a PS 5.1 Variant Collector

1. **Copy template:**
   ```powershell
   Copy-Item Collector-Template.ps1 Get-ServerInfo-PS5.ps1
   ```

2. **Update metadata tags:**
   ```powershell
   # @CollectorName: Get-ServerInfo-PS5
   # @PSVersions: 5.1,7.0
   # ... etc
   ```

3. **Use PS 5.1+ features:**
   - `Get-CimInstance` instead of `Get-WmiObject`
   - `@()` array syntax optimizations
   - `Where-Object -Parallel` (PS 7+)
   - Modern error handling (`$PSItem` vs `$_`)

4. **Register in metadata:**
   Update `collector-metadata.json`:
   ```json
   {
     "name": "Get-ServerInfo",
     "variants": {
       "2.0": "Get-ServerInfo.ps1",
       "4.0": "Get-ServerInfo.ps1",
       "5.1": "Get-ServerInfo-PS5.ps1",
       "7.0": "Get-ServerInfo-PS7.ps1"
     }
   }
   ```

## Compatibility Matrix (Post-T1)

| Collector | PS 2.0 | PS 4.0 | PS 5.1 | PS 7.x | Win2008R2 | Win2012R2 | Win2016+ |
|-----------|--------|--------|--------|--------|-----------|-----------|----------|
| Get-ServerInfo | ✅ Base | ✅ Base | ✅ PS5 | ✅ PS7 | ✅ | ✅ | ✅ |
| Get-ADInfo | ✅ | ✅ | ✅ PS5 | ❌ | ✅ | ✅ | ⚠️ (PS5 only) |
| Get-IISInfo | ✅ | ✅ | ✅ PS5 | ✅ PS7 | ⚠️ | ✅ | ✅ |
| Get-SQLServerInfo | ✅ | ✅ | ✅ PS5 | ❌ | ✅ | ✅ | ✅ |
| Get-HyperVInfo | ❌ | ✅ | ✅ PS5 | ✅ PS7 | ❌ | ✅ | ✅ |
| Get-Services | ✅ | ✅ | ✅ PS5 | ✅ PS7 | ✅ | ✅ | ✅ |
| Get-InstalledApps | ✅ | ✅ | ✅ PS5 | ✅ PS7 | ✅ | ✅ | ✅ |

## Testing T1

```powershell
# Test 1: Load metadata
$meta = Get-CollectorMetadata
Write-Host "Loaded $($meta.collectors.Count) collectors"

# Test 2: Filter by PS version
$compat = Get-CompatibleCollectors -Collectors $meta.collectors -PSVersion '2.0'
Write-Host "PS 2.0 compatible: $($compat.Count)"

# Test 3: Get variant
$col = $meta.collectors[0]
$var = Get-CollectorVariant -Collector $col -PSVersion '5.1'
Write-Host "PS 5.1 variant for $($col.name): $var"

# Test 4: Dry-run
Invoke-ServerAudit -DryRun

# Test 5: Execute on localhost
$results = Invoke-ServerAudit -ComputerName $env:COMPUTERNAME
$results.Servers[0].Collectors | Format-Table Name, Status, ExecutionTime
```

## Next Steps

- **T2**: Build `Get-ServerCapabilities.ps1` to detect CPU/RAM/disk and determine parallelism budget
- **T3**: Refactor `Invoke-ServerAudit.ps1` to use performance data for adaptive parallel execution
- **T4**: Create PS 5.1+ and PS 7.x optimized collectors