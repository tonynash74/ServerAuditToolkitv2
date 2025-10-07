function Get-SATADDS {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,  # ignored; AD context is domain-wide, but keep signature consistent
    [hashtable]$Capability
  )

  # Run on the *current* AD context via remoting to a DC if available; fallbacks use local tools.
  $target = $env:COMPUTERNAME

  $tryADModule = {
    Import-Module ActiveDirectory -ErrorAction Stop
    $forest = Get-ADForest
    $domain = Get-ADDomain
    $dcs    = Get-ADDomainController -Filter * | Select-Object HostName, IPv4Address, IsGlobalCatalog, OperationMasterRoles, Site
    [pscustomobject]@{
      Forest = [pscustomobject]@{
        Name=$forest.Name; Mode=$forest.ForestMode; RootDomain=$forest.RootDomain; Domains=$forest.Domains
        SchemaMaster=$forest.SchemaMaster; DomainNamingMaster=$forest.DomainNamingMaster
      }
      Domain = [pscustomobject]@{
        Name=$domain.DNSRoot; Mode=$domain.DomainMode; PDCEmulator=$domain.PDCEmulator
        RIDMaster=$domain.RIDMaster; InfrastructureMaster=$domain.InfrastructureMaster
      }
      DomainControllers = $dcs
      SysvolReplication = (try {
        # DFSR if this returns something; FRS if DFSR not present on sysvol
        $dfsr = Get-WmiObject -Namespace root\MicrosoftDfs -Class DfsrReplicationGroup -ErrorAction Stop |
                Where-Object { $_.GroupName -eq 'Domain System Volume' }
        if ($dfsr) { 'DFSR' } else { 'Unknown' }
      } catch { 'FRS or Unknown' })
      Notes = 'ActiveDirectory module'
    }
  }

  $tryDotNet = {
    $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    $fsmos  = $forest.SchemaRoleOwner.Name, $forest.NamingRoleOwner.Name,
             $domain.PdcRoleOwner.Name, $domain.RidRoleOwner.Name, $domain.InfrastructureRoleOwner.Name
    $dcs    = $domain.DomainControllers | ForEach-Object {
      [pscustomobject]@{ HostName=$_.Name; Site=$_.SiteName; IsGlobalCatalog=$_.IsGlobalCatalog; IPv4Address=$_.IPAddress }
    }
    [pscustomobject]@{
      Forest = [pscustomobject]@{
        Name=$forest.Name; Mode="$($forest.ForestMode)"; RootDomain=$forest.RootDomain.Name; Domains=$forest.Domains
        SchemaMaster=$forest.SchemaRoleOwner.Name; DomainNamingMaster=$forest.NamingRoleOwner.Name
      }
      Domain = [pscustomobject]@{
        Name=$domain.Name; Mode="$($domain.DomainMode)"
        PDCEmulator=$domain.PdcRoleOwner.Name; RIDMaster=$domain.RidRoleOwner.Name; InfrastructureMaster=$domain.InfrastructureRoleOwner.Name
      }
      DomainControllers = $dcs
      SysvolReplication = (try {
        $rk = 'HKLM:\SYSTEM\CurrentControlSet\Services\NtFrs\Parameters\SysVol'
        if (Test-Path $rk) { 'FRS' } else { 'DFSR or Unknown' }
      } catch { 'Unknown' })
      Notes = '.NET DirectoryServices fallback'
    }
  }

  $tryCommands = {
    $fsmo = (& netdom query fsmo 2>$null)
    $pdc  = (& nltest /dcname: 2>$null)
    [pscustomobject]@{
      Forest = [pscustomobject]@{ Name=$null; Mode=$null; RootDomain=$null; Domains=@() }
      Domain = [pscustomobject]@{ Name=$null; Mode=$null }
      DomainControllers = @()
      FsmoRaw = "$fsmo"
      DcRaw   = "$pdc"
      SysvolReplication = 'Unknown'
      Notes = 'netdom/nltest fallback'
    }
  }

  try {
    if ($Capability.HasADModule) {
      $res = & $tryADModule
    } else {
      try { $res = & $tryDotNet } catch { $res = & $tryCommands }
    }

    # normalize to hashtable
    $out = @{
      Forest = @{
        Name = $res.Forest.Name; Mode = $res.Forest.Mode; RootDomain = $res.Forest.RootDomain; Domains = @($res.Forest.Domains)
        SchemaMaster = $res.Forest.SchemaMaster; DomainNamingMaster = $res.Forest.DomainNamingMaster
      }
      Domain = @{
        Name = $res.Domain.Name; Mode = $res.Domain.Mode; PDCEmulator = $res.Domain.PDCEmulator
        RIDMaster = $res.Domain.RIDMaster; InfrastructureMaster = $res.Domain.InfrastructureMaster
      }
      DomainControllers = @($res.DomainControllers | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
      SysvolReplication = $res.SysvolReplication
      FsmoRaw = $res.FsmoRaw
      Notes = $res.Notes
    }

    return @{ 'ActiveDirectory' = $out }

  } catch {
    Write-Log Error "AD DS collector failed: $($_.Exception.Message)"
    return @{ 'ActiveDirectory' = @{ Error = $_.Exception.Message } }
  }
}
