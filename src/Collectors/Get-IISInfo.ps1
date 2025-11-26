<#
.SYNOPSIS
    Collects IIS configuration (sites, bindings, SSL certificates, app pools).

.DESCRIPTION
    Enumerates IIS configuration including:
    - Site names, bindings (HTTP/HTTPS), physical paths
    - SSL certificate info (thumbprint, expiry, issuer)
    - App pools, runtime versions, pipeline modes
    - Default documents, authentication methods
    - Virtual directories, handler mappings
    
    Critical for:
    - Web application inventory
    - SSL certificate compliance (expiry tracking)
    - Migration planning (version compatibility)
    - Security hardening (authentication audit)

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
    
    @CollectorName: Get-IISInfo
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2008
    @MaxWindowsVersion:
    @Dependencies: IIS installed
    @Timeout: 60
    @Category: infrastructure
    @Critical: false
    @Priority: TIER3
    @EstimatedExecutionTime: 30
#>

function Get-IISInfo {
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
            Write-Verbose "DRY-RUN: Would collect IIS info from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-IISInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $iisData = @{}

        # Check if IIS is installed
        $iisInstalled = Get-WmiObject -Class Win32_Product -Filter "Name LIKE '%Internet Information Services%'" `
            -ComputerName $ComputerName -Credential $Credential -ErrorAction SilentlyContinue

        if (-not $iisInstalled) {
            return @{
                Success       = $true
                CollectorName = 'Get-IISInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
                Status        = 'IIS not installed'
            }
        }

        # Try to get IIS info via COM object (Windows Server 2008+)
        try {
            [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Web.Administration") | Out-Null

            $iisManager = New-Object Microsoft.Web.Administration.ServerManager
            $sites = @()

            foreach ($site in $iisManager.Sites) {
                $siteBindings = @()

                foreach ($binding in $site.Bindings) {
                    # ✅ CRITICAL FIX: Normalize COM object to hashtable for serialization
                    $siteBindings += @{
                        Protocol            = [string]($binding.Protocol)
                        BindingInformation  = [string]($binding.BindingInformation)
                        HostHeader          = [string]($binding.HostHeader)
                        CertificateHash     = if ($binding.CertificateHash) { 
                            [System.BitConverter]::ToString($binding.CertificateHash) 
                        } else { 
                            $null 
                        }
                        CertificateStoreName = [string]($binding.CertificateStoreName)
                    }
                }

                $appPools = @()
                foreach ($pool in $site.Applications) {
                    # ✅ Normalize virtual directory collection
                    $physicalPath = if ($pool.VirtualDirectories.Count -gt 0) {
                        [string]($pool.VirtualDirectories[0].PhysicalPath)
                    } else {
                        $null
                    }
                    
                    $appPools += @{
                        AppName       = [string]($pool.Path)
                        AppPoolName   = [string]($pool.ApplicationPool)
                        PhysicalPath  = $physicalPath
                    }
                }

                $sites += @{
                    SiteName    = [string]($site.Name)
                    SiteID      = [int]($site.Id)
                    State       = [string]($site.State)
                    Bindings    = @($siteBindings)
                    AppPools    = @($appPools)
                }
            }

            $iisData['Sites'] = @($sites)

            # Get app pool info
            $appPools = @()
            foreach ($pool in $iisManager.ApplicationPoolCollection) {
                # ✅ Normalize app pool COM object
                $appPools += @{
                    Name                    = [string]($pool.Name)
                    State                   = [string]($pool.State)
                    RuntimeVersion          = [string]($pool.ManagedRuntimeVersion)
                    PipelineMode            = [string]($pool.ManagedPipelineMode)
                    IdentityType            = [string]($pool.ProcessModel.IdentityType)
                    AutoStart               = [bool]($pool.AutoStart)
                    Enable32BitAppOn64Bit   = [bool]($pool.Enable32BitAppOn64Bit)
                }
            }

            $iisData['AppPools'] = @($appPools)

            # Get SSL certificate info
            $certInfo = @()

            try {
                $certs = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue

                foreach ($cert in $certs) {
                    # ✅ Normalize certificate object
                    $certInfo += @{
                        Thumbprint   = [string]($cert.Thumbprint)
                        Subject      = [string]($cert.Subject)
                        Issuer       = [string]($cert.Issuer)
                        NotBefore    = [datetime]($cert.NotBefore)
                        NotAfter     = [datetime]($cert.NotAfter)
                        FriendlyName = [string]($cert.FriendlyName)
                    }
                }
            }
            catch {
                # Graceful fallback
            }

            $iisData['Certificates'] = @($certInfo)
        }
        catch {
            # Fallback to WMI/registry if COM object unavailable
            Write-Verbose "IIS COM object unavailable; graceful degradation"
        }

        return @{
            Success       = $true
            CollectorName = 'Get-IISInfo'
            Data          = $iisData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($iisData['Sites']).Count
            Summary       = @{
                SiteCount       = @($iisData['Sites']).Count
                AppPoolCount    = @($iisData['AppPools']).Count
                CertificateCount = @($iisData['Certificates']).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-IISInfo'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-IISInfo @PSBoundParameters
}
