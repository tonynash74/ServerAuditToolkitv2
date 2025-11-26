# ServerAuditToolkitV2 Code Review — Quick Checklist

**Print this page and use as a guide during implementation**

---

## 🔴 CRITICAL ISSUES CHECKLIST (v2.0.1)

### CRITICAL-001: Credential Passing
- [ ] Add `[System.Management.Automation.PSCredential]$Credential` parameter to all collectors
- [ ] Update 20+ collectors listed in CODE-REVIEW-REPORT.md
- [ ] Build invoke params hashtable with credential check
- [ ] Test with cross-domain credentials
- [ ] Verify `$PSBoundParameters.ContainsKey('Credential')` logic

**Files to Update** (20+ total):
- [ ] src/Collectors/100-RRAS.ps1 (line 69)
- [ ] src/Collectors/101-Fax.ps1 (line 37)
- [ ] src/Collectors/45-DNS.ps1 (lines 19, 38)
- [ ] src/Collectors/50-DHCP.ps1 (lines 19, 43)
- [ ] src/Collectors/55-SMB.ps1 (lines 37, 66)
- [ ] src/Collectors/65-Print.ps1 (lines 18, 28)
- [ ] src/Collectors/70-HyperV.ps1 (lines 31, 68)
- [ ] src/Collectors/20-Network.ps1 (lines 64, 103)
- [ ] src/Collectors/30-Storage.ps1 (lines 37, 68)
- [ ] src/Collectors/102-POP3Connector.ps1 (line 41)
- [ ] src/Collectors/103-RWA.ps1 (line 70)
- [ ] src/Collectors/10-RolesFeatures.ps1 (lines 18, 26)
- [ ] _AND 7+ MORE_ (see CODE-REVIEW-REPORT.md for full list)

**Validation**:
```powershell
# After fix, run this test
$cred = Get-Credential
Get-SATSystem -ComputerName "SERVER01" -Credential $cred
# Should work without "Access Denied" errors
```

---

### CRITICAL-002: WMI Date Conversion
- [ ] Open `src/Collectors/Get-ServerInfo-PS5.ps1` (lines 128-140)
- [ ] Replace `$osData.ConvertToDateTime()` with `[Management.ManagementDateTimeConverter]::ToDateTime()`
- [ ] Add helper function `ConvertWmiDate` for safety
- [ ] Handle null/invalid dates gracefully

**Exact Changes**:
- Line 133: `$osData.ConvertToDateTime($osData.InstallDate)` → `[Management.ManagementDateTimeConverter]::ToDateTime($osData.InstallDate)`
- Line 134: `$osData.ConvertToDateTime($osData.LastBootUpTime)` → `[Management.ManagementDateTimeConverter]::ToDateTime($osData.LastBootUpTime)`
- Line 137: Same fix for uptime calculation

**Validation**:
```powershell
# Test date conversion
$result = & 'src/Collectors/Get-ServerInfo-PS5.ps1'
if ($result.Data.OperatingSystem.InstallDate -is [datetime]) {
    Write-Host "✓ PASS: Date is valid datetime"
} else {
    Write-Host "✗ FAIL: Date is not datetime"
}
```

---

### CRITICAL-003: COM Object Serialization
- [ ] Open `src/Collectors/Get-IISInfo.ps1` (lines 94-140)
- [ ] Add hashtable normalization for all COM objects
- [ ] Convert `$site.Bindings` → iterate and convert to hashtables
- [ ] Test JSON export doesn't fail

**Key Changes**:
- [ ] Wrap COM collections in `foreach` loops
- [ ] Convert each COM object property to primitive types
- [ ] Use `[string]()` for string conversion, `[bool]()` for booleans
- [ ] Handle null values safely

**Validation**:
```powershell
# Test IIS collector on server with IIS installed
$result = & 'src/Collectors/Get-IISInfo.ps1'
$json = $result | ConvertTo-Json -Depth 10  # Should not fail
Write-Host "✓ PASS: JSON serialization successful"
```

---

