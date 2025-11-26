# ServerAuditToolkitV2 — MSP Quick Reference Card

**One-page guide for 1st-line MSP engineers**  
**Version**: v2.2.0-RC (Phase 3: 13/14 enhancements complete)

---

## What Is This?

Enterprise-grade **Windows Server auditing tool** with Phase 3 enhancements to determine:
- **Decommission-ready?** — Can we retire this server?
- **Migration-ready?** — Can we move to cloud/new infrastructure?
- **Risk areas?** — PII, compliance gaps, security issues?
- **Health status?** — Automated diagnostics with remediation suggestions (NEW in Phase 3)

---

## Prerequisites (60 seconds)

```powershell
# 1. On your Windows Server 2012+ admin box:
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
cd ServerAuditToolkitv2

# 2. Check your PowerShell version:
$PSVersionTable.PSVersion

# 3. Run. That's it.
.\Invoke-ServerAudit.ps1
```

---

## Quick Commands

### Audit Your Local Machine (2 minutes)
```powershell
.\Invoke-ServerAudit.ps1
# Results → audit_results/audit_*.json
```

### Audit a Remote Server (2 minutes)
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
# Results → audit_results/audit_*.json
```

### Audit Multiple Servers (Runs 3 at a time)
```powershell
$servers = "SERVER01", "SERVER02", "SERVER03", "SERVER04"
.\Invoke-ServerAudit.ps1 -ComputerName $servers
# Auto-throttles to 3 concurrent (MSP-safe)
```

### Dry-Run (See What Will Execute)
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" -DryRun
# No actual data collected; shows collectors that will run
```

### Specific Collectors Only
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
    -Collectors @("Get-IISInfo", "Get-SQLServerInfo")
# Just IIS and SQL (skip the rest)
```

---

## What Gets Collected?

| Category | Examples | Time |
|----------|----------|------|
| **Core** | OS version, hardware, uptime, network | 10s |
| **Apps** | IIS, SQL Server, Exchange, SharePoint | 30-60s |
| **Services** | Running services, startup types | 5s |
| **Compliance** | PII (SSN, credit cards, UK banking data) | 60-300s |
| **Infrastructure** | AD, DNS, DHCP, Hyper-V | 30-45s |

**Total Time**: 3-5 minutes per server (optimized with Phase 3)  
**Concurrency**: Auto-detected parallelism, up to 100+ servers with batch processing (NEW in Phase 3)  
**Memory**: 90% reduction via batch processing pipeline (Phase 3 M-010)
**Resilience**: DNS retry + WinRM session pooling + resource monitoring (Phase 3 M-008-M-009)

---

## Understanding Results

### JSON Output (Main File)
```
audit_results/SERVER01_audit_2025-11-21T14-30-45.json

Contains:
- Server details (OS, hardware, uptime)
- Each collector's output
- Execution times
- Any errors or warnings
- Recommendations
```

### CSV Output (Quick Analysis)
```
audit_results/audit_summary_2025-11-21.csv

