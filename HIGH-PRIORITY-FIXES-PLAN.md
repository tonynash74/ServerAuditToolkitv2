# HIGH PRIORITY FIXES IMPLEMENTATION PLAN

**Status**: READY TO START  
**Date**: November 26, 2025  
**Priority**: HIGH  

---

## Overview

This document outlines the implementation of HIGH-priority improvements identified in the code review. These are non-blocking but significantly impact reliability and user experience.

---

## HIGH-001: Missing Error Recovery for WinRM Connection Failures

### Issue
No retry logic for transient WinRM connection failures. Network hiccups cause entire audit to fail.

### Current State (Broken)
```powershell
try {
    $profile = Get-ServerCapabilities -ComputerName $server -UseCache:$true
} catch {
    Write-AuditLog "Profiling error: $_" -Level Warning
}
```

**Problem**: Single transient network error = complete audit failure

### Solution: Implement Invoke-WithRetry

**File to Create**: `src/Private/Invoke-WithRetry.ps1`

```powershell
<#
.SYNOPSIS
    Executes a command with exponential backoff retry on transient failures.

.DESCRIPTION
    Automatically retries PowerShell commands on transient network/remoting failures:
    - SocketException (network down)
    - PSRemotingTransportException (WinRM timeout/connection reset)
    
    Uses exponential backoff: 2s, 4s, 8s between retries.

.PARAMETER Command
    ScriptBlock to execute with retry logic.

.PARAMETER MaxRetries
    Maximum number of retry attempts. Default: 3

.PARAMETER InitialDelaySeconds
    Initial delay between retries (exponentially increasing). Default: 2

.PARAMETER Description
    Description of operation for logging.

.EXAMPLE
    Invoke-WithRetry -Command { Get-Process } -MaxRetries 3

.EXAMPLE
    Invoke-WithRetry -Command {
        Invoke-Command -ComputerName SERVER01 -ScriptBlock { Get-Service }
    } -Description "Remote service check"
#>

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Command,

        [Parameter(Mandatory=$false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory=$false)]
        [int]$InitialDelaySeconds = 2,

        [Parameter(Mandatory=$false)]
        [string]$Description = "Operation"
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($attempt -lt $MaxRetries) {
        try {
            $attempt++
            Write-Verbose "[$Description] Attempt $attempt of $MaxRetries"
            return & $Command
        }
        catch [System.Net.Sockets.SocketException],
              [System.Management.Automation.Remoting.PSRemotingTransportException] {
            if ($attempt -lt $MaxRetries) {
                Write-Warning "[$Description] Transient error (attempt $attempt): $_"
                Write-Verbose "[$Description] Retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
                $delay *= 2  # Exponential backoff
            } else {
                Write-Error "[$Description] Failed after $MaxRetries attempts: $_"
                throw
            }
        }
    }
}
```

### Integration Points

**File**: `Invoke-ServerAudit.ps1`

```powershell
# Before
try {
    $profile = Get-ServerCapabilities -ComputerName $server -UseCache:$true
} catch {
    Write-AuditLog "Profiling error: $_" -Level Warning
}

# After
try {
    $profile = Invoke-WithRetry -Command {
        Get-ServerCapabilities -ComputerName $server -UseCache:$true
    } -Description "Server capability detection" -MaxRetries 3
} catch {
    Write-AuditLog "Profiling error after retries: $_" -Level Warning
}
```

### Testing
- [ ] Simulate SocketException (network disconnect)
- [ ] Simulate PSRemotingTransportException (WinRM timeout)
- [ ] Verify retry count correct (1, 2, 3)
- [ ] Verify exponential backoff delay (2s, 4s, 8s)
- [ ] Verify eventually gives up after MaxRetries
- [ ] Verify logging shows all attempts

### Impact
- **Reliability**: Transient network errors no longer fail entire audit
- **User Experience**: Automatic recovery without user intervention
- **Diagnostics**: Clear logging of retry attempts

### Effort: 2-3 hours
### Files to Create: 1 (Invoke-WithRetry.ps1)
### Files to Modify: 3-5 (orchestrator + key collectors)

---

## HIGH-002: Missing Timeout Validation for Custom Collectors

### Issue
No validation that collector timeout values are realistic. Data discovery 300s timeout seems arbitrary on slow networks.

