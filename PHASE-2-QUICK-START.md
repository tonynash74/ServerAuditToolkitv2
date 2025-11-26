# PHASE 2: QUICK REFERENCE — ONE-PAGE GUIDE

**Branch**: `feature/phase-2-high-priority-improvements`  
**Status**: 🚀 ACTIVE  
**Effort**: 8-11 hours total  
**4 Tasks**: HIGH-001, HIGH-002, HIGH-003, HIGH-004  

---

## ✅ What's Already Done

Foundation functions committed (703 LOC):
- ✅ `src/Private/Invoke-WithRetry.ps1` — Retry logic with exponential backoff
- ✅ `src/Private/Get-AdjustedTimeout.ps1` — Adaptive timeouts (PS2/5/7)
- ✅ `src/Private/Test-AuditParameters.ps1` — Parameter validation
- ✅ `src/Private/Convert-AuditError.ps1` — Error categorization

**Commit**: `a25242c`

---

## 📋 Dev Team: Your Tasks

### TASK 1: Integrate Invoke-WithRetry (HIGH-001) — 2-3 hours
**What**: Wrap remote calls with `Invoke-WithRetry` for transient failure recovery

**Files to modify**:
- `Invoke-ServerAudit.ps1` (1 location)
- `src/Collectors/45-DNS.ps1` (1 location)
- `src/Collectors/100-RRAS.ps1` (1 location)
- `src/Collectors/Get-ServerInfo-PS5.ps1` (1 location)

**Pattern**:
```powershell
# OLD
$data = Get-Something -ComputerName $server

# NEW
$data = Invoke-WithRetry -Command {
    Get-Something -ComputerName $server
} -Description "Description" -MaxRetries 3
```

**Test**: Simulate network error, verify 3 retries with 2s → 4s → 8s backoff

---

### TASK 2: Integrate Get-AdjustedTimeout (HIGH-002) — 2 hours
**What**: Update config and orchestrator to use PS-version adaptive timeouts

**Files to modify**:
- `data/audit-config.json` (add timeout configs)
- `Invoke-ServerAudit.ps1` (load and apply)

**Config pattern**:
```json
{
  "collectorTimeouts": {
    "Get-ServerInfo": {
      "timeoutPs2": 20,
      "timeoutPs5": 10,
      "timeoutPs7": 8,
      "adaptive": true,
      "slowServerMultiplier": 1.5
    }
  }
}
```

**Usage pattern**:
```powershell
$timeout = Get-AdjustedTimeout `
    -CollectorName "Get-ServerInfo" `
    -PSVersion $PSVersionTable.PSVersion.Major `
    -TimeoutConfig $configMap `
    -IsSlowServer ($cpuUsage -gt 80)
```

**Test**: Run on PS2/5/7, verify PS5 is ~50% faster, PS7 ~60% faster

---

### TASK 3: Integrate Test-AuditParameters (HIGH-003) — 2 hours
**What**: Add parameter validation to orchestrator + collectors

**Entry point** (`Invoke-ServerAudit.ps1`):
```powershell
Test-AuditParameters `
    -ComputerName $ComputerName `
    -Credential $Credential `
    -CollectorMetadata $collectorMetadata
```

**In each collector** (add to parameter block):
```powershell
[ValidateNotNullOrEmpty()]
[string[]]$ComputerName,

[ValidateNotNull()]
[hashtable]$Capability
```

**Test**: Pass null, empty, invalid FQDN, verify clear error messages

---

### TASK 4: Integrate Convert-AuditError (HIGH-004) — 2-3 hours
**What**: Categorize errors in catch blocks across key collectors

**Pattern in each catch block**:
```powershell
catch {
    $error = Convert-AuditError -ErrorRecord $_ -Context "Operation Name"
    Write-Error "$($error.Category): $($error.Message)"
    Write-Information "Fix: $($error.Remediation)"
    Write-Debug $error.FullError
}
```

**Files to update**: 45-DNS.ps1, 100-RRAS.ps1, Get-ServerInfo-PS5.ps1, Get-IISInfo.ps1, 85-DataDiscovery.ps1

**Test**: Disable network, run audit, verify NetworkFailure categorized + remediation shown

---

## 🧪 Testing Each Task

### TASK 1 Testing
```powershell
# Simulate transient error
$result = Invoke-WithRetry -Command {
    if ([random]::new().Next(3) -eq 0) {
        throw [System.Net.Sockets.SocketException]"Network down"
    }
    return "Success"
} -MaxRetries 3

