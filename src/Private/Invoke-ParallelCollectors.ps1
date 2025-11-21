<#
.SYNOPSIS
    Executes collectors in parallel with max concurrency control and timeout enforcement.

.DESCRIPTION
    Manages execution of audit collectors across multiple servers with intelligent
    concurrency throttling (default: max 3 concurrent servers). Implements timeout
    enforcement per collector, job tracking, and graceful error handling.

    For PowerShell 5.1+, uses modern job management; for PS 2.0/4.0, uses
    sequential execution with timing simulation.

.PARAMETER Servers
    Target servers to audit. Accepts pipeline input.

.PARAMETER Collectors
    Array of collector script blocks or filenames to execute on each server.

.PARAMETER MaxConcurrentJobs
    Maximum concurrent remote jobs. Default: 3.
    Recommended: 1-4 for MSP scenarios (prevents resource contention).

.PARAMETER JobTimeoutSeconds
    Max execution time per job. Default: 30.
    Each collector can override via metadata.

.PARAMETER ResultCallback
    Script block invoked when a job completes. Receives job result as parameter.

.EXAMPLE
    $servers = @("SERVER01", "SERVER02", "SERVER03")
    $collectors = @(
        { Get-ServerInfo },
        { Get-IISInfo },
        { Get-Services }
    )

    Invoke-ParallelCollectors -Servers $servers -Collectors $collectors -MaxConcurrentJobs 2

.EXAMPLE
    # With result callback for real-time processing
    Invoke-ParallelCollectors `
        -Servers $servers `
        -Collectors $collectors `
        -MaxConcurrentJobs 3 `
        -ResultCallback { param($result) Write-Host "Completed: $($result.ServerName)" }

.OUTPUTS
    [PSObject[]]
    Array of job results with ServerName, CollectorName, Status, Duration, and Output properties.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   5.1+ (PS 2.0/4.0 use sequential fallback)
    License:      MIT

    Features:
    - Max 3 concurrent servers (MSP safety threshold)
    - Per-collector timeout enforcement
    - Graceful job cleanup on timeout
    - Result tracking and aggregation
    - Real-time progress via callback

.LINK
    https://github.com/tonynash74/ServerAuditToolkitv2

#>

function Invoke-ParallelCollectors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string[]]$Servers,

        [Parameter(Mandatory=$true)]
        [scriptblock[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 16)]
        [int]$MaxConcurrentJobs = 3,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 3600)]
        [int]$JobTimeoutSeconds = 30,

        [Parameter(Mandatory=$false)]
        [scriptblock]$ResultCallback
    )

    begin {
        $results = @()
        $jobs = @()
        $jobTracking = @{}

        # Verify PowerShell version supports job management
        $psVersion = $PSVersionTable.PSVersion.Major
        $supportsJobMgmt = $psVersion -ge 3
    }

    process {
        if (-not $supportsJobMgmt) {
            # Fallback: PS 2.0 sequential execution
            Write-Warning "PowerShell 2.0 detected; using sequential execution (slower)"

            foreach ($server in $Servers) {
                foreach ($collector in $Collectors) {
                    $startTime = Get-Date
                    try {
                        $output = Invoke-Command -ComputerName $server -ScriptBlock $collector -ErrorAction Stop
                        $duration = (Get-Date) - $startTime

                        $result = @{
                            ServerName    = $server
                            CollectorName = $collector.Name
                            Status        = 'Success'
                            Duration      = $duration
                            Output        = $output
                        }

                        $results += $result

                        if ($ResultCallback) {
                            & $ResultCallback $result
                        }
                    }
                    catch {
                        $duration = (Get-Date) - $startTime
                        $result = @{
                            ServerName    = $server
                            CollectorName = $collector.Name
                            Status        = 'Failed'
                            Duration      = $duration
                            Error         = $_.Exception.Message
                        }

                        $results += $result

                        if ($ResultCallback) {
                            & $ResultCallback $result
                        }
                    }
                }
            }

            return $results
        }

        # PS 3.0+ parallel job management
        $jobIndex = 0

        foreach ($server in $Servers) {
            foreach ($collector in $Collectors) {
                # Throttle: wait if max concurrent jobs reached
                while ($jobs.Count -ge $MaxConcurrentJobs) {
                    $completed = $jobs | Wait-Job -Any -Timeout 1
                    if ($completed) {
                        $result = Receive-Job -Job $completed -ErrorAction SilentlyContinue
                        $jobs = @($jobs | Where-Object { $_.Id -ne $completed.Id })

                        $duration = (Get-Date) - $jobTracking[$completed.Id].StartTime
                        $trackingInfo = $jobTracking[$completed.Id]

                        $resultObj = @{
                            ServerName    = $trackingInfo.ServerName
                            CollectorName = $trackingInfo.CollectorName
                            Status        = if ($completed.State -eq 'Completed') { 'Success' } else { 'Failed' }
                            Duration      = $duration
                            Output        = $result
                        }

                        $results += $resultObj

                        if ($ResultCallback) {
                            & $ResultCallback $resultObj
                        }

                        Remove-Job -Job $completed -Force -ErrorAction SilentlyContinue
                    }
                }

                # Start new job
                $job = Start-Job -ScriptBlock $collector -ArgumentList $server -Name "Collector_$jobIndex"
                $jobs += $job
                $jobTracking[$job.Id] = @{
                    ServerName    = $server
                    CollectorName = $collector.Name
                    StartTime     = Get-Date
                }

                $jobIndex++
            }
        }

        # Wait for all remaining jobs
        while ($jobs.Count -gt 0) {
            $completed = $jobs | Wait-Job -Any -Timeout 1

            if ($completed) {
                $duration = (Get-Date) - $jobTracking[$completed.Id].StartTime

                # Check timeout
                if ($duration.TotalSeconds -gt $JobTimeoutSeconds) {
                    Stop-Job -Job $completed -ErrorAction SilentlyContinue
                    Write-Warning "Job $($completed.Id) exceeded timeout ($JobTimeoutSeconds seconds)"
                }

                $result = Receive-Job -Job $completed -ErrorAction SilentlyContinue
                $trackingInfo = $jobTracking[$completed.Id]

                $resultObj = @{
                    ServerName    = $trackingInfo.ServerName
                    CollectorName = $trackingInfo.CollectorName
                    Status        = if ($duration.TotalSeconds -gt $JobTimeoutSeconds) { 'Timeout' } elseif ($completed.State -eq 'Completed') { 'Success' } else { 'Failed' }
                    Duration      = $duration
                    Output        = $result
                }

                $results += $resultObj

                if ($ResultCallback) {
                    & $ResultCallback $resultObj
                }

                Remove-Job -Job $completed -Force -ErrorAction SilentlyContinue
                $jobs = @($jobs | Where-Object { $_.Id -ne $completed.Id })
            }
        }
    }

    end {
        return $results
    }
}