### Current State
```json
{
  "85-DataDiscovery": 300,    // 5 minutes — is this right?
  "Get-IISInfo": 60,          // 2 minutes
  "Get-SQLServerInfo": 90     // 1.5 minutes
}
```

**Problem**: 
- No validation these times are realistic
- No adaptive timeout for slow/overloaded servers
- PS5/PS7 variants not faster (should be 50-80% less)
- No per-collector timeout monitoring

### Solution: Adaptive Timeout Calculation

**File to Modify**: `data/audit-config.json`

```json
{
  "collectorTimeouts": {
    "00-System": {
      "timeoutPs2": 20,
      "timeoutPs5": 10,
      "timeoutPs7": 8,
      "adaptive": true,
      "slowServerMultiplier": 1.5,
      "description": "Base system info collection"
    },
    "85-DataDiscovery": {
      "timeoutPs2": 300,
      "timeoutPs5": 180,
      "timeoutPs7": 120,
      "adaptive": true,
      "slowServerMultiplier": 2.0,
      "description": "PII/Financial pattern scanning (high I/O)"
    },
    "Get-IISInfo": {
      "timeoutPs2": 60,
      "timeoutPs5": 40,
      "timeoutPs7": 30,
      "adaptive": false,
      "description": "IIS site enumeration"
    }
  }
}
```

**File to Create**: `src/Private/Get-AdjustedTimeout.ps1`

```powershell
function Get-AdjustedTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CollectorName,

        [Parameter(Mandatory=$false)]
        [string]$PSVersion = $PSVersionTable.PSVersion.Major,

        [Parameter(Mandatory=$false)]
        [hashtable]$TimeoutConfig,

        [Parameter(Mandatory=$false)]
        [switch]$IsSlowServer
    )

    # Get collector timeout config
    if (-not $TimeoutConfig.ContainsKey($CollectorName)) {
        # Default safe timeout
        return 120
    }

    $config = $TimeoutConfig[$CollectorName]
    
    # Select PS-specific timeout
    $psKey = "timeoutPs$PSVersion"
    if (-not $config.ContainsKey($psKey)) {
        # Fallback to PS2 baseline
        $timeout = $config.timeoutPs2
    } else {
        $timeout = $config[$psKey]
    }

    # Apply adaptive multiplier if enabled
    if ($config.adaptive -and $IsSlowServer) {
        $multiplier = $config.slowServerMultiplier ?? 1.5
        $timeout = [math]::Round($timeout * $multiplier)
        Write-Verbose "Adjusted timeout for slow server: $timeout (multiplier: $multiplier)"
    }

    return $timeout
}
```

### Integration Points

**File**: `Invoke-ServerAudit.ps1`

```powershell
# Before
$timeout = $collectorMetadata.Timeout

# After
$timeout = Get-AdjustedTimeout `
    -CollectorName $collector.Name `
    -PSVersion $PSVersionTable.PSVersion.Major `
    -TimeoutConfig $timeoutConfig `
    -IsSlowServer ($serverProfile.CPUUsage -gt 80 -or $serverProfile.MemoryUsage -gt 85)
```

### Testing
- [ ] Verify PS5 timeouts are ~50% of PS2
- [ ] Verify PS7 timeouts are ~60% of PS5
- [ ] Verify slow server multiplier applied
- [ ] Verify fallback to defaults
- [ ] Verify JSON config loads correctly

### Impact
- **Reliability**: Timeouts match actual performance
- **Performance**: PS5+ variants benefit from faster timeout
- **Adaptability**: Slow servers get appropriate slack

### Effort: 2 hours
### Files to Create: 1 (Get-AdjustedTimeout.ps1)
### Files to Modify: 2 (audit-config.json, orchestrator)

---

## HIGH-003: Parameter Validation Missing in Core Functions

### Issue
Core functions don't validate input parameters. Wrong ComputerName types, null credentials silently fail.

### Current State (Broken)
```powershell
function Get-SATRRAS {
  param([string[]]$ComputerName, [hashtable]$Capability)
  
  # No validation!
  # $ComputerName could be null, empty, invalid FQDN
  # $Capability could be missing required keys
}
```

