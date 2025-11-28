<#
.SYNOPSIS
    PowerShell 5.1+ Hyper-V collector with CIM + replica health insights.

.DESCRIPTION
    Uses the Hyper-V module to enumerate virtual machines, resource assignments,
    replica status, checkpoints, and virtual switches. Provides richer telemetry
    than the PS4 WMI fallback and is optimized for CIM cmdlets.

.NOTES
    @CollectorName: Get-HyperVInfo-PS5
    @PSVersions: 5.1
    @MinWindowsVersion: 2012R2
    @Timeout: 75
#>

function Get-HyperVInfo-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        CollectorName  = 'Get-HyperVInfo-PS5'
        ComputerName   = $ComputerName
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($DryRun) {
            Import-Module Hyper-V -ErrorAction Stop | Out-Null
            $null = Get-VM -ErrorAction Stop | Select-Object -First 1
            $result.Success = $true
            $result.Data = @{ DryRun = $true; Message = 'Hyper-V module and CIM queries available.' }
            return $result
        }

        Import-Module Hyper-V -ErrorAction Stop | Out-Null

        $vms = Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Name                 = $_.Name
                State                = $_.State
                CPUUsage             = $_.CPUUsage
                MemoryAssignedMB     = [Math]::Round($_.MemoryAssigned / 1MB, 0)
                Uptime               = $_.Uptime
                Generation           = $_.Generation
                AutomaticStartAction = $_.AutomaticStartAction
                AutomaticStopAction  = $_.AutomaticStopAction
                ReplicationMode      = $_.ReplicationMode
                ReplicationHealth    = $_.ReplicationHealth
            }
        }

        $resources = Get-VMResourcePool -ErrorAction SilentlyContinue | Select-Object Name, ResourceType, MaximumCount, MinimumCount, ResourceSubType
        $switches  = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType, AllowManagementOS, BandwidthReservationMode
        $adapters  = Get-VMNetworkAdapter -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, SwitchName, MacAddress, Status, @{n='IPAddresses';e={($_.IPAddresses) -join ', '}}
        $replica   = Get-VMReplication -ErrorAction SilentlyContinue | Select-Object VMName, Mode, State, Health, PrimaryServerName, ReplicaServerName, LastReplicationTime
        $checkpoints = Get-VMSnapshot -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, Name, CreationTime, SnapshotType

        $result.Data = @{
            VirtualMachines    = $vms
            ResourcePools      = $resources
            Switches           = $switches
            NetworkAdapters    = $adapters
            Replication        = $replica
            Checkpoints        = $checkpoints
            Notes              = 'Hyper-V module'
        }

        $result.Success = $true
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        $result.Warnings += 'Hyper-V module missing; falling back to PS4 collector.'
        $fallbackPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PS4x\Get-HyperVInfo.ps1'
        if (Test-Path -LiteralPath $fallbackPath) {
            . $fallbackPath
            if (Get-Command Get-HyperVInfo -ErrorAction SilentlyContinue) {
                $fallbackResult = Get-HyperVInfo @PSBoundParameters
                if ($fallbackResult.Success) {
                    return $fallbackResult
                }
                $result.Errors += $fallbackResult.Errors
            }
        }
    }
    catch {
        $result.Errors += $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-HyperVInfo-PS5 @PSBoundParameters
}
