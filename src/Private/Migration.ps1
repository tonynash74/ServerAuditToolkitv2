function Get-SATDefaultReadinessRules {
  $rules = @()

  # Certs expiring in < 90 days
  $rules += @{ id='cert-expiring-90d'; appliesTo='Certificate'; severity='High'
    ; message='Certificate expires within 90 days.'
    ; when='$Item.NotAfter -and ([datetime]$Item.NotAfter -lt (Get-Date).AddDays(90))' }

  # HTTPS binding missing certificate dependency
  $rules += @{ id='iis-https-binding-no-cert'; appliesTo='IisBinding'; severity='High'
    ; message='HTTPS binding without a linked certificate.'
    ; when='($Item.Name -like "https*") -and (@($Item.DependsOn).Count -eq 0)' }

  # Share root broad Full Control
  $rules += @{ id='smb-share-broad-fullcontrol'; appliesTo='SmbAclEntry'; severity='Medium'
    ; message='Share root ACL grants broad Full Control.'
    ; when='(@("Everyone","Authenticated Users") -contains $Item.Identity) -and ($Item.Rights -like "*Full*")' }

  # Scheduled task executable on UNC
  $rules += @{ id='task-runs-unc'; appliesTo='ScheduledTask'; severity='Medium'
    ; message='Task runs an executable from a UNC path.'
    ; when='$Item.ActionExe -like "\\\\*"' }

  return $rules
}

