<#
.SYNOPSIS
    Collects file share information including paths, permissions, and accessibility.

.DESCRIPTION
    Enumerates all SMB shares on the server:
    - Share name, path, description
    - Share permissions (ACL)
    - NTFS permissions on underlying directory
    - Approximate share size (if accessible)
    - Last accessed (if available)
    
    Critical for:
    - Data migration scope (how much data to move?)
    - Compliance (where's the sensitive data stored?)
    - Access control audit
    - Orphaned share detection

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
    
    @CollectorName: Get-ShareInfo
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 60
    @Category: infrastructure
    @Critical: true
    @Priority: TIER2
    @EstimatedExecutionTime: 20
#>

function Get-ShareInfo {
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
            Write-Verbose "DRY-RUN: Would collect share info from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-ShareInfo'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $shares = @()

        $wmiParams = @{
            Class        = 'Win32_Share'
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }

        if ($Credential) {
            $wmiParams['Credential'] = $Credential
        }

        $shareList = Get-WmiObject @wmiParams

        if ($shareList) {
            if ($shareList -isnot [array]) {
                $shareList = @($shareList)
            }

            foreach ($share in $shareList) {
                # Skip system shares (ADMIN$, IPC$, C$, etc.)
                if ($share.Name -match '^\w\$$|^(ADMIN|IPC|NETLOGON|SYSVOL)') {
                    continue
                }

                # Try to get share size
                $shareSize = $null
                if ($share.Path -and (Test-Path $share.Path -ErrorAction SilentlyContinue)) {
                    try {
                        $dir = Get-Item -Path $share.Path -ErrorAction Stop
                        $shareSize = (Get-ChildItem -Path $share.Path -Recurse -ErrorAction Stop | 
                            Measure-Object -Sum -Property Length | Select-Object -ExpandProperty Sum)
                    }
                    catch {
                        $shareSize = $null
                    }
                }

                # Get ACL
                $shareAcl = @()
                try {
                    $ntfsPath = "\\$ComputerName\$($share.Name)"
                    $acl = Get-Acl -Path $ntfsPath -ErrorAction SilentlyContinue
                    if ($acl) {
                        foreach ($ace in $acl.Access) {
                            $shareAcl += @{
                                Identity          = $ace.IdentityReference
                                FileSystemRights  = $ace.FileSystemRights
                                AccessControlType = $ace.AccessControlType
                                IsInherited       = $ace.IsInherited
                            }
                        }
                    }
                }
                catch {
                    # ACL retrieval optional
                }

                $shares += @{
                    ShareName      = $share.Name
                    SharePath      = $share.Path
                    Description    = $share.Description
                    ShareSize      = $shareSize
                    ShareType      = $share.Type
                    AccessCount    = $share.AllowMaximumUsers
                    Permissions    = $shareAcl
                    MaxUsers       = if ($share.MaximumAllowed) { $share.MaximumAllowed } else { "Unlimited" }
                }
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-ShareInfo'
            Data          = $shares
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($shares).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-ShareInfo'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-ShareInfo @PSBoundParameters
}
