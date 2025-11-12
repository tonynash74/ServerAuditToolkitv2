function Get-SATNetwork {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [switch]$IncludeListening
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Network inventory on {0}" -f $c)

      $useModern = ($Capability.HasNetTCPIP -and ((Get-SATPSMajor) -ge 3))

      if ($useModern) {
        $scr = {
          param($incListen)
          Import-Module NetTCPIP -ErrorAction SilentlyContinue | Out-Null

          $adapters = @()
          try { $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object Name, InterfaceDescription, MacAddress, InterfaceOperationalStatus, LinkSpeed } catch {}

          $ipcfg = @()
          try { $ipcfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Select-Object InterfaceAlias, IPv4Address, IPv6Address, Ipv4DefaultGateway, DNSServer, DHCP } catch {}

          $routes = @()
          try { $routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric } catch {}

          $dnsSuffix = $null
          try { $dnsSuffix = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList } catch {}

          $teams = @()
          try {
            Import-Module NetLbfo -ErrorAction Stop | Out-Null
            $teams = Get-NetLbfoTeam -ErrorAction SilentlyContinue | Select-Object Name, TeamingMode, LoadBalancingAlgorithm, Status
          } catch {}

          $listening = @()
          if ($incListen) {
            try {
              $listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess
            } catch {
              $listening = (& cmd.exe /c 'netstat -ano' 2>$null)
            }
          }

          $fw = @()
          try { $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue | Select-Object Name, Enabled } catch {}

          $res = @{}
          $res["Adapters"]  = $adapters
          $res["IPConfig"]  = $ipcfg
          $res["RoutesV4"]  = $routes
          $res["DnsSuffix"] = $dnsSuffix
          $res["Teams"]     = $teams
          $res["Listening"] = $listening
          $res["Firewall"]  = $fw
          $res["Notes"]     = 'NetTCPIP(+NetLbfo)'

          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $IncludeListening.IsPresent
        $out[$c] = $res

      } else {
        # PS2+/no NetTCPIP → WMI + classic tools
        $scr = {
          param($incListen)
          $cfg = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPEnabled } |
                 Select-Object Description, MACAddress,
                   @{n='IPv4';e={ ($_.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) -join ',' }},
                   @{n='IPv6';e={ ($_.IPAddress | Where-Object { $_ -match ':' }) -join ',' }},
                   @{n='Gateway';e={ ($_.DefaultIPGateway) -join ',' }},
                   @{n='DNS';e={ ($_.DNSServerSearchOrder) -join ',' }},
                   DHCPEnabled

          $ipconfigRaw = (& ipconfig /all) 2>$null
          $fwRaw       = (& netsh advfirewall show allprofiles) 2>$null
          $routesRaw   = (& route print -4) 2>$null
          $netstatRaw  = ""
          if ($incListen) { $netstatRaw = (& cmd.exe /c 'netstat -ano' 2>$null) }

          $res = @{}
          $res["Adapters"]   = @()      # not available here
          $res["IPConfig"]   = $cfg
          $res["RoutesV4"]   = @()
          $res["Teams"]      = @()
          $res["DnsSuffix"]  = @()
          $res["Listening"]  = @()
          $res["Firewall"]   = @()
          $res["IpconfigRaw"]= "$ipconfigRaw"
          $res["FirewallRaw"]= "$fwRaw"
          $res["RoutesRaw"]  = "$routesRaw"
          $res["NetstatRaw"] = "$netstatRaw"
          $res["Notes"]      = 'WMI + classic tools'

          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList $IncludeListening.IsPresent
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("Network collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
