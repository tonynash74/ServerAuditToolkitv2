# T5 Phase 2 Quick Reference Guide

**Purpose**: Help developers quickly understand Phase 1 output format and prepare for Phase 2 implementation.

---

## Phase 1 Output Format (Decision JSON)

### Structure Overview

```powershell
$decision = @{
    # Metadata
    analyzeId = "analyze-2024-12-19-SERVER01-5432"
    timestamp = "2024-12-19T15:30:45.1234567Z"
    
    # Source server info
    sourceServer = @{
        name = "SERVER01"
        os = "Windows Server 2019"
        powerShellVersion = "5.1"
    }
    
    # Phase 1 Results
    workloadClassification = @{...}
    readinessScore = @{...}
    migrationOptions = @[...]
    remediationPlan = @{...}
    timeline = @{...}
    blockers = @[...]
}
```

---

## Field Reference

### workloadClassification
```powershell
@{
    primaryType = "Web Server" | "Database" | "Domain Controller" | "File Server" | "Print Server" | "Mail Server" | "Virtualization" | "Custom"
    estimatedWorkloadSize = "Small" | "Medium" | "Large" | "Enterprise"
    serviceCount = 8
    keyApplications = @("IIS 10.0", "SQL Server 2019", "Custom App")
    confidence = 0.85  # 0-1
}
```

### readinessScore
```powershell
@{
    overall = 72  # 0-100
    components = @{
        serverHealth = 85      # OS compat, patches, stability
        appCompatibility = 65  # Cloud-native readiness
        dataReadiness = 75     # Backup, encryption, size
        networkReadiness = 70  # Latency, bandwidth
        compliance = 60        # Security baselines, audit
    }
    assessment = "Ready with remediation"  # Ready | Needs Assessment | Risky | Not Recommended
}
```

### migrationOptions (Array of 3-5 items, ranked by confidence)
```powershell
@{
    destination = "Standard_D2s_v3"  # VM size or service name
    platform = "Azure"  # Azure | AWS | GCP | On-Premises | Hybrid
    type = "IaaS" | "PaaS" | "Hybrid" | "On-Premises"
    
    confidence = 0.92  # 0-1, how well workload fits
    complexity = "LOW" | "MEDIUM" | "HIGH"  # Implementation complexity
    
    justification = "Strong server-based workload fit..."
    
    estimatedTCO = @{
        computeMonthly = 96      # $/month
        storageMonthly = 20      # $/month
        networkMonthly = 10      # $/month
        licensingMonthly = 0     # $/month
        laborEstimateHours = 40  # Hours to migrate
        laborEstimateCost = 5000 # $ (hours * $125/hour)
        totalFirstYearCost = 6370  # KEY DECISION METRIC
    }
    
    risks = @("Database compatibility", "...")
    opportunities = @("Cost savings", "...")
}
```

### remediationPlan
```powershell
@{
    critical = @(
        @{
            issue = "Expiring SSL/TLS Certificates"
            count = 2
            description = "..."
            recommendation = "..."
            effortHours = 4
            timeline = "Immediate"
            risk = "Application downtime"
        }
    )
    
    important = @(
        @{
            issue = "Share Migration Planning"
            shareCount = 3
            totalSizeGB = 450
            effortHours = 12
            timeline = "During migration window"
        }
    )
    
    nice_to_have = @(
        @{
            issue = "Registry Cleanup"
            effortHours = 4
            timeline = "Post-migration"
            risk = "None"
        }
    )
}
```

