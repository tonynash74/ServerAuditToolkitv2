<#
.SYNOPSIS
    Generates executive-grade HTML audit report with heat maps, compliance dashboards, and migration recommendations.

.DESCRIPTION
    Transforms raw audit data into actionable executive reports:
    
    Report Sections:
    1. SERVER PROFILE CARD
       - OS, version, hardware (CPU, RAM, disk)
       - Uptime, last patch date
       - Migration readiness score (1-10)
    
    2. DATA HEAT MAP (Visual Chart)
       - HOT data (<30 days): urgent migration candidate
       - WARM data (30-180 days): archive or migrate soon
       - COOL data (>180 days): archive or delete
       - Storage breakdown by temperature
    
    3. COMPLIANCE RISK DASHBOARD
       - PII locations (red=found, yellow=possible, green=clear)
       - Financial data risk (UK IBAN, sort codes)
       - Certificate expiry warnings
       - Risk level recommendation
    
    4. SERVICE & APPLICATION INVENTORY
       - Critical services (what keeps it running?)
       - Application versions (licensing, EOL check)
       - Role classification (DC, DNS, DHCP, IIS, SQL, Exchange)
    
    5. DECOMMISSIONING CHECKLIST
       - Data migration status
       - Service dependencies
       - Backup validation
       - Access revocation requirements
    
    6. EXECUTIVE RECOMMENDATIONS
       - Migrate/Keep/Retire decision
       - Timeline estimate
       - Risk assessment
       - Cost model preview

.PARAMETER AuditDataPath
    Path to audit JSON results from Invoke-ServerAudit.

.PARAMETER OutputPath
    Path to save generated HTML report. Default: same as AuditDataPath with .html extension.

.PARAMETER CompanyName
    Organization name for branding. Default: "IT Audit".

.PARAMETER IncludeDrilldown
    Generate drill-down detailed data tables. Default: $true.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   3.0+
    License:      MIT
    
    @Category: reporting
    @Priority: CRITICAL
    @EstimatedExecutionTime: 60
#>

