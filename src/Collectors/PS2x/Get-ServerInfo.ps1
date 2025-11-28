<#
.SYNOPSIS
    PowerShell 2.0 friendly server information collector (WMI only).

.DESCRIPTION
    Gathers core operating system, hardware, network, and disk information using
    only Win32_* WMI classes so that the collector can run on PS 2.0 and 4.0.
    Mirrors the structure returned by the PS5+ variant to keep downstream
    consumers consistent.

.PARAMETER ComputerName
    Target computer (defaults to localhost).

.PARAMETER Credential
    Optional credential for remote queries.

.PARAMETER DryRun
    Skip data collection and just validate connectivity.

.NOTES
    @CollectorName: Get-ServerInfo
    @PSVersions: 2.0,4.0
    @MinWindowsVersion: 2008
    @Timeout: 35
#>

function Get-ServerInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        CollectorName  = 'Get-ServerInfo'
        ComputerName   = $ComputerName
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    function Convert-WmiDate {
        param([string]$DateString)
        if ([string]::IsNullOrEmpty($DateString)) { return $null }
        try {
            return [System.Management.ManagementDateTimeConverter]::ToDateTime($DateString)
        } catch {
            return $null
        }
    }

    $wmiParams = @{ ErrorAction = 'Stop' }
    if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) {
        $wmiParams.ComputerName = $ComputerName
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $wmiParams.Credential = $Credential
        }
    }

    try {
        if ($DryRun) {
            $null = Get-WmiObject -Class Win32_OperatingSystem @wmiParams -ErrorAction Stop
            $result.Success = $true
            $result.Data = @{ DryRun = $true; Message = 'WMI connectivity validated.' }
            return $result
        }

        # Operating system
        Write-Verbose ("Collecting OS info from {0}" -f $ComputerName)
        $os = Get-WmiObject -Class Win32_OperatingSystem @wmiParams
        if ($os) {
            $lastBoot = Convert-WmiDate $os.LastBootUpTime
            $result.Data.OperatingSystem = @{
                ComputerName          = $os.CSName
                OSName                = $os.Caption
                Version               = $os.Version
                BuildNumber           = $os.BuildNumber
                OSArchitecture        = $os.OSArchitecture
                InstallDate           = Convert-WmiDate $os.InstallDate
                LastBootUpTime        = $lastBoot
                SystemUptime          = if ($lastBoot) { [Math]::Round(((Get-Date) - $lastBoot).TotalDays, 2) } else { 0 }
                TotalVisibleMemoryGB  = [Math]::Round(($os.TotalVisibleMemorySize / 1MB), 2)
                FreePhysicalMemoryGB  = [Math]::Round(($os.FreePhysicalMemory / 1MB), 2)
                SystemDirectory       = $os.SystemDirectory
                WindowsDirectory      = $os.WindowsDirectory
            }
        }

        # Hardware
        Write-Verbose ("Collecting hardware info from {0}" -f $ComputerName)
        $cs = Get-WmiObject -Class Win32_ComputerSystem @wmiParams
        if ($cs) {
            $result.Data.Hardware = @{
                Manufacturer            = $cs.Manufacturer
                Model                   = $cs.Model
                SystemType              = $cs.SystemType
                NumberOfProcessors      = $cs.NumberOfProcessors
                NumberOfLogicalProcessors= $cs.NumberOfLogicalProcessors
                TotalPhysicalMemoryGB   = [Math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
                Domain                  = $cs.Domain
                PartOfDomain            = $cs.PartOfDomain
            }
        }

        $cpu = Get-WmiObject -Class Win32_Processor @wmiParams | Select-Object -First 1
        if ($cpu) {
            $result.Data.Processor = @{
                Name              = $cpu.Name
                NumberOfCores     = $cpu.NumberOfCores
                NumberOfLogical   = $cpu.NumberOfLogicalProcessors
                MaxClockGHz       = [Math]::Round(($cpu.MaxClockSpeed / 1000), 2)
                CurrentClockGHz   = [Math]::Round(($cpu.CurrentClockSpeed / 1000), 2)
            }
        }

        # Network adapters
        Write-Verbose ("Collecting network adapters from {0}" -f $ComputerName)
        $nics = Get-WmiObject -Class Win32_NetworkAdapterConfiguration @wmiParams | Where-Object { $_.IPEnabled }
        $result.Data.Network = @{ Adapters = @() }
        foreach ($nic in $nics) {
            $result.Data.Network.Adapters += @{
                Description     = $nic.Description
                MACAddress      = $nic.MACAddress
                IPAddress       = ($nic.IPAddress -join ', ')
                IPSubnet        = ($nic.IPSubnet -join ', ')
                DefaultGateway  = ($nic.DefaultIPGateway -join ', ')
                DNSServers      = ($nic.DNSServerSearchOrder -join ', ')
                DHCPEnabled     = $nic.DHCPEnabled
                DHCPServer      = $nic.DHCPServer
            }
        }

        # Roles / features via Win32_ServerFeature if DISM cmdlets missing
        try {
            if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                $features = Get-WindowsFeature | Where-Object { $_.Installed }
                $result.Data.RolesAndFeatures = @{
                    Roles    = @($features | Where-Object { $_.FeatureType -eq 'Role' } | ForEach-Object { $_.Name })
                    Features = @($features | Where-Object { $_.FeatureType -eq 'Feature' } | ForEach-Object { $_.Name })
                }
            } else {
                $features = Get-WmiObject -Class Win32_ServerFeature @wmiParams
                $result.Data.RolesAndFeatures = @{
                    Roles    = @($features | Where-Object { $_.ParentID -eq 0 } | ForEach-Object { $_.Name })
                    Features = @($features | Where-Object { $_.ParentID -ne 0 } | ForEach-Object { $_.Name })
                }
            }
        } catch {
            $result.Warnings += ("Role/feature discovery failed: {0}" -f $_.Exception.Message)
        }

        # Logical disks
        Write-Verbose ("Collecting disks from {0}" -f $ComputerName)
        $disks = Get-WmiObject -Class Win32_LogicalDisk @wmiParams
        $result.Data.Disks = @()
        foreach ($disk in $disks) {
            if ($disk.Size -and $disk.Size -gt 0) {
                $freePct = [Math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
            } else {
                $freePct = 0
            }
            $result.Data.Disks += @{
                DeviceID    = $disk.DeviceID
                VolumeName  = $disk.VolumeName
                FileSystem  = $disk.FileSystem
                SizeGB      = if ($disk.Size) { [Math]::Round(($disk.Size / 1GB), 2) } else { 0 }
                FreeSpaceGB = if ($disk.FreeSpace) { [Math]::Round(($disk.FreeSpace / 1GB), 2) } else { 0 }
                PercentFree = $freePct
            }
        }

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
    Get-ServerInfo @PSBoundParameters
}
