<#
.SYNOPSIS
    PowerShell 5.1+ Active Directory collector using the AD module + replication cmdlets.

.DESCRIPTION
    Captures forest, domain, domain controller, replication, site, and trust details.
    Falls back to the DirectoryServices implementation if the AD module is missing so
    Windows Server Core installs without RSAT still provide useful data.

.NOTES
    @CollectorName: Get-ADInfo-PS5
    @PSVersions: 5.1,7.0
    @MinWindowsVersion: 2008R2
    @Timeout: 60
#>

function Get-ADInfo-PS5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        CollectorName  = 'Get-ADInfo-PS5'
        ComputerName   = $ComputerName
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    function Build-DirectoryServicesFallback {
        try {
            $fallbackPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PS2x\Get-ADInfo.ps1'
            if (Test-Path -LiteralPath $fallbackPath) {
                . $fallbackPath
                if (Get-Command Get-ADInfo -ErrorAction SilentlyContinue) {
                    return Get-ADInfo @PSBoundParameters
                }
            }
        } catch {}
        return $null
    }

    try {
        if ($DryRun) {
            Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
            Get-ADForest -ErrorAction Stop | Out-Null
            $result.Success = $true
            $result.Data = @{ DryRun = $true; Message = 'ActiveDirectory module available.' }
            return $result
        }

        Import-Module ActiveDirectory -ErrorAction Stop | Out-Null

        $forest = Get-ADForest -ErrorAction Stop
        $domain = Get-ADDomain -ErrorAction Stop
        $dcList = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                HostName             = $_.HostName
                IPv4Address          = $_.IPv4Address
                Site                 = $_.Site
                IsGlobalCatalog      = $_.IsGlobalCatalog
                OperationMasterRoles = $_.OperationMasterRoles
                OSVersion            = $_.OperatingSystemVersion
            }
        }

        $trusts = Get-ADTrust -Filter * -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Name       = $_.Name
                Direction  = $_.TrustDirection
                TrustType  = $_.TrustType
                IsTreeRoot = $_.IsTreeRoot
            }
        }

        $sites = Get-ADReplicationSite -Filter * -ErrorAction SilentlyContinue | Select-Object -Property Name, Location
        $connections = Get-ADReplicationConnection -Filter * -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Name        = $_.Name
                SourceServer = $_.ReplicateFromDirectoryServer
                TargetServer = $_.ReplicateToDirectoryServer
                Enabled     = $_.EnabledConnection
            }
        }
        $failures = Get-ADReplicationFailure -Scope Forest -Target $forest.Name -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Server  = $_.TargetServer
                Reason  = $_.FailureReason
                FirstFailure = $_.FirstFailureTime
                LastFailure  = $_.LastErrorTime
            }
        }

        $gpoSummary = @{}
        try {
            $allGpo = Get-GPO -All -ErrorAction Stop
            $gpoSummary = @{
                Total        = $allGpo.Count
                Enforced     = ($allGpo | Where-Object { $_.GpoStatus -eq 'AllSettingsEnabled' }).Count
                Disabled     = ($allGpo | Where-Object { $_.GpoStatus -eq 'AllSettingsDisabled' }).Count
                ModifiedLast30d = ($allGpo | Where-Object { $_.ModificationTime -ge (Get-Date).AddDays(-30) }).Count
            }
        } catch {
            $result.Warnings += 'Failed to enumerate GPOs (requires GroupPolicy module).'
        }

        $result.Data = @{
            Forest            = @{
                Name               = $forest.Name
                RootDomain         = $forest.RootDomain
                ForestMode         = $forest.ForestMode
                Domains            = $forest.Domains
                Sites              = $forest.Sites
                SchemaMaster       = $forest.SchemaMaster
                DomainNamingMaster = $forest.DomainNamingMaster
            }
            Domain            = @{
                Name                 = $domain.DNSRoot
                DomainMode           = $domain.DomainMode
                PDCEmulator          = $domain.PDCEmulator
                RIDMaster            = $domain.RIDMaster
                InfrastructureMaster = $domain.InfrastructureMaster
                FSMORoles            = $domain.OperationsMasterRoles
            }
            DomainControllers = $dcList
            Trusts            = $trusts
            Replication       = @{
                Connections = $connections
                Failures    = $failures
            }
            Sites             = $sites
            GroupPolicy       = $gpoSummary
            Notes             = 'ActiveDirectory module'
        }

        $result.Success = $true
    }
    catch {
        $result.Errors += $_.Exception.Message
        $fallback = Build-DirectoryServicesFallback
        if ($fallback -and $fallback.Success) {
            $result.Success = $true
            $result.Data = $fallback.Data
            $result.Warnings += 'ActiveDirectory module unavailable; returned DirectoryServices fallback data.'
        }
    }
    finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-ADInfo-PS5 @PSBoundParameters
}
