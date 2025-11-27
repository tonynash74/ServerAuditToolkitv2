<#
.SYNOPSIS
    M-014: Health Diagnostics & Self-Healing
    Automated issue detection, diagnostics, and remediation suggestions.

.DESCRIPTION
    Provides comprehensive health diagnostics across audit infrastructure and suggests
    automated remediation strategies. Analyzes audit results, logs, and performance data
    to identify patterns and provide self-healing recommendations.

.NOTES
    Integrates with M-001 (Logging), M-005 (Profiling), M-009 (Resources), M-011 (Errors).
#>

function New-AuditHealthDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [object]$AuditResults,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = 'audit_results/logs',

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = 'audit_results/diagnostics',

        [Parameter(Mandatory=$false)]
        [switch]$GenerateHTML = $true,

        [Parameter(Mandatory=$false)]
        [switch]$ApplyAutoRemediation = $false
    )

    begin {
        $diagnostics = @{
            GeneratedAt         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            SessionId           = $null
            HealthScore         = 0
            IssuesDetected      = 0
            CriticalIssues      = 0
            Warnings            = 0
            Recommendations     = @()
            AutoRemediations    = @()
            PerformanceIssues   = @()
            ResourceIssues      = @()
            ConnectivityIssues  = @()
            ConfigurationIssues = @()
            Files               = @()
        }

        if (-not (Test-Path -LiteralPath $OutputPath)) {
            [void](New-Item -ItemType Directory -Path $OutputPath -Force)
        }
    }

    process {
        try {
            $diagnostics.SessionId = $AuditResults.SessionId

            # ====== STAGE 1: ANALYZE PERFORMANCE ======
            Write-Verbose "Analyzing performance metrics..."
            $perfIssues = Get-PerformanceIssues -AuditResults $AuditResults
            $diagnostics.PerformanceIssues = $perfIssues
            $diagnostics.IssuesDetected += $perfIssues.Count

            # ====== STAGE 2: ANALYZE RESOURCES ======
            Write-Verbose "Analyzing resource utilization..."
            $resourceIssues = Get-ResourceUtilizationIssues -AuditResults $AuditResults
            $diagnostics.ResourceIssues = $resourceIssues
            $diagnostics.IssuesDetected += $resourceIssues.Count

            # ====== STAGE 3: ANALYZE CONNECTIVITY ======
            Write-Verbose "Analyzing connectivity patterns..."
            $connIssues = Get-ConnectivityIssues -AuditResults $AuditResults
            $diagnostics.ConnectivityIssues = $connIssues
            $diagnostics.IssuesDetected += $connIssues.Count

            # ====== STAGE 4: ANALYZE CONFIGURATION ======
            Write-Verbose "Analyzing configuration..."
            $configIssues = Get-ConfigurationIssues -AuditResults $AuditResults
            $diagnostics.ConfigurationIssues = $configIssues
            $diagnostics.IssuesDetected += $configIssues.Count

            # ====== STAGE 5: GENERATE RECOMMENDATIONS ======
            Write-Verbose "Generating recommendations..."
            $recommendations = Get-HealthRecommendations `
                -PerformanceIssues $perfIssues `
                -ResourceIssues $resourceIssues `
                -ConnectivityIssues $connIssues `
                -ConfigurationIssues $configIssues

            $diagnostics.Recommendations = $recommendations
            $diagnostics.CriticalIssues = @($recommendations | Where-Object { $_.Severity -eq 'Critical' }).Count
            $diagnostics.Warnings = @($recommendations | Where-Object { $_.Severity -eq 'Warning' }).Count

            # ====== STAGE 6: CALCULATE HEALTH SCORE ======
            Write-Verbose "Calculating health score..."
            $diagnostics.HealthScore = Get-HealthScore `
                -CriticalIssues $diagnostics.CriticalIssues `
                -Warnings $diagnostics.Warnings `
                -TotalServers $AuditResults.Summary.TotalServers `
                -SuccessRate $AuditResults.Summary.SuccessfulServers / $AuditResults.Summary.TotalServers

            # ====== STAGE 7: GENERATE AUTO-REMEDIATION ======
            if ($ApplyAutoRemediation) {
                Write-Verbose "Generating auto-remediation scripts..."
                $diagnostics.AutoRemediations = Get-AutoRemediationScripts -Recommendations $recommendations
            }

            # ====== STAGE 8: EXPORT RESULTS ======
            Write-Verbose "Exporting diagnostics..."
            $jsonPath = Join-Path -Path $OutputPath -ChildPath "diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $diagnostics | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $jsonPath -Encoding UTF8 -Force
            $diagnostics.Files += $jsonPath

            if ($GenerateHTML) {
                $htmlPath = Join-Path -Path $OutputPath -ChildPath "health_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
                $htmlContent = New-HealthDiagnosticsHTML -Diagnostics $diagnostics
                $htmlContent | Out-File -LiteralPath $htmlPath -Encoding UTF8 -Force
                $diagnostics.Files += $htmlPath
            }

            return $diagnostics

        } catch {
            Write-Error "Health diagnostics generation failed: $_"
            throw
        }
    }
}

