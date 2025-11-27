<#
.SYNOPSIS
    Generates performance profiling reports for audit execution.

.DESCRIPTION
    Analyzes collector execution metrics and generates:
    - Top 5 slowest collectors
    - Per-collector execution statistics
    - Performance timeline (Gantt chart data)
    - Performance summary JSON

.PARAMETER AuditResults
    The audit results object from Invoke-ServerAudit.

.PARAMETER OutputPath
    Output directory for performance reports.

.EXAMPLE
    $results = Invoke-ServerAudit -ComputerName "SERVER01"
    New-PerformanceProfile -AuditResults $results -OutputPath ".\audit_results"

.NOTES
    Version: 1.0.0
    Modified: 2025-11-26 (Phase 3 M-005)
#>

function New-PerformanceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$AuditResults,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = (Join-Path -Path $PWD -ChildPath 'audit_results')
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $performanceReport = @{
        Timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
        TotalAuditTime = $AuditResults.Summary.DurationSeconds
        ServerCount = $AuditResults.Servers.Count
        AverageServerTime = $AuditResults.Summary.AverageFetchTimeSeconds
        PerServer = @()
        TopSlowestCollectors = @()
        PerCollectorStats = @()
    }

    # Analyze each server
    foreach ($server in $AuditResults.Servers) {
        $serverPerf = @{
            ComputerName = $server.ComputerName
            ExecutionTime = $server.ExecutionTimeSeconds
            CollectorCount = $server.Collectors.Count
            ParallelismUsed = $server.ParallelismUsed
            SuccessCount = $server.CollectorsSummary.Succeeded
            FailureCount = $server.CollectorsSummary.Failed
            TimeoutCount = $server.CollectorsSummary.Timeout
            AverageCollectorTime = 0
            TopCollectors = @()
        }

        # Calculate average collector time
        if ($server.Collectors.Count -gt 0) {
            $avgTime = ($server.Collectors | Measure-Object -Property ExecutionTime -Average).Average
            $serverPerf.AverageCollectorTime = [Math]::Round($avgTime, 3)

            # Top 5 slowest for this server
            $serverPerf.TopCollectors = $server.Collectors |
                Sort-Object -Property ExecutionTime -Descending |
                Select-Object -First 5 |
                ForEach-Object {
                    @{
                        Name = $_.CollectorName
                        ExecutionTime = $_.ExecutionTime
                        Status = $_.Success
                    }
                }
        }

        $performanceReport.PerServer += $serverPerf
    }

    # Calculate top 5 slowest collectors across all servers
    $allCollectors = @()
    foreach ($server in $AuditResults.Servers) {
        $allCollectors += $server.Collectors | ForEach-Object {
            @{
                Server = $server.ComputerName
                Name = $_.CollectorName
                ExecutionTime = $_.ExecutionTime
                Status = $_.Success
            }
        }
    }

    $performanceReport.TopSlowestCollectors = $allCollectors |
        Sort-Object -Property ExecutionTime -Descending |
        Select-Object -First 5

    # Calculate per-collector statistics
    $collectorStats = @{}
    foreach ($collector in $allCollectors) {
        if (-not $collectorStats[$collector.Name]) {
            $collectorStats[$collector.Name] = @{
                Name = $collector.Name
                Executions = 0
                TotalTime = 0
                MinTime = [double]::MaxValue
                MaxTime = 0
                SuccessCount = 0
                FailureCount = 0
            }
        }

        $stats = $collectorStats[$collector.Name]
        $stats.Executions++
        $stats.TotalTime += $collector.ExecutionTime
        $stats.MinTime = [Math]::Min($stats.MinTime, $collector.ExecutionTime)
        $stats.MaxTime = [Math]::Max($stats.MaxTime, $collector.ExecutionTime)
        if ($collector.Status) { $stats.SuccessCount++ } else { $stats.FailureCount++ }
    }

    # Convert to array and calculate averages
    foreach ($collName in $collectorStats.Keys) {
        $stats = $collectorStats[$collName]
        $stats.AverageTime = [Math]::Round($stats.TotalTime / $stats.Executions, 3)
        $stats.MinTime = if ($stats.MinTime -eq [double]::MaxValue) { 0 } else { $stats.MinTime }
        $performanceReport.PerCollectorStats += $stats
    }

    # Sort per-collector stats by average time (slowest first)
    $performanceReport.PerCollectorStats = $performanceReport.PerCollectorStats |
        Sort-Object -Property AverageTime -Descending

    # Export as JSON
    $reportPath = Join-Path -Path $OutputPath -ChildPath "performance-profile.json"
    $performanceReport | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportPath -Encoding UTF8

    # Generate HTML report with Gantt chart
    $htmlPath = Join-Path -Path $OutputPath -ChildPath "performance-report.html"
    New-PerformanceReportHTML -PerformanceData $performanceReport -OutputPath $htmlPath

    Write-Verbose "Performance profile saved to: $reportPath"
    Write-Verbose "Performance report saved to: $htmlPath"

    return $performanceReport
}

