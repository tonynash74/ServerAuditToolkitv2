# T4: Migration Decisions Engine

**Phase**: T4 (Post-T3 Production)  
**Status**: Planning & Specification  
**Target**: v2.1 release  
**Scope**: Build intelligent orchestrator to analyze T1-T3 audit data and recommend migration destinations

---

## 🎯 Executive Summary

The **Migration Decisions Engine** is a strategic new orchestrator that mines data from all 16 existing collectors (TIER 1-6) to answer critical migration questions:

1. **Where should this workload go?** (Azure VM, Azure App Service, AWS EC2, on-prem modern server, etc.)
2. **What remediation is needed?** (Link fixes, path migrations, dependency updates)
3. **What's the total cost of migration?** (Infrastructure, labor, validation)
4. **What's the risk profile?** (Complexity, downtime, validation effort)

**Key Differentiator**: Uses audit data already collected to generate **destination recommendations** without requiring additional scans.

---

## 📊 Data Mining Strategy

### Input Data Sources (Already Collected)

**T1-T2 Collectors (Server Audit)**
- Server specs (CPU, RAM, disk, OS version)
- Installed applications (version, vendor, EOL status)
- Services dependencies (what services depend on what)
- IIS/SQL/Exchange configurations (version, workload type)
- Scheduled tasks (batch windows, automation dependencies)
- Certificates (SSL/TLS requirements, PKI dependencies)
- Network config (DNS, DHCP, IP allocation strategy)

**T4 Compliance Data**
- PII detected (data privacy requirements → regional hosting)
- UK Financial data (FCA compliance requirements → UK region)
- Data heat map (access patterns → archival vs. active tiers)

**T3 Document Intelligence**
- Local hardcoded paths (C:\, D:\) → `HIGH` migration risk
- UNC paths (\\server\share) → `LOW` risk, SMB-friendly
- Broken links (external URLs, invalid files) → remediation needed
- Link dependencies → which shares/systems are referenced

---

## 🚀 Phase 1: Core Engine (Week 1-2)

### 1.1 Collector: Analyze-MigrationReadiness.ps1

Orchestrate all audit data and produce structured recommendation.

**Input**: Folder containing T1-T3 audit JSON files

**Processing**:
```powershell
1. Load audit results JSON
2. Analyze server specifications
3. Classify workload type (web, database, file server, legacy, etc.)
4. Score migration readiness (0-100)
5. Identify migration blockers
6. Generate destination options
7. Estimate TCO (total cost of ownership)
8. Create remediation plan
```

**Output**: JSON structure with recommendations

