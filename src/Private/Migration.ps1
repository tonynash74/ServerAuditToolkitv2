function Get-SATDefaultReadinessRules {
  # JSON rules (PS 4.0 friendly). You can override with -RulesPath later.
  $json = @'
[
  {
    "id": "cert-expiring-90d",
    "appliesTo": "Certificate",
    "severity": "High",
    "message": "Certificate expires within 90 days.",
    "when": "(ToDate($Item.NotAfter) -lt (Now().AddDays(90)))"
  },
  {
    "id": "iis-https-binding-no-cert",
    "appliesTo": "IisBinding",
    "severity": "High",
    "message": "HTTPS binding without a linked certificate.",
    "when": "($Item.Name -like 'https*') -and -not ($Item.DependsOn -match '^cert:')"
  },
  {
    "id": "smb-share-broad-fullcontrol",
    "appliesTo": "SmbAclEntry",
    "severity": "Medium",
    "message": "Share root ACL grants broad Full Control.",
    "when": "($Item.Identity -in @('Everyone','Authenticated Users')) -and ($Item.Rights -like '*Full*')"
  },
  {
    "id": "task-runs-unc",
    "appliesTo": "ScheduledTask",
    "severity": "Medium",
    "message": "Task runs an executable from a UNC path.",
    "when": "($Item.ActionExe -like '\\\\\\\\*')"
  }
]
'@
  return $json | ConvertFrom-Json
}

