# T4 Migration Decisions Engine - Quick Start Guide

**Target Audience**: Architects and MSPs  
**Time to First Recommendation**: 5 minutes  
**Effort to Integrate**: 2-3 hours

---

## 🚀 Quick Start (TL;DR)

You've already run `Invoke-ServerAudit.ps1` and have JSON audit results. Now generate migration recommendations:

```powershell
# 1. Analyze a single server's audit
$decision = .\src\Analysis\Invoke-MigrationDecisions.ps1 `
    -AuditPath ".\audit_results\SERVER01_audit_2025-11-21.json"

# 2. View recommendations (top 3 options)
$decision.migrationOptions | Select-Object rank, destination, estimatedTCO

# 3. Generate executive report
New-MigrationReport -DecisionData $decision -OutputPath ".\reports\SERVER01-migration-plan.html"
```

**Output**: HTML report with 3 destination options, costs, remediation plan, timeline.

---

## 📊 What You'll Get

### Migration Decision JSON
```json
{
  "sourceServer": "SERVER01",
  "workloadClassification": "FileServer",
  "readinessScore": 82,
  "migrationOptions": [
    {
      "rank": 1,
      "destination": "Azure VM (Standard_D4s_v3)",
      "estimatedTCO": 4195,
      "complexity": "MEDIUM",
      "downtime": "2-4 hours"
    }
  ],
  "blockers": ["Local path hardcoding in 42 documents"],
  "remediationPlan": [...]
}
```

### HTML Executive Report
- Server profile + workload type
- Readiness gauge (0-100 score)
- 3 destination options with cost/complexity comparison
- Remediation checklist (critical items first)
- Timeline estimate (weeks to complete)
- Network dependency diagram

---

## 🔄 Batch Analysis (Multiple Servers)

```powershell
# Analyze all servers at once
$audits = Get-ChildItem ".\audit_results\*.json"
$decisions = $audits | ForEach-Object {
    .\src\Analysis\Invoke-MigrationDecisions.ps1 -AuditPath $_.FullName
}

# Export for spreadsheet review
$decisions | 
    Select-Object sourceServer, workloadClassification, readinessScore, `
        @{N='TopOption'; E={$_.migrationOptions[0].destination}}, `
        @{N='FirstYearCost'; E={$_.migrationOptions[0].estimatedTCO}} |
    Export-Csv "migration-analysis-2025-11-21.csv"