```json
{
  "analyzeId": "analyze-2025-11-21-SERVER01-abc123",
  "sourceServer": {
    "name": "SERVER01",
    "os": "Windows Server 2019 Standard",
    "cpu": 4,
    "ramGb": 32,
    "diskGb": 500,
    "criticality": "HIGH|MEDIUM|LOW",
    "supportedUntil": "2026-01-13"
  },
  "workloadClassification": {
    "primaryType": "FileServer|WebServer|DatabaseServer|ApplicationServer|DomainController|HybridInfra",
    "confidence": 0.95,
    "secondaryTypes": ["ApplicationServer"],
    "keyApplications": ["Windows Server 2019", "IIS 10", "SQL 2019"],
    "estimatedWorkloadSize": "Small|Medium|Large|Enterprise"
  },
  "readinessScore": {
    "overall": 82,
    "serverHealthScore": 90,
    "applicationCompatibilityScore": 80,
    "dataReadinessScore": 75,
    "networkReadinessScore": 85,
    "complianceScore": 70,
    "blockers": [
      "Local path hardcoding in 42 documents (HIGH risk)",
      "Pending SSL certificate renewal (expires in 30 days)",
      "Dependent service: 'CustomApp' EOL status unknown"
    ]
  },
  "migrationOptions": [
    {
      "rank": 1,
      "destination": "Azure VM (Standard_D4s_v3)",
      "platform": "Azure",
      "rationale": "Windows Server 2019 native support, 4 CPU matches current, cost-effective lift-and-shift",
      "estimatedTCO": {
        "computeMonthly": 150,
        "storageMonthly": 25,
        "networkMonthly": 10,
        "licenseMonthly": 0,
        "laborEstimateHours": 40,
        "laborEstimateCost": 4000,
        "totalFirstYearCost": 4195
      },
      "complexity": "MEDIUM",
      "downtime": "2-4 hours (with planning)",
      "recommendedApproach": "Azure Migrate, Windows Server reimage",
      "riskFactors": ["Local path remediation needed", "Certificate renewal timing"]
    },
    {
      "rank": 2,
      "destination": "Azure App Service (if web-only)",
      "platform": "Azure",
      "rationale": "Containerized IIS, eliminates OS management",
      "estimatedTCO": {
        "computeMonthly": 70,
        "storageMonthly": 5,
        "networkMonthly": 5,
        "laborEstimateHours": 80,
        "laborEstimateCost": 8000,
        "totalFirstYearCost": 8955
      },
      "complexity": "HIGH",
      "downtime": "Zero-downtime (blue-green)",
      "recommendedApproach": "Application refactoring + containerization",
      "riskFactors": ["App refactoring effort significant", "Requires code review"]
    },
    {
      "rank": 3,
      "destination": "On-Prem Modern (Server 2022 refresh)",
      "platform": "OnPrem",
      "rationale": "Extend support lifecycle without cloud transformation",
      "estimatedTCO": {
        "hardware": 8000,
        "labourEstimateHours": 20,
        "laborEstimateCost": 2000,
        "supportYear1": 1200,
        "totalFirstYearCost": 11200
      },
      "complexity": "LOW",
      "downtime": "1-2 hours (migration window)",
      "recommendedApproach": "In-place upgrade or P2V migration",
      "riskFactors": ["On-prem capex required", "Support costs increase beyond year 3"]
    }
  ],
  "remediationPlan": {
    "critical": [
      {
        "issue": "Local path hardcoding in 42 documents",
        "recommendation": "Use Invoke-DocumentLinkAudit remediation module to rewrite paths as UNC",
        "effort": "MEDIUM (4-8 hours)",
        "priority": "BEFORE_MIGRATION",
        "automatable": true
      }
    ],
    "important": [
      {
        "issue": "SSL certificate expires 2025-12-15",
        "recommendation": "Renew 60 days before cutover to avoid downtime during migration",
        "effort": "LOW (1-2 hours)",
        "priority": "BEFORE_MIGRATION",
        "automatable": false
      }
    ],
    "nice_to_have": [
      {
        "issue": "Oldest IIS application binding predates SNI support",
        "recommendation": "Consider consolidating to modern SNI-capable bindings",
        "effort": "HIGH (20+ hours)",
        "priority": "OPTIONAL"
      }
    ]
  },
  "dataClassification": {
    "piiDetected": true,
    "piiTypes": ["SSN", "Email"],
    "piiCount": 87,
    "complianceRequirements": [
      "GDPR (EU data subjects)",
      "CCPA (if CA residents present)"
    ],
    "recommendedRegion": "EU (Ireland or Netherlands)",
    "regionLockingRequired": true
  },
  "networkDependencies": {
    "inboundDependencies": [
      {
        "source": "192.168.1.0/24 (users subnet)",
        "protocol": "RDP, SMB",
        "criticalityLevel": "HIGH"
      }
    ],
    "outboundDependencies": [
      {
        "target": "DC01.corp.local (Domain Controller)",
        "protocol": "LDAP, Kerberos",
        "resolutionStrategy": "Hybrid Azure AD Join + Local AD relay"
      }
    ]
  },
  "timeline": {
    "assessmentPhase": "1 week",
    "planningPhase": "2 weeks",
    "remediationPhase": "2-4 weeks",
    "migrationPhase": "1 week",
    "validationPhase": "2 weeks",
    "decommissionPhase": "4 weeks",
    "totalEstimate": "12-16 weeks"
  }
}
```

