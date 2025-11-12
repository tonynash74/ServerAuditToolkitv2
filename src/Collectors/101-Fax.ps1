function Get-SATFax {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Fax service inventory on {0}" -f $c)
      $scr = {
        $res = @{
          Service  = $null  # Running/Stopped
          Devices  = @()    # best-effort via printers containing 'Fax'
          Routing  = @()    # placeholder (requires Fax API), we surface basic hints
          Notes    = ''
          Error    = $null
        }

        # Service name is 'Fax'
        try {
          $s = Get-WmiObject -Class Win32_Service -Filter "Name='Fax'" -ErrorAction SilentlyContinue
          if ($s){ $res.Service = $s.State }
        } catch {}

        # Devices via printer list (common SBS config)
        try {
          $ps = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Fax' }
          foreach ($p in $ps) {
            $res.Devices += New-Object PSObject -Property @{
              Name=$p.Name; Port=$p.PortName; Driver=$p.DriverName; Shared=$p.Shared
            }
          }
        } catch {}

        $res.Notes = 'WMI'
        return $res
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("Fax collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ Service=$null; Devices=@(); Routing=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