# Generate individual HTML reports
$decisions | ForEach-Object {
    New-MigrationReport -DecisionData $_ `
        -OutputPath ".\reports\$($_.sourceServer)-decision.html"
}
```

---

## 🎯 Common Scenarios

### Scenario 1: Simple File Server Migration to Azure
```powershell
$audit = Get-Content ".\audit_results\FILESERVER01_audit.json" | ConvertFrom-Json
# System: 2 CPU, 8 GB RAM, Windows Server 2019
# Applications: None (just file sharing)
# Result: Azure VM (B2s) recommended for cost savings
# TCO: ~$2,400/year vs $15,000 on-prem hardware
```

### Scenario 2: Complex SQL + IIS Server (Hybrid Cloud)
```powershell
$audit = Get-Content ".\audit_results\WEBAPP01_audit.json" | ConvertFrom-Json
# System: 8 CPU, 64 GB RAM, SQL + IIS
# Applications: Custom web app, SQL 2019, Windows authentication
# Result: Azure VM recommended (lift-and-shift), but App Service alternative shown
# TCO: $8,500/year (VM) vs $12,000/year (App Service with refactoring)
```

### Scenario 3: Legacy Server with Hardcoded Paths
```powershell
$audit = Get-Content ".\audit_results\LEGACY01_audit.json" | ConvertFrom-Json
# System: Windows Server 2008 R2 (EOL), hardcoded paths in 200+ documents
# Applications: Unsupported version of COTS product
# Result: On-prem modern server recommended (Server 2022 refresh)
# Remediation: 4-6 week project to fix hardcoded paths
# Timeline: 12-16 weeks total (remediation + upgrade + validation)
```

---

## 🔍 Understanding Readiness Scores

**0-25** (Red): Significant blockers, major remediation needed
- Examples: Windows Server 2008 R2 EOL, unsupported applications, heavy hardcoded paths

**26-50** (Yellow): Moderate complexity, some remediation required
- Examples: Multiple hardcoded paths, older SQL versions, custom applications

**51-75** (Orange): Good candidates, minimal remediation
- Examples: Supported OS versions, standard applications, some path cleanup needed

**76-100** (Green): Ready to migrate, minimal effort
- Examples: Modern OS, standard apps, UNC paths or cloud-native design

---

## 🧠 How Recommendations Are Generated

### Workload Classification
The engine analyzes installed applications to classify as:
- **Web Server** (IIS detected) → Consider Azure App Service
- **Database Server** (SQL/MySQL detected) → Consider Azure SQL
- **File Server** (large shares, minimal apps) → Consider Azure VM + Storage
- **Application Server** (COTS or custom) → Azure VM or on-prem modern
- **Domain Controller** (AD detected) → On-prem or Hybrid Azure AD
- **Hybrid** (multiple roles) → Mixed recommendations

### Scoring Components (Readiness = weighted average)
- **Server Health** (25%): OS age, support status, hardware specs
- **App Compatibility** (25%): EOL status, cloud-native readiness
- **Data Readiness** (25%): PII compliance, link health, hardcoded paths
- **Network Readiness** (15%): Firewall rules, DNS, WinRM connectivity
- **Compliance** (10%): Regulatory requirements, data residency

### Cost Estimation (First-Year TCO)
- **Azure Option**: Compute (VM size) + Storage + License + Labor
- **App Service Option**: Compute (app tier) + Labor (refactoring) + Support
- **On-Prem Modern**: Hardware capex + Labor (migration) + Support year 1

---

## 📋 Remediation Plan Priorities

### CRITICAL (Do Before Cutover)
- Hardcoded local paths (will break post-migration)
- Expiring SSL certificates
- Unsupported OS versions (if not migrating)
- Unresolved service dependencies

### IMPORTANT (Do During Cutover Window)
- DNS/network reconfiguration
- Application configuration updates
- Firewall rule changes
- Monitoring agent installation

### NICE-TO-HAVE (Do Post-Cutover)
- Application version updates
- Modernization of legacy code
- Performance optimization
- Backup strategy review

---

## 🧑‍💻 Advanced Usage

### Custom Scoring Weights
```powershell
# Adjust what matters most to YOUR organization
$weights = @{
    ServerHealth = 0.15
    AppCompatibility = 0.35  # We care more about app support
    DataReadiness = 0.20
    NetworkReadiness = 0.20
    Compliance = 0.10
}

$decision = Invoke-MigrationDecisions -AuditPath $path -CustomWeights $weights
```

### Regional Cost Analysis
```powershell
# Show TCO for different Azure regions
$regions = @("EastUS", "WestEurope", "UK South", "Southeast Asia")
Invoke-MigrationDecisions -AuditPath $path -Regions $regions
```

### What-If Analysis
```powershell
# What if we delay migration 18 months?
Invoke-MigrationDecisions -AuditPath $path -AssumeDelayMonths 18

# What if we're on a reserved instance plan?
Invoke-MigrationDecisions -AuditPath $path -ReservedInstanceMonths 36
```

---

## 🐛 Troubleshooting

### "Audit file not found"
```powershell
# Make sure audit was run first
.\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
# Then analyze the results
$decision = Invoke-MigrationDecisions -AuditPath ".\audit_results\SERVER01_*.json"
```

### "Workload classification returned 'Unknown'"
This means the engine couldn't confidently classify the server. Check:
- Are installed applications detected? (Get-InstalledApps collector)
- Are services running? (Get-Services collector)
- Is IIS/SQL/Exchange configured? (respective collectors)

```powershell
# Debug: examine the full audit
$audit = Get-Content "audit_results\SERVER01_audit.json" | ConvertFrom-Json
$audit.collectors | Where-Object { $_.name -match "IIS|SQL|Services|Apps" }
```

### "Readiness score seems too low"
Review the blockers and scoring breakdown:
```powershell
$decision.readinessScore | Format-List
# Check the blockers field for issues affecting score
$decision.blockers
```

---

## 📚 Next Steps

1. **Run Analysis**: Follow the 5-minute quick start above
2. **Review HTML Report**: Share with stakeholders
3. **Validate Recommendations**: Does the suggested destination match your strategy?
4. **Build Remediation Plan**: Use the CRITICAL items as first sprint
5. **Cost Approval**: Show TCO comparison to finance/procurement
6. **Execute Migration**: Follow recommended timeline (12-16 weeks typical)

---

## 🔗 Related Commands

```powershell
# Run full audit pipeline (T1-T3) then analyze
.\Invoke-ServerAudit.ps1 -ComputerName $servers -AllCollectors -GenerateReport

# Then analyze
$audit = Get-ChildItem ".\audit_results\*.json" | Select-Object -First 1
$decision = .\src\Analysis\Invoke-MigrationDecisions.ps1 -AuditPath $audit.FullName

# And report
New-MigrationReport -DecisionData $decision -OutputPath ".\migration-recommendation.html"
```

---

**Ready?** Run your first analysis now! 🚀
