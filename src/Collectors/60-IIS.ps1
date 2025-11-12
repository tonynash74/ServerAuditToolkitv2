function Get-SATIIS {
  [CmdletBinding()]
  param([string[]]$ComputerName,[hashtable]$Capability)

  $out = @{}
  foreach ($c in $ComputerName) {
    try {
      Write-Log Info ("IIS inventory on {0}" -f $c)

      $useModule = $Capability.HasIISModule

      if ($useModule) {
        $scr = {
          Import-Module WebAdministration -ErrorAction SilentlyContinue | Out-Null

          $sites = @()
          try {
            $sitesRaw = Get-Website -ErrorAction SilentlyContinue
            foreach ($s in $sitesRaw) {
              $bindings = @()
              try {
                $bnd = Get-WebBinding -Name $s.Name -ErrorAction SilentlyContinue
                foreach ($b in $bnd) {
                  $bindings += New-Object PSObject -Property @{
                    protocol           = $b.protocol
                    bindingInformation = $b.bindingInformation
                    certificateHash    = $b.certificateHash
                  }
                }
              } catch {}
              $appPool = $null
              try { $appPool = (Get-Item ("IIS:\Sites\{0}" -f $s.Name)).applicationPool } catch {}
              $sites += New-Object PSObject -Property @{
                Name         = $s.Name
                Id           = $s.Id
                State        = $s.State
                PhysicalPath = $s.PhysicalPath
                Bindings     = $bindings
                AppPool      = $appPool
              }
            }
          } catch {}

          $pools = @()
          try {
            $poolItems = Get-Item 'IIS:\AppPools\*' -ErrorAction SilentlyContinue
            foreach ($p in $poolItems) {
              $state = $null; try { $state = (Get-WebAppPoolState -Name $p.Name -ErrorAction SilentlyContinue).Value } catch {}
              $pools += New-Object PSObject -Property @{
                Name           = $p.Name
                State          = $state
                RuntimeVersion = $p.managedRuntimeVersion
                PipelineMode   = $p.managedPipelineMode
                IdentityType   = $p.processModel.identityType
                StartMode      = $p.StartMode
                AutoStart      = $p.AutoStart
                QueueLength    = $p.QueueLength
              }
            }
          } catch {}

          $ssl = (& netsh http show sslcert 2>$null)

          $res = @{}
          $res["Sites"]    = $sites
          $res["AppPools"] = $pools
          $res["SslBind"]  = "$ssl"
          $res["Notes"]    = 'WebAdministration'
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res

      } else {
        # appcmd fallback (XML parse)
        $scr = {
          $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
          if (-not (Test-Path $appcmd)) { throw "appcmd.exe not found" }

          $siteXml = & $appcmd list site /config /xml
          $poolXml = & $appcmd list apppool /config /xml

          $sites = @(); $pools = @()
          try {
            [xml]$sx = $siteXml
            foreach ($s in $sx.appcmd.SITE) {
              $binds = @()
              foreach ($b in $s.bindings.binding) {
                $binds += New-Object PSObject -Property @{
                  protocol           = $b.'@PROTOCOL'
                  bindingInformation = $b.'@BINDING.INFORMATION'
                }
              }
              $sites += New-Object PSObject -Property @{
                Name         = $s.'@NAME'
                Id           = $s.'@ID'
                State        = $s.'@STATE'
                PhysicalPath = $s.'SITE.APPlications'.'APPLICATION'.'VIRTUAL.DIRECTORY'.'@PHYSICAL.PATH'
                Bindings     = $binds
                AppPool      = $s.'SITE.APPlications'.'APPLICATION'.'@APPPOOL'
              }
            }
          } catch {}

          try {
            [xml]$px = $poolXml
            foreach ($p in $px.appcmd.APPPOOL) {
              $pools += New-Object PSObject -Property @{
                Name           = $p.'@NAME'
                RuntimeVersion = $p.'APPPOOL'.managedRuntimeVersion
                PipelineMode   = $p.'APPPOOL'.managedPipelineMode
                AutoStart      = $p.'APPPOOL'.autoStart
                StartMode      = $p.'APPPOOL'.startMode
              }
            }
          } catch {}

          $res = @{}
          $res["Sites"]    = $sites
          $res["AppPools"] = $pools
          $res["SslBind"]  = ""
          $res["Notes"]    = 'appcmd.exe fallback'
          return $res
        }

        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        $out[$c] = $res
      }

    } catch {
      Write-Log Error ("IIS collector failed on {0} : {1}" -f $c, $_.Exception.Message)
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }
  return $out
}