### 1.2 Architecture: Decision Tree Engine

```
Analyze-MigrationReadiness
├─ Load audit data (JSON parser)
├─ Classify workload
│  ├─ Extract applications + versions
│  ├─ Match to known profiles (web, DB, file server, etc.)
│  └─ Generate workload type + confidence
├─ Calculate readiness scores
│  ├─ Server health (age, support status, HW compatibility)
│  ├─ App compatibility (EOL status, licensing, dependencies)
│  ├─ Data readiness (PII, compliance, link health)
│  └─ Network readiness (DNS, DHCP, firewall, WinRM)
├─ Identify migration blockers
│  ├─ Unsupported OS versions
│  ├─ EOL applications
│  ├─ Hardcoded paths (from T3 data)
│  └─ Compliance constraints
├─ Generate destination options
│  ├─ Azure VM (lift-and-shift)
│  ├─ Azure App Service (if web/api)
│  ├─ Azure SQL (if database)
│  ├─ AWS EC2 (if multi-cloud strategy)
│  └─ On-prem modern (if in-situ upgrade)
├─ Calculate TCO per option
│  ├─ Compute costs (VM size, region)
│  ├─ Storage costs (data transfer, retention)
│  ├─ Licensing (Windows, SQL, apps)
│  ├─ Labor (remediation, migration, validation)
│  └─ Risk cost (complexity discount/premium)
├─ Build remediation plan
│  ├─ Critical items (before cutover)
│  ├─ Important items (during cutover window)
│  └─ Nice-to-have items (post-cutover)
└─ Output: JSON recommendation + executive summary
```

---

## 🔄 Phase 2: Integration & Reporting (Week 3)

### 2.1 New Orchestrator: Invoke-MigrationDecisions.ps1

High-level wrapper to run full analysis and generate reports.

**Usage**:
```powershell
# Run analysis on single server audit
$decision = Invoke-MigrationDecisions -AuditPath ".\audit_results\SERVER01_audit_2025-11-21.json"

# Run on all servers in a folder
$decisions = Get-ChildItem ".\audit_results\*.json" | 
    ForEach-Object { Invoke-MigrationDecisions -AuditPath $_.FullName }

# Export to CSV for spreadsheet analysis
$decisions | Export-Csv "migration-decisions-2025-11-21.csv"
```

### 2.2 Report Generator: New-MigrationReport.ps1

Generates executive HTML dashboard from decision JSON.

**Features**:
- Server list with workload classification
- Readiness score visualization (gauge chart)
- Top 3 destination recommendations (comparison table)
- Remediation checklist
- Timeline and cost estimate
- Network dependency diagram (ASCII art)
- Compliance requirements summary

**Output**:
```
migration-decisions-2025-11-21.html
├─ Executive Summary (1-page)
├─ Server Readiness Profiles (1 per server)
├─ Migration Recommendations (comparison table)
├─ Remediation Plans (Gantt timeline)
├─ Cost Analysis (TCO comparison chart)
└─ Appendix (network diagrams, assumptions)
```

---

## 📋 Phase 3: Advanced Features (Week 4+)

### 3.1 Dependency Mapping: Get-ServiceDependencies.ps1

Mine scheduled tasks + services to understand operational dependencies.

```powershell
# For each service on the server:
#  1. Find dependent services
#  2. Find consuming applications
#  3. Map to other servers (via network analysis)
#  4. Score criticality

# Output: Service dependency graph JSON
{
  "serviceName": "SQL Server (MSSQLSERVER)",
  "dependencies": {
    "upstream": [
      { "service": "Windows Update", "type": "system", "criticality": "MEDIUM" }
    ],
    "downstream": [
      { 
        "application": "CustomApp", 
        "type": "business-logic",
        "criticality": "HIGH",
        "connectionString": "Server=SERVER01;Database=AppDB"
      }
    ],
    "external": [
      {
        "system": "DC01.corp.local",
        "protocol": "LDAP",
        "criticality": "HIGH"
      }
    ]
  }
}
```