### CRITICAL-004: Credential Context Threading
- [ ] Open `src/ServerAuditToolkitV2.psm1`
- [ ] Add `[System.Management.Automation.PSCredential]$Credential` parameter
- [ ] Store credential in `$script:AuditCredential` in try block
- [ ] Pass to all `Invoke-Command` and collector calls
- [ ] Clear in finally block: `Remove-Variable -Name AuditCredential`
- [ ] Also clear credential object: `$Credential.Password.Clear()`

**Validation**:
```powershell
$cred = Get-Credential
Invoke-ServerAudit -ComputerName "DOMAIN\SERVER01" -Credential $cred
# Should work across domain boundary
```

---

## 🟡 HIGH PRIORITY CHECKLIST (v2.1)

### HIGH-001: WinRM Retry Logic
- [ ] Create new file: `src/Private/Invoke-WithRetry.ps1`
- [ ] Implement retry function with exponential backoff
- [ ] Handle specific exceptions: SocketException, PSRemotingTransportException, TimeoutException
- [ ] Test with network interruption

**Test Scenario**:
```powershell
# Simulate transient failure
$command = { throw [System.Net.Sockets.SocketException]::new() }
Invoke-WithRetry -Command $command -MaxRetries 3  # Should retry and fail after 3 attempts
```

---

### HIGH-002: Adaptive Timeout Calculation
- [ ] Update `data/audit-config.json` with PS-version-specific timeouts
- [ ] Create function `Get-AdaptiveTimeout` in `Invoke-ServerAudit.ps1`
- [ ] Calculate timeout = baseTimeout × serverSlownessFactor
- [ ] Apply to all collector invocations

**Configuration Update**:
```json
"85-DataDiscovery": {
  "ps2": 300,
  "ps5": 150,
  "ps7": 100
}
```

---

### HIGH-003: Parameter Validation
- [ ] Add `[ValidateScript()]` attributes to all function parameters
- [ ] Validate ComputerName format (no special chars, length < 255)
- [ ] Validate paths (if applicable)
- [ ] Validate credentials not null

**Template**:
```powershell
[ValidateScript({
    if ([string]::IsNullOrWhiteSpace($_)) { throw "Cannot be empty" }
    if ($_ -match '[<>:"/\\|?*]') { throw "Invalid characters" }
    return $true
})]
[string]$ComputerName = $env:COMPUTERNAME
```

---

## 🟠 MEDIUM PRIORITY CHECKLIST (v2.2)

### MEDIUM-001: N+1 Query Optimization
- [ ] File: `src/Collectors/85-DataDiscovery.ps1`
- [ ] Pre-calculate cutoff dates OUTSIDE loop
- [ ] Replace date calculation with date comparison
- [ ] Benchmark: should see ~15-20% speedup

### MEDIUM-003: Standardize Error Objects
- [ ] Create helper: `Get-StandardCollectorResponse`
- [ ] Update all 40+ collectors to use standard format
- [ ] Ensure all return: Success, CollectorName, Data, Errors, Warnings, ExecutionTime, RecordCount

### MEDIUM-005: Metadata Validation
- [ ] Create new file: `src/Private/Test-CollectorMetadata.ps1`
- [ ] Validate all metadata entries have files
- [ ] Validate all files registered in metadata
- [ ] Call during module import, fail if invalid

---

## 📚 DOCUMENTATION CHECKLIST

### DOC-001: Fix Version Support Claims
- [ ] Update README.md badges from "PS 2.0+" to "PS 4.0+ (recommended 5.1+)"
- [ ] Correct support matrix table with accurate compatibility
- [ ] Add notes about limitations

### DOC-002: Update Quick Start Examples
- [ ] Update example commands to show actual function names
- [ ] Add usage examples for returned objects
- [ ] Test all examples work end-to-end

### DOC-003: Create Configuration Reference
- [ ] New file: `docs/CONFIGURATION-REFERENCE.md`
- [ ] Document all audit-config.json options
- [ ] Add timeout adjustment guide
- [ ] Document compliance patterns