function New-SATMigrationUnits {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][hashtable]$Data)

  $units = New-Object System.Collections.Generic.List[hashtable]

  function Add-Unit {
    param([string]$Id,[string]$Kind,[string]$Server,[string]$Name,[string]$Summary,[string[]]$DependsOn,[double]$Confidence,[hashtable]$Extra)
    $h = @{ Id=$Id; Kind=$Kind; Server=$Server; Name=$Name; Summary=$Summary; DependsOn=$DependsOn; Confidence=$Confidence }
    if ($Extra) { foreach($k in $Extra.Keys){ $h[$k] = $Extra[$k] } }
    $null = $units.Add($h)
  }

  function Get-Conf([string]$notes){
    if ([string]::IsNullOrEmpty($notes)) { return 0.8 }
    if ($notes -match 'module') { return 1.0 }
    if ($notes -match 'WMI')    { return 0.8 }
    if ($notes -match 'fallback'){ return 0.7 }
    return 0.85
  }

  # DHCP scopes
  if ($Data['Get-SATDHCP']) {
    foreach ($srv in @($Data['Get-SATDHCP'].Keys)) {
      $cap = Get-Conf $Data['Get-SATDHCP'][$srv].Notes
      foreach ($s in @($Data['Get-SATDHCP'][$srv].Scopes)) {
        Add-Unit -Id "dhcp:$srv:scope:$($s.ScopeId)" -Kind 'DhcpScope' -Server $srv -Name $s.Name `
          -Summary ("Scope {0} {1}-{2}/{3} ({4})" -f $s.ScopeId,$s.StartRange,$s.EndRange,$s.SubnetMask,$s.State) `
          -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # DNS zones
  if ($Data['Get-SATDNS']) {
    foreach ($srv in @($Data['Get-SATDNS'].Keys)) {
      $cap = Get-Conf $Data['Get-SATDNS'][$srv].Notes
      foreach ($z in @($Data['Get-SATDNS'][$srv].Zones)) {
        Add-Unit -Id "dns:$srv:zone:$($z.ZoneName)" -Kind 'DnsZone' -Server $srv -Name $z.ZoneName `
          -Summary ("Type={0} DSInt={1}" -f $z.ZoneType,$z.IsDsIntegrated) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # IIS (sites, bindings, pools)
  if ($Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $cap = Get-Conf $Data['Get-SATIIS'][$srv].Notes
      foreach ($site in @($Data['Get-SATIIS'][$srv].Sites)) {
        Add-Unit -Id "iis:$srv:site:$($site.Name)" -Kind 'IisSite' -Server $srv -Name $site.Name `
          -Summary ("State={0} Path={1}" -f $site.State,$site.PhysicalPath) -DependsOn @("iispool:$srv:$($site.AppPool)") -Confidence $cap -Extra @{}
        foreach ($b in @($site.Bindings)) {
  $thumb = $null
  if ($b -and $b.PSObject -and $b.PSObject.Properties) {
    try {
      if ($b.PSObject.Properties['certificateHash']) { $thumb = $b.certificateHash }
      elseif ($b.PSObject.Properties['thumbprint'])  { $thumb = $b.thumbprint }
    } catch {}
  }
  $deps = @()
  if ($thumb) { $deps = @("cert:$srv:$thumb") }

  $prot = $null; $bind = $null
  try { $prot = $b.protocol } catch {}
  try { $bind = $b.bindingInformation } catch {}

  Add-Unit -Id ("iis:$srv:binding:{0}:{1}:{2}" -f $site.Name,$prot,$bind) -Kind 'IisBinding' `
    -Server $srv -Name ("{0} {1}" -f $prot,$bind) -Summary ("Binding for {0}" -f $site.Name) `
    -DependsOn $deps -Confidence $cap -Extra @{}
}
}

        }
      }
      foreach ($p in @($Data['Get-SATIIS'][$srv].AppPools)) {
        Add-Unit -Id "iispool:$srv:$($p.Name)" -Kind 'IisAppPool' -Server $srv -Name $p.Name `
          -Summary ("State={0} CLR={1} Mode={2}" -f $p.State,$p.RuntimeVersion,$p.PipelineMode) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Certificates
  if ($Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $cap = Get-Conf $Data['Get-SATCertificates'][$srv].Notes
      foreach ($store in @($Data['Get-SATCertificates'][$srv].Stores.Keys)) {
        foreach ($c in @($Data['Get-SATCertificates'][$srv].Stores[$store])) {
          $name = $c.FriendlyName; if (-not $name) { $name = $c.Subject }
          Add-Unit -Id "cert:$srv:$($c.Thumbprint)" -Kind 'Certificate' -Server $srv -Name $name `
            -Summary ("{0} NotAfter={1}" -f $store,$c.NotAfter) -DependsOn @() -Confidence $cap -Extra @{ NotAfter=$c.NotAfter }
        }
      }
    }
  }

  # SMB
  if ($Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $cap = Get-Conf $Data['Get-SATSMB'][$srv].Notes
      foreach ($sh in @($Data['Get-SATSMB'][$srv].Shares)) {
        Add-Unit -Id "smb:$srv:share:$($sh.Name)" -Kind 'SmbShare' -Server $srv -Name $sh.Name `
          -Summary ("{0} Encrypt={1}" -f $sh.Path,$sh.EncryptData) -DependsOn @() -Confidence $cap -Extra @{}
      }
      foreach ($perm in @($Data['Get-SATSMB'][$srv].Permissions)) {
        foreach ($ntfs in @($perm.NtfsTop)) {
          $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}|{1}|{2}" -f $ntfs.IdentityReference,$ntfs.FileSystemRights,$ntfs.AccessControlType)))
          Add-Unit -Id ("smb:$srv:share:{0}:acl:{1}" -f $perm.Share,$key) -Kind 'SmbAclEntry' -Server $srv -Name $perm.Share `
            -Summary ("{0} {1} {2}" -f $ntfs.IdentityReference,$ntfs.AccessControlType,$ntfs.FileSystemRights) `
            -DependsOn @("smb:$srv:share:$($perm.Share)") -Confidence $cap -Extra @{ Identity=$ntfs.IdentityReference; Rights=$ntfs.FileSystemRights }
        }
      }
    }
  }

  # Hyper-V VMs
  if ($Data['Get-SATHyperV']) {
    foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
      $cap = Get-Conf $Data['Get-SATHyperV'][$srv].Notes
      foreach ($vm in @($Data['Get-SATHyperV'][$srv].VMs)) {
        Add-Unit -Id "hv:$srv:vm:$($vm.Name)" -Kind 'HvVm' -Server $srv -Name $vm.Name `
          -Summary ("State={0} Mem={1} Uptime={2}" -f $vm.State,$vm.MemoryAssigned,$vm.Uptime) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Printers
  if ($Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      $cap = Get-Conf $Data['Get-SATPrinters'][$srv].Notes
      foreach ($p in @($Data['Get-SATPrinters'][$srv].Printers)) {
        Add-Unit -Id "print:$srv:queue:$($p.Name)" -Kind 'PrinterQueue' -Server $srv -Name $p.Name `
          -Summary ("Shared={0} Driver={1} Port={2}" -f $p.Shared,$p.DriverName,$p.PortName) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Scheduled Tasks
  if ($Data['Get-SATScheduledTasks']) {
    foreach ($srv in @($Data['Get-SATScheduledTasks'].Keys)) {
      $cap = Get-Conf $Data['Get-SATScheduledTasks'][$srv].Notes
      foreach ($t in @($Data['Get-SATScheduledTasks'][$srv].Tasks)) {
        $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}{1}" -f $t.TaskPath,$t.TaskName)))
        Add-Unit -Id ("task:$srv:{0}" -f $key) -Kind 'ScheduledTask' -Server $srv -Name $t.TaskName `
          -Summary ("State={0} Next={1} Exec={2}" -f $t.State,$t.NextRun,$t.ActionExe) -DependsOn @() -Confidence $cap -Extra @{ ActionExe=$t.ActionExe }
      }
    }
  }

  return ,$units.ToArray()
}

function Evaluate-SATReadiness {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][array]$Units,
    [Parameter(Mandatory=$true)][array]$Rules
  )

  $findings = New-Object System.Collections.Generic.List[hashtable]
  foreach ($u in $Units) {
    foreach ($r in ($Rules | Where-Object { $_.appliesTo -eq $u.Kind })) {
      $Item = $u
      $ok = $false
      try {
        $sb = [ScriptBlock]::Create($r.when)
        $ok = [bool](& $sb)
      } catch {
        $ok = $false
      }
      if ($ok) {
        $null = $findings.Add(@{
          UnitId   = $u.Id; Kind=$u.Kind; Server=$u.Server; Name=$u.Name
          Severity = $r.severity; RuleId=$r.id; Message=$r.message
        })
      }
    }
  }
  return ,$findings.ToArray()
}
