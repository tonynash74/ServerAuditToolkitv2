# PHASE 2: HIGH PRIORITY IMPROVEMENTS — EXECUTION PLAN

**Status**: ACTIVE 🚀  
**Branch**: `feature/phase-2-high-priority-improvements`  
**Foundation Commit**: a25242c (Phase 2 utility functions)  
**Target Delivery**: v2.1 Release (2 weeks)  
**Total Effort**: 8-11 hours  

---

## 📊 Overview

Phase 2 implements **4 HIGH-priority improvements** from the code review. These enhance reliability, error handling, and performance optimization without breaking changes.

### What's Ready to Go

✅ **Foundation functions committed** (4 utilities, 703 LOC):
- `Invoke-WithRetry.ps1` — Exponential backoff retry logic
- `Get-AdjustedTimeout.ps1` — Adaptive timeout calculation
- `Test-AuditParameters.ps1` — Parameter validation
- `Convert-AuditError.ps1` — Error categorization

Now the dev team integrates these into the orchestrator and collectors.

---

## 🎯 Task Breakdown

### TASK 1: HIGH-001 Integration (Invoke-WithRetry) — **2-3 hours**

**Objective**: Wrap key remote execution points with retry logic

**Files to Modify**:
1. `Invoke-ServerAudit.ps1` — Server capability profiling
2. `src/Collectors/Get-ServerInfo-PS5.ps1` — Remote data collection
3. `src/Collectors/45-DNS.ps1` — Remote DNS collection
4. `src/Collectors/100-RRAS.ps1` — Remote RRAS collection

**Integration Pattern**:

```powershell
# OLD (single attempt, fails on transient error)
try {
    $profile = Get-ServerCapabilities -ComputerName $server -UseCache:$true
} catch {
    Write-Warning "Error: $_"
}

# NEW (retry 3x with exponential backoff)
try {
    $profile = Invoke-WithRetry -Command {
        Get-ServerCapabilities -ComputerName $server -UseCache:$true
    } -Description "Server capability detection" -MaxRetries 3
} catch {
    Write-Error "Failed after retries: $_"
}
```

**Testing Checklist**:
- [ ] Simulate transient network error → verify retry attempts
- [ ] Verify exponential backoff timing (2s → 4s → 8s)
- [ ] Verify permanent errors fail immediately (no retry)
- [ ] Verify log output shows all attempts
- [ ] Run orchestrator with 3 remote servers successfully

**Success Criteria**:
- Transient network errors no longer fail entire audit
- Retry delays logged and visible
- Permanent errors fail fast
- All remote calls consistently apply retry pattern

---

### TASK 2: HIGH-002 Integration (Adaptive Timeout) — **2 hours**

**Objective**: Update timeout configuration and orchestrator to use adaptive calculations

**Files to Modify**:
1. `data/audit-config.json` — Add PS-version and adaptive timeout configs
2. `Invoke-ServerAudit.ps1` — Load and apply timeouts
3. `src/Private/Invoke-ParallelCollectors.ps1` — Pass timeouts to executor

**Configuration Updates**:

```json
{
  "collectorTimeouts": {
    "00-System": {
      "timeoutPs2": 20,
      "timeoutPs5": 10,
      "timeoutPs7": 8,
      "adaptive": true,
      "slowServerMultiplier": 1.5
    },
    "85-DataDiscovery": {
      "timeoutPs2": 300,
      "timeoutPs5": 180,
      "timeoutPs7": 120,
      "adaptive": true,
      "slowServerMultiplier": 2.0
    },
    "Get-IISInfo": {
      "timeoutPs2": 60,
      "timeoutPs5": 40,
      "timeoutPs7": 30,
      "adaptive": false
    }
  }
}
```

**Integration in Orchestrator**:

```powershell
# Load config
$config = Get-Content "data/audit-config.json" | ConvertFrom-Json
$timeoutMap = ConvertToHashtable $config.collectorTimeouts

# For each collector:
$timeout = Get-AdjustedTimeout `
    -CollectorName $collector.Name `
    -PSVersion $PSVersionTable.PSVersion.Major `
    -TimeoutConfig $timeoutMap `
    -IsSlowServer ($serverProfile.CPUUsage -gt 80)
```

**Testing Checklist**:
- [ ] Verify PS2 timeouts are baseline (no change)
- [ ] Verify PS5 timeouts are ~50% of PS2
- [ ] Verify PS7 timeouts are ~60% of PS5
- [ ] Simulate slow server (CPU 85%) → verify multiplier applied
- [ ] Verify fallback to defaults for unknown collectors
- [ ] Run audit on mixed server types (PS2, PS5, PS7)

**Success Criteria**:
- PS5/PS7 variants complete 2-3x faster due to aggressive timeouts
- Slow servers don't timeout due to adaptive multiplier
- Configuration is extensible (easy to add new collectors)