Server,Success,Collectors,ExecutionTime
SERVER01,TRUE,12/12,47s
SERVER02,TRUE,11/12,42s
```

### Key Fields in JSON
```json
{
  "computerName": "SERVER01",
  "operatingSystem": "Windows Server 2019",
  "powerShellVersion": "5.1",
  "collectors": {
    "Get-ServerInfo": {
      "status": "Success",
      "executionTimeSeconds": 5,
      "data": { /* OS info */ }
    },
    "85-DataDiscovery": {
      "status": "Success",
      "data": {
        "piiDetected": true,
        "patterns": [
          { "type": "SSN", "count": 8 },
          { "type": "UK_IBAN", "count": 5 }
        ]
      }
    }
  }
}
```

---

## ⚠️ Common Issues & Fixes

| Issue | Fix |
|-------|-----|
| **"Access Denied"** | Enable WinRM: `Enable-PSRemoting -Force` on target server |
| **"Connection timeout"** | Check firewall (port 5985/5986 WinRM) |
| **"Collector timeout"** | Server is slow; run again in off-hours |
| **"PII not detected"** | Check share permissions; collector needs read access |
| **"Out of memory"** | Reduce parallelism: `-MaxParallelJobs 1` |

---

## Key Safeguards

✅ **No credentials stored** — Uses your domain user  
✅ **Max 3 servers at once** — Prevents network storms  
✅ **Stops at 7 AM** — Won't jam business hours  
✅ **Graceful timeouts** — Partial audit is OK  
✅ **No modifications** — Read-only audit  

---

## Decommissioning Checklist

After audit completes, use JSON results to check:

- [ ] **Applications** — Get-InstalledApps output; notify business owners
- [ ] **Services** — Get-Services; identify custom/critical services
- [ ] **Data** — 85-DataDiscovery; classify and move PII
- [ ] **Shares** — Get shares and permissions; plan migration
- [ ] **Dependencies** — Check what services depend on this server
- [ ] **Compliance** — Any open ports, old OS, unpatched?
- [ ] **Hardware** — CPU/RAM/disk capacity; plan redeployment

**Questions?** Ask your infrastructure team or Tony Nash.

---

## PowerShell Version Notes

| Version | Where | Command |
|---------|-------|---------|
| **PS 2.0** | Windows Server 2008 R2 | Slowest; sequential only |
| **PS 5.1** | Windows Server 2012 R2+ (default) | **RECOMMENDED**; 3-5x faster |
| **PS 7.x** | Windows Server 2016+ (optional) | Fastest; parallel-ready |

**Check your version**:
```powershell
$PSVersionTable.PSVersion.Major  # 2, 5, 7, etc.
```

---

## Advanced Usage (If Needed)

### Export to Specific Path
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
    -OutputPath "C:\Audits\Q4-2025"
```

### Enable Verbose Logging
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
    -LogLevel "Verbose"
```

### Skip Performance Profiling (Faster)
```powershell
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01" `
    -SkipPerformanceProfile
```

### Use Different Collectors Folder
```powershell
.\Invoke-ServerAudit.ps1 -CollectorPath "C:\CustomCollectors"
```

---

## Performance Tips

| Action | Impact |
|--------|--------|
| Run at **2-6 AM** (off-hours) | ✅ Full audit, no business impact |
| Run **3 servers max** | ✅ Safe; no network saturation |
| Skip **data discovery** (85-*) | ✅ Faster, but no PII detection |
| Use **PS 5.1** (not PS 2.0) | ✅ 3-5x faster |
| Run on **DC or admin box** | ✅ No credential prompts |

---

## Getting Help

| Need | Link |
|------|------|
| **Full documentation** | README.md in repo |
| **Development guide** | docs/DEVELOPMENT.md |
| **Contributing** | CONTRIBUTING.md |
| **Report a bug** | GitHub Issues |
| **Start a discussion** | GitHub Discussions |

---

## Useful Links

- **GitHub Repo**: https://github.com/tonynash74/ServerAuditToolkitv2
- **Author**: Tony Nash
- **Organization**: inTEC Group
- **License**: MIT (open-source, free to modify)

---

**One-Minute Recap**:
1. ✅ Run `.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"`
2. ✅ Check `audit_results/` for JSON output
3. ✅ Use results to plan decommissioning or migration
4. ✅ Questions? Ask infrastructure team

**Remember**: This tool is **read-only** and **safe** — it never modifies servers.

---

---

## Phase 3 Enhancements (NEW - v2.2.0)

**Included in this version** (13/14 complete):
- ✅ **M-001-M-006**: Structured logging, PS7 parallelization, 3-tier fallback, caching, profiling, configuration
- ✅ **M-007-M-009**: Health checks, network resilience (DNS retry + session pooling), resource monitoring
- ✅ **M-010-M-011**: Batch processing (100+ servers, 90% memory reduction), error dashboard with 9 categories
- ✅ **M-013-M-014**: Comprehensive API reference (docs/API-REFERENCE.md), health diagnostics engine
- ⏳ **M-012**: Output streaming (deferred for future optimization)

**See full documentation**: docs/API-REFERENCE.md for integration examples

---

*Last Updated: November 26, 2025*  
*Status: Phase 3 Complete (93% - 13/14 enhancements)*
