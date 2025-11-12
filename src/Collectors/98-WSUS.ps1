function Get-SATWSUS {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("WSUS inventory on {0}" -f $c)
      $scr = {
        $res = @{
          Version    = $null
          ContentDir = $null
          DBBackend  = $null     # 'WID'|'SQL'|'Unknown'
          SQLServer  = $null
          SQLDB      = $null
          Services   = @()       # Update Services/WSUSService/WSusCertServer states
          Approvals  = @()       # best-effort summary (API-free)
          Notes      = ''
          Error      = $null
        }

        $used = 'Registry'
        # Basic registry footprint
        $rk = 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup'
        try {
          $p = Get-ItemProperty $rk -ErrorAction SilentlyContinue
          if ($p) {
            if ($p.PSObject.Properties['VersionString']) { $res.Version    = "$($p.VersionString)" }
            if ($p.PSObject.Properties['ContentDir'])    { $res.ContentDir = "$($p.ContentDir)" }
            if ($p.PSObject.Properties['SqlServerName']) { $res.SQLServer  = "$($p.SqlServerName)" }
            if ($p.PSObject.Properties['SqlDatabaseName']) { $res.SQLDB    = "$($p.SqlDatabaseName)" }
          }
        } catch {}

        # Determine backend (WID vs SQL)
        $db = 'Unknown'
        if ($res.SQLServer) {
          if ($res.SQLServer -match 'MICROSOFT##SSEE|\\?MICROSOFT##SSEE|\\?MICROSOFT##WID|\\?WID') { $db = 'WID' } else { $db = 'SQL' }
        } else {
          # Try known defaults
          $db = 'WID'
        }
        $res.DBBackend = $db

        # Services
        $svcNames = @('WsusService','WSusCertServer','W3SVC')
        foreach ($sn in $svcNames) {
          try {
            $s = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}'" -f $sn) -ErrorAction SilentlyContinue
            if ($s) {
              $res.Services += New-Object PSObject -Property @{
                Name=$s.Name; Display=$s.DisplayName; State=$s.State; StartMode=$s.StartMode; PathName=$s.PathName
              }
            }
          } catch {}
        }

        # Best-effort approvals backlog (API-less): look for WSUS MMC snap-in presence and SUSDB files
        # We’ll just note content dir size as a rough indicator of data volume.
        try {
          if ($res.ContentDir -and (Test-Path $res.ContentDir)) {
            $size = 0L
            try {
              [System.IO.Directory]::EnumerateFiles($res.ContentDir,'*',[System.IO.SearchOption]::AllDirectories) | ForEach-Object {
                try { $size += (Get-Item $_).Length } catch {}
              }
            } catch {}
            $res.Approvals += New-Object PSObject -Property @{ Key='ContentBytes'; Value=[int64]$size }
          }
        } catch {}

        $res.Notes = $used
        return $res
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("WSUS collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ Version=$null; ContentDir=$null; DBBackend=$null; SQLServer=$null; SQLDB=$null; Services=@(); Approvals=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