function New-PerformanceReportHTML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$PerformanceData,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>ServerAuditToolkitV2 - Performance Report</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 8px;
            margin-bottom: 30px;
        }
        .section {
            background: white;
            padding: 20px;
            margin-bottom: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .metric {
            display: inline-block;
            margin: 10px 20px;
            padding: 15px;
            background: #f9f9f9;
            border-left: 4px solid #667eea;
        }
        .metric-label { font-size: 12px; color: #666; }
        .metric-value { font-size: 24px; font-weight: bold; color: #333; }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
        }
        th {
            background: #667eea;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #eee;
        }
        tr:hover { background: #f5f5f5; }
        .status-success { color: #27ae60; font-weight: bold; }
        .status-failure { color: #e74c3c; font-weight: bold; }
        .bar {
            background: #667eea;
            height: 20px;
            border-radius: 3px;
            margin: 5px 0;
        }
        .time { font-family: 'Courier New', monospace; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Performance Report</h1>
        <p>ServerAuditToolkitV2 - Audit Performance Analysis</p>
        <p>Generated: $($PerformanceData.Timestamp)</p>
    </div>

    <div class="section">
        <h2>Summary Metrics</h2>
        <div class="metric">
            <div class="metric-label">Total Audit Time</div>
            <div class="metric-value">$($PerformanceData.TotalAuditTime)s</div>
        </div>
        <div class="metric">
            <div class="metric-label">Servers Audited</div>
            <div class="metric-value">$($PerformanceData.ServerCount)</div>
        </div>
        <div class="metric">
            <div class="metric-label">Average Time per Server</div>
            <div class="metric-value">$($PerformanceData.AverageServerTime)s</div>
        </div>
    </div>

    <div class="section">
        <h2>Top 5 Slowest Collectors</h2>
        <table>
            <tr>
                <th>Collector Name</th>
                <th>Server</th>
                <th>Execution Time</th>
                <th>Performance Bar</th>
            </tr>
"@

    foreach ($collector in $PerformanceData.TopSlowestCollectors) {
        $barWidth = [Math]::Min($collector.ExecutionTime * 10, 100)
        $html += @"
            <tr>
                <td>$($collector.Name)</td>
                <td>$($collector.Server)</td>
                <td class="time">$($collector.ExecutionTime)s</td>
                <td><div class="bar" style="width: $($barWidth)px;"></div></td>
            </tr>
"@
    }

    $html += @"
        </table>
    </div>

    <div class="section">
        <h2>Per-Collector Statistics</h2>
        <table>
            <tr>
                <th>Collector Name</th>
                <th>Executions</th>
                <th>Average Time</th>
                <th>Min Time</th>
                <th>Max Time</th>
                <th>Success Rate</th>
            </tr>
"@

    foreach ($stat in $PerformanceData.PerCollectorStats | Select-Object -First 10) {
        $successRate = if ($stat.Executions -gt 0) {
            [Math]::Round(($stat.SuccessCount / $stat.Executions) * 100, 1)
        } else { 0 }

        $html += @"
            <tr>
                <td>$($stat.Name)</td>
                <td>$($stat.Executions)</td>
                <td class="time">$($stat.AverageTime)s</td>
                <td class="time">$($stat.MinTime)s</td>
                <td class="time">$($stat.MaxTime)s</td>
                <td><span class="status-success">$successRate%</span></td>
            </tr>
"@
    }

    $html += @"
        </table>
    </div>

    <div class="section">
        <h2>Server Performance</h2>
        <table>
            <tr>
                <th>Server</th>
                <th>Execution Time</th>
                <th>Collectors</th>
                <th>Success Rate</th>
                <th>Parallelism</th>
            </tr>
"@

    foreach ($server in $PerformanceData.PerServer) {
        $successRate = if ($server.CollectorCount -gt 0) {
            [Math]::Round(($server.SuccessCount / $server.CollectorCount) * 100, 1)
        } else { 0 }

        $html += @"
            <tr>
                <td>$($server.ComputerName)</td>
                <td class="time">$($server.ExecutionTime)s</td>
                <td>$($server.CollectorCount)</td>
                <td><span class="status-success">$successRate%</span></td>
                <td>$($server.ParallelismUsed)</td>
            </tr>
"@
    }

    $html += @"
        </table>
    </div>

    <footer style="text-align: center; color: #666; margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd;">
        <p>ServerAuditToolkitV2 - Performance Analysis Report</p>
    </footer>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Verbose "HTML performance report generated: $OutputPath"
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function @(
        'New-PerformanceProfile'
    )
}
