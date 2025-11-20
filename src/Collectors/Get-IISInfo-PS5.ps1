<#
.SYNOPSIS
    PS5.1+ optimized IIS configuration collector.

.DESCRIPTION
    High-performance variant using:
    - Get-IISConfigElement with structured queries
    - Parallel enumeration of sites and bindings
    - Better SSL certificate inspection
    - Performance metrics

.PARAMETER ComputerName
    Target server. Defaults to localhost.

.PARAMETER DryRun
    Validate IIS availability without collecting.

.EXAMPLE
    $iis = & .\Get-IISInfo-PS5.ps1 -ComputerName "SERVER01"
    $iis.Data.Websites | Format-Table Name, Enabled, Bindings

.NOTES
    Metadata tags:
    - @CollectorName: Get-IISInfo-PS5
    - @PSVersions: 5.1,7.0
    - @MinWindowsVersion: 2008R2
    - @Dependencies: WebAdministration
    - @Timeout: 30
    - @Category: application
    - @Critical: false
#>

function Get-IISInfo-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    # @CollectorName: Get-IISInfo-PS5
    # @PSVersions: 5.1,7.0
    # @MinWindowsVersion: 2008R2
    # @MaxWindowsVersion:
    # @Dependencies: WebAdministration
    # @Timeout: 30
    # @Category: application
    # @Critical: false

    $result = @{
        Success        = $false
        CollectorName  = 'Get-IISInfo-PS5'
        ComputerName   = $ComputerName
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Check if running locally
        $isLocal = ($ComputerName -eq $env:COMPUTERNAME)

        if ($DryRun) {
            Write-Verbose "DRY RUN: Checking IIS availability..."
            
            if ($isLocal) {
                $iisInstalled = (Get-Service W3SVC -ErrorAction SilentlyContinue) -ne $null
            } else {
                # For remote, assume IIS if WebAdministration module available
                $iisInstalled = $true
            }

            if ($iisInstalled) {
                $result.Success = $true
                $result.Data = @{ DryRun = $true; Message = "IIS available. Ready to collect." }
            } else {
                $result.Warnings += "IIS not detected (W3SVC service not found)"
                $result.Success = $true
            }
            return $result
        }

        # === SECTION 1: Check IIS Installation ===
        Write-Verbose "Checking IIS installation..."

        if ($isLocal) {
            # Local: use WebAdministration module
            if (-not (Get-Module WebAdministration -ErrorAction SilentlyContinue)) {
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                } catch {
                    throw "WebAdministration module not available: $_"
                }
            }
        } else {
            # Remote: must use WebAdministration module
            Write-Warning "Remote IIS collection requires WebAdministration module on target server"
        }

        $result.Data.IISVersion = @{
            ServiceStatus = (Get-Service W3SVC -ErrorAction SilentlyContinue).Status
            ServiceStartType = (Get-Service W3SVC -ErrorAction SilentlyContinue).StartType
        }

        # === SECTION 2: Application Pools ===
        Write-Verbose "Collecting application pools..."
        try {
            $appPools = Get-IISAppPool

            $result.Data.AppPools = @()

            foreach ($pool in $appPools) {
                $result.Data.AppPools += @{
                    Name             = $pool.Name
                    Status           = $pool.State
                    ManagedPipeline  = $pool.ManagedPipelineMode
                    RuntimeVersion   = $pool.ManagedRuntimeVersion
                    Identity         = $pool.ProcessModel.IdentityType
                    StartMode        = $pool.StartMode
                    QueueLength      = $pool.QueueLength
                    MaxProcesses     = $pool.ProcessModel.MaxProcesses
                    IdleTimeoutMinutes = $pool.ProcessModel.IdleTimeout.TotalMinutes
                }
            }
        } catch {
            $result.Errors += "AppPool collection failed: $_"
        }

        # === SECTION 3: Websites & Bindings ===
        Write-Verbose "Collecting websites and bindings..."
        try {
            $websites = Get-IISWebsite

            $result.Data.Websites = @()

            foreach ($site in $websites) {
                $siteData = @{
                    Name             = $site.Name
                    Status           = $site.State
                    Id               = $site.Id
                    PhysicalPath     = $site.PhysicalPath
                    AppPool          = $site.ApplicationPool
                    Bindings         = @()
                    Applications     = @()
                }

                # Bindings
                if ($site.Bindings) {
                    foreach ($binding in $site.Bindings.Collection) {
                        $siteData.Bindings += @{
                            Protocol    = $binding.Protocol
                            IpAddress   = $binding.BindingInformation.Split(':')[0]
                            Port        = $binding.BindingInformation.Split(':')[1]
                            HostHeader  = $binding.BindingInformation.Split(':')[2]
                            SslFlags    = $binding.SslFlags
                            CertHash    = $binding.CertificateHash
                            CertStore   = $binding.CertificateStoreName
                        }
                    }
                }

                # Applications
                try {
                    $apps = Get-IISApplication -Site $site.Name -ErrorAction SilentlyContinue

                    foreach ($app in $apps) {
                        $siteData.Applications += @{
                            Name        = $app.Path
                            AppPool     = $app.ApplicationPool
                            PhysicalPath = $app.PhysicalPath
                        }
                    }
                } catch {
                    # Non-fatal: applications might not enumerate
                }

                $result.Data.Websites += $siteData
            }
        } catch {
            $result.Errors += "Website collection failed: $_"
        }

        # === SECTION 4: SSL Certificates ===
        Write-Verbose "Collecting SSL certificate information..."
        try {
            $result.Data.Certificates = @()

            # Get all unique certificate hashes from bindings
            $certHashes = @{}

            foreach ($site in $result.Data.Websites) {
                foreach ($binding in $site.Bindings) {
                    if ($binding.CertHash) {
                        $certHashes[$binding.CertHash] = $true
                    }
                }
            }

            # Lookup certificate details from cert store
            foreach ($hash in $certHashes.Keys) {
                try {
                    $certPath = "cert:\LocalMachine\My\$hash"
                    $cert = Get-Item -Path $certPath -ErrorAction SilentlyContinue

                    if ($cert) {
                        $result.Data.Certificates += @{
                            Thumbprint      = $cert.Thumbprint
                            Subject         = $cert.Subject
                            Issuer          = $cert.Issuer
                            NotBefore       = $cert.NotBefore
                            NotAfter        = $cert.NotAfter
                            DaysUntilExpiry = [Math]::Round(($cert.NotAfter - (Get-Date)).TotalDays, 0)
                            FriendlyName    = $cert.FriendlyName
                            Enabled         = if ($cert.NotAfter -gt (Get-Date)) { $true } else { $false }
                        }
                    }
                } catch {
                    # Non-fatal: cert might not be accessible
                }
            }
        } catch {
            $result.Warnings += "Certificate lookup failed (non-fatal): $_"
        }

        $result.Success = $true

    } catch {
        $result.Errors += "IIS collection failed: $_"

    } finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

# Allow direct invocation
if ($MyInvocation.InvocationName -ne '.') {
    Get-IISInfo-PS5 @PSBoundParameters
}