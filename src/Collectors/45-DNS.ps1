# src/Collectors/45-DNS.ps1
function Get-SATDNS {
  [CmdletBinding()] param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach($c in $ComputerName){
    Write-Log Info "DNS config on $c"
    if($Capability.HasDnsModule){
      $scr = {
        $server = Get-DnsServer
        $zones  = Get-DnsServerZone
        $fwds   = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        [pscustomobject]@{
          Server = $server.ServerSettings
          Zones  = $zones | Select ZoneName,ZoneType,IsReverseLookupZone,IsDsIntegrated
          Forwarders = $fwds | Select IPAddress,UseRootHint
        }
      }
      $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
      $out[$c] = $res | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    } else {
      # WMI fallback
      $zones = Get-WmiObject -Namespace root\MicrosoftDNS -Class MicrosoftDNS_Zone -ComputerName $c -ErrorAction SilentlyContinue
      $fwds = Get-WmiObject -Namespace root\MicrosoftDNS -Class MicrosoftDNS_Server -ComputerName $c -ErrorAction SilentlyContinue
      $out[$c] = @{
        Zones = @($zones | Select Name, ZoneType, DsIntegrated)
        Forwarders = @($fwds.Forwarders)
        Notes = 'WMI root\MicrosoftDNS fallback'
      }
    }
  }
  return $out
}
