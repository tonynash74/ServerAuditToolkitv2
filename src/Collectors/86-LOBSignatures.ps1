function Get-SATLOBSignatures {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $signs = @(
    @{ Key='Sage';      Pattern='sage|payroll|accounts|line50|sage200' },
    @{ Key='Intuit';    Pattern='intuit|quickbooks' },
    @{ Key='AccessApp'; Pattern='\.mdb$|\.accdb$' },
    @{ Key='FoxPro';    Pattern='\.dbf$' },
    @{ Key='Crystal';   Pattern='crystal reports|\.rpt$' },
    @{ Key='JavaApp';   Pattern='\.jar$' },
    @{ Key='LegacyExe'; Pattern='setup\.exe|install\.exe|application\.exe' }
  )

  $out=@{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("LOB signature scan on {0}" -f $c)
      $scr = {
        param($signsIn)

        $res = @{
          Hits  = @()   # Key, Path, Count
          Notes = ''
          Error = $null
        }

        # Get shares (reuse WMI Win32_Share to avoid dependency)
        $shares = @()
        try {
          $tmp = Get-WmiObject -Class Win32_Share -Filter "Type=0" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\w\$$' }
          foreach ($s in $tmp) { $shares += New-Object PSObject -Property @{ Name=$s.Name; Path=$s.Path } }
        } catch {}

        if ($shares.Count -eq 0) {
          $res.Notes = 'No shares'
          return $res
        }

        foreach ($sig in $signsIn) {
          $key = $sig.Key
          $pat = $sig.Pattern
          $total = 0
          foreach ($sh in $shares) {
            $root = $sh.Path
            if (-not $root -or -not (Test-Path $root)) { continue }
            try {
              $files = [System.IO.Directory]::EnumerateFiles($root,'*',[System.IO.SearchOption]::AllDirectories)
            } catch { $files = @() }
            foreach ($f in $files) {
              $fn = [System.IO.Path]::GetFileName($f)
              $full = $f.ToLower()
              if ($full -match $pat -or $fn -match $pat) { $total++ }
              if ($total -ge 2000) { break } # keep it reasonable per signature
            }
            if ($total -ge 2000) { break }
          }
          if ($total -gt 0) {
            $res.Hits += New-Object PSObject -Property @{ Key=$key; Pattern=$pat; Count=$total }
          }
        }

        $res.Notes = 'WMI+FS'
        return $res
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr -ArgumentList @($signs)
    } catch {
      Write-Log Error ("LOB signature collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ Hits=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
