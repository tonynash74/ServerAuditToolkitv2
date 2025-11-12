function Get-SATADDS {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  try {
    if ($Capability.HasADModule -and ((Get-SATPSMajor) -ge 3)) {
      Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
      $forest = $null; $domain=$null; $dcs=@()
      try { $forest = Get-ADForest -ErrorAction SilentlyContinue } catch {}
      try { $domain = Get-ADDomain -ErrorAction SilentlyContinue } catch {}
      try { $dcs = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object HostName, IPv4Address, IsGlobalCatalog, OperationMasterRoles, Site } catch {}

      $out = @{
        ActiveDirectory = @{
          Forest = @{
            Name = (if($forest){$forest.Name}); Mode=(if($forest){$forest.ForestMode}); RootDomain=(if($forest){$forest.RootDomain}); Domains=(if($forest){$forest.Domains})
            SchemaMaster=(if($forest){$forest.SchemaMaster}); DomainNamingMaster=(if($forest){$forest.DomainNamingMaster})
          }
          Domain = @{
            Name=(if($domain){$domain.DNSRoot}); Mode=(if($domain){$domain.DomainMode}); PDCEmulator=(if($domain){$domain.PDCEmulator})
            RIDMaster=(if($domain){$domain.RIDMaster}); InfrastructureMaster=(if($domain){$domain.InfrastructureMaster})
          }
          DomainControllers = $dcs
          SysvolReplication = (try {
            $dfsr = Get-WmiObject -Namespace root\MicrosoftDfs -Class DfsrReplicationGroup -ErrorAction SilentlyContinue |
                    Where-Object { $_.GroupName -eq 'Domain System Volume' }
            if ($dfsr) { 'DFSR' } else { 'Unknown' }
          } catch { 'Unknown' })
          Notes = 'ActiveDirectory module'
        }
      }
      return $out
    } else {
      # DirectoryServices fallback
      try {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $dcs    = @()
        foreach ($dc in $domain.DomainControllers) {
          $dcs += New-Object PSObject -Property @{ HostName=$dc.Name; Site=$dc.SiteName; IsGlobalCatalog=$dc.IsGlobalCatalog; IPv4Address=$dc.IPAddress }
        }
        $out = @{
          ActiveDirectory = @{
            Forest = @{
              Name=$forest.Name; Mode="$($forest.ForestMode)"; RootDomain=$forest.RootDomain.Name; Domains=$forest.Domains
              SchemaMaster=$forest.SchemaRoleOwner.Name; DomainNamingMaster=$forest.NamingRoleOwner.Name
            }
            Domain = @{
              Name=$domain.Name; Mode="$($domain.DomainMode)"
              PDCEmulator=$domain.PdcRoleOwner.Name; RIDMaster=$domain.RidRoleOwner.Name; InfrastructureMaster=$domain.InfrastructureRoleOwner.Name
            }
            DomainControllers = $dcs
            SysvolReplication = (try {
              $rk = 'HKLM:\SYSTEM\CurrentControlSet\Services\NtFrs\Parameters\SysVol'
              if (Test-Path $rk) { 'FRS' } else { 'DFSR or Unknown' }
            } catch { 'Unknown' })
            Notes = '.NET DirectoryServices'
          }
        }
        return $out
      } catch {
        $fsmo = (& netdom query fsmo 2>$null)
        $pdc  = (& nltest /dcname: 2>$null)
        return @{
          ActiveDirectory = @{
            Forest=@{ Name=$null; Mode=$null; RootDomain=$null; Domains=@(); SchemaMaster=$null; DomainNamingMaster=$null }
            Domain=@{ Name=$null; Mode=$null; PDCEmulator=$null; RIDMaster=$null; InfrastructureMaster=$null }
            DomainControllers=@()
            SysvolReplication='Unknown'
            FsmoRaw="$fsmo"; DcRaw="$pdc"
            Notes='netdom/nltest fallback'
          }
        }
      }
    }
  } catch {
    Write-Log Error ("AD DS collector failed: {0}" -f $_.Exception.Message)
    return @{ ActiveDirectory = @{ Error = $_.Exception.Message } }
  }
}