### DOC-004: Add Remote Execution Guide
- [ ] Expand `docs/DEVELOPMENT.md` with credential handling section
- [ ] Document common WinRM issues
- [ ] Add troubleshooting steps

### DOC-005: Clarify T3 Limitations
- [ ] Update README.md T3 section to note "Alpha release"
- [ ] Document PDF extraction limitations
- [ ] Link to roadmap for iText7 integration

---

## 🧪 TESTING CHECKLIST

### Before v2.0.1 Release:

#### PowerShell Version Matrix
- [ ] PS 2.0 (Server 2008 R2)
  - [ ] Basic collectors work
  - [ ] No COM serialization errors
  - [ ] Credential passing works

- [ ] PS 5.1 (Server 2016/2019)
  - [ ] CIM collectors work
  - [ ] Date conversion works
  - [ ] JSON export successful

- [ ] PS 7.x (Server 2022)
  - [ ] All collectors complete
  - [ ] Performance acceptable
  - [ ] Async operations work

#### Scenario Testing
- [ ] Local audit (same domain): `Invoke-ServerAudit -ComputerName $env:COMPUTERNAME`
- [ ] Remote audit (same domain): `Invoke-ServerAudit -ComputerName "SERVER01"`
- [ ] Cross-domain audit: `Invoke-ServerAudit -ComputerName "OTHERDOMAIN\SERVER01" -Credential $cred`
- [ ] Network failure (pull network cable during audit)
  - [ ] Verify retry logic activates
  - [ ] Verify graceful degradation
- [ ] Permission denied (run without admin)
  - [ ] Verify clear error message
  - [ ] Verify execution doesn't hang
- [ ] Large data set (85-DataDiscovery on 200K+ files)
  - [ ] Monitor memory usage
  - [ ] Verify completion time < 5 minutes
- [ ] Timeout scenario (disconnect remote server during collection)
  - [ ] Verify timeout triggers
  - [ ] Verify results reflect timeout

#### Output Validation
- [ ] JSON output valid format: `$results | ConvertFrom-Json`
- [ ] CSV output readable: Open in Excel
- [ ] HTML output renders: Open in browser
- [ ] All dates valid (no null or invalid values)
- [ ] No COM objects in output

---

## 🔐 Security Checklist

- [ ] Credentials cleared from memory after use
- [ ] No plaintext password logging
- [ ] Credential objects disposed properly
- [ ] WinRM uses HTTPS when available
- [ ] No credential caching between runs
- [ ] Audit log doesn't contain sensitive data

---

## 📋 SIGN-OFF TEMPLATE

**Code Review Implementation Complete**

```
┌─────────────────────────────────────────────────────────────────┐
│ CRITICAL Issues Fixed:                                  ☐ 4/4   │
│ HIGH Priority Issues Fixed:                             ☐ 4/4   │
│ MEDIUM Priority Issues Fixed:                           ☐ 14/14 │
│                                                                  │
│ Documentation Updated:                                  ☐ 5/5   │
│ All Tests Passed:                                       ☐ YES   │
│ Peer Review Completed:                                  ☐ YES   │
│ Ready for Release:                                      ☐ YES   │
│                                                                  │
│ Version: 2.0.1                                                   │
│ Release Date: _______________                                    │
│ Released By: _______________                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## ⏱️ TIME ESTIMATES

| Phase | Tasks | Estimated Time |
|-------|-------|-----------------|
| CRITICAL Fixes | 4 blocking issues | 6-8 hours |
| Testing | All scenarios | 4-6 hours |
| Documentation | Update 5 docs | 3-4 hours |
| **v2.0.1 Total** | | **13-18 hours** |
| HIGH Fixes | 4 improvements | 8-12 hours |
| MEDIUM Fixes | 14 improvements | 8-12 hours |
| **v2.1 Total** | | **16-24 hours** |

---

**Generated**: November 26, 2025  
**Review Status**: Complete ✅  
**Ready for Implementation**: Yes ✅