function New-SATMigrationUnits {
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Data)

  $units = New-Object System.Collections.Generic.List[hashtable]

  function Add-Unit {
    param([string]$Id,[string]$Kind,[string]$Server,[string]$Name,[string]$Summary,[string[]]$DependsOn,[double]$Confidence,[hashtable]$Extra)
    $h=@{
      Id=$Id; Kind=$Kind; Server=$Server; Name=$Name; Summary=$Summary
      DependsOn=$DependsOn; Confidence=$Confidence
    }
    if($Extra){ foreach($k in $Extra.Keys){ $h[$k]=$Extra[$k] } }
    $units.Add($h) | Out-Null
  }

  function Get-ConfidenceFromNotes([string]$notes){
    if([string]::IsNullOrEmpty($notes)){ return 0.8 }
    if($notes -match 'module') { return 1.0 }
    if($notes -match 'fallback') { return 0.7 }
    if($notes -match 'WMI') { return 0.8 }
    return 0.85
  }

  # DHCP scopes
  if($Data['Get-SATDHCP']){
    foreach($srv in @($Data['Get-SATDHCP'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATDHCP'][$srv].Notes)
      foreach($s in @($Data['Get-SATDHCP'][$srv].Scopes)){
        $cidr = "$($s.ScopeId) $($s.StartRange)-$($s.EndRange)/$($s.SubnetMask)"
        Add-Unit -Id "dhcp:$srv:scope:$($s.ScopeId)" -Kind 'DhcpScope' -Server $srv -Name $s.Name `
          -Summary "Scope $($s.State) $cidr" -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # DNS zones
  if($Data['Get-SATDNS']){
    foreach($srv in @($Data['Get-SATDNS'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATDNS'][$srv].Notes)
      foreach($z in @($Data['Get-SATDNS'][$srv].Zones)){
        Add-Unit -Id "dns:$srv:zone:$($z.ZoneName)" -Kind 'DnsZone' -Server $srv -Name $z.ZoneName `
          -Summary "Type=$($z.ZoneType) DSInt=$($z.IsDsIntegrated)" -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # IIS: sites, bindings, apppools
  if($Data['Get-SATIIS']){
    foreach($srv in @($Data['Get-SATIIS'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATIIS'][$srv].Notes)
      foreach($site in @($Data['Get-SATIIS'][$srv].Sites)){
        Add-Unit -Id "iis:$srv:site:$($site.Name)" -Kind 'IisSite' -Server $srv -Name $site.Name `
          -Summary "State=$($site.State) Path=$($site.PhysicalPath)" -DependsOn @("iispool:$srv:$($site.AppPool)") -Confidence $cap -Extra @{}
        foreach($b in @($site.Bindings)){
          $thumb = ($b.certificateHash ?? $b.thumbprint)
          $deps = if($thumb){ @("cert:$srv:$thumb") } else { @() }
          Add-Unit -Id "iis:$srv:binding:$($site.Name):$($b.protocol):$($b.bindingInformation)" -Kind 'IisBinding' `
            -Server $srv -Name "$($b.protocol) $($b.bindingInformation)" -Summary "Binding for $($site.Name)" `
            -DependsOn $deps -Confidence $cap -Extra @{}
        }
      }
      foreach($p in @($Data['Get-SATIIS'][$srv].AppPools)){
        Add-Unit -Id "iispool:$srv:$($p.Name)" -Kind 'IisAppPool' -Server $srv -Name $p.Name `
          -Summary "State=$($p.State) CLR=$($p.RuntimeVersion) Mode=$($p.PipelineMode)" -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Certificates
  if($Data['Get-SATCertificates']){
    foreach($srv in @($Data['Get-SATCertificates'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATCertificates'][$srv].Notes)
      foreach($store in @($Data['Get-SATCertificates'][$srv].Stores.Keys)){
        foreach($c in @($Data['Get-SATCertificates'][$srv].Stores[$store])){
          Add-Unit -Id "cert:$srv:$($c.Thumbprint)" -Kind 'Certificate' -Server $srv `
            -Name ($c.FriendlyName ?? $c.Subject) -Summary "$store NotAfter=$($c.NotAfter)" -DependsOn @() -Confidence $cap -Extra @{ NotAfter=$c.NotAfter }
        }
      }
    }
  }

  # SMB shares (and top-level ACL entries as separate MUs)
  if($Data['Get-SATSMB']){
    foreach($srv in @($Data['Get-SATSMB'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATSMB'][$srv].Notes)
      foreach($sh in @($Data['Get-SATSMB'][$srv].Shares)){
        Add-Unit -Id "smb:$srv:share:$($sh.Name)" -Kind 'SmbShare' -Server $srv -Name $sh.Name `
          -Summary "$($sh.Path) Encrypt=$($sh.EncryptData)" -DependsOn @() -Confidence $cap -Extra @{}
      }
      foreach($perm in @($Data['Get-SATSMB'][$srv].Permissions)){
        foreach($ntfs in @($perm.NtfsTop)){
          Add-Unit -Id ("smb:$srv:share:$($perm.Share):acl:"+([convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($ntfs.IdentityReference)|$($ntfs.FileSystemRights)|$($ntfs.AccessControlType)")))) `
            -Kind 'SmbAclEntry' -Server $srv -Name "$($perm.Share)" `
            -Summary "$($ntfs.IdentityReference) $($ntfs.AccessControlType) $($ntfs.FileSystemRights)" -DependsOn @("smb:$srv:share:$($perm.Share)") `
            -Confidence $cap -Extra @{ Identity=$ntfs.IdentityReference; Rights=$ntfs.FileSystemRights }
        }
      }
    }
  }

  # Hyper-V VMs
  if($Data['Get-SATHyperV']){
    foreach($srv in @($Data['Get-SATHyperV'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATHyperV'][$srv].Notes)
      foreach($vm in @($Data['Get-SATHyperV'][$srv].VMs)){
        Add-Unit -Id "hv:$srv:vm:$($vm.Name)" -Kind 'HvVm' -Server $srv -Name $vm.Name `
          -Summary "State=$($vm.State) Mem=$($vm.MemoryAssigned) Uptime=$($vm.Uptime)" -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Printers
  if($Data['Get-SATPrinters']){
    foreach($srv in @($Data['Get-SATPrinters'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATPrinters'][$srv].Notes)
      foreach($p in @($Data['Get-SATPrinters'][$srv].Printers)){
        Add-Unit -Id "print:$srv:queue:$($p.Name)" -Kind 'PrinterQueue' -Server $srv -Name $p.Name `
          -Summary "Shared=$($p.Shared) Driver=$($p.DriverName) Port=$($p.PortName)" -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # Scheduled Tasks
  if($Data['Get-SATScheduledTasks']){
    foreach($srv in @($Data['Get-SATScheduledTasks'].Keys)){
      $cap = Get-ConfidenceFromNotes($Data['Get-SATScheduledTasks'][$srv].Notes)
      foreach($t in @($Data['Get-SATScheduledTasks'][$srv].Tasks)){
        Add-Unit -Id ("task:$srv:"+[convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($t.TaskPath)$($t.TaskName)"))) `
          -Kind 'ScheduledTask' -Server $srv -Name $t.TaskName `
          -Summary "State=$($t.State) Next=$($t.NextRun) Exec=$($t.ActionExe)" -DependsOn @() -Confidence $cap -Extra @{ ActionExe=$t.ActionExe }
      }
    }
  }

  return ,$units.ToArray()
}

function Evaluate-SATReadiness {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][array]$Units,
    [Parameter(Mandatory)][array]$Rules
  )

  function Now { Get-Date }
  function ToDate([object]$x) { try { [datetime]$x } catch { Get-Date 1970-01-01 } }

  $findings = New-Object System.Collections.Generic.List[hashtable]
  foreach($u in $Units){
    foreach($r in $Rules | Where-Object { $_.appliesTo -eq $u.Kind }){
      $Item = $u
      $sb = [ScriptBlock]::Create($r.when)
      $ok = $false
      try { $ok = [bool](& $sb) } catch { $ok = $false }
      if($ok){
        $findings.Add(@{
          UnitId   = $u.Id
          Kind     = $u.Kind
          Server   = $u.Server
          Name     = $u.Name
          Severity = $r.severity
          RuleId   = $r.id
          Message  = $r.message
        }) | Out-Null
      }
    }
  }
  return ,$findings.ToArray()
}
