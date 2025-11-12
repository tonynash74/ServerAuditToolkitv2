function Get-SATPrinters {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Printer inventory on {0}" -f $c)
      $useModule = ($Capability.HasPrintModule -and ((Get-SATPSMajor) -ge 3))

      if ($useModule) {
        $scr = {
          Import-Module PrintManagement -ErrorAction SilentlyContinue | Out-Null
          $printers = Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, Shared, ShareName, Published, DriverName, PortName, Location, Comment, PrinterStatus, Type
          $ports    = Get-PrinterPort -ErrorAction SilentlyContinue | Select-Object Name, PrinterHostAddress, PortNumber, SnmpEnabled
          $res=@{}; $res["Printers"]=$printers; $res["Ports"]=$ports; $res["Notes"]='PrintManagement'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      } else {
        $scr = {
          $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                      Select-Object Name, ShareName, Shared, Published, DriverName, PortName, Location, Comment, WorkOffline, Default
          $ports = Get-WmiObject -Namespace root\cimv2 -Class Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue |
                   Select-Object Name, HostAddress, PortNumber, SNMPEnabled
          $res=@{}; $res["Printers"]=$printers; $res["Ports"]=$ports; $res["Notes"]='WMI fallback'; return $res
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }
    } catch {
      Write-Log Error ("Printers collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

