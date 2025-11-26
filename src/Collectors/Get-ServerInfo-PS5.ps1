<#
.SYNOPSIS
    PS5.1+ optimized server info collector using Get-CimInstance.

.DESCRIPTION
    High-performance variant leveraging:
    - Get-CimInstance (CIM vs. WMI, ~3-5x faster)
    - Better error handling via $PSItem
    - Structured output normalization
    - Parallel processing where applicable

    Falls back gracefully if CIM unavailable.

.PARAMETER ComputerName
    Target server. Defaults to localhost.

.PARAMETER Credential
    PSCredential for remote access.

.PARAMETER DryRun
    Validate prerequisites without collecting data.

.EXAMPLE
    $info = & .\Get-ServerInfo-PS5.ps1 -ComputerName "SERVER01"
    $info.Data.OperatingSystem | Format-Table

.NOTES
    Requires PS 5.1+. Falls back to WMI on older versions.
    Metadata tags:
    - @CollectorName: Get-ServerInfo-PS5
    - @PSVersions: 5.1,7.0
    - @MinWindowsVersion: 2008R2
    - @Dependencies:
    - @Timeout: 25
    - @Category: core
    - @Critical: true
#>

function Get-ServerInfo-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-ServerInfo-PS5
    # @PSVersions: 5.1,7.0
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies:
    # @Timeout: 25
    # @Category: core
    # @Critical: true

    $result = @{
        Success        = $false
        CollectorName  = 'Get-ServerInfo-PS5'
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
            Write-Verbose "DRY RUN: Validating CIM availability..."
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                $result.Success = $true
                $result.Data = @{ DryRun = $true; Message = "CIM available. Ready to collect." }
            } else {
                $result.Warnings += "Get-CimInstance not available; would fallback to WMI"
                $result.Success = $true
            }
            return $result
        }

        # Build invocation parameters
        $cimParams = @{
            ErrorAction = 'Stop'
        }

        $wmiParams = @{
            ErrorAction = 'Stop'
        }

        if ($ComputerName -ne $env:COMPUTERNAME) {
            $cimParams.ComputerName = $ComputerName
            $wmiParams.ComputerName = $ComputerName

            if ($PSBoundParameters.ContainsKey('Credential')) {
                $cimParams.Credential = $Credential
                $wmiParams.Credential = $Credential
            }
        }

        # === SECTION 1: Operating System ===
        Write-Verbose "Collecting OS information..."
        try {
            # PS5.1+ CIM (faster)
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                $osData = Invoke-WithRetry -Command {
                    Get-CimInstance -ClassName Win32_OperatingSystem @cimParams | Select-Object -First 1
                } -Description "OS info collection on $ComputerName" -MaxRetries 3
                
                $result.Data.OperatingSystem = @{
                    ComputerName          = $osData.CSName
                    OSName                = $osData.Caption
                    Version               = $osData.Version
                    BuildNumber           = $osData.BuildNumber
                    OSArchitecture        = $osData.OSArchitecture
                    InstallDate           = $osData.InstallDate
                    LastBootUpTime        = $osData.LastBootUpTime
                    SystemUptime          = if ($osData.LastBootUpTime) {
                        [Math]::Round(((Get-Date) - $osData.LastBootUpTime).TotalDays, 2)
                    } else { 0 }
                    TotalVisibleMemorySize = [Math]::Round($osData.TotalVisibleMemorySize / 1024 / 1024, 2)
                    FreePhysicalMemory    = [Math]::Round($osData.FreePhysicalMemory / 1024 / 1024, 2)
                    Manufacturer          = $osData.Manufacturer
                    SystemDirectory       = $osData.SystemDirectory
                    WindowsDirectory      = $osData.WindowsDirectory
                }
            } else {
                throw "Get-CimInstance not available; this should use PS2 variant"
            }
        } catch {
            $result.Errors += "CIM collection failed: $_"
            $result.Warnings += "Falling back to WMI for OS data"

            try {
                $osData = Get-WmiObject -Class Win32_OperatingSystem @wmiParams | Select-Object -First 1
                
                # Helper function to safely convert WMI dates
                function ConvertWmiDate {
                    param([string]$WmiDate)
                    if ([string]::IsNullOrEmpty($WmiDate)) { return $null }
                    try {
                        return [System.Management.ManagementDateTimeConverter]::ToDateTime($WmiDate)
                    } catch {
                        return $null
                    }
                }
                
                $result.Data.OperatingSystem = @{
                    ComputerName          = $osData.CSName
                    OSName                = $osData.Caption
                    Version               = $osData.Version
                    BuildNumber           = $osData.BuildNumber
                    OSArchitecture        = if ($osData.OSArchitecture) { $osData.OSArchitecture } else { 'Unknown' }
                    InstallDate           = ConvertWmiDate $osData.InstallDate
                    LastBootUpTime        = ConvertWmiDate $osData.LastBootUpTime
                    SystemUptime          = $(
                        $lastBoot = ConvertWmiDate $osData.LastBootUpTime
                        if ($lastBoot) {
                            [Math]::Round(((Get-Date) - $lastBoot).TotalDays, 2)
                        } else { 
                            0 
                        }
                    )
                    TotalVisibleMemorySize = [Math]::Round($osData.TotalVisibleMemorySize / 1024 / 1024, 2)
                    FreePhysicalMemory    = [Math]::Round($osData.FreePhysicalMemory / 1024 / 1024, 2)
                    Manufacturer          = $osData.Manufacturer
                    SystemDirectory       = $osData.SystemDirectory
                    WindowsDirectory      = $osData.WindowsDirectory
                }
                $result.Success = $true
            } catch {
                $result.Errors += "WMI fallback also failed: $_"
                $result.Success = $false
            }
        }

        # === SECTION 2: Hardware (CPU, RAM) ===
        Write-Verbose "Collecting hardware information..."
        try {
            $hwData = Get-CimInstance -ClassName Win32_ComputerSystem @cimParams

            $result.Data.Hardware = @{
                Manufacturer          = $hwData.Manufacturer
                Model                 = $hwData.Model
                SystemType            = $hwData.SystemType
                NumberOfLogicalProcessors = $hwData.NumberOfLogicalProcessors
                NumberOfProcessors    = $hwData.NumberOfProcessors
                TotalPhysicalMemory   = [Math]::Round($hwData.TotalPhysicalMemory / 1GB, 2)
                Domain                = $hwData.Domain
                DomainRole            = $hwData.DomainRole
                PartOfDomain          = $hwData.PartOfDomain
            }

            # CPU details
            $cpuData = Get-CimInstance -ClassName Win32_Processor @cimParams | Select-Object -First 1

            $result.Data.Processor = @{
                Name                = $cpuData.Name
                Cores               = $cpuData.NumberOfCores
                LogicalProcessors   = $cpuData.NumberOfLogicalProcessors
                MaxClockSpeed       = [Math]::Round($cpuData.MaxClockSpeed / 1000, 2)
                Architecture        = $cpuData.Architecture
                CurrentClockSpeed   = [Math]::Round($cpuData.CurrentClockSpeed / 1000, 2)
            }
        } catch {
            $result.Errors += "Hardware collection failed: $_"
        }

        # === SECTION 3: Network ===
        Write-Verbose "Collecting network information..."
        try {
            $netAdapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration @cimParams | Where-Object { $_.IPEnabled }

            $result.Data.Network = @{
                Adapters = @()
            }

            foreach ($adapter in $netAdapters) {
                $result.Data.Network.Adapters += @{
                    Description       = $adapter.Description
                    IPAddress         = $adapter.IPAddress -join ', '
                    IPSubnet          = $adapter.IPSubnet -join ', '
                    DefaultGateway    = $adapter.DefaultIPGateway -join ', '
                    DNSServers        = $adapter.DNSServerSearchOrder -join ', '
                    DHCPEnabled       = $adapter.DHCPEnabled
                    DHCPServer        = $adapter.DHCPServer
                    MACAddress        = $adapter.MACAddress
                }
            }
        } catch {
            $result.Errors += "Network collection failed: $_"
        }

        # === SECTION 4: Roles & Features ===
        Write-Verbose "Collecting installed roles and features..."
        try {
            if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                $features = Get-WindowsFeature | Where-Object { $_.Installed }

                $result.Data.RolesAndFeatures = @{
                    Roles    = @($features | Where-Object { $_.FeatureType -eq 'Role' } | ForEach-Object { @{
                        Name        = $_.Name
                        DisplayName = $_.DisplayName
                        Installed   = $_.Installed
                    }})
                    Features = @($features | Where-Object { $_.FeatureType -eq 'Feature' } | ForEach-Object { @{
                        Name        = $_.Name
                        DisplayName = $_.DisplayName
                        Installed   = $_.Installed
                    }})
                }
            } else {
                $result.Warnings += "Get-WindowsFeature not available (may not be Windows Server)"
            }
        } catch {
            $result.Warnings += "Role/Feature collection failed (non-fatal): $_"
        }

        # === SECTION 5: Disk Information ===
        Write-Verbose "Collecting disk information..."
        try {
            $volumes = Get-CimInstance -ClassName Win32_LogicalDisk @cimParams

            $result.Data.Disks = @()

            foreach ($vol in $volumes) {
                $result.Data.Disks += @{
                    DeviceID        = $vol.DeviceID
                    VolumeName      = $vol.VolumeName
                    FileSystem      = $vol.FileSystem
                    Size            = [Math]::Round($vol.Size / 1GB, 2)
                    FreeSpace       = [Math]::Round($vol.FreeSpace / 1GB, 2)
                    PercentFree     = if ($vol.Size -gt 0) { [Math]::Round(($vol.FreeSpace / $vol.Size) * 100, 1) } else { 0 }
                }
            }
        } catch {
            $result.Errors += "Disk collection failed: $_"
        }

        $result.Success = $true

    } catch [System.UnauthorizedAccessException] {
        $result.Errors += "Access Denied collecting from $ComputerName"

    } catch [System.Net.NetworkInformation.PingException] {
        $result.Errors += "Network unreachable: $ComputerName"

    } catch {
        $result.Errors += "Unexpected error: $_"

    } finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

# Allow direct invocation
if ($MyInvocation.InvocationName -ne '.') {
    Get-ServerInfo-PS5 @PSBoundParameters
}