function Get-SATPOP3Connector {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("SBS POP3 Connector inventory on {0}" -f $c)
      $scr = {
        $res = @{
          ServiceState = $null
          Schedule     = $null   # poll interval (minutes) best-effort
          Accounts     = $null   # count best-effort
          Notes        = ''
          Error        = $null
        }

        # Service (name varies across SBS builds)
        $names = @('Pop3Connector','Microsoft POP3 Connector','Windows SBS POP3 Connector')
        foreach ($n in $names) {
          try {
            $s = Get-WmiObject -Class Win32_Service -Filter ("Name='{0}' OR DisplayName='{0}'" -f $n) -ErrorAction SilentlyContinue
            if ($s -and $s.State) { $res.ServiceState = $s.State; break }
          } catch {}
        }

        # Config (registry guesses used across SBS versions)
        # Common: HKLM\SOFTWARE\Microsoft\SmallBusinessServer\POP3Connector
        try {
          $k = 'HKLM:\SOFTWARE\Microsoft\SmallBusinessServer\POP3Connector'
          $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
          if ($p) {
            if ($p.PSObject.Properties['ScheduleFrequency']) { $res.Schedule = [int]$p.ScheduleFrequency }
            if ($p.PSObject.Properties['AccountCount'])      { $res.Accounts = [int]$p.AccountCount }
          }
        } catch {}

        if (-not $res.Notes) { $res.Notes = 'Registry+WMI' }
        return $res
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("POP3 Connector collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ ServiceState=$null; Schedule=$null; Accounts=$null; Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
