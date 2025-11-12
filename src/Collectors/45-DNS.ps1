function Get-SATDNS {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("DNS inventory on {0}" -f $c)
      $useModule = ($Capability.HasDnsModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          Import-Module DnsServer -ErrorAction SilentlyContinue | Out-Null
          $zones = @(); $fw=@()
          try { $zones = Get-DnsServerZone -ErrorAction SilentlyContinue | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone } catch {}
          try { $fw = Get-DnsServerForwarder -ErrorAction SilentlyContinue | Select-Object IPAddress, UseRootHint } catch {}
          $res = @{}; $res["Zones"]=$zones; $res["Forwarders"]=$fw; $res["Notes"]='DnsServer module'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      } else {
        # WMI provider on DNS servers
        $scr = {
          $zones = @()
          try {
            $wmi = Get-WmiObject -Namespace root\MicrosoftDNS -Class MicrosoftDNS_Zone -ErrorAction SilentlyContinue
            foreach ($z in $wmi) {
              $zones += New-Object PSObject -Property @{
                ZoneName = $z.Name
                ZoneType = $z.ZoneType
                IsDsIntegrated = $z.DsIntegrated
                IsReverseLookupZone = ($z.Reverse -eq $true)
              }
            }
          } catch {}
          $res = @{}; $res["Zones"]=$zones; $res["Forwarders"]=@(); $res["Notes"]='WMI root\MicrosoftDNS'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }
    } catch {
      Write-Log Error ("DNS collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