### 3.2 Cost Modeling: Estimate-MigrationCost.ps1

Detailed TCO calculation with regional pricing, licensing, labor rates.

**Variables**:
- Azure region pricing (EUS, WEU, UKS, etc.)
- Licensing (Windows Server, SQL Server, 3rd-party apps)
- Labor rates (configurable per organization)
- Network transfer costs (data egress)
- Downtime costs (revenue impact per hour)

### 3.3 Link Remediation Strategy: Build-LinkRemediationPlan.ps1

Using T3 document link data, generate automated fix scripts.

```powershell
# For each document with hardcoded local paths:
# 1. Parse path pattern
# 2. Recommend UNC replacement
# 3. Generate Find-and-Replace instructions
# 4. Create PowerShell remediation script

# Output: Remediation scripts for MSP to execute
```

---

## 🔌 Integration Points

### With Existing T1-T3 Infrastructure

```
┌─────────────────────────────────────────────────┐
│  Invoke-ServerAudit.ps1 (Main Orchestrator)     │
│  - Runs T1-T3 collectors                        │
│  - Generates JSON audit results                 │
│  - Stores in audit_results/                     │
└────────────┬────────────────────────────────────┘
             │ (reads)
             ▼
┌─────────────────────────────────────────────────┐
│  T4 Engine: Invoke-MigrationDecisions.ps1       │
│  - Loads JSON from T1-T3 audits                 │
│  - Analyzes data → generates recommendations    │
│  - Outputs decision JSON                        │
└────────────┬────────────────────────────────────┘
             │ (reads)
             ▼
┌─────────────────────────────────────────────────┐
│  T4 Reporting: New-MigrationReport.ps1          │
│  - Generates HTML/CSV/Excel reports             │
│  - Creates executive dashboards                 │
│  - Exports for stakeholder review               │
└─────────────────────────────────────────────────┘
```

### New Metadata Entries

```json
{
  "name": "Analyze-MigrationReadiness",
  "category": "analysis",
  "description": "Analyzes audit data to recommend migration destinations",
  "psVersions": ["3.0", "5.1", "7.0"],
  "inputs": ["JSON audit file from T1-T3"],
  "outputs": ["JSON recommendation, CSV export, HTML report"]
}
```

---

## 📝 File Structure (T4 Addition)

```
ServerAuditToolkitv2/
├── src/
│   ├── Collectors/
│   │   ├── ... (T1-T3 unchanged)
│   │   └── Analyze-MigrationReadiness.ps1 [NEW]
│   │
│   ├── Analysis/ [NEW FOLDER]
│   │   ├── Invoke-MigrationDecisions.ps1
│   │   ├── New-MigrationReport.ps1
│   │   ├── Get-ServiceDependencies.ps1 [Future]
│   │   ├── Estimate-MigrationCost.ps1 [Future]
│   │   └── Build-LinkRemediationPlan.ps1 [Future]
│   │
│   └── ServerAuditToolkitV2.psd1 [UPDATED]
│
├── data/
│   ├── audit-config.json [UPDATED]
│   ├── collector-metadata.json [UPDATED - add T4 entries]
│   ├── destinationProfiles.json [NEW]
│   ├── costingModel.json [NEW - regional pricing]
│   └── workloadClassifications.json [NEW - decision tree]
│
├── docs/
│   ├── T4-MIGRATION-DECISIONS-ENGINE.md [THIS FILE]
│   └── T4-QUICK-START.md [NEW]
│
└── reports/
    └── templates/
        └── migration-decision-template.html [NEW]
```

