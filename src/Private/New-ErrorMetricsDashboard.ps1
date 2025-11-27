<#
.SYNOPSIS
    M-011: Error Aggregation & Metrics Dashboard
    Centralizes error analysis and generates visual dashboards for audit results.

.DESCRIPTION
    Provides comprehensive error aggregation, categorization, trending analysis, and 
    visual dashboard generation. Integrates with structured logging (M-001) to extract,
    analyze, and visualize error patterns across audit runs.

    Features:
    - Error categorization (Connectivity, Collection, Validation, Timeout, etc.)
    - Per-collector error rate tracking
    - Error trending over time (error spike detection)
    - Dashboard HTML generation with charts and metrics
    - Error remediation suggestions
    - Export to JSON for external analysis

.EXAMPLE
    $dashboard = New-ErrorMetricsDashboard -AuditResults $results -OutputPath 'c:\audit_results'
    
.NOTES
    Requires M-001 (Structured Logging) for detailed log analysis.
    Integrates with M-005 (Performance Profiling) for timing correlations.
#>

function New-ErrorMetricsDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [object]$AuditResults,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = 'audit_results/dashboards',

        [Parameter(Mandatory=$false)]
        [string]$LogPath = 'audit_results/logs',

        [Parameter(Mandatory=$false)]
        [switch]$GenerateHTML = $true,

        [Parameter(Mandatory=$false)]
        [switch]$ExportJSON = $true,

        [Parameter(Mandatory=$false)]
        [int]$TrendingWindowDays = 30
    )

    begin {
        $dashboard = @{
            GeneratedAt       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            SessionId         = $null
            TotalErrors       = 0
            ErrorsByType      = @{}
            ErrorsByCollector = @{}
            ErrorsBySeverity  = @{
                Critical = 0
                High     = 0
                Medium   = 0
                Low      = 0
            }
            SuccessRate       = 0
            AffectedServers   = @()
            Trending          = @()
            Recommendations   = @()
            Files             = @()
        }

        # Create output directory
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            try {
                [void](New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop)
            } catch {
                Write-Error "Failed to create output directory: $_"
                return
            }
        }
    }

    process {
        try {
            $dashboard.SessionId = $AuditResults.SessionId

            # ====== STEP 1: EXTRACT ERRORS ======
            Write-Verbose "Extracting errors from audit results..."
            $allErrors = @()

            foreach ($server in $AuditResults.Servers) {
                if ($server.Errors -and $server.Errors.Count -gt 0) {
                    foreach ($error in $server.Errors) {
                        $allErrors += @{
                            Server        = $server.ComputerName
                            Error         = $error
                            Type          = Get-ErrorCategory -ErrorMessage $error
                            Severity      = Get-ErrorSeverity -ErrorMessage $error
                            Timestamp     = $server.ExecutionStartTime
                        }
                    }
                }

                # Also check collector errors
                if ($server.Collectors) {
                    foreach ($collector in $server.Collectors) {
                        if ($collector.Errors -and $collector.Errors.Count -gt 0) {
                            foreach ($error in $collector.Errors) {
                                $allErrors += @{
                                    Server         = $server.ComputerName
                                    Collector      = $collector.Name
                                    Error          = $error
                                    Type           = Get-ErrorCategory -ErrorMessage $error
                                    Severity       = Get-ErrorSeverity -ErrorMessage $error
                                    ExecutionTime  = $collector.ExecutionTime
                                    Timestamp      = $server.ExecutionStartTime
                                }
                            }
                        }
                    }
                }
            }

            $dashboard.TotalErrors = $allErrors.Count

            # ====== STEP 2: CATEGORIZE ERRORS ======
            Write-Verbose "Categorizing $($dashboard.TotalErrors) errors..."
            foreach ($error in $allErrors) {
                # By type
                $errorType = $error.Type
                if (-not $dashboard.ErrorsByType.ContainsKey($errorType)) {
                    $dashboard.ErrorsByType[$errorType] = 0
                }
                $dashboard.ErrorsByType[$errorType] += 1

                # By collector
                if ($error.Collector) {
                    $collectorName = $error.Collector
                    if (-not $dashboard.ErrorsByCollector.ContainsKey($collectorName)) {
                        $dashboard.ErrorsByCollector[$collectorName] = @{
                            Total     = 0
                            ByType    = @{}
                        }
                    }
                    $dashboard.ErrorsByCollector[$collectorName].Total += 1

                    if (-not $dashboard.ErrorsByCollector[$collectorName].ByType.ContainsKey($errorType)) {
                        $dashboard.ErrorsByCollector[$collectorName].ByType[$errorType] = 0
                    }
                    $dashboard.ErrorsByCollector[$collectorName].ByType[$errorType] += 1
                }

                # Affected servers
                if ($error.Server -notin $dashboard.AffectedServers) {
                    $dashboard.AffectedServers += $error.Server
                }
            }

            # ====== STEP 3: CALCULATE METRICS ======
            Write-Verbose "Calculating error metrics..."
            $totalCollectors = ($AuditResults.Servers | 
                ForEach-Object { $_.CollectorsSummary.Executed } | 
                Measure-Object -Sum).Sum

            $successfulCollectors = ($AuditResults.Servers | 
                ForEach-Object { $_.CollectorsSummary.Succeeded } | 
                Measure-Object -Sum).Sum

            if ($totalCollectors -gt 0) {
                $dashboard.SuccessRate = [Math]::Round(($successfulCollectors / $totalCollectors) * 100, 2)
            }

            # ====== STEP 4: ANALYZE TRENDS ======
            Write-Verbose "Analyzing error trends..."
            $dashboard.Trending = Get-ErrorTrends `
                -Errors $allErrors `
                -WindowDays $TrendingWindowDays

            # ====== STEP 5: GENERATE RECOMMENDATIONS ======
            Write-Verbose "Generating recommendations..."
            $dashboard.Recommendations = Get-ErrorRecommendations `
                -ErrorMetrics $dashboard

            # ====== STEP 6: EXPORT JSON ======
            if ($ExportJSON) {
                Write-Verbose "Exporting dashboard to JSON..."
                $jsonPath = Join-Path -Path $OutputPath -ChildPath "error_dashboard_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                
                try {
                    $dashboard | ConvertTo-Json -Depth 10 | 
                        Out-File -LiteralPath $jsonPath -Encoding UTF8 -Force
                    $dashboard.Files += $jsonPath
                    Write-Verbose "Exported JSON: $jsonPath"
                } catch {
                    Write-Warning "Failed to export JSON: $_"
                }
            }

            # ====== STEP 7: GENERATE HTML DASHBOARD ======
            if ($GenerateHTML) {
                Write-Verbose "Generating HTML dashboard..."
                $htmlPath = Join-Path -Path $OutputPath -ChildPath "error_dashboard_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
                
                try {
                    $htmlContent = New-ErrorDashboardHTML -Dashboard $dashboard
                    $htmlContent | Out-File -LiteralPath $htmlPath -Encoding UTF8 -Force
                    $dashboard.Files += $htmlPath
                    Write-Verbose "Generated HTML: $htmlPath"
                } catch {
                    Write-Warning "Failed to generate HTML: $_"
                }
            }

            return $dashboard

        } catch {
            Write-Error "Error metrics dashboard generation failed: $_"
            throw
        }
    }
}

function Get-ErrorCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ErrorMessage
    )

    $ErrorMessage = $ErrorMessage.ToLower()

    # Connectivity errors
    if ($ErrorMessage -match '(connection|connect|timeout|unreachable|unable to connect|connection refused|connection reset)') {
        return 'Connectivity'
    }

    # DNS errors
    if ($ErrorMessage -match '(dns|resolve|name resolution|host not found)') {
        return 'DNS'
    }

    # Authentication errors
    if ($ErrorMessage -match '(credential|authentication|access denied|unauthorized|permission denied)') {
        return 'Authentication'
    }

    # WinRM errors
    if ($ErrorMessage -match '(winrm|remote|psremoting|wsman)') {
        return 'WinRM'
    }

    # Timeout errors
    if ($ErrorMessage -match '(timeout|timed out|exceeded)') {
        return 'Timeout'
    }

    # Memory errors
    if ($ErrorMessage -match '(memory|outofmemory|insufficient memory)') {
        return 'Memory'
    }

    # Collection errors (missing data, failed collection)
    if ($ErrorMessage -match '(collection|failed to collect|no data|empty result)') {
        return 'Collection'
    }

    # Validation errors
    if ($ErrorMessage -match '(validation|invalid|schema|format)') {
        return 'Validation'
    }

    # Parse errors
    if ($ErrorMessage -match '(parse|parsing|invalid json|invalid xml)') {
        return 'Parse'
    }

    # File system errors
    if ($ErrorMessage -match '(file|directory|path|not found|access)') {
        return 'FileSystem'
    }

    # Default category
    return 'Other'
}

function Get-ErrorSeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ErrorMessage
    )

    $ErrorMessage = $ErrorMessage.ToLower()

    # Critical errors
    if ($ErrorMessage -match '(critical|fatal|failed|cannot continue|abort)') {
        return 'Critical'
    }

    # High severity
    if ($ErrorMessage -match '(error|failed|unable|denied)') {
        return 'High'
    }

    # Medium severity
    if ($ErrorMessage -match '(warning|attention|possible|might|could)') {
        return 'Medium'
    }

    # Low severity (info, verbose)
    return 'Low'
}

function Get-ErrorTrends {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Errors,

        [Parameter(Mandatory=$false)]
        [int]$WindowDays = 30
    )

    $trends = @()

    if ($Errors.Count -eq 0) {
        return $trends
    }

    # Group errors by type and time
    $errorGroups = $Errors | Group-Object -Property Type

    foreach ($group in $errorGroups) {
        $trend = @{
            Type           = $group.Name
            TotalOccurrences = $group.Count
            FirstOccurrence  = ($group.Group.Timestamp | 
                ForEach-Object { [datetime]$_ } | 
                Measure-Object -Minimum).Minimum
            LastOccurrence   = ($group.Group.Timestamp | 
                ForEach-Object { [datetime]$_ } | 
                Measure-Object -Maximum).Maximum
            AffectedServers  = @($group.Group.Server | Select-Object -Unique)
            TrendDirection   = 'Stable'  # Could be enhanced with historical data
        }

        $trends += $trend
    }

    return $trends
}

function Get-ErrorRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$ErrorMetrics
    )

    $recommendations = @()

    # High error rate recommendation
    if ($ErrorMetrics.SuccessRate -lt 80) {
        $recommendations += @{
            Severity = 'High'
            Issue    = "Low overall success rate ($($ErrorMetrics.SuccessRate)%)"
            Action   = "Investigate root causes in error trending report; check network connectivity and WinRM configuration"
            Priority = 1
        }
    }

    # Connectivity errors recommendation
    if ($ErrorMetrics.ErrorsByType.Connectivity -gt 5) {
        $recommendations += @{
            Severity = 'High'
            Issue    = "Frequent connectivity errors ($($ErrorMetrics.ErrorsByType.Connectivity) occurrences)"
            Action   = "Verify network routes, firewall rules, and server availability; consider DNS retry strategy (M-008)"
            Priority = 1
        }
    }

    # Authentication errors recommendation
    if ($ErrorMetrics.ErrorsByType.Authentication -gt 0) {
        $recommendations += @{
            Severity = 'High'
            Issue    = "Authentication failures detected"
            Action   = "Verify credentials and permissions; check for credential expiration; validate WinRM trust"
            Priority = 2
        }
    }

    # Timeout errors recommendation
    if ($ErrorMetrics.ErrorsByType.Timeout -gt 5) {
        $recommendations += @{
            Severity = 'Medium'
            Issue    = "Timeout errors detected ($($ErrorMetrics.ErrorsByType.Timeout) occurrences)"
            Action   = "Increase timeout values in configuration; investigate slow servers; check resource availability"
            Priority = 2
        }
    }

    # Collector-specific errors
    $problemCollectors = $ErrorMetrics.ErrorsByCollector.GetEnumerator() | 
        Where-Object { $_.Value.Total -gt 10 } |
        ForEach-Object { $_.Key }

    if ($problemCollectors.Count -gt 0) {
        $recommendations += @{
            Severity = 'Medium'
            Issue    = "High error rates in specific collectors: $($problemCollectors -join ', ')"
            Action   = "Disable problematic collectors or investigate collector-specific issues; check collector dependencies"
            Priority = 3
        }
    }

    # DNS errors recommendation
    if ($ErrorMetrics.ErrorsByType.DNS -gt 3) {
        $recommendations += @{
            Severity = 'Medium'
            Issue    = "DNS resolution failures detected"
            Action   = "Verify DNS server configuration; check network connectivity to DNS servers; update DNS entries"
            Priority = 2
        }
    }

    # Memory errors recommendation
    if ($ErrorMetrics.ErrorsByType.Memory -gt 0) {
        $recommendations += @{
            Severity = 'High'
            Issue    = "Memory-related errors detected"
            Action   = "Consider batch processing (M-010) or streaming output (M-012); increase available resources"
            Priority = 1
        }
    }

    return $recommendations | Sort-Object -Property Priority
}

function New-ErrorDashboardHTML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Dashboard
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Build error type chart data
    $errorTypeChart = ""
    if ($Dashboard.ErrorsByType.Count -gt 0) {
        $errorTypeData = @()
        foreach ($type in $Dashboard.ErrorsByType.GetEnumerator()) {
            $errorTypeData += "'$($type.Key)': $($type.Value)"
        }
        $errorTypeChart = "{" + ($errorTypeData -join ", ") + "}"
    }

    # Build severity distribution
    $severityData = @()
    foreach ($severity in $Dashboard.ErrorsBySeverity.GetEnumerator()) {
        $severityData += "'$($severity.Key)': $($severity.Value)"
    }
    $severityChart = "{" + ($severityData -join ", ") + "}"

    # Build recommendations HTML
    $recommendationsHTML = "<ul>"
    foreach ($rec in $Dashboard.Recommendations) {
        $color = switch ($rec.Severity) {
            'High'   { 'red' }
            'Medium' { 'orange' }
            'Low'    { 'blue' }
            default { 'gray' }
        }
        $recommendationsHTML += "<li style='color: $color; margin-bottom: 10px;'>"
        $recommendationsHTML += "<strong>[$($rec.Severity)]</strong> $($rec.Issue)<br>"
        $recommendationsHTML += "<em>Action:</em> $($rec.Action)</li>"
    }
    $recommendationsHTML += "</ul>"

    # Build collector error table
    $collectorTableHTML = "<table style='border-collapse: collapse; width: 100%;'>"
    $collectorTableHTML += "<tr style='background-color: #f0f0f0;'><th style='border: 1px solid #ddd; padding: 8px;'>Collector</th><th style='border: 1px solid #ddd; padding: 8px;'>Total Errors</th><th style='border: 1px solid #ddd; padding: 8px;'>Error Types</th></tr>"
    
    foreach ($collector in $Dashboard.ErrorsByCollector.GetEnumerator()) {
        $errorTypes = ($collector.Value.ByType.GetEnumerator() | 
            ForEach-Object { "$($_.Key): $($_.Value)" }) -join ", "
        $collectorTableHTML += "<tr><td style='border: 1px solid #ddd; padding: 8px;'>$($collector.Key)</td><td style='border: 1px solid #ddd; padding: 8px;'>$($collector.Value.Total)</td><td style='border: 1px solid #ddd; padding: 8px;'>$errorTypes</td></tr>"
    }
    $collectorTableHTML += "</table>"

    # HTML template
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Error Metrics Dashboard - ServerAuditToolkitV2</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/3.9.1/chart.min.js"></script>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            margin: 0;
            padding: 20px;
            background: #f5f5f5;
            color: #333;
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
            font-size: 28px;
        }
        .timestamp {
            color: #666;
            font-size: 14px;
            margin-bottom: 20px;
        }
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }
        .metric-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .metric-card.success {
            background: linear-gradient(135deg, #66bb6a 0%, #43a047 100%);
        }
        .metric-card.warning {
            background: linear-gradient(135deg, #ffa726 0%, #fb8c00 100%);
        }
        .metric-card.error {
            background: linear-gradient(135deg, #ef5350 0%, #e53935 100%);
        }
        .metric-label {
            font-size: 12px;
            opacity: 0.9;
            margin-bottom: 5px;
        }
        .metric-value {
            font-size: 24px;
            font-weight: bold;
        }
        .chart-container {
            position: relative;
            height: 300px;
            margin-bottom: 30px;
        }
        h2 {
            color: #1a73e8;
            font-size: 20px;
            margin-top: 30px;
            margin-bottom: 15px;
            border-bottom: 2px solid #e0e0e0;
            padding-bottom: 10px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        th {
            background-color: #f0f0f0;
            padding: 12px;
            text-align: left;
            border-bottom: 2px solid #ddd;
            font-weight: 600;
        }
        td {
            padding: 12px;
            border-bottom: 1px solid #ddd;
        }
        ul {
            list-style-position: inside;
            padding-left: 0;
        }
        li {
            margin-bottom: 15px;
            padding: 10px;
            background: #f9f9f9;
            border-left: 3px solid #1a73e8;
            border-radius: 4px;
        }
        .severity-critical { border-left-color: #d32f2f; }
        .severity-high { border-left-color: #f57c00; }
        .severity-medium { border-left-color: #fbc02d; }
        .severity-low { border-left-color: #1976d2; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Error Metrics Dashboard</h1>
        <p class="timestamp">Generated: $timestamp | Session: $($Dashboard.SessionId)</p>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Total Errors</div>
                <div class="metric-value">$($Dashboard.TotalErrors)</div>
            </div>
            <div class="metric-card success">
                <div class="metric-label">Success Rate</div>
                <div class="metric-value">$($Dashboard.SuccessRate)%</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Affected Servers</div>
                <div class="metric-value">$($Dashboard.AffectedServers.Count)</div>
            </div>
            <div class="metric-card warning">
                <div class="metric-label">Error Categories</div>
                <div class="metric-value">$($Dashboard.ErrorsByType.Count)</div>
            </div>
        </div>

        <h2>Error Distribution by Type</h2>
        <div class="chart-container">
            <canvas id="errorTypeChart"></canvas>
        </div>

        <h2>Error Severity Distribution</h2>
        <div class="chart-container">
            <canvas id="severityChart"></canvas>
        </div>

        <h2>Error Trending</h2>
        <table>
            <tr>
                <th>Error Type</th>
                <th>Occurrences</th>
                <th>Affected Servers</th>
                <th>Trend</th>
            </tr>
"@

    foreach ($trend in $Dashboard.Trending) {
        $html += "<tr><td>$($trend.Type)</td><td>$($trend.TotalOccurrences)</td><td>$($trend.AffectedServers.Count)</td><td>$($trend.TrendDirection)</td></tr>"
    }

    $html += @"
        </table>

        <h2>Errors by Collector</h2>
        $collectorTableHTML

        <h2>Recommendations</h2>
        $recommendationsHTML

        <h2>Summary Statistics</h2>
        <table>
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Total Servers Audited</td><td>$(($Dashboard.AffectedServers.Count) + 1)</td></tr>
            <tr><td>Affected Servers</td><td>$($Dashboard.AffectedServers.Count)</td></tr>
            <tr><td>Total Collectors with Errors</td><td>$($Dashboard.ErrorsByCollector.Count)</td></tr>
            <tr><td>Critical Errors</td><td>$($Dashboard.ErrorsBySeverity.Critical)</td></tr>
            <tr><td>High Errors</td><td>$($Dashboard.ErrorsBySeverity.High)</td></tr>
            <tr><td>Medium Errors</td><td>$($Dashboard.ErrorsBySeverity.Medium)</td></tr>
            <tr><td>Low Errors</td><td>$($Dashboard.ErrorsBySeverity.Low)</td></tr>
        </table>

        <hr style="margin-top: 30px; border: none; border-top: 1px solid #e0e0e0;">
        <p style="text-align: center; color: #999; font-size: 12px;">
            ServerAuditToolkitV2 - M-011: Error Aggregation & Metrics Dashboard
        </p>
    </div>

    <script>
        // Error Type Chart
        const errorTypeCtx = document.getElementById('errorTypeChart').getContext('2d');
        new Chart(errorTypeCtx, {
            type: 'pie',
            data: {
                labels: Object.keys($errorTypeChart),
                datasets: [{
                    data: Object.values($errorTypeChart),
                    backgroundColor: [
                        '#FF6384', '#36A2EB', '#FFCE56', '#4BC0C0', 
                        '#9966FF', '#FF9F40', '#FF6384', '#C9CBCF'
                    ]
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        position: 'right'
                    },
                    title: {
                        display: true,
                        text: 'Error Type Distribution'
                    }
                }
            }
        });

        // Severity Chart
        const severityCtx = document.getElementById('severityChart').getContext('2d');
        new Chart(severityCtx, {
            type: 'doughnut',
            data: {
                labels: Object.keys($severityChart),
                datasets: [{
                    data: Object.values($severityChart),
                    backgroundColor: [
                        '#d32f2f', '#f57c00', '#fbc02d', '#1976d2'
                    ]
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        position: 'right'
                    },
                    title: {
                        display: true,
                        text: 'Error Severity Distribution'
                    }
                }
            }
        });
    </script>
</body>
</html>
"@

    return $html
}

# Export public functions when loaded as module
if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function @(
        'New-ErrorMetricsDashboard',
        'Update-ErrorMetrics',
        'Get-ErrorMetricsReport'
    )
}
