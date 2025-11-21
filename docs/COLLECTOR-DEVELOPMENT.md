# Collector Development Guide - ServerAuditToolkitV2

## Overview

This guide explains how to develop robust collectors for ServerAuditToolkitV2. Collectors are PowerShell functions that execute on remote servers and return structured data for analysis, reporting, and migration planning.

## Collector Architecture

### Tier Classification

Collectors are organized by executive impact and data criticality:

| Tier | Purpose | Example | Execution Time | Timeout |
|------|---------|---------|-----------------|---------|
| **TIER 1** | Core server identity | Services, apps, roles | ~10-20s | 30-45s |
| **TIER 2** | Infrastructure scope | Shares, accounts, AD | ~15-30s | 60s |
| **TIER 3** | Applications | IIS, SQL, Exchange | ~30-45s | 90s |
| **TIER 4** | Data discovery | PII, financial, heat maps | ~120-180s | 300s |
| **TIER 5** | Compliance | Certs, tasks, audit logs | ~15-30s | 60s |

### Standard Collector Structure

Every collector must follow this template:

```powershell
#requires -Version 2.0

<#
.SYNOPSIS
    One-line description.

.DESCRIPTION
    Extended description with:
    - What data is collected
    - Why it matters for migration
    - Critical for: [use cases]

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER [OtherParams]
    Custom parameters.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     YYYY-MM-DD
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: [Name from metadata]
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies: [module1, module2]
    @Timeout: [seconds]
    @Category: [core|infrastructure|application|compliance]
    @Critical: [true|false]
    @Priority: [TIER1|TIER2|TIER3|TIER4|TIER5]
    @EstimatedExecutionTime: [seconds]
#>

function Get-[Name] {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        # Early exit for DRY-RUN
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would collect [description] from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-[Name]'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        # MAIN LOGIC HERE
        $data = @()

        # Graceful error handling - continue on failure
        try {
            # Primary method (WMI/CIM/PS cmdlets)
        }
        catch {
            try {
                # Fallback method
            }
            catch {
                # Graceful degradation - return partial data
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-[Name]'
            Data          = $data
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($data).Count
            Summary       = @{
                TotalRecords = @($data).Count
                # Additional summary metrics
            }
        }
    }
    catch {
        # Return error structure - orchestrator continues
        return @{
            Success       = $false
            CollectorName = 'Get-[Name]'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# CRITICAL: Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-[Name] @PSBoundParameters
}
```

## Return Value Structure

All collectors must return this hashtable:

```powershell
@{
    Success       = $true|$false           # Did collection succeed?
    CollectorName = 'Get-ServiceName'      # Unique identifier
    Data          = @()                    # Array of results (can be empty)
    ExecutionTime = [TimeSpan]             # How long execution took
    RecordCount   = [int]                  # Count of returned records
    Summary       = @{ ... }               # Optional: aggregate metrics
    Error         = "Error message"        # If Success=$false
    Status        = "Installed|Unavailable"# For optional components
}
```

## Key Principles

### 1. Graceful Degradation

**NEVER** halt the orchestrator on error. Always:
- Return `Success=$false` with error message
- Return partial data if possible
- Continue on WMI timeout or access denied

Example:
```powershell
try {
    # Primary method
    $result = Get-WmiObject -Class Win32_Service -ErrorAction Stop
}
catch {
    # Fallback
    try {
        $result = Get-CimInstance -ClassName Win32_Service
    }
    catch {
        # Still return structure, mark as failure
        return @{
            Success       = $false
            CollectorName = 'Get-Services'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}
```

### 2. Remote Execution Support

Collectors must support both local and remote execution:

```powershell
# Local execution (default)
Get-Services

# Remote execution with credential
Get-Services -ComputerName "SERVER01" -Credential $cred

# Pattern:
if ($ComputerName -eq $env:COMPUTERNAME) {
    # Local path
}
else {
    # Remote path with -ComputerName parameter
    $params = @{
        ComputerName = $ComputerName
        ErrorAction  = 'SilentlyContinue'
    }
    
    if ($Credential) {
        $params['Credential'] = $Credential
    }
    
    $result = Get-WmiObject -Class Win32_Service @params
}
```

### 3. Legacy OS Support (PowerShell 2.0)