---

## 🎯 Success Criteria (T4 Completion)

### Core Functionality
- ✅ Parse T1-T3 audit JSON
- ✅ Classify workload type with >80% accuracy
- ✅ Generate readiness score (0-100)
- ✅ Identify migration blockers
- ✅ Recommend 3+ destination options
- ✅ Calculate TCO per option
- ✅ Export JSON + CSV + HTML

### Testing
- ✅ Unit tests for scoring algorithms
- ✅ Integration test on sample audit data
- ✅ Real-world validation (5+ actual servers)
- ✅ Cost estimates within ±20% of real quotes

### Documentation
- ✅ This specification document
- ✅ Quick start guide (5 min to first recommendation)
- ✅ Algorithm documentation (scoring, decision tree)
- ✅ Worked examples (small, medium, large servers)

### Performance
- ✅ Analysis runs in <10 seconds per server
- ✅ HTML report generates in <5 seconds
- ✅ Can process 100+ servers in batch (<2 min)

---

## 📌 Implementation Order

```
Week 1-2: Core Engine
  Day 1-2:   Analyze-MigrationReadiness.ps1 (core logic)
  Day 3-4:   Workload classification engine
  Day 5:     Readiness scoring algorithm
  Day 6:     Migration blocker identification
  Day 7:     Destination recommendation logic
  Day 8:     TCO calculation module
  Day 9-10:  Integration testing + refinement

Week 3: Integration & Reporting
  Day 1-2:   Invoke-MigrationDecisions.ps1 orchestrator
  Day 3-4:   New-MigrationReport.ps1 (HTML/CSV)
  Day 5:     Metadata registration
  Day 6-7:   E2E testing

Week 4+: Advanced Features (Backlog)
  - Dependency mapping
  - Cost modeling refinements
  - Link remediation automation
  - Dashboard visualization
```

---

## 🚀 Next Steps

1. **Approve Specification** — Confirm scope and deliverables
2. **Create Branch** — `git checkout -b t4-migration-engine`
3. **Begin Implementation** — Start with Analyze-MigrationReadiness.ps1
4. **Parallel Testing** — Sample audit data for validation
5. **Weekly Syncs** — Review progress, adjust scope as needed
6. **T3 PR Merge** — Ensure T3 code is merged to `main` before T4 development

---

## 💭 Design Decisions & Rationale

### Why Analyze After Audit, Not During?

**Benefit**: Separates concerns (data collection vs. analysis)
- **Faster audits**: Collectors don't need to do analysis
- **Flexible analysis**: Can re-analyze with new algorithms without re-auditing
- **Batch processing**: Analyze 100 servers without re-scanning
- **Offline analysis**: Air-gapped environments can analyze later

### Why 3+ Destination Options?

**Benefit**: Stakeholders make informed decisions
- **Cloud-first**: Recommend Azure VM (cost vs. effort trade-off)
- **PaaS alternative**: Show App Service if web-only (more modern)
- **On-prem option**: Extend support without cloud (for risk-averse shops)
- **Cost comparison**: Let CFO see TCO differences

### Why Mine Document Links into Remediation Plan?

**Benefit**: Turns risk data into actionable fixes
- **Hardcoded paths**: Specific files and line counts
- **Automated scripts**: PowerShell remediation scripts generated
- **Validation**: Before/after link checking
- **Timeline**: Estimate remediation effort accurately

---

## 📞 Questions & Open Items

- [ ] Should we include AWS/GCP pricing, or Azure-only for MVP?
- [ ] What labor hourly rate to assume in TCO? (Configurable?)
- [ ] Should remediation plans include automation scripts or just guidance?
- [ ] How to handle servers with no clear workload type? (Default: "Unknown")
- [ ] Should regional recommendations account for data residency? (Yes)

---

**Ready to start implementation?** Proceed to Phase 1 or discuss any design questions above.