# Should succeed after 1-3 retries
```

### TASK 2 Testing
```powershell
$config = @{
    "Get-ServerInfo" = @{
        timeoutPs2 = 20; timeoutPs5 = 10; timeoutPs7 = 8; adaptive = $true; slowServerMultiplier = 1.5
    }
}

$t5 = Get-AdjustedTimeout -CollectorName "Get-ServerInfo" -PSVersion 5 -TimeoutConfig $config
$t2 = Get-AdjustedTimeout -CollectorName "Get-ServerInfo" -PSVersion 2 -TimeoutConfig $config

$t5  # Should be 10
$t2  # Should be 20
```

### TASK 3 Testing
```powershell
# Should fail
Test-AuditParameters -ComputerName $null

# Should fail
Test-AuditParameters -ComputerName ""

# Should succeed
Test-AuditParameters -ComputerName "SERVER01", "SERVER02"
```

### TASK 4 Testing
```powershell
try {
    throw [System.UnauthorizedAccessException]"Access Denied"
} catch {
    $err = Convert-AuditError -ErrorRecord $_
    $err.Category  # PermissionDenied
    $err.Remediation  # "Verify user is in Administrators group..."
}
```

---

## 📊 Progress Tracking

Track each task in git commits:

```powershell
git add ...
git commit -m "refactor(HIGH-001): Integrate Invoke-WithRetry in orchestrator

- Wrapped Get-ServerCapabilities in Invoke-WithRetry
- Added 3-retry with exponential backoff (2s, 4s, 8s)
- Verified against simulated network failures
- All remote calls now resilient to transient failures"
```

---

## 🚀 Merge Strategy

When all 4 tasks complete:

```powershell
# From feature/phase-2-high-priority-improvements
git add -A
git commit -m "refactor(HIGH-001-004): Complete Phase 2 integrations"
git push origin feature/phase-2-high-priority-improvements

# Then PR to main:
# Title: refactor(HIGH-001-004): Phase 2 HIGH-priority improvements
# Description:
#   Implements retry logic, adaptive timeouts, parameter validation, and error categorization
#   across orchestrator and all major collectors.
#   
#   High-001: Invoke-WithRetry for transient failure recovery
#   High-002: Adaptive timeout calculation (PS2/5/7 optimized)
#   High-003: Parameter validation at entry point
#   High-004: Error categorization with remediation guidance
#   
#   Backwards compatible. 100% test coverage on new functions.
#   +~200 LOC in orchestrator, +~50 LOC per collector
```

---

## 📞 Quick Links

- **Full Plan**: `PHASE-2-EXECUTION-PLAN.md`
- **Original Plan**: `HIGH-PRIORITY-FIXES-PLAN.md`
- **Foundation**: `src/Private/*.ps1` (4 utility functions)
- **Orchestrator**: `Invoke-ServerAudit.ps1`
- **Collectors**: `src/Collectors/*.ps1`

---

## ⏰ Timeline

| Day | Milestone |
|-----|-----------|
| **1** | TASK 1 + TASK 2 integrated |
| **2** | TASK 1 + 2 tested, TASK 3 started |
| **3** | TASK 3 integrated, TASK 4 started |
| **4** | TASK 4 complete, all tested |
| **5** | PR ready for code review, merge to main |

---

## 🎯 Success = Merge to Main

✅ All 4 tasks complete  
✅ All tests passing  
✅ Code review approved  
✅ No regressions in existing collectors  
✅ `v2.1` tag created  
✅ Users get better reliability + faster execution + clearer errors  

---

**Let's go!** 🚀

Questions? Ask in daily standup or check `PHASE-2-EXECUTION-PLAN.md` for details.

**Status**: Ready to integrate  
**Branch**: `feature/phase-2-high-priority-improvements`  
**Foundation**: a25242c (committed, 703 LOC, all 4 utilities)