All collectors must support Windows Server 2003+ with PowerShell 2.0:

```powershell
# DON'T USE: New syntax only available in PS 3+
Get-ChildItem -Path $path -Recurse

# DO USE: PS 2.0 compatible
Get-ChildItem -Path $path -Recurse

# DON'T USE: CIM (PS 3+ only)
Get-CimInstance -ClassName Win32_Service

# DO USE: WMI (PS 2.0+ available)
Get-WmiObject -Class Win32_Service

# DON'T USE: Array syntax (assume array results, not single)
if ($result) { ... }

# DO USE: Normalize to array
if ($result -isnot [array]) { $result = @($result) }
```

### 4. Structured Output

Always return data as array of hashtables, never strings:

```powershell
# DON'T DO THIS
$data = @(
    "Service1 - Running",
    "Service2 - Stopped"
)

# DO THIS
$data = @(
    @{
        ServiceName = "Service1"
        Status      = "Running"
        StartupType = "Automatic"
    },
    @{
        ServiceName = "Service2"
        Status      = "Stopped"
        StartupType = "Manual"
    }
)
```

### 5. Timeout Resilience

Collectors may timeout. Plan for it:

```powershell
# Use -TimeoutSeconds or early exit on large datasets
$files = Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue

# Sample large result sets to avoid timeout
$sampleSize = [Math]::Max(1, [int]($files.Count * 0.20))  # 20% sample
$filesToScan = $files | Get-Random -Count $sampleSize
```

### 6. Metadata Tags

Every collector header must include metadata for orchestrator discovery:

```powershell
<#
@CollectorName: Get-Services          # Unique name (use in -Collectors param)
@PSVersions: 2.0,4.0,5.1,7.0           # Supported PowerShell versions
@MinWindowsVersion: 2003               # Minimum Windows Server version
@MaxWindowsVersion:                    # (empty = no upper limit)
@Dependencies: RSAT-AD-PowerShell      # Required Windows features/modules
@Timeout: 30                           # Max execution time (seconds)
@Category: core|infrastructure|application|compliance
@Critical: true|false                  # Is this essential for migration?
@Priority: TIER1|TIER2|TIER3|TIER4|TIER5
@EstimatedExecutionTime: 10            # Typical execution (seconds)
#>
```

## Common Patterns

### Pattern: WMI with Fallback

```powershell
try {
    $params = @{
        Class       = 'Win32_LogicalDisk'
        Filter      = "DriveType=3"
        ErrorAction = 'Stop'
    }
    
    if ($ComputerName -ne $env:COMPUTERNAME) {
        $params['ComputerName'] = $ComputerName
        if ($Credential) { $params['Credential'] = $Credential }
    }
    
    $result = Get-WmiObject @params
}
catch {
    # Fallback to CIM (PS 3+)
    try {
        $cimParams = @{
            ClassName   = 'Win32_LogicalDisk'
            Filter      = "DriveType=3"
            ErrorAction = 'Stop'
        }
        
        if ($ComputerName -ne $env:COMPUTERNAME) {
            $cimParams['ComputerName'] = $ComputerName
            if ($Credential) { $cimParams['Credential'] = $Credential }
        }
        
        $result = Get-CimInstance @cimParams
    }
    catch {
        # Return error
        throw $_
    }
}
```

### Pattern: File System Scanning with Sampling

```powershell
# Get eligible files
$files = Get-ChildItem -Path $path -Recurse -Include *.txt, *.csv -ErrorAction SilentlyContinue

# Apply sampling to avoid timeout
$sampleSize = [Math]::Max(1, [int]($files.Count * ($SamplingPercentage / 100)))
$filesToScan = $files | Get-Random -Count $sampleSize

# Scan with early exit
foreach ($file in $filesToScan) {
    try {
        # Read first N lines only
        $content = Get-Content -Path $file.FullName -TotalCount 500 | Out-String
        
        # Process...
    }
    catch {
        # Continue on access denied
    }
}
```

### Pattern: Registry Access (Local + Remote)

```powershell
if ($ComputerName -eq $env:COMPUTERNAME) {
    # Local registry
    $key = Get-Item -Path 'HKLM:\Software\Microsoft\Windows' -ErrorAction SilentlyContinue
}
else {
    # Remote registry via WMI
    $reg = [WMI] "\\$ComputerName\root\cimv2:StdRegProv=@"
    $value = $reg.GetStringValue(2147483650, "Software\Microsoft\Windows", "Version")
}
```

