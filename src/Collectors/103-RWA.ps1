function Get-SATRWA {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out=@{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("Remote Web Access (RWA) inventory on {0}" -f $c)
      $scr = {
        $res = @{
          SiteName   = $null
          Bindings   = @()      # protocol host:port, certificate thumb if https
          Physical   = $null
          CertIssues = @()      # e.g., https with no thumb
          Notes      = ''
          Error      = $null
        }

        $used = 'WebAdministration'
        $modOk = $false
        try { Import-Module WebAdministration -ErrorAction Stop | Out-Null; $modOk = $true } catch { $modOk = $false }

        if ($modOk) {
          try {
            # Common SBS site name patterns
            $sites = Get-ChildItem IIS:\Sites -ErrorAction SilentlyContinue
            $cand = $sites | Where-Object { $_.Name -match 'SBS|Remote Web Access|Default Web Site' }
            if (-not $cand -or $cand.Count -eq 0) { $cand = $sites }
            $s = $cand | Select-Object -First 1
            if ($s) {
              $res.SiteName = $s.Name
              try { $res.Physical = (Get-Item ("IIS:\Sites\{0}" -f $s.Name)).PhysicalPath } catch {}

              $b = $s.Bindings
              foreach ($binding in $b) {
                $prot=$null;$info=$null;$thumb=$null
                try { $prot = $binding.protocol } catch {}
                try { $info = $binding.bindingInformation } catch {}
                if ($binding.PSObject -and $binding.PSObject.Properties['certificateHash']) {
                  $thumb = $binding.certificateHash
                } elseif ($binding.PSObject -and $binding.PSObject.Properties['thumbprint']) {
                  $thumb = $binding.thumbprint
                }
                $res.Bindings += New-Object PSObject -Property @{
                  Protocol=$prot; Binding=$info; Thumbprint=$thumb
                }
                if ($prot -like 'https*' -and -not $thumb) {
                  $res.CertIssues += "HTTPS binding without certificate: $info"
                }
              }
            }
          } catch {}
        } else {
          $used = 'appcmd'
          try {
            $sys = $env:SystemRoot; $appcmd = Join-Path $sys 'System32\inetsrv\appcmd.exe'
            if (Test-Path $appcmd) {
              $xml = & $appcmd list site /config /xml
              # Best-effort parse without XML casting on PS2 if not well-formed
              $res.Notes = 'appcmd list site'
            } else {
              $res.Notes = 'IIS admin tool missing'
            }
          } catch {}
        }

        if (-not $res.Notes) { $res.Notes = $used }
        return $res
      }
      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr
    } catch {
      Write-Log Error ("RWA collector failed on {0}: {1}" -f $c,$_.Exception.Message)
      $out[$c] = @{ SiteName=$null; Bindings=@(); Physical=$null; CertIssues=@(); Notes='collector exception'; Error=$_.Exception.Message }
    }
  }
  return $out
}
