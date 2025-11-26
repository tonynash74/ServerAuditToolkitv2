function Get-SATRRAS {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability,
    [System.Management.Automation.PSCredential]$Credential
  )

  $out=@{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("RRAS inventory on {0}" -f $c)
      $scr = {
        $res = @{
          ServiceState = $null   # Running/Stopped
          Mode         = $null   # NAT|VPN|LAN Routing (best-effort)
          Ports        = $null   # configured ports count (best-effort)
          ActiveVPN    = $null   # active connections count (best-effort)
          Notes        = ''
          Error        = $null
        }

        # Service
        try {
          $s = Get-WmiObject -Class Win32_Service -Filter "Name='RemoteAccess'" -ErrorAction SilentlyContinue
          if ($s){ $res.ServiceState = $s.State }
        } catch {}

        # netsh ras best-effort
        $used = 'netsh'
        function _exec([string]$args) {
          $psi = New-Object System.Diagnostics.ProcessStartInfo
          $psi.FileName = "netsh.exe"
          $psi.Arguments = $args
          $psi.RedirectStandardOutput = $true
          $psi.RedirectStandardError  = $true
          $psi.UseShellExecute = $false
          $p = [System.Diagnostics.Process]::Start($psi)
          $txt = $p.StandardOutput.ReadToEnd()
          $p.WaitForExit()
          return $txt
        }

        try {
          $cfg = _exec "ras show config"
          if ($cfg -match 'VPN') { $res.Mode = 'VPN' }
          elseif ($cfg -match 'NAT') { $res.Mode = 'NAT' }
          elseif ($cfg -match 'LAN') { $res.Mode = 'LAN Routing' }
        } catch {}

        try {
          $ports = _exec "ras show rasports"
          if ($ports) {
            $lines = ($ports -split "\r?\n") | Where-Object { $_ -match 'Device' -or $_ -match 'Port' }
            $res.Ports = $lines.Count
          }
        } catch {}

        try {
          $act = _exec "ras show activeservers"  # older systems alternative
          if (-not $act -or $act.Trim().Length -eq 0) {
            $act = _exec "ras show connections"
          }
          if ($act) {
            $rows = ($act -split "\r?\n") | Where-Object { $_ -match 'Connected' -or $_ -match 'VPN' -or $_ -match 'PPTP|L2TP|SSTP' }
            $res.ActiveVPN = $rows.Count
          }
        } catch {}

        $res.Notes = $used
        return $res
      }

      # Build invoke parameters with credential support
      $invokeParams = @{
        ComputerName = $c
        ScriptBlock  = $scr
      }
      
      if ($PSBoundParameters.ContainsKey('Credential')) {
        $invokeParams['Credential'] = $Credential
      }
      
      $res = Invoke-WithRetry -Command {
        Invoke-Command @invokeParams
      } -Description "RRAS inventory on $c" -MaxRetries 3
    } catch [System.UnauthorizedAccessException] {
      Write-Log Error ("RRAS collector — Access denied on {0}. Verify credentials and admin privileges." -f $c)
      $out[$c] = @{ 
        ServiceState = $null
        Mode         = $null
        Ports        = $null
        ActiveVPN    = $null
        Notes        = 'access denied'
        Error        = "Authorization failed. User must be in Administrators group."
        ErrorType    = 'AuthenticationFailure'
      }
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
      Write-Log Error ("RRAS collector — WinRM connection failed on {0}" -f $c)
      $out[$c] = @{ 
        ServiceState = $null
        Mode         = $null
        Ports        = $null
        ActiveVPN    = $null
        Notes        = 'connection failed'
        Error        = "WinRM connection failed. Ensure WinRM is enabled and firewall allows port 5985/5986."
        ErrorType    = 'ConnectionFailure'
      }
    } catch {
      Write-Log Error ("RRAS collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ ServiceState=$null; Mode=$null; Ports=$null; ActiveVPN=$null; Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