### timeline
```powershell
@{
    assessmentPhase = @{
        duration = "1 week"
        description = "Audit analysis and planning"
    }
    planningPhase = @{
        duration = "2 weeks"
        description = "Architecture design, resource allocation"
    }
    remediationPhase = @{
        duration = "4 weeks"  # Adjusted from baseline 2 weeks
        description = "Fix compliance gaps"
        adjustedFrom = 2
        reason = "High blocker count requires extended remediation"
    }
    migrationPhase = @{
        duration = "1.5 weeks"  # Adjusted from baseline 1 week
        description = "Workload cutover"
        adjustedFrom = 1
        reason = "High complexity"
    }
    validationPhase = @{
        duration = "2 weeks"
        description = "Testing and sign-off"
    }
    decommissionPhase = @{
        duration = "4 weeks"
        description = "Archival and shutdown"
    }
    
    summary = @{
        totalWeeks = 14
        totalMonths = 3.2
        readinessDate = "2025-03-19"  # Now + totalWeeks
        criticality = "MEDIUM - Standard timeline"
    }
}
```

### blockers (Array)
```powershell
@(
    @{
        blocker = "Unsupported OS"
        severity = "CRITICAL"  # CRITICAL | HIGH | MEDIUM
        description = "Windows Server 2008 not supported in Azure"
        mitigation = "Upgrade to Windows Server 2016 or later"
        estimatedEffort = "40 hours"
    },
    @{
        blocker = "Perpetual License"
        severity = "HIGH"
        description = "Perpetual SQL Server license not portable to cloud"
        mitigation = "Negotiate license conversion or on-premises only"
        estimatedEffort = "Depends on vendor"
    }
)
```

---

## Phase 2 Implementation Checkpoints

### Checkpoint 1: Destination Decision
**Input**: `migrationOptions` array  
**Output**: Single recommended destination + 2 alternates

**Questions to Answer**:
1. Which destination minimizes total cost of ownership?
2. Which destination meets organization's risk tolerance?
3. Which destination aligns with compliance requirements?
4. Are there budget or timeline constraints that eliminate options?

**Implementation**:
```powershell
function Invoke-DestinationDecision {
    param($migrationOptions, $orgConstraints)
    
    # 1. Score each option
    foreach ($option in $migrationOptions) {
        $score = (readiness * 0.35) + (cost_efficiency * 0.35) + (risk_inverse * 0.30)
    }
    
    # 2. Apply constraints (hard filters)
    $validOptions = $migrationOptions | Where-Object { 
        $_.totalFirstYearCost -le $orgConstraints.maxBudget -AND
        $timeline -le $orgConstraints.maxTimeline
    }
    
    # 3. Return highest-scoring option
    @{
        recommended = $validOptions | Sort-Object score -Descending | Select-Object -First 1
        alternates = $validOptions | Sort-Object score -Descending | Select-Object -First 2 -Skip 1
    }
}
```

---

### Checkpoint 2: Business Case
**Input**: Recommended destination + current state costs  
**Output**: 3-year TCO comparison with ROI/NPV

**Data Needed**:
- Current annual infrastructure costs (servers, licenses, support)
- Annual FTE costs (DBA, admin, support)
- Transition costs (migration labor, training, contingency)
- Cloud service costs (from destination TCO)

**Calculation Formula**:
```
Year 1: Current = $120K | Target = $85K | Transition = $35K
Year 1 Savings = $120K - $85K - $35K = $0

Year 2: Current = $120K | Target = $85K | Transition = $0
Year 2 Savings = $120K - $85K = $35K

Year 3: Current = $120K | Target = $85K | Transition = $0
Year 3 Savings = $120K - $85K = $35K

Total 3-Year Savings = $0 + $35K + $35K = $70K
NPV @ 10% discount = $0 + ($35K / 1.1) + ($35K / 1.1²) = $61K
ROI = Savings / Investment = $70K / $35K = 200%
Payback Period = Transition / Annual Savings = $35K / $35K = 1 year
```

---

### Checkpoint 3: Risk Assessment
**Input**: `readinessScore`, `complexity`, `blockers` count  
**Output**: Risk register with mitigation strategies

**Risk Scoring Formula**:
```
Risk Score = Probability × Impact (0-1 scale)

Probability based on:
  - Readiness score (lower = higher probability)
  - Complexity level
  - Blocker count

Impact based on:
  - Data loss = Very High
  - Performance degradation = High
  - Knowledge gap = Medium
  - Cost overrun = Medium
  - Timeline slippage = Medium

Mitigation Priority = Risk Score (descending)
```