**Problem**:
- Empty ComputerName array causes silent no-op
- Null Capability hashtable causes null reference errors
- Invalid FQDN not caught until Invoke-Command fails (late error)
- No clear error messages for troubleshooting

### Solution: Add Validation

**File to Create**: `src/Private/Test-AuditParameters.ps1`

```powershell
function Test-AuditParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [hashtable]$Capability,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [hashtable]$CollectorMetadata
    )

    # Validate ComputerNames
    foreach ($computer in $ComputerName) {
        if ([string]::IsNullOrWhiteSpace($computer)) {
            throw "Invalid ComputerName: empty or whitespace"
        }
        
        # Basic FQDN validation
        if ($computer -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-\.]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})*$') {
            if ($computer -ne 'localhost' -and $computer -ne '.' -and $computer -ne $env:COMPUTERNAME) {
                Write-Warning "ComputerName '$computer' may be invalid FQDN"
            }
        }
    }

    # Validate Capability hashtable required keys
    $requiredCapabilities = @('HasDnsModule', 'HasIIS', 'HasSQL', 'IsRemote')
    foreach ($key in $requiredCapabilities) {
        if (-not $Capability.ContainsKey($key)) {
            throw "Capability missing required key: $key"
        }
    }

    # Validate Credential if provided
    if ($null -ne $Credential) {
        if ($Credential.Username -eq $null) {
            throw "Credential object invalid: UserName is null"
        }
    }

    # Validate CollectorMetadata if provided
    if ($null -ne $CollectorMetadata) {
        foreach ($collectorName in $CollectorMetadata.Keys) {
            $meta = $CollectorMetadata[$collectorName]
            if ($meta -isnot [hashtable]) {
                throw "CollectorMetadata value must be hashtable for '$collectorName'"
            }
        }
    }

    return $true
}
```

### Integration

**File**: Every collector function

```powershell
# Before
function Get-SATRRAS {
  param([string[]]$ComputerName, [hashtable]$Capability)
  # No validation

# After
function Get-SATRRAS {
  param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNull()]
    [hashtable]$Capability,
    
    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential
  )
  
  # Pre-validate all inputs
  Test-AuditParameters -ComputerName $ComputerName -Capability $Capability -Credential $Credential
```

### Testing
- [ ] Null ComputerName rejected
- [ ] Empty ComputerName rejected
- [ ] Invalid FQDN logged as warning
- [ ] Missing Capability keys detected
- [ ] Null Credential handled gracefully
- [ ] Clear error messages provided

### Impact
- **Reliability**: Invalid inputs caught early
- **Debuggability**: Clear error messages
- **User Experience**: Fails fast with actionable guidance

### Effort: 2 hours
### Files to Create: 1 (Test-AuditParameters.ps1)
### Files to Modify: 10-15 (all main collectors)

---

## HIGH-004: Inadequate Error Logging for Cross-Domain Scenarios

### Issue
Error messages don't distinguish between authentication failure, network failure, and permission issues.

### Current State (Broken)
```powershell
} catch {
    Write-Log Error ("Collector failed on {0}: {1}" -f $c, $_.Exception.Message)
}
```

**Problem**:
- Generic error logging doesn't help troubleshooting
- No distinction between "auth failed" vs "network down" vs "no perms"
- User doesn't know next steps

### Solution: Categorize Errors

**File to Modify**: `src/Private/Convert-AuditError.ps1`

```powershell
function Convert-AuditError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory=$false)]
        [string]$Context = "Audit"
    )

    $category = 'Unknown'
    $remediation = 'Check system logs'

    # Categorize exception types
    switch ($ErrorRecord.Exception) {
        { $_ -is [System.UnauthorizedAccessException] } {
            $category = 'AuthenticationFailure'
            $remediation = 'Verify user is in Administrators group on target server'
        }
        { $_ -is [System.Net.Sockets.SocketException] } {
            $category = 'NetworkFailure'
            $remediation = 'Check network connectivity to target server'
        }
        { $_ -is [System.Management.Automation.Remoting.PSRemotingTransportException] } {
            $category = 'RemotingFailure'
            $remediation = 'Enable WinRM on target: Enable-PSRemoting -Force'
        }
        { $_ -is [System.IO.FileNotFoundException] } {
            $category = 'FileMissing'
            $remediation = 'Check file path and permissions'
        }
        { $_.Message -match 'Access Denied' } {
            $category = 'PermissionDenied'
            $remediation = 'Verify user has read permissions to required resources'
        }
        default {
            $category = 'UnknownError'
            $remediation = $ErrorRecord.Exception.Message
        }
    }

    return @{
        Category = $category
        Message = $ErrorRecord.Exception.Message
        FullError = $ErrorRecord | Out-String
        Remediation = $remediation
        Context = $Context
    }
}
```

