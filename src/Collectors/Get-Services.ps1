<#
.SYNOPSIS
    Collects running services, startup types, dependencies, and status information.

.DESCRIPTION
    Enumerates all services on target server, including:
    - Service name, display name, status (Running/Stopped)
    - Startup type (Auto/Manual/Disabled)
    - Service account (LocalSystem/NetworkService/User)
    - Executable path
    - Dependencies
    
    Critical for identifying:
    - What keeps the server running (auto-start services)
    - Manual intervention jobs (manual services)
    - Zombie/disabled services (cleanup candidates)
    - Custom/vendor services (non-standard)

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+ (Get-WmiObject), 5.1+ (Get-CimInstance)
    License:      MIT
    
    @CollectorName: Get-Services
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 30
    @Category: core
    @Critical: true
    @Priority: TIER1
    @EstimatedExecutionTime: 8
#>

function Get-Services {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would collect services from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-Services'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        # Build WMI query parameters
        $wmiParams = @{
            Class        = 'Win32_Service'
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }

        if ($Credential) {
            $wmiParams['Credential'] = $Credential
        }

        # Get services
        $services = Get-WmiObject @wmiParams | Sort-Object Name

        if (-not $services) {
            $services = @()
        } elseif ($services -isnot [array]) {
            $services = @($services)
        }

        # Normalize output
        $normalized = @()
        foreach ($svc in $services) {
            $normalized += @{
                ServiceName   = $svc.Name
                DisplayName   = $svc.DisplayName
                Status        = $svc.State
                StartupType   = $svc.StartMode
                ServiceAccount = $svc.StartName
                ExecutablePath = $svc.PathName
                Description   = $svc.Description
                ProcessId     = if ($svc.ProcessId) { $svc.ProcessId } else { $null }
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-Services'
            Data          = $normalized
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($normalized).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-Services'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-Services @PSBoundParameters
}
