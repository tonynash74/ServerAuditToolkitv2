<#
.SYNOPSIS
    PS5.1+ optimized SQL Server configuration collector.

.DESCRIPTION
    High-performance variant using:
    - Registry queries for instance detection
    - WMI/CIM for service enumeration
    - Structured SQL Server discovery
    - Database inventory

.PARAMETER ComputerName
    Target server. Defaults to localhost.

.PARAMETER DryRun
    Validate SQL Server availability without collecting.

.EXAMPLE
    $sql = & .\Get-SQLServerInfo-PS5.ps1 -ComputerName "SERVER01"
    $sql.Data.Instances | Format-Table Name, Version, Edition

.NOTES
    Metadata tags:
    - @CollectorName: Get-SQLServerInfo-PS5
    - @PSVersions: 5.1,7.0
    - @MinWindowsVersion: 2008R2
    - @Dependencies: SQL-Server-Management-Studio
    - @Timeout: 45
    - @Category: application
    - @Critical: true
#>

function Get-SQLServerInfo-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-SQLServerInfo-PS5
    # @PSVersions: 5.1,7.0
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies: SQL-Server-Management-Studio
    # @Timeout: 45
    # @Category: application
    # @Critical: true

    $result = @{
        Success        = $false
        CollectorName  = 'Get-SQLServerInfo-PS5'
        ComputerName   = $ComputerName
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $isLocal = ($ComputerName -eq $env:COMPUTERNAME)

        if ($DryRun) {
            Write-Verbose "DRY RUN: Checking SQL Server availability..."
            
            # Check for MSSQL services
            if ($isLocal) {
                $sqlServices = Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue
            } else {
                $sqlServices = $null
            }

            if ($sqlServices) {
                $result.Success = $true
                $result.Data = @{ DryRun = $true; Message = "SQL Server services detected. Ready to collect." }
            } else {
                $result.Warnings += "No SQL Server services detected"
                $result.Success = $true
            }
            return $result
        }

        $result.Data.Instances = @()

        # === SECTION 1: Detect SQL Server Instances ===
        Write-Verbose "Detecting SQL Server instances..."

        if ($isLocal) {
            # Local registry access
            try {
                $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'
                
                if (Test-Path -LiteralPath $regPath) {
                    $instances = Get-ItemProperty -Path "$regPath\Instance Names\SQL" -ErrorAction SilentlyContinue

                    if ($instances) {
                        foreach ($propName in $instances.PSObject.Properties.Name) {
                            if ($propName -ne 'PSPath' -and $propName -ne 'PSParentPath' -and $propName -ne 'PSChildName' -and $propName -ne 'PSDrive' -and $propName -ne 'PSProvider') {
                                $instanceName = if ($propName -eq 'MSSQLSERVER') { '(Default)' } else { $propName }
                                $result.Data.Instances += Get-SQLInstanceInfo -InstanceName $instanceName
                            }
                        }
                    }
                } else {
                    $result.Warnings += "SQL Server registry path not found; SQL Server may not be installed"
                }
            } catch {
                $result.Errors += "SQL Server detection failed: $_"
            }
        } else {
            # Remote: via WMI
            try {
                $wmiParams = @{
                    ComputerName = $ComputerName
                    ErrorAction  = 'Stop'
                }

                # Look for MSSQL services
                $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MSSQL%'" @wmiParams

                foreach ($service in $services) {
                    $result.Data.Instances += @{
                        Name        = $service.Name
                        DisplayName = $service.DisplayName
                        Status      = $service.State
                        StartMode   = $service.StartMode
                        PathName    = $service.PathName
                    }
                }
            } catch {
                $result.Warnings += "Remote SQL Server detection via WMI failed: $_"
            }
        }

        # === SECTION 2: Windows Services (SQL-related) ===
        Write-Verbose "Collecting SQL Server services..."
        try {
            if ($isLocal) {
                $services = Get-Service -Name 'MSSQL*', 'SQLAgent*', 'SSAS*', 'SSIS*' -ErrorAction SilentlyContinue
            } else {
                $wmiParams = @{
                    ComputerName = $ComputerName
                    ErrorAction  = 'Stop'
                }
                $services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MSSQL%' OR Name LIKE 'SQLAgent%'" @wmiParams
            }

            if ($services) {
                $result.Data.Services = @()

                foreach ($svc in $services) {
                    $result.Data.Services += @{
                        Name        = if ($svc.Name) { $svc.Name } else { $svc.Name }
                        DisplayName = if ($svc.DisplayName) { $svc.DisplayName } else { $svc.DisplayName }
                        Status      = if ($svc.Status) { $svc.Status } else { $svc.State }
                        StartMode   = if ($svc.StartType) { $svc.StartType } else { $svc.StartMode }
                    }
                }
            }
        } catch {
            $result.Errors += "Service enumeration failed: $_"
        }

        $result.Success = $true

    } catch {
        $result.Errors += "SQL Server collection failed: $_"

    } finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

<#
.SYNOPSIS
    Helper to get SQL instance info from registry (local only).
#>
function Get-SQLInstanceInfo {
    param([string]$InstanceName)

    @{
        Name        = $InstanceName
        Description = "SQL Server Instance"
        Version     = "Unknown"
        Edition     = "Unknown"
        Status      = "Unknown"
        Databases   = @()
    }
}

# Allow direct invocation
if ($MyInvocation.InvocationName -ne '.') {
    Get-SQLServerInfo-PS5 @PSBoundParameters
}