function Get-PerformanceIssues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$AuditResults
    )

    $issues = @()

    # Check average execution time
    $avgTime = $AuditResults.Summary.AverageFetchTimeSeconds
    if ($avgTime -gt 300) {
        $issues += @{
            Type        = 'Performance'
            Severity    = 'Warning'
            Issue       = "High average execution time: ${avgTime}s per server"
            Description = "Servers are taking longer than expected to audit"
            RootCauses  = @('Slow network', 'Overloaded servers', 'Slow collectors')
        }
    }

    # Check for timeout issues
    $timeoutCount = ($AuditResults.Servers | 
        ForEach-Object { $_.Collectors | Where-Object { $_.ExecutionTime -gt 60 } } | 
        Measure-Object).Count

    if ($timeoutCount -gt 0) {
        $issues += @{
            Type        = 'Performance'
            Severity    = 'Warning'
            Issue       = "High timeout count: $timeoutCount collectors exceeded 60s"
            Description = "Some collectors are running past acceptable timeouts"
            RootCauses  = @('Slow collector logic', 'WMI issues', 'Network latency')
        }
    }

    # Check for slow collectors
    $slowCollectors = $AuditResults.Servers | 
        ForEach-Object { $_.Collectors } | 
        Group-Object -Property Name | 
        Where-Object { ($_.Group | Measure-Object -Property ExecutionTime -Average).Average -gt 30 }

    foreach ($collector in $slowCollectors) {
        $issues += @{
            Type        = 'Performance'
            Severity    = 'Informational'
            Issue       = "Slow collector: $($collector.Name)"
            Description = "This collector consistently runs slow"
            RootCauses  = @('Complex queries', 'WMI performance', 'Network overhead')
        }
    }

    return $issues
}

function Get-ResourceUtilizationIssues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$AuditResults
    )

    $issues = @()

    # Check for memory pressure
    $failureRate = 1 - ($AuditResults.Summary.SuccessfulServers / $AuditResults.Summary.TotalServers)
    if ($failureRate -gt 0.2) {
        $issues += @{
            Type        = 'Resources'
            Severity    = 'Critical'
            Issue       = "High failure rate: $([Math]::Round($failureRate * 100, 1))% servers failed"
            Description = "More than 20% of servers failed audit"
            RootCauses  = @('Insufficient memory', 'CPU throttling', 'Network issues')
        }
    }

    # Check parallelism usage
    $totalCollectors = $AuditResults.Summary.TotalCollectorsExecuted
    $totalTime = $AuditResults.Summary.DurationSeconds
    $estimatedSequential = $totalCollectors * ($AuditResults.Summary.AverageFetchTimeSeconds / 1)

    if ($estimatedSequential -gt ($totalTime * 2)) {
        $issues += @{
            Type        = 'Resources'
            Severity    = 'Informational'
            Issue       = "Parallelism could be increased"
            Description = "Audit is not fully utilizing available parallelism"
            RootCauses  = @('Conservative parallelism settings', 'Resource constraints')
        }
    }

    return $issues
}

