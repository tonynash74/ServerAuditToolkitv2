function Get-SATIIS {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [hashtable]$Capability
  )

  $out = @{}

  foreach ($c in $ComputerName) {
    try {
      Write-Log Info "IIS inventory on $c"

      if ($Capability.HasIISModule) {
        $scr = {
          Import-Module WebAdministration -ErrorAction Stop
          $sites = Get-Website | ForEach-Object {
            [pscustomobject]@{
              Name         = $_.Name
              Id           = $_.Id
              State        = $_.State
              PhysicalPath = $_.PhysicalPath
              Bindings     = (Get-WebBinding -Name $_.Name | Select protocol, bindingInformation) 
              AppPool      = (Get-Item "IIS:\Sites\$($_.Name)").applicationPool
            }
          }
          $pools = Get-Item 'IIS:\AppPools\*' | ForEach-Object {
            [pscustomobject]@{
              Name                  = $_.Name
              State                 = (Get-WebAppPoolState -Name $_.Name).Value
              RuntimeVersion        = $_.managedRuntimeVersion
              PipelineMode          = $_.managedPipelineMode
              IdentityType          = $_.processModel.identityType
              StartMode             = $_.StartMode
              AutoStart             = $_.AutoStart
              QueueLength           = $_.QueueLength
              Recycling_PeriodicMin = $_.recycling.periodicRestart.time.TotalMinutes
            }
          }
          $certBindings = & netsh http show sslcert 2>$null
          [pscustomobject]@{
            Sites        = $sites
            AppPools     = $pools
            SslBindRaw   = $certBindings
            Notes        = 'WebAdministration'
          }
        }
        $res = Invoke-Command -ComputerName $c -ScriptBlock $scr
        # Convert PSCustomObject tree -> hashtable for speed/consistency
        $out[$c] = @{
          Sites    = @($res.Sites | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
          AppPools = @($res.AppPools | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
          SslBind  = "$($res.SslBindRaw)"
          Notes    = $res.Notes
        }

      } else {
        # Fallback: appcmd XML
        $scr = {
          $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
          if (-not (Test-Path $appcmd)) { throw "appcmd.exe not found" }
          $siteXml = & $appcmd list site /config /xml
          $poolXml = & $appcmd list apppool /config /xml
          [pscustomobject]@{
            SitesXml = $siteXml
            PoolsXml = $poolXml
            Notes    = 'appcmd.exe fallback'
          }
        }
        $raw = Invoke-Command -ComputerName $c -ScriptBlock $scr

        # Parse XML minimally (keeps PS4 happy)
        [xml]$sx = $raw.SitesXml
        [xml]$px = $raw.PoolsXml

        $sites = @()
        foreach ($s in $sx.appcmd.SITE) {
          $sites += [pscustomobject]@{
            Name         = $s.'@NAME'
            Id           = $s.'@ID'
            State        = $s.'@STATE'
            PhysicalPath = ($s.'SITE.APPlications'.'APPLICATION'.'VIRTUAL.DIRECTORY'.'@PHYSICAL.PATH')
            Bindings     = @($s.'bindings'.'binding' | ForEach-Object {
                              [pscustomobject]@{ protocol = $_.'@PROTOCOL'; bindingInformation = $_.'@BINDING.INFORMATION' }
                            })
            AppPool      = ($s.'SITE.APPlications'.'APPLICATION'.'@APPPOOL')
          }
        }
        $pools = @()
        foreach ($p in $px.appcmd.APPPOOL) {
          $pools += [pscustomobject]@{
            Name           = $p.'@NAME'
            RuntimeVersion = $p.'APPPOOL'?.managedRuntimeVersion
            PipelineMode   = $p.'APPPOOL'?.managedPipelineMode
            AutoStart      = $p.'APPPOOL'?.autoStart
            StartMode      = $p.'APPPOOL'?.startMode
          }
        }

        $out[$c] = @{
          Sites    = $sites
          AppPools = $pools
          SslBind  = ''
          Notes    = 'appcmd.exe fallback (parsed)'
        }
      }

    } catch {
      Write-Log Error "IIS collector failed on $c : $($_.Exception.Message)"
      $out[$c] = @{ Error = $_.Exception.Message }
    }
  }

  return $out
}
