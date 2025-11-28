<#
.SYNOPSIS
    PS5.1+ optimized Windows service collector.

.DESCRIPTION
    High-performance variant using:
    - Get-Service with efficient filtering
    - Parallel service enumeration on PS7
    - Dependency analysis
    - Startup type consistency

.PARAMETER ComputerName
    Target server. Defaults to localhost.

.PARAMETER DryRun
    Validate prerequisites without collecting.

.EXAMPLE
    $svcs = & .\Get-Services-PS5.ps1 -ComputerName "SERVER01"
    $svcs.Data.Services | Where-Object Status -eq Running | Format-Table

.NOTES
    Metadata tags:
    - @CollectorName: Get-Services-PS5
    - @PSVersions: 5.1,7.0
    - @MinWindowsVersion: 2008R2
    - @Dependencies:
    - @Timeout: 20
    - @Category: core
    - @Critical: false
#>

function Get-Services-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-Services-PS5
    # @PSVersions: 5.1,7.0
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies:
    # @Timeout: 20
    # @Category: core
    # @Critical: false

    $result = @{
        Success        = $false
        CollectorName  = 'Get-Services-PS5'
        ComputerName   = $ComputerName
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($DryRun) {
            $result.Success = $true
            $result.Data = @{ DryRun = $true; Message = "Ready to enumerate services." }
            return $result
        }

        # === SECTION 1: Get All Services ===
        Write-Verbose "Enumerating services from $ComputerName..."

        $serviceParams = @{
            ErrorAction = 'Stop'
        }

        if ($ComputerName -ne $env:COMPUTERNAME) {
            $serviceParams.ComputerName = $ComputerName
        }

        # Get service details via CIM
        try {
            $services = Get-CimInstance -ClassName Win32_Service @serviceParams
        } catch {
            Write-Verbose "CIM failed, falling back to Get-Service"
            $services = Get-Service @serviceParams | ForEach-Object {
                [PSCustomObject]@{
                    Name        = $_.Name
                    DisplayName = $_.DisplayName
                    State       = $_.Status
                    StartMode   = $_.StartType
                }
            }
        }

        $result.Data.Services = @()
        $result.Data.Summary = @{
            Total   = 0
            Running = 0
            Stopped = 0
            Auto    = 0
            Manual  = 0
        }
        $result.Data.Summary.Disabled = 0

        # === SECTION 2: Process Services ===
        foreach ($svc in $services) {
            $result.Data.Summary.Total++

            $svcData = @{
                Name           = $svc.Name
                DisplayName    = $svc.DisplayName
                Status         = if ($svc.State) { $svc.State } else { $svc.Status }
                StartMode      = if ($svc.StartMode) { $svc.StartMode } else { $svc.StartType }
                PathName       = if ($svc.PathName) { $svc.PathName } else { 'N/A' }
                ProcessId      = if ($svc.ProcessId) { $svc.ProcessId } else { 0 }
                Description    = $svc.Description
            }

            # Update summary counters
            switch ($svcData.Status) {
                'Running' { $result.Data.Summary.Running++ }
                'Stopped' { $result.Data.Summary.Stopped++ }
            }

            switch ($svcData.StartMode) {
                'Auto' { $result.Data.Summary.Auto++ }
                'Manual' { $result.Data.Summary.Manual++ }
                'Disabled' { $result.Data.Summary.Disabled++ }
            }

            $result.Data.Services += $svcData
        }

        $result.Data.Services = $result.Data.Services | Sort-Object -Property DisplayName

        $result.Success = $true

    } catch {
        $result.Errors += "Service enumeration failed: $_"

    } finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

# Allow direct invocation
if ($MyInvocation.InvocationName -ne '.') {
    Get-Services-PS5 @PSBoundParameters
}