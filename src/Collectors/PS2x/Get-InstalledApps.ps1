<#
.SYNOPSIS
    Collects installed applications from registry and WMI.

.DESCRIPTION
    Enumerates all installed applications by querying:
    - HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall (64-bit)
    - HKEY_LOCAL_MACHINE\Software\Wow6432Node\Uninstall (32-bit on 64-bit OS)
    
    Returns: Application name, version, vendor, install date, size, uninstall command.
    
    Critical for:
    - Identifying unsupported/deprecated software
    - License tracking
    - Application migration dependencies
    - Version compatibility assessment

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
    
    @CollectorName: Get-InstalledApps
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 45
    @Category: core
    @Critical: true
    @Priority: TIER1
    @EstimatedExecutionTime: 15
#>

function Get-InstalledApps {
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
            Write-Verbose "DRY-RUN: Would collect installed apps from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-InstalledApps'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $apps = @()

        if ($ComputerName -eq $env:COMPUTERNAME) {
            # Local registry query (faster)
            $regPaths = @(
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )

            foreach ($path in $regPaths) {
                if (Test-Path $path) {
                    $keys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
                    foreach ($key in $keys) {
                        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                        
                        if ($props.DisplayName) {
                            $apps += @{
                                DisplayName   = $props.DisplayName
                                Version       = $props.DisplayVersion
                                Publisher     = $props.Publisher
                                InstallDate   = if ($props.InstallDate) { [datetime]::ParseExact($props.InstallDate, 'yyyyMMdd', $null) } else { $null }
                                InstallLocation = $props.InstallLocation
                                UninstallString = $props.UninstallString
                                EstimatedSize = if ($props.EstimatedSize) { [int]$props.EstimatedSize * 1024 } else { $null }  # Convert KB to bytes
                                ProductCode   = $key.PSChildName
                            }
                        }
                    }
                }
            }
        }
        else {
            # Remote registry query via WMI
            $wmiParams = @{
                Class        = 'Win32_Product'
                ComputerName = $ComputerName
                ErrorAction  = 'Stop'
            }

            if ($Credential) {
                $wmiParams['Credential'] = $Credential
            }

            $products = Get-WmiObject @wmiParams

            if ($products) {
                if ($products -isnot [array]) {
                    $products = @($products)
                }

                foreach ($product in $products) {
                    $apps += @{
                        DisplayName      = $product.Name
                        Version          = $product.Version
                        Publisher        = $product.Vendor
                        InstallDate      = if ($product.InstallDate) { [datetime]::ParseExact($product.InstallDate, 'yyyyMMdd', $null) } else { $null }
                        InstallLocation  = $product.InstallLocation
                        UninstallString  = $product.UninstallString
                        EstimatedSize    = $product.Size
                        ProductCode      = $product.IdentifyingNumber
                    }
                }
            }
        }

        # Sort by name
        $apps = $apps | Sort-Object -Property DisplayName -Unique

        return @{
            Success       = $true
            CollectorName = 'Get-InstalledApps'
            Data          = $apps
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($apps).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-InstalledApps'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-InstalledApps @PSBoundParameters
}