### Integration

**File**: Core collectors

```powershell
# Before
} catch {
    Write-Log Error ("Failed: $_")
}

# After
} catch {
    $error = Convert-AuditError -ErrorRecord $_ -Context "DNS Collection"
    Write-Log Error ("DNS collector failed: $($error.Category) — $($error.Message)")
    Write-Log Info ("Remediation: $($error.Remediation)")
}
```

### Testing
- [ ] UnauthorizedAccessException properly categorized
- [ ] SocketException properly categorized
- [ ] PSRemotingTransportException properly categorized
- [ ] Unknown errors fall back gracefully
- [ ] Remediation messages clear and actionable

### Impact
- **Debuggability**: Clear error categorization
- **User Experience**: Actionable remediation steps
- **Support**: Reduced support tickets from unclear errors

### Effort: 2-3 hours
### Files to Create: 1 (Convert-AuditError.ps1)
### Files to Modify: 5-10 (main collectors)

---

## Implementation Roadmap

### Week 1: Foundation
- [ ] HIGH-001: Implement Invoke-WithRetry
- [ ] Unit tests for retry logic
- [ ] Integration with 3 key collectors

### Week 2: Robustness
- [ ] HIGH-002: Adaptive timeout calculation
- [ ] HIGH-003: Parameter validation
- [ ] Test on diverse server types

### Week 3: Polish
- [ ] HIGH-004: Error categorization
- [ ] Documentation updates
- [ ] Integration testing across full suite

---

## PR Strategy

### PR-002: HIGH Improvements Phase 1 (Retry + Timeout)
```
Title: refactor(HIGH-001-002): Add retry logic and adaptive timeouts

Files: 
- src/Private/Invoke-WithRetry.ps1 (new)
- src/Private/Get-AdjustedTimeout.ps1 (new)
- data/audit-config.json (modified)
- Invoke-ServerAudit.ps1 (modified)

Commits:
- feat(HIGH-001): Add Invoke-WithRetry for transient failure recovery
- feat(HIGH-002): Implement adaptive timeout calculation per PS version
- refactor: Integrate retry and timeout logic into orchestrator
```

### PR-003: HIGH Improvements Phase 2 (Validation + Error Handling)
```
Title: refactor(HIGH-003-004): Add parameter validation and error categorization

Files:
- src/Private/Test-AuditParameters.ps1 (new)
- src/Private/Convert-AuditError.ps1 (new)
- src/Collectors/*.ps1 (modified - 10+)

Commits:
- feat(HIGH-003): Add comprehensive parameter validation
- feat(HIGH-004): Implement error categorization with remediation
- refactor: Apply validation pattern across all collectors
```

---

## Effort Estimation

| Task | Files Created | Files Modified | Effort | Risk |
|------|----------------|-----------------|---------|------|
| HIGH-001 | 1 | 3 | 2-3h | LOW |
| HIGH-002 | 1 | 2 | 2h | LOW |
| HIGH-003 | 1 | 10-15 | 2h | LOW |
| HIGH-004 | 1 | 5-10 | 2-3h | LOW |
| **Total** | **4** | **20-35** | **8-11h** | **LOW** |

---

## Success Criteria

- [x] All HIGH priority improvements implemented
- [ ] Unit tests passing (80%+ coverage)
- [ ] Integration tests passing
- [ ] No regressions in existing collectors
- [ ] Error messages clear and actionable
- [ ] Timeout adjustments effective (measured in production)
- [ ] Retry logic prevents transient failures
- [ ] Documentation updated with new patterns

---

**Status**: READY TO IMPLEMENT  
**Priority**: HIGH  
**Target**: v2.1 Release  
**Owner**: Development Team  
**Last Updated**: November 26, 2025
