function Get-SATNetwork {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [switch]$IncludeListening # add if you want ports (uses Get-NetTCPConnection/netstat)
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Network inventory on $c"

      if ($Capability.HasNetTCPIP) {
        $scr = {
          param($IncludeListening)
          Import-Module NetTCPIP -ErrorAction Stop

          $adapters = Get-NetAdapter -Physical | Select-Object Name, InterfaceDescription, MacAddress, InterfaceOperationalStatus, LinkSpeed
          $ipcfg    = Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv6Address, Ipv4DefaultGateway, DNSServer, DHCP
          $routes   = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric
          $dnsSuf   = (Get-DnsClientGlobalSetting).SuffixSearchList
          $teams = @()
          try { Import-Module NetLbfo -ErrorAction Stop; $teams = Get-NetLbfoTeam | Select-Object Name, TeamingMode, LoadBalancingAlgorithm, Status } catch {}

          $listening = @()
          if ($IncludeListening) {
            try {
              $listening = Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess
            } catch {
              $listening = (& cmd /c 'netstat -ano' 2>$null)
            }
          }

          [pscustomobject]@{
            Adapters   = $adapters
            IPConfig   = $ipcfg
            RoutesV4   = $routes
            DnsSuffix  = $dnsSuf
            Teams      = $teams
            Listening  = $listening
            Firewall   = (try { Get-NetFirewallProfile | Select-Object Name, Enabled } catch { $null })
            Notes      = 'NetTCPIP + (optional) NetLbfo'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $IncludeListening.IsPresent
        $out[$c] = @{
          Adapters  = @($res.Adapters  | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          IPConfig  = @($res.IPConfig  | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
          RoutesV4  = @($res.RoutesV4  | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Teams     = @($res.Teams     | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          DnsSuffix = @($res.DnsSuffix)
          Listening = (if ($IncludeListening) { ($res.Listening | ConvertTo-Json -Depth 4 | ConvertFrom-Json) } else { @() })
          Firewall  = @($res.Firewall  | ConvertTo-Json -Depth 4 | ConvertFrom-Json)
          Notes     = $res.Notes
        }

      } else {
        # WMI + classic tools
        $scr = {
          param($IncludeListening)
          $cfg = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPEnabled } |
                 Select-Object Description, MACAddress,
                   @{n='IPv4';e={$_.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }}},
                   @{n='IPv6';e={$_.IPAddress | Where-Object { $_ -match ':' }}},
                   @{n='Gateway';e={$_.DefaultIPGateway -join ','}},
                   @{n='DNS';e={$_.DNSServerSearchOrder -join ','}},
                   DHCPEnabled
          $ipconfig = (& ipconfig /all) 2>$null
          $fw       = (& netsh advfirewall show allprofiles) 2>$null
          $routes   = (& route print -4) 2>$null
          $listening = @()
          if ($IncludeListening) { $listening = (& cmd /c 'netstat -ano' 2>$null) }

          [pscustomobject]@{
            IPConfig  = $cfg
            IpconfigRaw = "$ipconfig"
            FirewallRaw = "$fw"
            RoutesRaw = "$routes"
            ListeningRaw = (if ($IncludeListening) { "$listening" } else { "" })
            Notes = 'WMI + classic tools fallback'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $IncludeListening.IsPresent
        $out[$c] = @{
          Adapters   = @()
          IPConfig   = @($res.IPConfig | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          RoutesV4   = @()
          Teams      = @()
          DnsSuffix  = @()
          Listening  = @()
          Firewall   = @()
          IpconfigRaw= $res.IpconfigRaw
          FirewallRaw= $res.FirewallRaw
          RoutesRaw  = $res.RoutesRaw
          NetstatRaw = $res.ListeningRaw
          Notes      = $res.Notes
        }
      }

    } catch {
      Write-Log Error "Network collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
