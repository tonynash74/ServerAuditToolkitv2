function Get-SATPrinters {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "Printer inventory on $c"

      if ($Capability.HasPrintModule) {
        $scr = {
          Import-Module PrintManagement -ErrorAction Stop
          $printers = Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, Shared, ShareName, Published, DriverName, PortName, Location, Comment, PrinterStatus, Type
          $ports    = Get-PrinterPort -ErrorAction SilentlyContinue | Select-Object Name, PrinterHostAddress, PortNumber, SnmpEnabled
          [pscustomobject]@{ Printers=$printers; Ports=$ports; Notes='PrintManagement' }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          Printers = @($res.Printers | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Ports    = @($res.Ports    | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes    = $res.Notes
        }
      } else {
        $scr = {
          $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                      Select-Object Name, ShareName, Shared, Published, DriverName, PortName, Location, Comment, WorkOffline, Default
          $ports = Get-WmiObject -Namespace root\cimv2 -Class Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue |
                   Select-Object Name, HostAddress, PortNumber, SNMPEnabled
          [pscustomobject]@{ Printers=$printers; Ports=$ports; Notes='WMI fallback' }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = @{
          Printers = @($res.Printers | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Ports    = @($res.Ports    | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
          Notes    = $res.Notes
        }
      }
    } catch {
      Write-Log Error "Printers collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}