---

### TASK 3: HIGH-003 Integration (Parameter Validation) — **2 hours**

**Objective**: Add parameter validation to orchestrator and key collectors

**Files to Modify**:
1. `Invoke-ServerAudit.ps1` — Validate user inputs at entry point
2. `src/Collectors/*.ps1` (10-15 files) — Add validation to collector functions

**Integration in Orchestrator**:

```powershell
# Validate all inputs immediately
try {
    Test-AuditParameters `
        -ComputerName $ComputerName `
        -Capability $capabilityTemplate `
        -Credential $Credential `
        -CollectorMetadata $collectorMetadata
} catch {
    Write-Error "Invalid parameters: $_"
    exit 1
}
```

**Pattern in Each Collector**:

```powershell
function Get-SATRRAS {
    [CmdletBinding()]
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

    # Validate all inputs
    Test-AuditParameters `
        -ComputerName $ComputerName `
        -Capability $Capability `
        -Credential $Credential
    
    # ... rest of collector logic
}
```

**Testing Checklist**:
- [ ] Null ComputerName rejected with clear error
- [ ] Empty array rejected
- [ ] Invalid FQDN triggers warning (but proceeds)
- [ ] Missing Capability keys detected
- [ ] Null Credential handled gracefully
- [ ] Clear error messages guide users
- [ ] Run audit with various invalid inputs → correct error messages

**Success Criteria**:
- Invalid inputs caught at entry point (fail fast)
- Error messages clear and actionable
- No null reference errors deep in execution
- All collectors validate consistently

---

### TASK 4: HIGH-004 Integration (Error Categorization) — **2-3 hours**

**Objective**: Apply error categorization across all collectors

**Files to Modify**:
1. `src/Collectors/*.ps1` (5-10 key collectors) — Wrap catch blocks with error conversion

**Integration Pattern**:

```powershell
# OLD (generic error)
try {
    $data = Get-WmiObject -ComputerName $computer -Class Win32_Service
} catch {
    Write-Log Error "Service collection failed: $_"
}

# NEW (categorized with remediation)
try {
    $data = Invoke-WithRetry -Command {
        Get-WmiObject -ComputerName $computer -Class Win32_Service
    } -Description "Service inventory collection"
} catch {
    $error = Convert-AuditError -ErrorRecord $_ -Context "Service Inventory"
    Write-Log Error "$($error.Category): $($error.Message)"
    Write-Log Info "Remediation: $($error.Remediation)"
}
```

**Key Collectors to Update**:
- `45-DNS.ps1` — Network errors
- `100-RRAS.ps1` — Remote execution errors
- `Get-ServerInfo-PS5.ps1` — Generic WMI errors
- `Get-IISInfo.ps1` — COM object errors
- `85-DataDiscovery.ps1` — File access errors

**Testing Checklist**:
- [ ] Simulate each error type (network, auth, file, timeout)
- [ ] Verify error categorized correctly
- [ ] Verify remediation message is actionable
- [ ] Run audit on problematic server → verify helpful error output
- [ ] Check audit logs for consistent error formatting
- [ ] Verify no stack traces exposed to users

**Success Criteria**:
- Error messages are categorized correctly
- Remediation steps guide users to fix
- Admin logs contain full error details
- User-facing output is clear and actionable

---

## 📅 Implementation Timeline

### Week 1 (Days 1-5)
| Day | Task | Effort | Status |
|-----|------|--------|--------|
| 1 | TASK 1: HIGH-001 integration (orchestrator) | 2h | ⏳ |
| 1 | TASK 1: HIGH-001 integration (3 collectors) | 1h | ⏳ |
| 2 | TASK 1: Testing & validation | 1h | ⏳ |
| 2 | TASK 2: audit-config.json updates | 1h | ⏳ |
| 3 | TASK 2: Orchestrator integration | 1h | ⏳ |
| 3 | TASK 3: Parameter validation setup | 1h | ⏳ |
| 4 | TASK 3: Apply to 10-15 collectors | 1.5h | ⏳ |
| 4 | TASK 3: Testing & validation | 0.5h | ⏳ |
| 5 | TASK 4: Error categorization (5-10 collectors) | 2h | ⏳ |
| 5 | Integration testing (cross-collector) | 1h | ⏳ |

**Week 1 Total**: ~12 hours → Prioritize TASK 1 & 2 for MVP

### Week 2 (Optional - Final Polish)
- Full error categorization (all collectors)
- Integration testing with real environments
- Performance benchmarking
- Documentation updates

---

## 🧪 Testing Strategy

### Unit Testing

**For Invoke-WithRetry**:
```powershell
Describe "Invoke-WithRetry" {
    It "succeeds on first attempt" { ... }
    It "retries on SocketException" { ... }
    It "retries on PSRemotingTransportException" { ... }
    It "fails immediately on permanent errors" { ... }
    It "applies exponential backoff" { ... }
}
```

**For Get-AdjustedTimeout**:
```powershell
Describe "Get-AdjustedTimeout" {
    It "uses PS5 timeout correctly" { ... }
    It "applies slow server multiplier" { ... }
    It "falls back to PS2 baseline" { ... }
}
```

**For Test-AuditParameters**:
```powershell
Describe "Test-AuditParameters" {
    It "rejects null ComputerName" { ... }
    It "validates FQDN format" { ... }
    It "validates Capability hashtable" { ... }
}
```

**For Convert-AuditError**:
```powershell
Describe "Convert-AuditError" {
    It "categorizes AuthenticationFailure" { ... }
    It "categorizes NetworkFailure" { ... }
    It "provides remediation" { ... }
}
```

### Integration Testing

```powershell
# Test 1: Remote audit with transient failures
$servers = @("SERVER01", "SERVER02", "SERVER03")
.\Invoke-ServerAudit.ps1 -ComputerName $servers -DryRun

# Test 2: Timeouts on slow server
# Simulate CPU 85% → verify adaptive timeout applied

# Test 3: Invalid parameters
.\Invoke-ServerAudit.ps1 -ComputerName $null  # Should fail with clear error

# Test 4: Error categorization
# Disable network → run audit → verify categorized as NetworkFailure
```

---

## 📝 Code Review Checklist

Before committing each TASK:

- [ ] Code follows existing patterns in codebase
- [ ] Functions have proper help documentation
- [ ] Parameters have validation attributes
- [ ] Error handling is comprehensive
- [ ] Logging is consistent (Verbose, Warning, Error)
- [ ] No backwards-incompatible changes
- [ ] Functions are testable (no hard-coded paths)
- [ ] All tests pass
- [ ] No security issues (credentials not logged, etc.)

---

## 🚀 Deployment & Release

### Before Merge to Main

1. All tasks complete and tested
2. PR created with detailed description
3. Code review approved
4. Integration tests passing
5. Documentation updated

### Release as v2.1

```powershell
git checkout main
git pull origin main
git merge feature/phase-2-high-priority-improvements
git tag v2.1
git push origin main && git push origin v2.1
```

### Changelog Entry

```markdown
## v2.1 (HIGH Improvements) — [Date]

### New Features
- **Resilience**: Automatic retry with exponential backoff for transient failures
- **Performance**: Adaptive timeouts optimized per PowerShell version
- **Reliability**: Comprehensive error categorization with actionable remediation

### Improvements
- Remote execution now retries on network/WinRM timeouts
- PS5/PS7 variants complete 2-3x faster with optimized timeouts
- Error messages guide users to fix (not just "failed")
- Parameter validation prevents early failures with clear guidance

### Technical Details
- Implements Invoke-WithRetry for SocketException and PSRemotingTransportException
- Get-AdjustedTimeout adapts per PS version (PS2 baseline → PS5 -50% → PS7 -60%)
- Test-AuditParameters validates FQDN, Capability structure, Credentials
- Convert-AuditError categorizes 8+ error types with remediation steps

### Breaking Changes
None. 100% backwards compatible.
```

---

## 📊 Success Metrics

After Phase 2 completion, measure:

| Metric | Target | Success Indicator |
|--------|--------|-------------------|
| **Transient Failure Recovery** | 95% | Audits succeed even with brief network interruptions |
| **Execution Speed** | 40% faster | PS5+ audits complete 2-3x quicker |
| **Error Clarity** | 90% actionable | Users can fix issues from error messages alone |
| **Code Coverage** | 85%+ | All NEW functions tested |
| **Backwards Compat** | 100% | No existing workflows break |

---

## 📚 Resources & References

- Phase 2 Plan: `HIGH-PRIORITY-FIXES-PLAN.md`
- Foundation Functions: `src/Private/*.ps1` (4 files)
- Orchestrator: `Invoke-ServerAudit.ps1`
- Collectors: `src/Collectors/*.ps1`

---

## 🎯 Next Steps

1. **Today**: Assign tasks to dev team members
2. **By EOD**: TASK 1 (HIGH-001) integration complete
3. **By Tomorrow**: TASK 1 tested, TASK 2 underway
4. **By EOW**: All 4 tasks complete, PR ready
5. **Next Week**: Code review, merge to main, tag v2.1

---

**Dev Team**: You're now operating with a solid foundation (4 utility functions, 703 LOC, committed to branch). Next: integrate these into the orchestrator and collectors following the patterns above.

**Questions?** Review `HIGH-PRIORITY-FIXES-PLAN.md` for detailed solutions, or ask during daily standup.

**Status**: 🟢 READY TO EXECUTE

---

**Last Updated**: November 26, 2025  
**Branch**: `feature/phase-2-high-priority-improvements`  
**Foundation Commit**: a25242c  
**Owner**: Development Team
