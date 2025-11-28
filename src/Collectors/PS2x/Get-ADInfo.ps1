<#
.SYNOPSIS
    PowerShell 2.0/4.0 compatible Active Directory inventory collector.

.DESCRIPTION
    Uses the ActiveDirectory module when available and falls back to the
    System.DirectoryServices APIs (and finally legacy tools) so that domain
    controllers running older PowerShell versions can still provide a useful
    snapshot of their AD state.

.NOTES
    @CollectorName: Get-ADInfo
    @PSVersions: 2.0,4.0
    @MinWindowsVersion: 2008R2
    @Timeout: 45
#>

function Get-ADInfo {
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
        CollectorName  = 'Get-ADInfo'
        ComputerName   = $ComputerName
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
        ExecutionTime  = 0
        Data           = @{}
        Errors         = @()
        Warnings       = @()
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    function Get-RegValue {
        param([string]$Path,[string]$Name)
        try {
            if (Test-Path -LiteralPath $Path) {
                return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
            }
        } catch {}
        return $null
    }

    try {
        if ($DryRun) {
            try {
                [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain() | Out-Null
                $result.Success = $true
                $result.Data = @{ DryRun = $true; Message = 'DirectoryServices reachable.' }
            } catch {
                $result.Errors += "Dry run failed: $($_.Exception.Message)"
            }
            return $result
        }

        $forest   = $null
        $domain   = $null
        $dcList   = @()
        $notes    = 'DirectoryServices fallback'

        $adModuleAvailable = Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue
        if ($adModuleAvailable) {
            try {
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
                    }
                }
                $notes = 'ActiveDirectory module'
            } catch {
                $result.Warnings += 'Failed to query via ActiveDirectory module. Switching to DirectoryServices.'
                $forest = $null
                $domain = $null
                $dcList = @()
            }
        }

        if (-not $forest) {
            try {
                $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
                $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
                if ($domain) {
                    foreach ($dc in $domain.DomainControllers) {
                        $dcList += [pscustomobject]@{
                            HostName             = $dc.Name
                            IPv4Address          = $dc.IPAddress
                            Site                 = $dc.SiteName
                            IsGlobalCatalog      = $dc.IsGlobalCatalog
                            OperationMasterRoles = @()
                        }
                    }
                }
            } catch {
                $result.Errors += "Failed to query DirectoryServices: $($_.Exception.Message)"
                throw
            }
        }

        $forestInfo = @{}
        if ($forest) {
            $forestDomains = @()
            try {
                foreach ($d in $forest.Domains) { $forestDomains += $d }
            } catch {}
            $forestInfo = @{
                Name               = $forest.Name
                RootDomain         = if ($forest.RootDomain) { $forest.RootDomain.Name } else { $null }
                ForestMode         = "$($forest.ForestMode)"
                Domains            = $forestDomains
                SchemaMaster       = if ($forest.SchemaRoleOwner) { $forest.SchemaRoleOwner.Name } else { $null }
                DomainNamingMaster = if ($forest.NamingRoleOwner) { $forest.NamingRoleOwner.Name } else { $null }
            }
        }

        $domainInfo = @{}
        if ($domain) {
            $domainInfo = @{
                Name                 = $domain.Name
                DomainMode           = "$($domain.DomainMode)"
                PDCEmulator          = if ($domain.PdcRoleOwner) { $domain.PdcRoleOwner.Name } else { $null }
                RIDMaster            = if ($domain.RidRoleOwner) { $domain.RidRoleOwner.Name } else { $null }
                InfrastructureMaster = if ($domain.InfrastructureRoleOwner) { $domain.InfrastructureRoleOwner.Name } else { $null }
            }
        }

        $sysvolReplication = 'Unknown'
        $dfrsGroup = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dfsr\Parameters\SysVols' -Name 'Sysvols'
        if ($dfrsGroup) {
            $sysvolReplication = 'DFSR'
        } elseif (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NtFrs\Parameters\SysVol') {
            $sysvolReplication = 'FRS'
        }

        $result.Data = @{
            Forest            = $forestInfo
            Domain            = $domainInfo
            DomainControllers = $dcList
            SysvolReplication = $sysvolReplication
            Notes             = $notes
        }

        if ($dcList.Count -eq 0) {
            $result.Warnings += 'No domain controllers returned by the query.'
        }

        $result.Success = $true
    }
    catch {
        $result.Errors += $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
        $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-ADInfo @PSBoundParameters
}
