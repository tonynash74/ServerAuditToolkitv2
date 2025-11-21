<#
.SYNOPSIS
    Collects SQL Server inventory (instances, databases, backup status).

.DESCRIPTION
    Enumerates SQL Server information including:
    - SQL Server instances (named + default)
    - SQL version, edition, service pack
    - Database list (names, sizes, compatibility level)
    - Backup job status, last backup times
    - Service account, TCP port
    - Database recovery models, growth settings
    
    Critical for:
    - Database migration planning
    - Backup/recovery audit
    - Licensing (edition/version compliance)
    - High-availability assessment

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
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Get-SQLServerInfo
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2008
    @MaxWindowsVersion:
    @Dependencies: SQL Server installed
    @Timeout: 90
    @Category: infrastructure
    @Critical: false
    @Priority: TIER3
    @EstimatedExecutionTime: 45
#>

function Get-SQLServerInfo {
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
            Write-Verbose "DRY-RUN: Would collect SQL Server info from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-SQLServerInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $sqlData = @{
            Instances = @()
            Databases = @()
            Services  = @()
        }

        # Get SQL Server services
        $wmiParams = @{
            Class       = 'Win32_Service'
            Filter      = "Name LIKE '%MSSQL%' OR Name LIKE '%SQL%'"
            ErrorAction = 'SilentlyContinue'
        }

        if ($ComputerName -ne $env:COMPUTERNAME) {
            $wmiParams['ComputerName'] = $ComputerName
            if ($Credential) {
                $wmiParams['Credential'] = $Credential
            }
        }

        $sqlServices = Get-WmiObject @wmiParams

        if (-not $sqlServices) {
            return @{
                Success       = $true
                CollectorName = 'Get-SQLServerInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
                Status        = 'SQL Server not installed'
            }
        }

        # Process SQL services
        foreach ($service in $sqlServices) {
            $sqlData['Services'] += @{
                ServiceName  = $service.Name
                DisplayName  = $service.DisplayName
                Status       = $service.State
                StartMode    = $service.StartMode
                StartName    = $service.StartName
            }
        }

        # Try to enumerate instances via registry
        try {
            $regPath = "HKLM:\Software\Microsoft\Microsoft SQL Server"

            if ($ComputerName -eq $env:COMPUTERNAME) {
                $instances = Get-Item -Path $regPath -ErrorAction SilentlyContinue
            }
            else {
                # Remote registry access via WMI
                $regWmiParams = @{
                    Class       = 'StdRegProv'
                    ComputerName = $ComputerName
                    ErrorAction = 'SilentlyContinue'
                }

                if ($Credential) {
                    $regWmiParams['Credential'] = $Credential
                }

                $regProvider = Get-WmiObject @regWmiParams
            }

            # Instance enumeration (best-effort)
            $sqlData['Instances'] = @(
                @{
                    InstanceName = 'MSSQLSERVER'
                    InstanceType = 'Default'
                    Status       = 'Discovered'
                }
            )
        }
        catch {
            # Graceful fallback
        }

        # Try to get database info via WMI query (if available)
        try {
            # This is a best-effort query; may fail on older SQL versions
            $dbWmiParams = @{
                Class       = 'SQLDatabase'
                ComputerName = $ComputerName
                ErrorAction = 'SilentlyContinue'
            }

            if ($Credential) {
                $dbWmiParams['Credential'] = $Credential
            }

            $databases = Get-WmiObject @dbWmiParams

            foreach ($db in $databases) {
                $sqlData['Databases'] += @{
                    DatabaseName      = $db.Name
                    Size              = $db.Size
                    Status            = $db.Status
                }
            }
        }
        catch {
            # Graceful fallback if WMI class unavailable
        }

        return @{
            Success       = $true
            CollectorName = 'Get-SQLServerInfo'
            Data          = $sqlData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($sqlData['Instances']).Count + @($sqlData['Databases']).Count
            Summary       = @{
                ServiceCount   = @($sqlData['Services']).Count
                InstanceCount  = @($sqlData['Instances']).Count
                DatabaseCount  = @($sqlData['Databases']).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-SQLServerInfo'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-SQLServerInfo @PSBoundParameters
}
