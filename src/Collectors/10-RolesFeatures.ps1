function Get-SATRolesFeatures {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Roles/Features on {0}" -f $c)

      $useServerMgr = $Capability.HasServerMgr

      if ($useServerMgr) {
        $scr = {
          Import-Module ServerManager -ErrorAction SilentlyContinue | Out-Null
          $rf = @(); try { $rf = Get-WindowsFeature -ErrorAction SilentlyContinue | Select-Object Name, DisplayName, Installed } catch {}
          $res=@{}; $res["RolesFeatures"]=$rf; $res["Notes"]='ServerManager'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      } else {
        $scr = {
          $installed = Get-WmiObject -Class Win32_ServerFeature -ErrorAction SilentlyContinue |
                       Select-Object ID, Name
          $res=@{}; $res["RolesFeatures"]=$installed; $res["Notes"]='Win32_ServerFeature (installed only)'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }
    } catch {
      Write-Log Error ("Roles/Features collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

