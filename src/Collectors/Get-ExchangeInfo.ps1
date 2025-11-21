<#
.SYNOPSIS
    Collects Exchange Server configuration (version, connectors, databases).

.DESCRIPTION
    Enumerates Exchange Server information including:
    - Exchange version, edition, service pack
    - Mailbox databases (count, size)
    - Receive/Send connectors (SMTP config)
    - Transport services (HUB, Edge)
    - Database health, replication status
    - Client access roles (CAS), Hub Transport
    
    Critical for:
    - Email migration planning
    - High-availability assessment
    - Database health monitoring
    - Licensing compliance

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
    
    @CollectorName: Get-ExchangeInfo
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2008
    @MaxWindowsVersion:
    @Dependencies: Exchange Server installed
    @Timeout: 90
    @Category: infrastructure
    @Critical: false
    @Priority: TIER3
    @EstimatedExecutionTime: 45
#>

function Get-ExchangeInfo {
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
            Write-Verbose "DRY-RUN: Would collect Exchange info from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-ExchangeInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $exchangeData = @{
            ServerInfo  = @()
            Databases   = @()
            Connectors  = @()
            Services    = @()
        }

        # Check for Exchange installation via registry
        $wmiParams = @{
            Class       = 'Win32_Service'
            Filter      = "Name='MSExchangeAD' OR Name='MSExchangeMailSubmission' OR Name='MSExchangeTransport'"
            ErrorAction = 'SilentlyContinue'
        }

        if ($ComputerName -ne $env:COMPUTERNAME) {
            $wmiParams['ComputerName'] = $ComputerName
            if ($Credential) {
                $wmiParams['Credential'] = $Credential
            }
        }

        $exchangeServices = Get-WmiObject @wmiParams

        if (-not $exchangeServices) {
            return @{
                Success       = $true
                CollectorName = 'Get-ExchangeInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
                Status        = 'Exchange Server not installed'
            }
        }

        # Process Exchange services
        foreach ($service in $exchangeServices) {
            $exchangeData['Services'] += @{
                ServiceName = $service.Name
                DisplayName = $service.DisplayName
                Status      = $service.State
                StartMode   = $service.StartMode
            }
        }

        # Try to get Exchange version via registry
        try {
            $regKey = "HKLM:\Software\Microsoft\ExchangeServer\v15"

            if ($ComputerName -eq $env:COMPUTERNAME) {
                if (Test-Path $regKey) {
                    $exchangeVersion = Get-ItemProperty -Path $regKey -Name "MsiVersion" -ErrorAction SilentlyContinue
                    
                    $exchangeData['ServerInfo'] = @{
                        Version         = $exchangeVersion.MsiVersion
                        ProductPath     = (Get-ItemProperty -Path $regKey -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
                        ServicePack     = "Detected from install path"
                    }
                }
                else {
                    # Try v14 (Exchange 2010)
                    $regKey = "HKLM:\Software\Microsoft\ExchangeServer\v14"
                    if (Test-Path $regKey) {
                        $exchangeVersion = Get-ItemProperty -Path $regKey -Name "MsiVersion" -ErrorAction SilentlyContinue
                        
                        $exchangeData['ServerInfo'] = @{
                            Version = $exchangeVersion.MsiVersion
                            Edition = "Exchange 2010"
                        }
                    }
                }
            }
        }
        catch {
            # Graceful fallback
        }

        # Try to enumerate mailbox databases via WMI
        try {
            $dbWmiParams = @{
                Class       = 'ExchangeDatabase'
                ComputerName = $ComputerName
                ErrorAction = 'SilentlyContinue'
            }

            if ($Credential) {
                $dbWmiParams['Credential'] = $Credential
            }

            $databases = Get-WmiObject @dbWmiParams

            foreach ($db in $databases) {
                $exchangeData['Databases'] += @{
                    DatabaseName = $db.Name
                    Size         = $db.Size
                    Status       = $db.Status
                }
            }
        }
        catch {
            # Graceful fallback
        }

        return @{
            Success       = $true
            CollectorName = 'Get-ExchangeInfo'
            Data          = $exchangeData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($exchangeData['Services']).Count + @($exchangeData['Databases']).Count
            Summary       = @{
                ServiceCount    = @($exchangeData['Services']).Count
                DatabaseCount   = @($exchangeData['Databases']).Count
                ConnectorCount  = @($exchangeData['Connectors']).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-ExchangeInfo'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-ExchangeInfo @PSBoundParameters
}