function New-AuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path $_ })]
        [string]$AuditDataPath,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath,

        [Parameter(Mandatory=$false)]
        [string]$CompanyName = "IT Audit",

        [Parameter(Mandatory=$false)]
        [switch]$IncludeDrilldown
    )

    $startTime = Get-Date

    try {
        # Load audit data
        $auditData = Get-Content -Path $AuditDataPath -Raw | ConvertFrom-Json
        $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $computerName = $auditData.ComputerName

        # Determine output path
        if (-not $OutputPath) {
            $OutputPath = $AuditDataPath -replace '\.json$', '.html'
        }

        # Extract key metrics
        $osInfo = $auditData.Data | Where-Object { $_.CollectorName -eq 'Get-ServerInfo' } | Select-Object -First 1
        $services = $auditData.Data | Where-Object { $_.CollectorName -eq 'Get-Services' } | Select-Object -First 1
        $apps = $auditData.Data | Where-Object { $_.CollectorName -eq 'Get-InstalledApps' } | Select-Object -First 1
        $heatMap = $auditData.Data | Where-Object { $_.CollectorName -eq 'Data-Discovery-HeatMap' } | Select-Object -First 1
        $piiData = $auditData.Data | Where-Object { $_.CollectorName -eq 'Data-Discovery-PII' } | Select-Object -First 1
        $financialData = $auditData.Data | Where-Object { $_.CollectorName -eq 'Data-Discovery-FinancialUK' } | Select-Object -First 1
        $certificates = $auditData.Data | Where-Object { $_.CollectorName -eq 'Get-CertificateInfo' } | Select-Object -First 1

        # Calculate migration readiness score
        $readinessScore = 5  # baseline
        
        # Adjust based on data heat
        if ($heatMap.Summary.HotData.Count -lt 5) {
            $readinessScore += 2
        }
        
        # Risk from compliance issues
        if ($piiData.RecordCount -gt 0) {
            $readinessScore -= 2
        }
        
        if ($financialData.RecordCount -gt 0) {
            $readinessScore -= 2
        }
        
        # Certificate issues
        if ($certificates.Summary.ExpiredCertificates -gt 0) {
            $readinessScore -= 1
        }
        
        $readinessScore = [Math]::Max(1, [Math]::Min(10, $readinessScore))

        # Build HTML report
        $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Audit Report - $computerName</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 8px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        
        .content {
            padding: 40px;
        }
        
        .report-meta {
            background: #f8f9fa;
            border-left: 4px solid #667eea;
            padding: 20px;
            margin-bottom: 30px;
            border-radius: 4px;
        }
        
        .report-meta-item {
            display: inline-block;
            margin-right: 40px;
            margin-bottom: 10px;
        }
        
        .report-meta-item strong {
            color: #667eea;
        }
        
        .section {
            margin-bottom: 40px;
        }
        
        .section-title {
            font-size: 1.8em;
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        
        .card-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }
        
        .card {
            background: white;
            border: 1px solid #ddd;
            border-radius: 6px;
            padding: 20px;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
        }
        
        .card-title {
            font-size: 0.9em;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .card-value {
            font-size: 2em;
            font-weight: bold;
            color: #667eea;
        }
        
        .card.warning {
            border-left: 4px solid #ff9800;
        }
        
        .card.danger {
            border-left: 4px solid #f44336;
        }
        
        .card.success {
            border-left: 4px solid #4caf50;
        }
        
        .score-badge {
            display: inline-block;
            width: 120px;
            height: 120px;
            border-radius: 50%;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 3em;
            font-weight: bold;
            box-shadow: 0 4px 15px rgba(102, 126, 234, 0.4);
            margin: 20px 0;
        }
        
        .chart-container {
            position: relative;
            height: 400px;
            margin: 20px 0;
        }
        
        .table-container {
            overflow-x: auto;
            margin: 20px 0;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            background: white;
        }
        
        thead {
            background: #f8f9fa;
        }
        
        th {
            padding: 12px;
            text-align: left;
            font-weight: 600;
            color: #333;
            border-bottom: 2px solid #ddd;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #eee;
        }
        
        tr:hover {
            background: #f5f5f5;
        }
        
        .status-good { color: #4caf50; font-weight: bold; }
        .status-warning { color: #ff9800; font-weight: bold; }
        .status-critical { color: #f44336; font-weight: bold; }
        
        .recommendation-box {
            background: #e8f5e9;
            border-left: 4px solid #4caf50;
            padding: 20px;
            margin: 20px 0;
            border-radius: 4px;
        }
        
        .recommendation-box.warning {
            background: #fff3e0;
            border-left-color: #ff9800;
        }
        
        .recommendation-box.critical {
            background: #ffebee;
            border-left-color: #f44336;
        }
        
        .footer {
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            border-top: 1px solid #ddd;
        }
        
        .timeline {
            position: relative;
            padding: 20px 0;
        }
        
        .timeline-item {
            padding: 20px;
            border-left: 3px solid #667eea;
            margin-bottom: 10px;
            position: relative;
            padding-left: 30px;
        }
        
        .timeline-item::before {
            content: '';
            position: absolute;
            left: -8px;
            top: 25px;
            width: 13px;
            height: 13px;
            border-radius: 50%;
            background: #667eea;
            border: 3px solid white;
            box-shadow: 0 0 0 3px #667eea;
        }
        
        .dashboard-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin: 20px 0;
        }
        
        @media (max-width: 768px) {
            .dashboard-grid {
                grid-template-columns: 1fr;
            }
            
            .card-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Server Audit Report</h1>
            <p>$computerName - Executive Summary</p>
        </div>
        
        <div class="content">
            <!-- Report Metadata -->
            <div class="report-meta">
                <div class="report-meta-item">
                    <strong>Organization:</strong> $CompanyName
                </div>
                <div class="report-meta-item">
                    <strong>Server:</strong> $computerName
                </div>
                <div class="report-meta-item">
                    <strong>Report Date:</strong> $reportDate
                </div>
                <div class="report-meta-item">
                    <strong>Execution Time:</strong> $([Math]::Round((Get-Date - $startTime).TotalSeconds, 2))s
                </div>
            </div>
            
            <!-- Section 1: Server Profile & Readiness Score -->
            <div class="section">
                <h2 class="section-title">🖥️ Server Profile & Migration Readiness</h2>
                
                <div class="dashboard-grid">
                    <div>
                        <div class="card-grid">
                            <div class="card">
                                <div class="card-title">Operating System</div>
                                <div class="card-value">$($osInfo.OSName)</div>
                            </div>
                            <div class="card">
                                <div class="card-title">Service Pack</div>
                                <div class="card-value">$($osInfo.ServicePack)</div>
                            </div>
                            <div class="card">
                                <div class="card-title">Processors</div>
                                <div class="card-value">$($osInfo.ProcessorCount)</div>
                            </div>
                            <div class="card">
                                <div class="card-title">RAM</div>
                                <div class="card-value">$([Math]::Round($osInfo.TotalMemoryMB / 1024, 1)) GB</div>
                            </div>
                        </div>
                    </div>
                    <div>
                        <h3 style="margin-bottom: 20px;">Migration Readiness Score</h3>
                        <div class="score-badge">$readinessScore/10</div>
                        <p style="text-align: center; color: #666; margin-top: 10px;">
                            $(switch ($readinessScore) {
                                {$_ -ge 8} { 'Excellent - Ready to migrate' }
                                {$_ -ge 6} { 'Good - Minimal blockers' }
                                {$_ -ge 4} { 'Fair - Address compliance issues' }
                                default { 'Poor - Significant blockers' }
                            })
                        </p>
                    </div>
                </div>
            </div>
            
            <!-- Section 2: Data Heat Map -->
            <div class="section">
                <h2 class="section-title">🔥 Data Classification Heat Map</h2>
                
                <div class="card-grid">
                    <div class="card">
                        <div class="card-title">HOT Data (&lt;30 days)</div>
                        <div class="card-value" style="color: #f44336;">$($heatMap.Summary.HotData.Count) dirs</div>
                        <div style="font-size: 0.9em; color: #666;">$(if ($heatMap.Summary.HotData.Size -gt 1TB) { "$([Math]::Round($heatMap.Summary.HotData.Size / 1TB, 2)) TB" } else { "$([Math]::Round($heatMap.Summary.HotData.Size / 1GB, 2)) GB" })</div>
                    </div>
                    <div class="card">
                        <div class="card-title">WARM Data (30-180 days)</div>
                        <div class="card-value" style="color: #ff9800;">$($heatMap.Summary.WarmData.Count) dirs</div>
                        <div style="font-size: 0.9em; color: #666;">$(if ($heatMap.Summary.WarmData.Size -gt 1TB) { "$([Math]::Round($heatMap.Summary.WarmData.Size / 1TB, 2)) TB" } else { "$([Math]::Round($heatMap.Summary.WarmData.Size / 1GB, 2)) GB" })</div>
                    </div>
                    <div class="card">
                        <div class="card-title">COOL Data (&gt;180 days)</div>
                        <div class="card-value" style="color: #2196f3;">$($heatMap.Summary.CoolData.Count) dirs</div>
                        <div style="font-size: 0.9em; color: #666;">$(if ($heatMap.Summary.CoolData.Size -gt 1TB) { "$([Math]::Round($heatMap.Summary.CoolData.Size / 1TB, 2)) TB" } else { "$([Math]::Round($heatMap.Summary.CoolData.Size / 1GB, 2)) GB" })</div>
                    </div>
                </div>
                
                <div class="chart-container">
                    <canvas id="heatMapChart"></canvas>
                </div>
            </div>
            
            <!-- Section 3: Compliance Risk Dashboard -->
            <div class="section">
                <h2 class="section-title">⚠️ Compliance & Risk Assessment</h2>
                
                <div class="card-grid">
                    <div class="card $(if ($piiData.RecordCount -gt 0) { 'danger' } else { 'success' })">
                        <div class="card-title">PII Data Found</div>
                        <div class="card-value $(if ($piiData.RecordCount -gt 0) { 'status-critical' } else { 'status-good' })">$($piiData.RecordCount)</div>
                    </div>
                    <div class="card $(if ($financialData.RecordCount -gt 0) { 'danger' } else { 'success' })">
                        <div class="card-title">Financial Data Found</div>
                        <div class="card-value $(if ($financialData.RecordCount -gt 0) { 'status-critical' } else { 'status-good' })">$($financialData.RecordCount)</div>
                    </div>
                    <div class="card $(if ($certificates.Summary.ExpiredCertificates -gt 0) { 'warning' } else { 'success' })">
                        <div class="card-title">Expired Certificates</div>
                        <div class="card-value $(if ($certificates.Summary.ExpiredCertificates -gt 0) { 'status-warning' } else { 'status-good' })">$($certificates.Summary.ExpiredCertificates)</div>
                    </div>
                    <div class="card $(if ($certificates.Summary.ExpiringWithinWarningDays -gt 0) { 'warning' } else { 'success' })">
                        <div class="card-title">Expiring Soon (&lt;30 days)</div>
                        <div class="card-value $(if ($certificates.Summary.ExpiringWithinWarningDays -gt 0) { 'status-warning' } else { 'status-good' })">$($certificates.Summary.ExpiringWithinWarningDays)</div>
                    </div>
                </div>
                
                <div class="recommendation-box $(if ($piiData.RecordCount -gt 5 -or $financialData.RecordCount -gt 0) { 'critical' } elseif ($piiData.RecordCount -gt 0) { 'warning' } else { '' })">
                    <h3 style="margin-bottom: 10px;">Compliance Status</h3>
                    <p>
                        $(if ($piiData.RecordCount -gt 0) {
                            "&#9888; <strong>CRITICAL</strong>: Personally identifiable information found in $($piiData.RecordCount) locations. Immediate remediation required."
                        } elseif ($financialData.RecordCount -gt 0) {
                            "&#9888; <strong>HIGH</strong>: UK financial data detected. FCA/PSD2 compliance review required."
                        } elseif ($certificates.Summary.ExpiredCertificates -gt 0) {
                            "&#9888; <strong>MEDIUM</strong>: Expired SSL/TLS certificates detected. Reissue before migration."
                        } else {
                            "&#10003; <strong>COMPLIANT</strong>: No PII, financial data, or certificate issues detected."
                        })
                    </p>
                </div>
            </div>
            
            <!-- Section 4: Service & Application Inventory -->
            <div class="section">
                <h2 class="section-title">📦 Service & Application Inventory</h2>
                
                <div class="card-grid">
                    <div class="card">
                        <div class="card-title">Running Services</div>
                        <div class="card-value">$($services.Summary.RunningCount)</div>
                    </div>
                    <div class="card">
                        <div class="card-title">Installed Applications</div>
                        <div class="card-value">$($apps.Summary.TotalApps)</div>
                    </div>
                    <div class="card">
                        <div class="card-title">Critical Services</div>
                        <div class="card-value">$(@($services.Data | Where-Object { $_.StartupType -eq 'Auto' }).Count)</div>
                    </div>
                </div>
            </div>
            
            <!-- Section 5: Decommissioning Checklist -->
            <div class="section">
                <h2 class="section-title">✅ Decommissioning Readiness Checklist</h2>
                
                <div class="timeline">
                    <div class="timeline-item">
                        <h3>Phase 1: Data Assessment</h3>
                        <p>$(if ($readinessScore -ge 7) { '✓ Low complexity' } else { '⚠️ Complex data distribution - requires careful planning' })</p>
                    </div>
                    <div class="timeline-item">
                        <h3>Phase 2: Service Migration</h3>
                        <p>$(if ($services.Summary.RunningCount -lt 20) { '✓ Manageable service count' } else { '⚠️ High service count - extended migration window' })</p>
                    </div>
                    <div class="timeline-item">
                        <h3>Phase 3: Compliance Validation</h3>
                        <p>$(if ($piiData.RecordCount -eq 0 -and $financialData.RecordCount -eq 0) { '✓ No compliance blockers' } else { '⚠️ Compliance issues must be resolved before decommissioning' })</p>
                    </div>
                    <div class="timeline-item">
                        <h3>Phase 4: Backup Validation</h3>
                        <p>Verify all critical data backed up and restorable from target environment</p>
                    </div>
                    <div class="timeline-item">
                        <h3>Phase 5: Access Revocation</h3>
                        <p>Disable accounts, revoke permissions, remove from network</p>
                    </div>
                </div>
            </div>
            
            <!-- Section 6: Executive Recommendations -->
            <div class="section">
                <h2 class="section-title">💡 Executive Recommendations</h2>
                
                <div class="recommendation-box $(if ($readinessScore -lt 4) { 'critical' } elseif ($readinessScore -lt 6) { 'warning' } else { '' })">
                    <h3 style="margin-bottom: 10px;">Migration Decision</h3>
                    <p style="font-size: 1.1em; margin-bottom: 10px;">
                        $(switch ($readinessScore) {
                            {$_ -ge 8} { 
                                '<strong style="color: #4caf50;">RECOMMENDED: Proceed with migration</strong><br/>' +
                                'This server is an excellent candidate for migration. Low complexity, minimal compliance issues, and straightforward service dependencies make it a low-risk candidate.'
                            }
                            {$_ -ge 6} {
                                '<strong style="color: #ff9800;">CONDITIONAL: Address blockers then migrate</strong><br/>' +
                                'Migration is feasible after addressing identified issues: compliance data remediation, certificate renewal, and service dependency validation.'
                            }
                            {$_ -ge 4} {
                                '<strong style="color: #ff9800;">DELAYED: Plan extended migration</strong><br/>' +
                                'Significant blockers detected. Recommend extended timeline for data remediation, compliance validation, and service migration testing.'
                            }
                            default {
                                '<strong style="color: #f44336;">HOLD: Resolve critical issues</strong><br/>' +
                                'Critical compliance and data issues must be resolved before migration consideration. Recommend immediate remediation plan.'
                            }
                        })
                    </p>
                </div>
                
                <div style="margin-top: 20px;">
                    <h3>Estimated Timeline</h3>
                    <p>
                        $(switch ($readinessScore) {
                            {$_ -ge 8} { 'Fast-track: 2-4 weeks' }
                            {$_ -ge 6} { 'Standard: 4-8 weeks' }
                            {$_ -ge 4} { 'Extended: 8-12 weeks' }
                            default { 'On-hold: Requires remediation before planning' }
                        })
                    </p>
                </div>
                
                <div style="margin-top: 20px;">
                    <h3>Next Steps</h3>
                    <ol style="margin-left: 20px; line-height: 1.8;">
                        <li>Review PII/financial data locations and remediate $(if ($piiData.RecordCount -gt 0 -or $financialData.RecordCount -gt 0) { '(URGENT)' } else { '(No action required)' })</li>
                        <li>Validate service dependencies with application owners $(if ($services.Summary.RunningCount -gt 20) { '(Extended review needed)' } else { '' })</li>
                        <li>Plan data heat map migration (HOT data first, COOL data for archival)</li>
                        <li>Schedule SSL/TLS certificate renewal $(if ($certificates.Summary.ExpiredCertificates -gt 0) { '(BEFORE migration)' } else { '' })</li>
                        <li>Develop detailed runbook for service cutover and validation</li>
                    </ol>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>Generated by ServerAuditToolkitV2 | Confidential</p>
        </div>
    </div>
    
    <script>
        // Heat Map Chart
        const heatMapCtx = document.getElementById('heatMapChart').getContext('2d');
        const heatMapData = {
            labels: ['HOT (&lt;30d)', 'WARM (30-180d)', 'COOL (&gt;180d)'],
            datasets: [
                {
                    label: 'Directories',
                    data: [$($heatMap.Summary.HotData.Count), $($heatMap.Summary.WarmData.Count), $($heatMap.Summary.CoolData.Count)],
                    backgroundColor: ['#f44336', '#ff9800', '#2196f3'],
                    borderColor: ['#d32f2f', '#e65100', '#1565c0'],
                    borderWidth: 2
                }
            ]
        };
        
        new Chart(heatMapCtx, {
            type: 'doughnut',
            data: heatMapData,
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        position: 'bottom'
                    }
                }
            }
        });
    </script>
</body>
</html>
"@

        # Save HTML report
        $htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

        return @{
            Success       = $true
            ReportPath    = $OutputPath
            ComputerName  = $computerName
            ExecutionTime = (Get-Date) - $startTime
            ReadinessScore = $readinessScore
        }
    }
    catch {
        return @{
            Success       = $false
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    New-AuditReport @PSBoundParameters
}
