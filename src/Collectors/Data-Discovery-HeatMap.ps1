<#
.SYNOPSIS
    Classifies data by access/modification heat (Hot/Warm/Cool).

.DESCRIPTION
    Scans file system and classifies data by recency of access:
    
    - HOT: Modified in last 30 days (active use, must migrate)
    - WARM: Modified 30-180 days ago (used occasionally, consider archiving)
    - COOL: Not modified in 180+ days (archive candidates, safe to delete)
    
    Returns:
    - Path, size, last modified, modification history
    - Heat classification
    - Migration urgency recommendations
    
    Critical for:
    - Migration prioritization (hot data = urgent)
    - Archive planning (warm/cool = backup candidates)
    - Cost modeling (storage requirements)
    - Risk assessment (is data still relevant?)

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER ScanPath
    Root path to scan. Default: all shares.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Data-Discovery-HeatMap
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 300
    @Category: compliance
    @Critical: true
    @Priority: TIER4
    @EstimatedExecutionTime: 180
#>

function Get-DataHeatMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string[]]$ScanPath,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would create heat map for $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Data-Discovery-HeatMap'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $heatData = @()
        $now = Get-Date

        # Determine paths to scan
        if (-not $ScanPath) {
            if ($ComputerName -eq $env:COMPUTERNAME) {
                $shareWmiParams = @{
                    Class       = 'Win32_Share'
                    Filter      = "Type=0 AND NOT Name LIKE '%$%'"
                    ErrorAction = 'SilentlyContinue'
                }
            }
            else {
                $shareWmiParams = @{
                    Class        = 'Win32_Share'
                    ComputerName = $ComputerName
                    Filter       = "Type=0 AND NOT Name LIKE '%$%'"
                    ErrorAction  = 'SilentlyContinue'
                }

                if ($Credential) {
                    $shareWmiParams['Credential'] = $Credential
                }
            }

            $shares = Get-WmiObject @shareWmiParams
            if ($shares) {
                if ($shares -isnot [array]) {
                    $shares = @($shares)
                }
                $ScanPath = $shares | ForEach-Object { $_.Path }
            }
        }

        # Heat calculation function
        function Get-Heat {
            param([datetime]$LastModified)

            $daysSinceModified = ($now - $LastModified).Days

            if ($daysSinceModified -le 30) {
                return 'HOT'
            }
            elseif ($daysSinceModified -le 180) {
                return 'WARM'
            }
            else {
                return 'COOL'
            }
        }

        # Scan directories
        foreach ($path in $ScanPath) {
            if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
                continue
            }

            try {
                $dirs = Get-ChildItem -Path $path -Directory -Recurse -ErrorAction SilentlyContinue

                foreach ($dir in $dirs) {
                    try {
                        $files = Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue

                        if ($files) {
                            if ($files -isnot [array]) {
                                $files = @($files)
                            }

                            $totalSize = ($files | Measure-Object -Sum -Property Length).Sum
                            $lastModified = ($files | Measure-Object -Maximum -Property LastWriteTime).Maximum

                            $heat = Get-Heat $lastModified

                            $heatData += @{
                                Path          = $dir.FullName
                                Heat          = $heat
                                FileCount     = @($files).Count
                                TotalSize     = $totalSize
                                LastModified  = $lastModified
                                DaysSinceUse  = ($now - $lastModified).Days
                                Recommendation = switch ($heat) {
                                    'HOT'  { 'URGENT: Migrate this data immediately' }
                                    'WARM' { 'Consider archiving or moving to cold storage' }
                                    'COOL' { 'Archive candidate - validate before deletion' }
                                }
                            }
                        }
                    }
                    catch {
                        # Continue on error
                    }
                }
            }
            catch {
                # Continue on error
            }
        }

        # Summary statistics
        $hotTotal = @($heatData | Where-Object { $_.Heat -eq 'HOT' } | Measure-Object -Sum -Property TotalSize).Sum
        $warmTotal = @($heatData | Where-Object { $_.Heat -eq 'WARM' } | Measure-Object -Sum -Property TotalSize).Sum
        $coolTotal = @($heatData | Where-Object { $_.Heat -eq 'COOL' } | Measure-Object -Sum -Property TotalSize).Sum

        return @{
            Success       = $true
            CollectorName = 'Data-Discovery-HeatMap'
            Data          = $heatData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($heatData).Count
            Summary       = @{
                HotData   = @{
                    Count = @($heatData | Where-Object { $_.Heat -eq 'HOT' }).Count
                    Size  = $hotTotal
                }
                WarmData  = @{
                    Count = @($heatData | Where-Object { $_.Heat -eq 'WARM' }).Count
                    Size  = $warmTotal
                }
                CoolData  = @{
                    Count = @($heatData | Where-Object { $_.Heat -eq 'COOL' }).Count
                    Size  = $coolTotal
                }
                TotalSize = $hotTotal + $warmTotal + $coolTotal
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Data-Discovery-HeatMap'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-DataHeatMap @PSBoundParameters
}
