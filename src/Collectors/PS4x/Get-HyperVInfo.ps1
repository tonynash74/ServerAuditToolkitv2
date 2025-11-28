<#
.SYNOPSIS
    PowerShell 4.x compatible Hyper-V collector with WMI fallback.

.DESCRIPTION
    Uses the Hyper-V module when present; otherwise falls back to legacy WMI
    namespaces (root\virtualization / root\virtualization\v2) so that Hyper-V
    hosts running Windows Server 2012 R2 still report useful inventory data.

.NOTES
    @CollectorName: Get-HyperVInfo
    @PSVersions: 4.0
    @MinWindowsVersion: 2012R2
    @Timeout: 60
#>

function Get-HyperVInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        CollectorName  = 'Get-HyperVInfo'
        ComputerName   = $ComputerName
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    function Get-WmiNamespace {
        $ns = 'root\virtualization\v2'
        try {
            Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -ErrorAction Stop | Out-Null
            return $ns
        } catch {
            return 'root\virtualization'
        }
    }

    try {
        if ($DryRun) {
            if (Get-Module -ListAvailable -Name Hyper-V) {
                $result.Data = @{ DryRun = $true; Message = 'Hyper-V module detected.' }
            } else {
                $ns = Get-WmiNamespace
                $result.Data = @{ DryRun = $true; Message = "Hyper-V module missing; WMI namespace $ns reachable." }
            }
            $result.Success = $true
            return $result
        }

        $data = @{}
        $notes = 'Hyper-V module'

        if (Get-Module -ListAvailable -Name Hyper-V) {
            try {
                Import-Module Hyper-V -ErrorAction Stop | Out-Null
                $data.VirtualMachines = Get-VM -ErrorAction SilentlyContinue | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime, Generation, Path, AutomaticStartAction, AutomaticStopAction
                $data.NetworkAdapters = Get-VMNetworkAdapter -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, SwitchName, MacAddress, @{n='IPv4';e={($_.IPAddresses | Where-Object { $_ -match '^(?:\d+\.){3}\d+$' }) -join ', '}}
                $data.Switches = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType, AllowManagementOS
                $data.Disks = Get-VMHardDiskDrive -VMName * -ErrorAction SilentlyContinue | Select-Object VMName, Path, ControllerType, ControllerNumber, ControllerLocation
            } catch {
                $result.Warnings += 'Failed to query via Hyper-V module; falling back to WMI.'
                $notes = 'WMI fallback'
                $data = @{}
            }
        } else {
            $notes = 'WMI fallback'
        }

        if ($notes -eq 'WMI fallback') {
            $ns = Get-WmiNamespace
            $vmClass = 'Msvm_ComputerSystem'
            $vms = Get-WmiObject -Namespace $ns -Class $vmClass -ErrorAction SilentlyContinue | Where-Object { $_.Caption -eq 'Virtual Machine' }
            $vmOutput = @()
            foreach ($vm in $vms) {
                $stateMap = @{ 2='Running'; 3='Stopped'; 32768='Paused'; 32769='Suspended' }
                $uptime = $null
                if ($vm.OnTimeInMilliseconds) {
                    $uptime = [TimeSpan]::FromMilliseconds([double]$vm.OnTimeInMilliseconds)
                }
                $vmOutput += [pscustomobject]@{
                    Name   = $vm.ElementName
                    State  = $stateMap[[int]$vm.EnabledState]
                    Uptime = $uptime
                    Path   = $vm.Path
                }
            }
            $data.VirtualMachines = $vmOutput
            $data.NetworkAdapters = @()
            $data.Switches        = @()
            $data.Disks           = @()
            $data.Namespace       = $ns
        }

        $result.Data = $data
        $result.Data.Notes = $notes
        $result.Success = $true
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
    Get-HyperVInfo @PSBoundParameters
}