---

### Checkpoint 4: Executive Summary
**Input**: All previous outputs  
**Output**: 1-page recommendation

**Template**:
```
EXECUTIVE SUMMARY: Migration Decision
=======================================

RECOMMENDATION
Migrate SERVER01 to Azure Standard_D2s_v3.
This option provides 35% cost savings ($35K/year), 
manages risk effectively, and aligns with cloud strategy.

BUSINESS IMPACT
- Year 1 Investment: $35K (labor + transition)
- Year 1 Net: $0 (offset by investment)
- Year 2-3: $35K/year savings
- 3-Year NPV: $61K
- Payback: 14 months

READINESS
- Overall Score: 72/100 (Ready with remediation)
- Gaps: Compliance (60/100) - Remediation: 12 hours
- Blockers: 0 (none prevent migration)
- Timeline: 14 weeks (4-6 weeks above baseline due to remediation)

RISKS (Top 3)
1. Database compatibility (MEDIUM) - Mitigate: Extended testing
2. Timeline pressure (MEDIUM) - Mitigate: Parallel execution
3. Compliance gaps (LOW) - Mitigate: Azure Policy automation

NEXT STEPS
☐ Business stakeholder approval
☐ IT infrastructure sign-off
☐ Security/compliance review
→ Once approved: Detailed migration plan (Phase 2 output)
```

---

### Checkpoint 5: Migration Plan
**Input**: Recommendation + remediation plan + timeline  
**Output**: Week-by-week detailed plan with gates

**Structure**:
```
PHASE 1: ASSESSMENT & PLANNING (Weeks 1-2)
├─ Gate 1.1: Audit Validation (success criteria)
├─ Gate 1.2: Architecture Design (deliverable: diagram)
├─ Gate 1.3: Azure Subscription (deliverable: subscription ready)
└─ Gate 1.4: Team Mobilization (deliverable: trained team)

PHASE 2: REMEDIATION (Weeks 3-6)
├─ Week 3: Remediation Item 1 (SSL certs) - Owner: Security
├─ Week 4: Remediation Item 2 (Azure Policy) - Owner: Compliance
├─ Week 5-6: Remediation validation
└─ Gate 2.1: Remediation Complete (success: all items signed off)

PHASE 3: MIGRATION (Weeks 7-10)
├─ Week 7: Pre-cutover validation
├─ Week 8: Cutover window (Fri 10pm - Sun 6am)
├─ Week 9-10: Post-cutover validation
└─ Gate 3.1: Go/No-Go Decision (success: all tests pass)

PHASE 4: STABILIZATION (Weeks 11-14)
├─ Week 11: Performance optimization
├─ Week 12: Documentation & training
├─ Week 13: Monitoring setup
├─ Week 14: Decommission planning
└─ Gate 4.1: Production Sign-off (success: stable for 7 days)
```

---

## Development Workflow for Phase 2

### Week 1: Decision Optimization
1. **Read Phase 1 Output**: Understand Decision JSON structure
2. **Implement Invoke-DestinationDecision**: Score and rank
3. **Implement Evaluate-ConstraintCompliance**: Filter by org constraints
4. **Test with 5 sample scenarios**: Validate scoring logic
5. **Review with finance**: Confirm TCO assumptions

### Week 2: Business Case
1. **Implement Build-BusinessCase**: 3-year projection
2. **Create cost templates**: Current state, target state, transition
3. **Test with 10 scenarios**: Validate NPV/ROI calculations
4. **Validate against historical data**: Ensure accuracy ±20%
5. **Present to CFO**: Confirm model assumptions

### Week 3: Risk Assessment
1. **Implement Calculate-RiskMitigation**: Risk identification
2. **Create risk register template**: Categories, scoring, mitigation
3. **Test with blockers**: Ensure risk scores realistic
4. **Review with IT**: Confirm technical risks captured
5. **Review with security**: Confirm compliance risks captured

