function Get-SATDHCP {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("DHCP inventory on {0}" -f $c)
      $useModule = ($Capability.HasDhcpModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          Import-Module DhcpServer -ErrorAction SilentlyContinue | Out-Null
          $scopes=@(); $fw=@()
          try { $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object ScopeId, Name, StartRange, EndRange, SubnetMask, State } catch {}
          try { $fw = Get-DhcpServerv4OptionValue -OptionId 3 -All -ErrorAction SilentlyContinue | Select-Object ScopeId, Value } catch {}
          $res=@{}; $res["Scopes"]=$scopes; $res["Options"]=$fw; $res["Notes"]='DhcpServer module'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      } else {
        # netsh export fallback (requires admin & ADMIN$)
        $scr = {
          $tmp = Join-Path $env:SystemRoot "Temp\sat_dhcp_{0}.xml" -f ([guid]::NewGuid().ToString('N'))
          $ok = $true
          try { & netsh dhcp server export "$tmp" all 2>$null } catch { $ok = $false }
          $scopes = @(); $raw = $null
          if ($ok -and (Test-Path $tmp)) {
            $raw = Get-Content -Path $tmp -Raw
            # Lightweight scope parse (best effort)
            $lines = $raw -split "`r?`n"
            foreach ($ln in $lines) {
              if ($ln -match 'ADD Scope ([0-9\.]+) ([0-9\.]+) \"?([^"]*)\"?') {
                $scope = $matches[1]; $mask=$matches[2]; $name=$matches[3]
                $scopes += New-Object PSObject -Property @{ ScopeId=$scope; SubnetMask=$mask; Name=$name; StartRange=$null; EndRange=$null; State=$null }
              }
            }
            try { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue } catch {}
          }
          $res=@{}; $res["Scopes"]=$scopes; $res["ExportRaw"]="$raw"; $res["Notes"]='netsh export'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }
    } catch {
      Write-Log Error ("DHCP collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
