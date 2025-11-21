<#
.SYNOPSIS
    Collects installed Windows Server roles and features.

.DESCRIPTION
    Enumerates all installed server roles and features, including:
    - Role name (DC, DNS, DHCP, IIS, Hyper-V, etc.)
    - Installation state
    - SubRoles/Features
    - Dependencies
    
    Critical for:
    - Understanding server purpose and scope
    - Migration planning (e.g., DCs need special handling)
    - Feature deprecation tracking
    - Dependency mapping

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
    PowerShell:   2.0+ (WMI query)
    License:      MIT
    
    @CollectorName: Get-ServerRoles
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2008R2
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 30
    @Category: core
    @Critical: true
    @Priority: TIER1
    @EstimatedExecutionTime: 10
#>

function Get-ServerRoles {
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
            Write-Verbose "DRY-RUN: Would collect server roles from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-ServerRoles'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $roles = @()

        # Try PowerShell command first (PS 2.0+)
        if ($ComputerName -eq $env:COMPUTERNAME) {
            # Local query
            try {
                # Try Get-WindowsFeature (PS 3+)
                if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                    $features = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed }
                    
                    foreach ($feature in $features) {
                        $roles += @{
                            Name             = $feature.Name
                            DisplayName      = $feature.DisplayName
                            Installed        = $feature.Installed
                            FeatureType      = $feature.FeatureType
                            SubFeatures      = @($feature.SubFeatures).Count
                            DependsOn        = @($feature.DependsOn).Count
                            Description      = ""
                        }
                    }
                }
                else {
                    # Fall back to WMI
                    $wmiParams = @{
                        Class       = 'Win32_ServerFeature'
                        ErrorAction = 'Stop'
                    }

                    $features = Get-WmiObject @wmiParams

                    if ($features) {
                        if ($features -isnot [array]) {
                            $features = @($features)
                        }

                        foreach ($feature in $features) {
                            $roles += @{
                                Name        = $feature.Name
                                DisplayName = $feature.Name
                                Installed   = $true
                                FeatureType = "Role"
                                SubFeatures = 0
                                DependsOn   = 0
                                Description = ""
                            }
                        }
                    }
                }
            }
            catch {
                Write-Warning "Error querying local roles: $_"
            }
        }
        else {
            # Remote query via WMI
            $wmiParams = @{
                Class        = 'Win32_ServerFeature'
                ComputerName = $ComputerName
                ErrorAction  = 'Stop'
            }

            if ($Credential) {
                $wmiParams['Credential'] = $Credential
            }

            try {
                $features = Get-WmiObject @wmiParams

                if ($features) {
                    if ($features -isnot [array]) {
                        $features = @($features)
                    }

                    foreach ($feature in $features) {
                        $roles += @{
                            Name        = $feature.Name
                            DisplayName = $feature.Name
                            Installed   = $true
                            FeatureType = "Role"
                            SubFeatures = 0
                            DependsOn   = 0
                            Description = ""
                        }
                    }
                }
            }
            catch {
                Write-Warning "Error querying remote roles: $_"
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-ServerRoles'
            Data          = $roles
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($roles).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-ServerRoles'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-ServerRoles @PSBoundParameters
}
