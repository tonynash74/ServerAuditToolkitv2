<#
.SYNOPSIS
    Collects local user accounts and group memberships.

.DESCRIPTION
    Enumerates:
    - Local user accounts (username, SID, description)
    - Group membership (who's in local Administrators, etc.)
    - Account properties (enabled, locked, password expiry)
    - Privilege levels (local admins)
    
    Critical for:
    - Privilege audit (identify excessive local admins)
    - User/account cleanup before decommissioning
    - Orphaned account detection
    - Security hardening assessment

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
    
    @CollectorName: Get-LocalAccounts
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 30
    @Category: infrastructure
    @Critical: false
    @Priority: TIER2
    @EstimatedExecutionTime: 8
#>

function Get-LocalAccounts {
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
            Write-Verbose "DRY-RUN: Would collect local accounts from $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Get-LocalAccounts'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $accounts = @()

        # Get local users
        $wmiParams = @{
            Class        = 'Win32_UserAccount'
            ComputerName = $ComputerName
            Filter       = "LocalAccount=True"
            ErrorAction  = 'Stop'
        }

        if ($Credential) {
            $wmiParams['Credential'] = $Credential
        }

        $users = Get-WmiObject @wmiParams

        if ($users) {
            if ($users -isnot [array]) {
                $users = @($users)
            }

            foreach ($user in $users) {
                # Determine if user is admin
                $isAdmin = $false
                try {
                    $groupWmiParams = @{
                        Class        = 'Win32_GroupUser'
                        ComputerName = $ComputerName
                        Filter       = "GroupComponent.Name='Administrators' AND PartComponent.Name='$($user.Name)'"
                        ErrorAction  = 'Stop'
                    }
                    if ($Credential) {
                        $groupWmiParams['Credential'] = $Credential
                    }

                    $adminCheck = Get-WmiObject @groupWmiParams
                    $isAdmin = $null -ne $adminCheck
                }
                catch {
                    # Ignore errors in admin check
                }

                $accounts += @{
                    Username       = $user.Name
                    FullName       = $user.FullName
                    Description    = $user.Description
                    Enabled        = -not $user.Disabled
                    PasswordChange = $user.PasswordChangeable
                    PasswordExpire = $user.PasswordExpires
                    SID            = $user.SID
                    LocalAdmin     = $isAdmin
                    Lockout        = $user.Lockout
                    AccountType    = if ($user.LocalAccount) { "Local" } else { "Domain" }
                }
            }
        }

        # Get local groups and members
        $groupWmiParams = @{
            Class        = 'Win32_Group'
            ComputerName = $ComputerName
            Filter       = "LocalAccount=True"
            ErrorAction  = 'SilentlyContinue'
        }

        if ($Credential) {
            $groupWmiParams['Credential'] = $Credential
        }

        $groups = Get-WmiObject @groupWmiParams

        if ($groups) {
            if ($groups -isnot [array]) {
                $groups = @($groups)
            }

            foreach ($group in $groups) {
                $members = @()
                try {
                    $memberWmiParams = @{
                        Class        = 'Win32_GroupUser'
                        ComputerName = $ComputerName
                        Filter       = "GroupComponent.Name='$($group.Name)'"
                        ErrorAction  = 'Stop'
                    }
                    if ($Credential) {
                        $memberWmiParams['Credential'] = $Credential
                    }

                    $memberRelations = Get-WmiObject @memberWmiParams
                    foreach ($relation in $memberRelations) {
                        $members += $relation.PartComponent.Name
                    }
                }
                catch {
                    # Ignore errors in member enumeration
                }

                $accounts += @{
                    GroupName     = $group.Name
                    Description   = $group.Description
                    Members       = $members
                    MemberCount   = @($members).Count
                    AccountType   = "Group"
                    LocalAdmin    = $group.Name -eq "Administrators"
                }
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Get-LocalAccounts'
            Data          = $accounts
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($accounts).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-LocalAccounts'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Get-LocalAccounts @PSBoundParameters
}
