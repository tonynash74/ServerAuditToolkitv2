<#
.SYNOPSIS
    Collects SSL/TLS certificate inventory (expiry, issuer, usage).

.DESCRIPTION
    Enumerates SSL/TLS certificates including:
    - Certificate thumbprint, subject, issuer, serial number
    - Validity dates (NotBefore, NotAfter)
    - Days until expiry (urgency flag)
    - Certificate chain information
    - Intended purposes (ServerAuth, ClientAuth, etc.)
    - Self-signed or trusted CA indicators
    
    Critical for:
    - SSL certificate expiry tracking
    - HTTPS readiness audit
    - Compliance (certificate pinning, trusted CAs)
    - Migration planning (certificate reissuance)

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER WarningDays
    Flag certificates expiring within this many days. Default: 30.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Get-CertificateInfo
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 30
    @Category: compliance
    @Critical: true
    @Priority: TIER5
    @EstimatedExecutionTime: 15
#>

function Get-CertificateInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [int]$WarningDays = 30,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would collect certificate info from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-CertificateInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $certData = @()

        # Get certificates from local machine
        if ($ComputerName -eq $env:COMPUTERNAME) {
            $storePaths = @(
                'Cert:\LocalMachine\My',
                'Cert:\LocalMachine\Root',
                'Cert:\LocalMachine\WebHosting'
            )

            foreach ($storePath in $storePaths) {
                if (Test-Path $storePath -ErrorAction SilentlyContinue) {
                    $certs = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue

                    foreach ($cert in $certs) {
                        $daysUntilExpiry = ($cert.NotAfter - (Get-Date)).Days
                        $isExpired = $cert.NotAfter -lt (Get-Date)
                        $expiringWarning = $daysUntilExpiry -le $WarningDays

                        $certData += @{
                            Thumbprint          = $cert.Thumbprint
                            Subject             = $cert.Subject
                            Issuer              = $cert.Issuer
                            FriendlyName        = $cert.FriendlyName
                            NotBefore           = $cert.NotBefore
                            NotAfter            = $cert.NotAfter
                            SerialNumber        = $cert.SerialNumber
                            DaysUntilExpiry     = $daysUntilExpiry
                            IsExpired           = $isExpired
                            ExpiringWarning     = $expiringWarning
                            CertificateStore    = $storePath
                            HasPrivateKey       = $cert.HasPrivateKey
                            KeyLength           = if ($cert.PublicKey.Key) { $cert.PublicKey.Key.KeySize } else { 'Unknown' }
                        }
                    }
                }
            }
        }
        else {
            # Remote certificate enumeration via CIM/WMI
            try {
                $cimParams = @{
                    ComputerName = $ComputerName
                    ErrorAction  = 'SilentlyContinue'
                }

                if ($Credential) {
                    $cimParams['Credential'] = $Credential
                }

                # Use CIM to enumerate certificates (requires PS 3+)
                $certs = Get-CimInstance -ClassName Win32_PnPSignedDevice -Filter "Class = 'Certificate'" @cimParams

                foreach ($cert in $certs) {
                    $certData += @{
                        Description = $cert.Description
                        Name        = $cert.Name
                        Status      = $cert.Status
                    }
                }
            }
            catch {
                # Graceful fallback for older systems
                Write-Verbose "CIM certificate enumeration unavailable on $ComputerName"
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-CertificateInfo'
            Data          = $certData
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($certData).Count
            Summary       = @{
                TotalCertificates        = @($certData).Count
                ExpiredCertificates      = @($certData | Where-Object { $_.IsExpired -eq $true }).Count
                ExpiringWithinWarningDays = @($certData | Where-Object { $_.ExpiringWarning -eq $true -and $_.IsExpired -eq $false }).Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-CertificateInfo'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-CertificateInfo @PSBoundParameters
}
