function Get-SATSharePoint {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("SharePoint inventory on {0}" -f $c)
      $scr = {
        $res = @{
          Version   = $null     # 14.x BuildVersion
          FarmMode  = $null     # Standalone/Complete (registry best-guess)
          Databases = @()       # Name, Server (best-effort via snap-in), Size if available
          Sites     = @()       # Url, Owner (if snap-in)
          Services  = @()       # SharePoint Timer/Admin/Tracer
          Notes     = ''
          Error     = $null
        }

        $used = 'Registry'
        # Version via 14.0 hive
        try {
          $k = 'HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\14.0'
          $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
          if ($p -and $p.PSObject.Properties['BuildVersion']) { $res.Version = "$($p.BuildVersion)" }
        } catch {}
        # Setup role hint
        try {
          $k2 = 'HKLM:\SOFTWARE\Microsoft\Office Server\14.0'
          $p2 = Get-ItemProperty $k2 -ErrorAction SilentlyContinue
          if ($p2 -and $p2.PSObject.Properties['InstallType']) {
            $res.FarmMode = "$($p2.InstallType)"
          }
        } catch {}

        # Services
        $svcNames = @('SPTimerV4','SPAdminV4','SPTrace')
        foreach ($sn in $svcNames) {
          try {
            $s = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}'" -f $sn) -ErrorAction SilentlyContinue
            if ($s) {
              $res.Services += New-Object PSObject -Property @{
                Name=$s.Name; Display=$s.DisplayName; State=$s.State; StartMode=$s.StartMode
              }
            }
          } catch {}
        }

        # Try SharePoint snap-in for richer data (if present)
        $snapOk = $false
        try { Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction Stop; $snapOk = $true } catch { $snapOk = $false }
        if ($snapOk) {
          $used = 'SP2010Snapin'
          try {
            $dbs = Get-SPDatabase -ErrorAction SilentlyContinue
            foreach ($d in $dbs) {
              $sz = $null; try { $sz = $d.DiskSizeRequired } catch {}
              $res.Databases += New-Object PSObject -Property @{
                Name=$d.Name; Server="$($d.Server)"; Type="$($d.TypeName)"; Size="$sz"
              }
            }
          } catch {}
          try {
            $apps = Get-SPWebApplication -ErrorAction SilentlyContinue
            foreach ($wa in $apps) {
              $res.Sites += New-Object PSObject -Property @{
                Url="$($wa.Url)"; ApplicationPool="$($wa.ApplicationPool.Name)"
              }
            }
          } catch {}
        }

        if (-not $res.Notes) { $res.Notes = $used }
        return $res
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("SharePoint collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ Version=$null; FarmMode=$null; Databases=@(); Sites=@(); Services=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
