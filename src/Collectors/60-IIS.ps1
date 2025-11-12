function Get-SATIIS {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("IIS inventory on {0}" -f $c)

      $scr = {
        $res = @{ Sites=@(); AppPools=@(); Notes=''; Error=$null }

        # Is IIS even installed?
        $hasIIS = $false
        try { $hasIIS = Test-Path 'HKLM:\SOFTWARE\Microsoft\InetStp' } catch { $hasIIS = $false }
        if (-not $hasIIS) {
          $res.Notes = 'IIS not installed'
          return $res
        }

        # Try WebAdministration first
        $sites=@(); $pools=@()
        $used = 'none'
        try {
          Import-Module WebAdministration -ErrorAction Stop | Out-Null
          $used = 'WebAdministration'

          # Sites
          try {
            $sites = Get-ChildItem IIS:\Sites -ErrorAction Stop | ForEach-Object {
              $b = @()
              # Bindings; guard each property
              $binds = @()
              try { $binds = $_.Bindings.Collection } catch {}
              foreach ($bb in @($binds)) {
                $certHash = $null
                try { if ($bb.PSObject -and $bb.PSObject.Properties['certificateHash']) { $certHash = $bb.certificateHash } } catch {}
                $b += New-Object PSObject -Property @{
                  protocol           = $bb.protocol
                  bindingInformation = $bb.bindingInformation
                  certificateHash    = $certHash
                  thumbprint         = $certHash
                }
              }
              New-Object PSObject -Property @{
                Name=$_.Name
                State=$_.State
                AppPool=$_.ApplicationPool
                PhysicalPath=$_.PhysicalPath
                Bindings=$b
              }
            }
          } catch {}

          # AppPools
          try {
            $pools = Get-ChildItem IIS:\AppPools -ErrorAction Stop | ForEach-Object {
              $rt = $null; $pm = $null; $id = $null
              try { $rt = $_.managedRuntimeVersion } catch {}
              try { $pm = $_.managedPipelineMode } catch {}
              try { $id = $_.processModel.identityType } catch {}
              New-Object PSObject -Property @{
                Name=$_.Name
                State=$_.State
                RuntimeVersion=$rt
                PipelineMode=$pm
                IdentityType=$id
              }
            }
          } catch {}

          if ($sites -or $pools) {
            $res.Sites   = $sites
            $res.AppPools= $pools
            $res.Notes   = $used
            return $res
          }
        } catch {
          # fall through to appcmd
        }

        # Fallback to appcmd
        $appcmd = Join-Path $env:SystemRoot 'System32\inetsrv\appcmd.exe'
        if (-not (Test-Path $appcmd)) {
          $alt = Join-Path $env:windir 'sysnative\inetsrv\appcmd.exe'
          if (Test-Path $alt) { $appcmd = $alt }
        }

        if (-not (Test-Path $appcmd)) {
          $res.Error = 'appcmd.exe not found'
          $res.Notes = 'IIS installed; admin tool unavailable'
          return $res
        }

        $xmlSites = $null; $xmlPools=$null
        try {
          $raw1 = & $appcmd list site /config /xml 2>&1
          if ($raw1) { $xmlSites = [xml]("<root>$raw1</root>") }
        } catch {}

        try {
          $raw2 = & $appcmd list apppool /config /xml 2>&1
          if ($raw2) { $xmlPools = [xml]("<root>$raw2</root>") }
        } catch {}

        $sites=@()
        if ($xmlSites -and $xmlSites.root) {
          foreach ($s in @($xmlSites.root.site)) {
            $b=@()
            foreach ($bd in @($s.bindings.add)) {
              $certHash = $null
              try { if ($bd.PSObject -and $bd.PSObject.Properties['certificateHash']) { $certHash = $bd.certificateHash } } catch {}
              $b += New-Object PSObject -Property @{
                protocol           = $bd.protocol
                bindingInformation = $bd.bindingInformation
                certificateHash    = $certHash
                thumbprint         = $certHash
              }
            }
            $ap   = $null
            $path = $null
            try { if ($s.application -and $s.application.applicationPool) { $ap = $s.application.applicationPool } } catch {}
            try { if ($s.application -and $s.application.virtualDirectory -and $s.application.virtualDirectory.physicalPath) { $path = $s.application.virtualDirectory.physicalPath } } catch {}
            $sites += New-Object PSObject -Property @{
              Name=$s.name; State=$s.state; AppPool=$ap; PhysicalPath=$path; Bindings=$b
            }
          }
        }

        $pools=@()
        if ($xmlPools -and $xmlPools.root) {
          foreach ($p in @($xmlPools.root['applicationPool'])) {
            $rt=$null; $pm=$null
            try { $rt = $p.managedRuntimeVersion } catch {}
            try { $pm = $p.managedPipelineMode } catch {}
            $pools += New-Object PSObject -Property @{
              Name=$p.name; State=$p.state; RuntimeVersion=$rt; PipelineMode=$pm; IdentityType=$null
            }
          }
        }

        $res.Sites    = $sites
        $res.AppPools = $pools
        $res.Notes    = 'appcmd'
        return $res
      }

      $out[$c] = Invoke-Command -ComputerName $c -ScriptBlock $scr

      # No throwing on expected absences; mark as Warn at most
      if ($out[$c] -and $out[$c].Error) {
        Write-Log Warn ("IIS on {0}: {1}" -f $c, $out[$c].Error)
      }

    } catch {
      Write-Log Error ("IIS collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Sites=@(); AppPools=@(); Error=$_.Exception.Message; Notes='collector exception' }
    }
  }
  return $out
}