### Week 4: Executive Summary
1. **Implement New-ExecutiveSummary**: Structure data
2. **Create template**: 1-page format
3. **Implement Export-SummaryDocument**: PDF/HTML/DOCX
4. **Test rendering**: Validate formatting
5. **Review with marketing**: Refine presentation

### Week 5: Migration Plan
1. **Implement Build-DetailedMigrationPlan**: Phase structure
2. **Implement Build-RollingWaveSchedule**: Week-by-week timeline
3. **Implement Build-SuccessCriteria**: Gate definitions
4. **Test with complex scenario**: Multi-phase validation
5. **Review with project managers**: Confirm feasibility

### Week 6: Approval Workflow
1. **Implement Request-MigrationApproval**: Approval request
2. **Implement Track-ApprovalProgress**: Workflow tracking
3. **Implement Create-ApprovalAuditTrail**: Audit log
4. **Test approval flow**: End-to-end workflow
5. **Review with compliance**: Ensure audit requirements met

### Week 7-8: Integration & Testing
1. **End-to-end testing**: Phase 1 → Phase 2 flow
2. **Performance testing**: Process 50+ audit records
3. **User acceptance testing**: Stakeholder feedback
4. **Documentation**: Function help, examples, workflows
5. **Code review**: Quality and maintainability

---

## Common Gotchas & Solutions

### Gotcha 1: TCO Assumption Validation
**Problem**: Phase 2 business case uses TCO from Phase 1, but assumptions may not align with actual cloud pricing.

**Solution**:
- Validate Azure pricing monthly (it changes)
- Create regional price multipliers
- Compare Phase 1 estimates against actual cloud bills quarterly
- Adjust pricing assumptions if variance >10%

### Gotcha 2: Timeline Accuracy
**Problem**: Phase 1 timeline estimates are often optimistic.

**Solution**:
- Add 15% contingency buffer
- Track actual vs. estimated on every migration
- Adjust baseline estimates based on historical data
- Consider team experience and availability

### Gotcha 3: Risk Underestimation
**Problem**: Phase 1 identifies technical risks but misses organizational risks.

**Solution**:
- Interview stakeholders during Phase 2
- Add operational risks (staffing, knowledge gaps)
- Add financial risks (budget constraints)
- Add compliance risks (audit readiness)

### Gotcha 4: Constraint Conflicts
**Problem**: Multiple constraints make recommendation impossible (e.g., low budget + low timeline + high compliance).

**Solution**:
- Explicitly document constraint conflicts
- Recommend prioritization (which constraint to relax?)
- Offer trade-off analysis (cost vs. timeline)
- Escalate to stakeholders for decision

---

## Phase 2 Success Checklist

Before shipping Phase 2:

- [ ] All 10 functions implemented and unit tested
- [ ] End-to-end workflow tested with 10+ scenarios
- [ ] Executive summary reviewed by stakeholders
- [ ] Migration plan validated by project managers
- [ ] Risk register reviewed by security/compliance
- [ ] Business case validated against historical data
- [ ] Approval workflow tested with real approvers
- [ ] Code documented with examples
- [ ] Performance tested with 50+ records
- [ ] User acceptance testing complete

---

## Phase 2 to Phase 3 Handoff

Once Phase 2 is complete and approved:

1. **Archive Decision JSON**: Save all Phase 2 outputs with timestamps
2. **Create Project Record**: In Phase 3 execution system
3. **Assign Phase 3 Team**: Who will execute the migration?
4. **Notify Phase 3 PM**: Migration approval ready for execution
5. **Schedule Phase 3 Kickoff**: Week after Phase 2 approval

Phase 3 will consume Phase 2 outputs and orchestrate execution.

---

**Ready to implement Phase 2?** Start with the "Development Workflow" section above.  
**Questions?** Review `T5-PHASE-2-PLAN.md` for detailed specifications.
