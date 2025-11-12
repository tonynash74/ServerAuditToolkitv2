function Get-SATExchange {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Exchange inventory on {0}" -f $c)

      $scr = {
        $res = @{
          Version   = $null     # e.g., 14.x.x.x (E2010)
          Edition   = $null
          Roles     = @()       # MBX/HT/CAS flags if available
          Services  = @()       # MSExchange* service states
          Databases = @()       # Name, Mounted, Size(approx), EDB, Logs
          Transport = @()       # Send/Receive connectors (if snap-in)
          Notes     = ''
          Error     = $null
        }

        $used = 'none'
        $snapOk = $false
        try {
          Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010 -ErrorAction Stop
          $snapOk = $true
        } catch { $snapOk = $false }

        if ($snapOk) {
          $used = 'ExchangeSnapin'
          try {
            $exSrv = $null
            try { $exSrv = Get-ExchangeServer -Identity $env:COMPUTERNAME -ErrorAction Stop } catch {}
            if ($exSrv) {
              $ver = $null; $ed=$null
              try { $ver = $exSrv.AdminDisplayVersion } catch {}
              try { $ed  = $exSrv.Edition } catch {}
              $res.Version = "$ver"
              $res.Edition = "$ed"

              $roles = @()
              try { if ($exSrv.IsMailboxServer)   { $roles += 'Mailbox' } } catch {}
              try { if ($exSrv.IsHubTransportServer){ $roles += 'HubTransport' } } catch {}
              try { if ($exSrv.IsClientAccessServer){ $roles += 'ClientAccess' } } catch {}
              $res.Roles = $roles
            }

            # Databases (status includes size/mount)
            try {
              $dbs = Get-MailboxDatabase -Status -ErrorAction SilentlyContinue
              foreach ($d in $dbs) {
                $size = $null; $edb=$null; $logs=$null; $mounted=$null; $srv=$null
                try { $size    = $d.DatabaseSize } catch {}
                try { $edb     = $d.EdbFilePath } catch {}
                try { $logs    = $d.LogFolderPath } catch {}
                try { $mounted = $d.Mounted } catch {}
                try { $srv     = $d.Server } catch {}
                $res.Databases += New-Object PSObject -Property @{
                  Name    = $d.Name
                  Server  = "$srv"
                  Mounted = [bool]$mounted
                  Size    = "$size"
                  EdbPath = "$edb"
                  LogPath = "$logs"
                }
              }
            } catch {}

            # Transport (best-effort)
            try {
              $rcv = Get-ReceiveConnector -ErrorAction SilentlyContinue
              foreach ($r in $rcv) {
                $res.Transport += New-Object PSObject -Property @{
                  Kind   = 'ReceiveConnector'
                  Name   = $r.Name
                  Bind   = ($r.Bindings -join ',')
                  Auth   = ($r.AuthMechanism -join ',')
                }
              }
            } catch {}
            try {
              $snd = Get-SendConnector -ErrorAction SilentlyContinue
              foreach ($s in $snd) {
                $res.Transport += New-Object PSObject -Property @{
                  Kind   = 'SendConnector'
                  Name   = $s.Name
                  Addr   = ($s.AddressSpaces -join ',')
                  Smart  = "$($s.SmartHosts)"
                }
              }
            } catch {}

          } catch {
            $res.Notes = "Exchange snap-in errors: $($_.Exception.Message)"
          }
        }

        # Services (works with or without snap-in)
        try {
          $svc = Get-WmiObject -Class Win32_Service -Filter "Name LIKE 'MSExchange%'" -ErrorAction SilentlyContinue
          foreach ($s in $svc) {
            $res.Services += New-Object PSObject -Property @{
              Name      = $s.Name
              State     = $s.State
              StartMode = $s.StartMode
              PathName  = $s.PathName
            }
          }
        } catch {}

        # Registry fallback for version/edition
        if (-not $res.Version) {
          $used = 'Registry'
          try {
            $k = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v14\Setup'
            $disp = $null; $ed = $null; $mBuild=$null
            try { $disp   = (Get-ItemProperty $k -ErrorAction SilentlyContinue).DisplayVersion } catch {}
            try { $ed     = (Get-ItemProperty $k -ErrorAction SilentlyContinue).Edition } catch {}
            try { $mBuild = (Get-ItemProperty $k -ErrorAction SilentlyContinue).MsiBuild } catch {}
            if ($disp) { $res.Version = "$disp" }
            if ($ed)   { $res.Edition = "$ed" }
            if (-not $res.Version -and $mBuild) { $res.Version = "$mBuild" }
          } catch {}
        }

        if (-not $res.Notes) { $res.Notes = $used }
        return $res
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("Exchange collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Version=$null; Edition=$null; Roles=@(); Services=@(); Databases=@(); Transport=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