## Testing Your Collector

### Unit Tests

```powershell
# Test local execution
& $collector -DryRun

# Test with actual data
& $collector -ComputerName localhost

# Test error handling
& $collector -ComputerName "InvalidServer"

# Verify return structure
$result = & $collector -ComputerName localhost
$result.Keys | Should -Contain 'Success'
$result.Keys | Should -Contain 'CollectorName'
$result.Keys | Should -Contain 'Data'
```

### Integration Tests

```powershell
# Test with orchestrator
Invoke-ServerAudit -ComputerName localhost -Collectors Get-Services

# Verify timeout handling
Invoke-ServerAudit -ComputerName localhost -Collectors Data-Discovery-PII -Timeout 5

# Verify partial success
Invoke-ServerAudit -ComputerName localhost -Collectors Get-IISInfo, Get-Services
# Even if IIS fails, Get-Services should continue
```

## Registering Your Collector

Add metadata entry to `collector-metadata.json`:

```json
{
  "name": "Get-MyCollector",
  "displayName": "My Collector Name",
  "description": "What this collector discovers",
  "filename": "Get-MyCollector.ps1",
  "category": "core|infrastructure|application|compliance",
  "psVersions": ["2.0", "4.0", "5.1", "7.0"],
  "minWindowsVersion": "2008R2",
  "maxWindowsVersion": null,
  "dependencies": [],
  "timeout": 30,
  "estimatedExecutionTime": 15,
  "criticalForMigration": true,
  "priority": "TIER1"
}
```

## Common Mistakes to Avoid

1. **❌ Assuming array results are single objects**
   ```powershell
   # Wrong
   if ($result) { $result.Property }
   
   # Right
   if ($result -isnot [array]) { $result = @($result) }
   foreach ($item in $result) { $item.Property }
   ```

2. **❌ Throwing exceptions (halts orchestrator)**
   ```powershell
   # Wrong
   throw "Error occurred"
   
   # Right
   return @{ Success = $false; Error = "Error occurred" }
   ```

3. **❌ Assuming modules are installed**
   ```powershell
   # Wrong
   Import-Module RSAT-AD-PowerShell
   
   # Right
   try {
       # Use cmdlet
   }
   catch [System.Management.Automation.CommandNotFoundException] {
       # Module not available - return gracefully
       return @{ Success = $true; Status = "Module not available" }
   }
   ```

4. **❌ Using PowerShell 3+ only syntax**
   ```powershell
   # Wrong - PS 3+ only
   Get-ChildItem -Path $path -Recurse | Where-Object { $_.Extension -eq '.txt' }
   
   # Right - PS 2.0+ compatible
   Get-ChildItem -Path $path -Recurse | Where-Object { $_.Extension -like '*.txt' }
   ```

5. **❌ Unbounded timeouts on recursive scans**
   ```powershell
   # Wrong - could timeout on large directory trees
   $files = Get-ChildItem -Path $path -Recurse
   
   # Right - sample large result sets
   $files = Get-ChildItem -Path $path -Recurse
   if ($files.Count -gt 10000) {
       $files = $files | Get-Random -Count 1000
   }
   ```

## Examples

See `/src/Collectors/` for production examples:

- **TIER 1**: Get-Services.ps1, Get-InstalledApps.ps1, Get-ServerRoles.ps1
- **TIER 2**: Get-ShareInfo.ps1, Get-LocalAccounts.ps1
- **TIER 3**: Get-IISInfo.ps1, Get-SQLServerInfo.ps1, Get-ExchangeInfo.ps1
- **TIER 4**: Data-Discovery-PII.ps1, Data-Discovery-FinancialUK.ps1, Data-Discovery-HeatMap.ps1
- **TIER 5**: Get-ScheduledTasks.ps1, Get-CertificateInfo.ps1

## Submitting New Collectors

1. Follow collector template above
2. Implement graceful error handling
3. Test with PowerShell 2.0 (legacy systems)
4. Test remote execution with -Credential
5. Add metadata to collector-metadata.json
6. Create PR with changes

See CONTRIBUTING.md for PR process.