function Get-ConnectivityIssues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$AuditResults
    )

    $issues = @()

    # Analyze failed servers
    $failedServers = @($AuditResults.Servers | Where-Object { -not $_.Success })
    
    if ($failedServers.Count -gt 0) {
        $connectionErrors = @($failedServers | 
            ForEach-Object { $_.Errors } | 
            Where-Object { $_ -match '(connection|timeout|unreachable)' }).Count

        if ($connectionErrors -gt 0) {
            $issues += @{
                Type        = 'Connectivity'
                Severity    = 'Critical'
                Issue       = "Connectivity failures: $connectionErrors servers unreachable"
                Description = "Unable to connect to multiple servers"
                RootCauses  = @('Network down', 'Firewall blocking', 'Server offline', 'DNS issues')
            }
        }

        # Check for DNS errors
        $dnsErrors = @($failedServers | 
            ForEach-Object { $_.Errors } | 
            Where-Object { $_ -match '(dns|resolve|host not found)' }).Count

        if ($dnsErrors -gt 0) {
            $issues += @{
                Type        = 'Connectivity'
                Severity    = 'Critical'
                Issue       = "DNS resolution failures: $dnsErrors servers"
                Description = "Unable to resolve server names"
                RootCauses  = @('DNS server down', 'DNS configuration error', 'Network isolation')
            }
        }
    }

    return $issues
}

function Get-ConfigurationIssues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$AuditResults
    )

    $issues = @()

    # Check for authentication errors
    $authErrors = @($AuditResults.Servers | 
        ForEach-Object { $_.Errors } | 
        Where-Object { $_ -match '(credential|authentication|access denied)' }).Count

    if ($authErrors -gt 0) {
        $issues += @{
            Type        = 'Configuration'
            Severity    = 'Critical'
            Issue       = "Authentication failures: $authErrors occurrences"
            Description = "Permission or credential issues detected"
            RootCauses  = @('Incorrect credentials', 'Permission denied', 'Account disabled', 'Credential expiration')
        }
    }

    # Check for WinRM configuration
    $winrmErrors = @($AuditResults.Servers | 
        ForEach-Object { $_.Errors } | 
        Where-Object { $_ -match '(winrm|psremoting|wsman)' }).Count

    if ($winrmErrors -gt 0) {
        $issues += @{
            Type        = 'Configuration'
            Severity    = 'Critical'
            Issue       = "WinRM configuration issues: $winrmErrors occurrences"
            Description = "Remote execution infrastructure problems"
            RootCauses  = @('WinRM not running', 'Trust issues', 'Firewall rules', 'Wrong port')
        }
    }

    return $issues
}

function Get-HealthScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [int]$CriticalIssues,

        [Parameter(Mandatory=$true)]
        [int]$Warnings,

        [Parameter(Mandatory=$true)]
        [int]$TotalServers,

        [Parameter(Mandatory=$true)]
        [decimal]$SuccessRate
    )

    # Start with 100
    $score = 100

    # Deduct for critical issues (10 points each)
    $score -= ($CriticalIssues * 10)

    # Deduct for warnings (2 points each)
    $score -= ($Warnings * 2)

    # Deduct for success rate below 90%
    if ($SuccessRate -lt 0.9) {
        $score -= [Math]::Round((0.9 - $SuccessRate) * 100)
    }

    # Floor at 0
    $score = [Math]::Max(0, $score)

    return [Math]::Min(100, $score)
}

function Get-HealthRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$PerformanceIssues,

        [Parameter(Mandatory=$true)]
        [object[]]$ResourceIssues,

        [Parameter(Mandatory=$true)]
        [object[]]$ConnectivityIssues,

        [Parameter(Mandatory=$true)]
        [object[]]$ConfigurationIssues
    )

    $recommendations = @()

    # Performance recommendations
    foreach ($issue in $PerformanceIssues) {
        if ($issue.Severity -eq 'Warning') {
            $recommendations += @{
                Severity    = 'Warning'
                Category    = 'Performance'
                Issue       = $issue.Issue
                Suggestion  = "Investigate slow collectors; consider disabling non-critical collectors or increasing timeouts"
                Priority    = 2
            }
        } else {
            $recommendations += @{
                Severity    = 'Informational'
                Category    = 'Performance'
                Issue       = $issue.Issue
                Suggestion  = "Review collector performance; optimize slow collectors"
                Priority    = 3
            }
        }
    }

    # Resource recommendations
    foreach ($issue in $ResourceIssues) {
        if ($issue.Severity -eq 'Critical') {
            $recommendations += @{
                Severity    = 'Critical'
                Category    = 'Resources'
                Issue       = $issue.Issue
                Suggestion  = "Enable batch processing (M-010); reduce parallelism; increase resource allocation"
                Priority    = 1
            }
        } elseif ($issue.Severity -eq 'Warning') {
            $recommendations += @{
                Severity    = 'Warning'
                Category    = 'Resources'
                Issue       = $issue.Issue
                Suggestion  = "Monitor resource usage; increase -MaxParallelJobs if resources allow"
                Priority    = 2
            }
        }
    }

    # Connectivity recommendations
    foreach ($issue in $ConnectivityIssues) {
        $recommendations += @{
            Severity    = 'Critical'
            Category    = 'Connectivity'
            Issue       = $issue.Issue
            Suggestion  = "Verify network connectivity; check firewall rules; verify DNS configuration; check server availability"
            Priority    = 1
        }
    }

    # Configuration recommendations
    foreach ($issue in $ConfigurationIssues) {
        $recommendations += @{
            Severity    = 'Critical'
            Category    = 'Configuration'
            Issue       = $issue.Issue
            Suggestion  = "Verify credentials, WinRM service status, trust relationships, and firewall port rules"
            Priority    = 1
        }
    }

    return $recommendations | Sort-Object -Property Priority
}

