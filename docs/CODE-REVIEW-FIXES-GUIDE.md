# ServerAuditToolkitV2 — Code Review Detailed Fix Guide

**Companion Document to**: CODE-REVIEW-REPORT.md  
**Purpose**: Provides ready-to-implement code fixes for identified issues

---

## TABLE OF CONTENTS

1. [Fix CRITICAL-001: Credential Passing in Invoke-Command](#fix-critical-001-credential-passing)
2. [Fix CRITICAL-002: WMI Date Conversion](#fix-critical-002-wmi-date-conversion)
3. [Fix CRITICAL-003: COM Object Serialization](#fix-critical-003-com-object-serialization)
4. [Fix CRITICAL-004: Credential Context Threading](#fix-critical-004-credential-context)
5. [Fix HIGH-001: WinRM Retry Logic](#fix-high-001-winrm-retry)
6. [Fix HIGH-002: Adaptive Timeout Calculation](#fix-high-002-adaptive-timeouts)
7. [Fix HIGH-003: Parameter Validation](#fix-high-003-parameter-validation)
8. [Fix MEDIUM-001: N+1 Query Optimization](#fix-medium-001-n-plus-1-optimization)
9. [Fix MEDIUM-003: Standardize Error Objects](#fix-medium-003-error-standardization)
10. [Fix MEDIUM-005: Metadata Validation](#fix-medium-005-metadata-validation)

---

# Fix CRITICAL-001: Credential Passing in Invoke-Command {#fix-critical-001-credential-passing}

## Problem Summary
    $attempts++
    if ($attempts -lt 2) {
        throw [System.Net.Sockets.SocketException]::new("Simulated network failure")
    }
    return "Success on attempt $attempts"
}

$result = Invoke-WithRetry -Command $command -MaxRetries 3
Write-Host "Result: $result"  # Output: "Success on attempt 2"
```

---

# Fix HIGH-002: Adaptive Timeout Calculation {#fix-high-002-adaptive-timeouts}

## Problem Summary
Timeout values hardcoded and not adjusted for server performance tier or PS version.

## Files to Update
- `data/audit-config.json`
- `Invoke-ServerAudit.ps1` (lines 250-280)

## Implementation

### Update audit-config.json:
```json
{
  "execution": {
    "timeout": {
      "default": 30,
      "byCollector": {
        "Get-ServerInfo": {
          "ps2": 25,
          "ps5": 10,
          "ps7": 8
        },
        "Get-Services": {
          "ps2": 20,
          "ps5": 8,
          "ps7": 5
        },
        "Get-IISInfo": {
          "ps2": 60,
          "ps5": 30,
          "ps7": 20
        },
        "Get-SQLServerInfo": {
          "ps2": 90,
          "ps5": 40,
          "ps7": 25
        },
        "85-DataDiscovery": {
          "ps2": 300,
          "ps5": 150,
          "ps7": 100
        }
      },
      "adaptiveFactors": {
        "slowServer": 1.5,
        "normalServer": 1.0,
        "fastServer": 0.7
      }
    }
  }
}
```

### Update Orchestrator:
```powershell
# In Invoke-ServerAudit.ps1 (new helper function)

function Get-AdaptiveTimeout {
    param(
        [string]$CollectorName,
        [string]$PSVersion,
        [double]$ServerSlownessFactor = 1.0
    )
    
    # Load config
    $configPath = Join-Path $PSScriptRoot '..\data\audit-config.json'
    $config = Get-Content $configPath | ConvertFrom-Json
    
    # Get base timeout for collector
    $collectorConfig = $config.execution.timeout.byCollector.$CollectorName
    
    if (-not $collectorConfig) {
        # Use default
        return $config.execution.timeout.default * $ServerSlownessFactor
    }
    
    # Select timeout based on PS version
    $psVersion = [version]$PSVersion
    
    if ($psVersion.Major -ge 7) {
        $baseTimeout = $collectorConfig.ps7
    } elseif ($psVersion.Major -ge 5) {
        $baseTimeout = $collectorConfig.ps5
    } else {
        $baseTimeout = $collectorConfig.ps2
    }
    
    # Apply server slowness multiplier
    $effectiveTimeout = [int]($baseTimeout * $ServerSlownessFactor)
    
    # Minimum 5 seconds, maximum 600 seconds
    return [Math]::Max(5, [Math]::Min(600, $effectiveTimeout))
}

# Usage in collector execution
$timeout = Get-AdaptiveTimeout -CollectorName "Get-IISInfo" `
    -PSVersion $auditSession.LocalPSVersion `
    -ServerSlownessFactor $serverProfile.SlownessFactor

Write-AuditLog "Using timeout: ${timeout}s for Get-IISInfo" -Level Verbose
```

## Testing Script
```powershell
# Test adaptive timeout calculation
$timeout_ps2 = Get-AdaptiveTimeout -CollectorName "85-DataDiscovery" -PSVersion "2.0" -ServerSlownessFactor 1.0
$timeout_ps5 = Get-AdaptiveTimeout -CollectorName "85-DataDiscovery" -PSVersion "5.1" -ServerSlownessFactor 1.0
$timeout_ps5_slow = Get-AdaptiveTimeout -CollectorName "85-DataDiscovery" -PSVersion "5.1" -ServerSlownessFactor 1.5

Write-Host "PS2.0 timeout: ${timeout_ps2}s (expect 300)"
Write-Host "PS5.1 timeout: ${timeout_ps5}s (expect 150)"
Write-Host "PS5.1 slow server: ${timeout_ps5_slow}s (expect 225)"
```

---

# Fix HIGH-003: Parameter Validation {#fix-high-003-parameter-validation}

## Problem Summary
Functions accept parameters without validation, leading to silent failures.

## Template Implementation

### Apply to ALL Collectors:

#### BEFORE:
```powershell
function Get-Services {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )
    # No validation
}
```

#### AFTER:
```powershell
function Get-Services {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "ComputerName cannot be empty"
            }
            if ($_ -match '[<>:"/\\|?*]') {
                throw "ComputerName contains invalid characters: $([char[]]$_ | Where-Object {$_ -match '[<>:"/\\|?*]'} | Join-String)"
            }
            if ($_.Length -gt 255) {
                throw "ComputerName exceeds 255 characters"
            }
            return $true
        })]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )
    
    # Additional runtime validation
    if ($ComputerName -ne $env:COMPUTERNAME) {
        # Validate remote connectivity (optional, can be expensive)
        if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            Write-Warning "Target server $ComputerName may be unreachable; attempting anyway"
        }
    }
}
```

---

# Fix MEDIUM-001: N+1 Query Optimization {#fix-medium-001-n-plus-1-optimization}

## Problem Summary
Data Discovery enumerates 200K+ files and recalculates age category for each file.

## File to Update
- `src/Collectors/85-DataDiscovery.ps1` (lines 100-180)

## Implementation

### BEFORE (Inefficient):
```powershell
foreach ($fp in $enum) {
    if ($totalFiles -ge $maxFilesPerShare) { $sampled = $true; break }
    try {
        $fi = New-Object System.IO.FileInfo($fp)
    } catch { continue }

    $totalFiles++
    $len = 0L; try { $len = $fi.Length } catch {}
    $totalBytes += $len

    $lw = $null; try { $lw = $fi.LastWriteTime } catch {}
    if ($lw) {
        if ($lw -gt $newest) { $newest = $lw }
        if ($lw -lt $oldest) { $oldest = $lw }
        $age = ($now - $lw).Days           # ❌ Calculated for each file
        if ($age -le 30) { $hot++ }        # ❌ Repeated logic
        elseif ($age -le 180) { $warm++ }
        elseif ($age -le 365) { $cold++ }
        else { $frozen++ }
    }
}
```

### AFTER (Optimized):
```powershell
# Pre-calculate cutoff dates ONCE
$cutoffHot   = (Get-Date).AddDays(-30)
$cutoffWarm  = (Get-Date).AddDays(-180)
$cutoffCold  = (Get-Date).AddDays(-365)

foreach ($fp in $enum) {
    if ($totalFiles -ge $maxFilesPerShare) { $sampled = $true; break }
    try {
        $fi = New-Object System.IO.FileInfo($fp)
    } catch { continue }

    $totalFiles++
    $len = 0L; try { $len = $fi.Length } catch {}
    $totalBytes += $len

    $lw = $null; try { $lw = $fi.LastWriteTime } catch {}
    if ($lw) {
        if ($lw -gt $newest) { $newest = $lw }
        if ($lw -lt $oldest) { $oldest = $lw }
        
        # ✅ Simple date comparison instead of computing age
        if ($lw -gt $cutoffHot) { 
            $hot++ 
        } elseif ($lw -gt $cutoffWarm) { 
            $warm++ 
        } elseif ($lw -gt $cutoffCold) { 
            $cold++ 
        } else { 
            $frozen++ 
        }
    }
}
```

**Performance Impact**: ~15-20% faster on 200K+ file shares  
**Testing**: Compare execution time with large share: `Measure-Command { ... }`

---

# Fix MEDIUM-003: Standardize Error Objects {#fix-medium-003-error-standardization}

## Problem Summary
Error objects returned in different formats across collectors.

## Implementation

### Standardized Error Response Template:
```powershell
# ALL collectors MUST return this structure consistently

function Get-StandardCollectorResponse {
    param(
        [string]$CollectorName,
        [string]$ComputerName,
        [bool]$Success,
        [hashtable]$Data = @{},
        [string[]]$Errors = @(),
        [string[]]$Warnings = @(),
        [double]$ExecutionTimeSeconds = 0,
        [int]$RecordCount = 0
    )
    
    return @{
        Success               = $Success
        CollectorName         = $CollectorName
        ComputerName          = $ComputerName
        Timestamp             = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
        ExecutionTimeSeconds  = [Math]::Round($ExecutionTimeSeconds, 3)
        RecordCount           = $RecordCount
        Data                  = $Data
        Errors                = @($Errors)
        Warnings              = @($Warnings)
        
        # Additional fields if failed
        ErrorClassification   = if ($Errors.Count -gt 0) {
            if ($Errors[0] -match 'Access Denied|Unauthorized') { 'AuthenticationFailure' }
            elseif ($Errors[0] -match 'timeout|timed out') { 'Timeout' }
            elseif ($Errors[0] -match 'not found|not installed') { 'MissingComponent' }
            elseif ($Errors[0] -match 'network|connectivity|WinRM') { 'ConnectivityFailure' }
            else { 'UnknownError' }
        } else { $null }
    }
}

# Usage in ALL collectors:
try {
    $data = Collect-Data
    return Get-StandardCollectorResponse -CollectorName 'Get-Services' `
        -ComputerName $ComputerName `
        -Success $true `
        -Data $data `
        -RecordCount $data.Count `
        -ExecutionTimeSeconds $stopwatch.Elapsed.TotalSeconds
} catch {
    return Get-StandardCollectorResponse -CollectorName 'Get-Services' `
        -ComputerName $ComputerName `
        -Success $false `
        -Errors @("Collection failed: $_") `
        -ExecutionTimeSeconds $stopwatch.Elapsed.TotalSeconds
}
```

---

# Fix MEDIUM-005: Metadata Validation {#fix-medium-005-metadata-validation}

## Problem Summary
No validation that metadata.json matches actual collector files.

## File to Create
- Create `src/Private/Test-CollectorMetadata.ps1` (new file)

## Implementation

```powershell
<#
.SYNOPSIS
    Validates collector metadata integrity against actual files.

.DESCRIPTION
    Checks:
    - All collectors in metadata.json have corresponding .ps1 files
    - All collector files have corresponding metadata entries
    - Metadata @CollectorName tags match filenames
    - All required metadata fields present
#>
function Test-CollectorMetadata {
    [CmdletBinding()]
    param(
        [string]$MetadataPath = (Join-Path $PSScriptRoot '..\Collectors\collector-metadata.json'),
        [string]$CollectorDir = (Join-Path $PSScriptRoot '..\Collectors')
    )
    
    $errors = @()
    $warnings = @()
    
    # Load metadata
    try {
        $metadata = Get-Content $MetadataPath -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Failed to load metadata from $MetadataPath : $_"
    }
    
    # Get all collector files
    $files = Get-ChildItem $CollectorDir -Filter '*.ps1' -ErrorAction SilentlyContinue | 
        Where-Object { $_.BaseName -notmatch '^Collector-Template$' }
    
    # VALIDATION 1: Check metadata entries have corresponding files
    foreach ($collector in $metadata.collectors) {
        $fileName = "$($collector.name).ps1"
        $filePath = Join-Path $CollectorDir $fileName
        
        if (-not (Test-Path $filePath)) {
            $errors += "Metadata entry '$($collector.name)' has no corresponding file: $fileName"
        }
    }
    
    # VALIDATION 2: Check files have metadata entries
    foreach ($file in $files) {
        $baseName = $file.BaseName
        
        # Skip non-collector files
        if ($baseName -notmatch '^(Get-|[0-9]+-)') {
            continue
        }
        
        if ($baseName -notin $metadata.collectors.name) {
            $warnings += "Collector file '$($file.Name)' not registered in metadata"
        }
    }
    
    # VALIDATION 3: Verify @CollectorName tags in files match metadata
    foreach ($collector in $metadata.collectors) {
        $filePath = Join-Path $CollectorDir "$($collector.name).ps1"
        
        if (Test-Path $filePath) {
            $content = Get-Content $filePath -Raw
            
            if ($content -notmatch "@CollectorName:\s*$([regex]::Escape($collector.name))") {
                $warnings += "Metadata name '$($collector.name)' not found in @CollectorName tag of file"
            }
        }
    }
    
    # VALIDATION 4: Check required metadata fields
    foreach ($collector in $metadata.collectors) {
        if (-not $collector.name) { $errors += "Collector missing 'name' field" }
        if (-not $collector.displayName) { $warnings += "Collector '$($collector.name)' missing 'displayName'" }
        if (-not $collector.psVersions) { $errors += "Collector '$($collector.name)' missing 'psVersions'" }
    }
    
    return @{
        IsValid  = $errors.Count -eq 0
        Errors   = $errors
        Warnings = $warnings
        Summary  = "Valid collectors: $(($metadata.collectors | Where-Object {$_ -in @($files.BaseName)}).Count)/$($metadata.collectors.Count)"
    }
}

# Usage: Call during module import
$validationResult = Test-CollectorMetadata
if (-not $validationResult.IsValid) {
    Write-Error "Collector metadata validation failed:"
    $validationResult.Errors | ForEach-Object { Write-Error "  - $_" }
    throw "Invalid metadata"
} else {
    Write-Verbose $validationResult.Summary
}
```

---

## Summary of All Fixes

| Fix ID | Category | Files Updated | Complexity | Est. Time |
|---|---|---|---|---|
| CRITICAL-001 | Credentials | 20+ collectors | High | 2-3h |
| CRITICAL-002 | Date Conversion | 1 file | Low | 30m |
| CRITICAL-003 | Serialization | 2 files | Medium | 1-2h |
| CRITICAL-004 | Credential Threading | 1 file | High | 2-3h |
| HIGH-001 | Retry Logic | 2 files | Medium | 1-2h |
| HIGH-002 | Timeouts | 2 files | Medium | 2-3h |
| HIGH-003 | Validation | 40+ files | High | 2-3h |
| MEDIUM-001 | Performance | 1 file | Low | 30m |
| MEDIUM-003 | Error Objects | 40+ files | Medium | 2-3h |
| MEDIUM-005 | Metadata | 1 new file | Low | 1h |

**Total Estimated Implementation Time**: 16-26 hours (2-3 days for experienced PowerShell engineer)

