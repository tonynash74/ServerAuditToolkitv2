function Get-SATPrinters {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Printer inventory on {0}" -f $c)

      $scr = {
        $res = @{ Printers=@(); Ports=@(); Notes=''; Error=$null }

        # If Spooler is stopped/disabled, don’t hard fail
        $spState = $null
        try { $sp = Get-WmiObject -Class Win32_Service -Filter "Name='Spooler'" -ErrorAction SilentlyContinue; if ($sp){ $spState = $sp.State } } catch {}
        if ($spState -and $spState -ne 'Running') {
          $res.Notes = "Spooler service $spState"
        }

        $used = $null

        # Try PrintManagement (Win2012+)
        $printers=@(); $ports=@()
        $pmOk = $false
        try {
          Import-Module PrintManagement -ErrorAction Stop | Out-Null
          $pmOk = $true
        } catch { $pmOk = $false }

        if ($pmOk) {
          $used = 'PrintManagement'
          try {
            $printers = Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
              New-Object PSObject -Property @{
                Name       = $_.Name
                Shared     = $_.Shared
                ShareName  = $_.ShareName
                DriverName = $_.DriverName
                PortName   = $_.PortName
                Published  = $_.Published
                Location   = $_.Location
                Comment    = $_.Comment
                PrinterStatus = $_.PrinterStatus
              }
            }
          } catch {}
          try {
            $ports = Get-PrinterPort -ErrorAction SilentlyContinue | ForEach-Object {
              $sn = $null
              if ($_.PSObject -and $_.PSObject.Properties['SnmpEnabled']) { $sn = $_.SnmpEnabled }
              elseif ($_.PSObject -and $_.PSObject.Properties['SNMPEnabled']) { $sn = $_.SNMPEnabled }
              New-Object PSObject -Property @{
                Name = $_.Name
                PrinterHostAddress = $_.PrinterHostAddress
                HostAddress = $_.PrinterHostAddress
                PortNumber = $_.PortNumber
                SnmpEnabled = $sn
              }
            }
          } catch {}
        }

        # Fallback to WMI if module gave nothing
        if (-not $printers -and -not $ports) {
          $used = 'WMI'
          try {
            $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
              New-Object PSObject -Property @{
                Name       = $_.Name
                Shared     = $_.Shared
                ShareName  = $_.ShareName
                DriverName = $_.DriverName
                PortName   = $_.PortName
                Published  = $_.Published
                Location   = $_.Location
                Comment    = $_.Comment
                PrinterStatus = $_.PrinterStatus
              }
            }
          } catch {}

          try {
            $ports = Get-WmiObject -Class Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue | ForEach-Object {
              $sn = $null
              if ($_.PSObject -and $_.PSObject.Properties['SNMPEnabled']) { $sn = $_.SNMPEnabled }
              elseif ($_.PSObject -and $_.PSObject.Properties['SnmpEnabled']) { $sn = $_.SnmpEnabled }
              New-Object PSObject -Property @{
                Name = $_.Name
                PrinterHostAddress = $_.HostAddress
                HostAddress = $_.HostAddress
                PortNumber = $_.PortNumber
                SnmpEnabled = $sn
              }
            }
          } catch {}
        }

        $res.Printers = ($printers  | Where-Object { $_ }) # squash nulls
        $res.Ports    = ($ports     | Where-Object { $_ })
        $res.Notes    = (if ($used) { $used } else { 'none' })
        return $res
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr

      if ($out[$c] -and $out[$c].Error) {
        Write-Log Warn ("Printers on {0}: {1}" -f $c, $out[$c].Error)
      }

    } catch {
      Write-Log Error ("Printer collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Printers=@(); Ports=@(); Error=$_.Exception.Message; Notes='collector exception' }
    }
  }
  return $out
}