function Get-AutoRemediationScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Recommendations
    )

    $scripts = @()

    foreach ($rec in $Recommendations) {
        switch ($rec.Category) {
            'Connectivity' {
                if ($rec.Issue -match 'DNS') {
                    $scripts += @{
                        Type        = 'Network'
                        Description = "Flush DNS cache on local machine"
                        Script      = 'ipconfig /flushdns'
                        CanAutoApply = $true
                    }
                }
            }
            'Configuration' {
                if ($rec.Issue -match 'WinRM') {
                    $scripts += @{
                        Type        = 'WinRM'
                        Description = "Restart WinRM service on local machine"
                        Script      = 'Restart-Service -Name WinRM -Force'
                        CanAutoApply = $false
                        RequiresApproval = $true
                    }
                }
            }
            'Performance' {
                $scripts += @{
                    Type        = 'Tuning'
                    Description = "Review and optimize collector configuration"
                    Script      = 'Get-Content data/audit-config.json | ConvertFrom-Json | Format-List'
                    CanAutoApply = $false
                    RequiresReview = $true
                }
            }
        }
    }

    return $scripts | Where-Object { $_ -ne $null } | Select-Object -Unique
}

function New-HealthDiagnosticsHTML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Diagnostics
    )

    $healthColor = switch ($Diagnostics.HealthScore) {
        { $_ -ge 90 } { '#66bb6a' }
        { $_ -ge 75 } { '#ffa726' }
        { $_ -ge 50 } { '#ef5350' }
        default { '#d32f2f' }
    }

    $statusEmoji = switch ($Diagnostics.HealthScore) {
        { $_ -ge 90 } { '✅' }
        { $_ -ge 75 } { '⚠️' }
        { $_ -ge 50 } { '❌' }
        default { '🔴' }
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Health Diagnostics Report - ServerAuditToolkitV2</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/3.9.1/chart.min.js"></script>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #1a73e8;
            margin: 0 0 10px 0;
        }
        .timestamp {
            color: #999;
            font-size: 12px;
        }
        .health-card {
            background: linear-gradient(135deg, $healthColor 0%, #555 100%);
            color: white;
            padding: 30px;
            border-radius: 8px;
            text-align: center;
            margin-bottom: 30px;
        }
        .health-score {
            font-size: 48px;
            font-weight: bold;
            margin: 10px 0;
        }
        .health-status {
            font-size: 24px;
            margin-bottom: 10px;
        }
        .issue-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        .issue-card {
            background: #f5f5f5;
            padding: 15px;
            border-left: 4px solid;
            border-radius: 4px;
        }
        .issue-critical { border-color: #d32f2f; }
        .issue-warning { border-color: #ffa726; }
        .issue-info { border-color: #1976d2; }
        .issue-count {
            font-size: 24px;
            font-weight: bold;
            color: #1a73e8;
        }
        .issue-label {
            font-size: 12px;
            color: #666;
            margin-top: 5px;
        }
        h2 {
            color: #1a73e8;
            border-bottom: 2px solid #e0e0e0;
            padding-bottom: 10px;
            margin-top: 30px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        th {
            background: #f0f0f0;
            padding: 12px;
            text-align: left;
            border-bottom: 2px solid #ddd;
            font-weight: 600;
        }
        td {
            padding: 12px;
            border-bottom: 1px solid #ddd;
        }
        .severity-critical { color: #d32f2f; font-weight: bold; }
        .severity-warning { color: #ffa726; font-weight: bold; }
        .severity-info { color: #1976d2; }
        .recommendation {
            background: #f9f9f9;
            padding: 15px;
            margin-bottom: 10px;
            border-left: 3px solid #1a73e8;
            border-radius: 4px;
        }
        .recommendation.critical { border-left-color: #d32f2f; }
        .recommendation.warning { border-left-color: #ffa726; }
        .recommendation-title {
            font-weight: bold;
            margin-bottom: 5px;
        }
        .recommendation-suggestion {
            color: #666;
            font-size: 14px;
            margin-top: 5px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>$statusEmoji Health Diagnostics Report</h1>
        <p class="timestamp">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Session: $($Diagnostics.SessionId)</p>

        <div class="health-card">
            <div class="health-status">$statusEmoji Overall Health</div>
            <div class="health-score">$($Diagnostics.HealthScore)/100</div>
            <div style="font-size: 14px; opacity: 0.9;">System Status</div>
        </div>

        <div class="issue-grid">
            <div class="issue-card issue-critical">
                <div class="issue-count">$($Diagnostics.CriticalIssues)</div>
                <div class="issue-label">Critical Issues</div>
            </div>
            <div class="issue-card issue-warning">
                <div class="issue-count">$($Diagnostics.Warnings)</div>
                <div class="issue-label">Warnings</div>
            </div>
            <div class="issue-card issue-info">
                <div class="issue-count">$($Diagnostics.IssuesDetected)</div>
                <div class="issue-label">Total Issues</div>
            </div>
        </div>

        <h2>Performance Issues ($($Diagnostics.PerformanceIssues.Count))</h2>
        <table>
            <tr>
                <th>Issue</th>
                <th>Description</th>
                <th>Root Causes</th>
            </tr>
"@

    foreach ($issue in $Diagnostics.PerformanceIssues) {
        $html += "<tr><td>$($issue.Issue)</td><td>$($issue.Description)</td><td>$($issue.RootCauses -join ', ')</td></tr>"
    }

    $html += @"
        </table>

        <h2>Resource Issues ($($Diagnostics.ResourceIssues.Count))</h2>
        <table>
            <tr>
                <th>Issue</th>
                <th>Severity</th>
                <th>Description</th>
            </tr>
"@

    foreach ($issue in $Diagnostics.ResourceIssues) {
        $severity = "severity-$($issue.Severity.ToLower())"
        $html += "<tr><td>$($issue.Issue)</td><td class='$severity'>$($issue.Severity)</td><td>$($issue.Description)</td></tr>"
    }

    $html += @"
        </table>

        <h2>Connectivity Issues ($($Diagnostics.ConnectivityIssues.Count))</h2>
        <table>
            <tr>
                <th>Issue</th>
                <th>Root Causes</th>
            </tr>
"@

    foreach ($issue in $Diagnostics.ConnectivityIssues) {
        $html += "<tr><td>$($issue.Issue)</td><td>$($issue.RootCauses -join ', ')</td></tr>"
    }

    $html += @"
        </table>

        <h2>Configuration Issues ($($Diagnostics.ConfigurationIssues.Count))</h2>
        <table>
            <tr>
                <th>Issue</th>
                <th>Root Causes</th>
            </tr>
"@

    foreach ($issue in $Diagnostics.ConfigurationIssues) {
        $html += "<tr><td>$($issue.Issue)</td><td>$($issue.RootCauses -join ', ')</td></tr>"
    }

    $html += @"
        </table>

        <h2>Recommendations ($($Diagnostics.Recommendations.Count))</h2>
"@

    foreach ($rec in $Diagnostics.Recommendations) {
        $className = "recommendation $($rec.Severity.ToLower())"
        $html += @"
        <div class="$className">
            <div class="recommendation-title">[$($rec.Severity)] $($rec.Category) - $($rec.Issue)</div>
            <div class="recommendation-suggestion">💡 $($rec.Suggestion)</div>
        </div>
"@
    }

    $html += @"
        <hr style="margin-top: 30px; border: none; border-top: 1px solid #e0e0e0;">
        <p style="text-align: center; color: #999; font-size: 12px;">
            ServerAuditToolkitV2 - M-014: Health Diagnostics & Self-Healing
        </p>
    </div>
</body>
</html>
"@

    return $html
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function @(
        'New-AuditHealthDiagnostics'
    )
}
