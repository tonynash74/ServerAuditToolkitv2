# ------------------------------
# Migration / Readiness helpers
# ------------------------------

function Get-SATDefaultReadinessRules {
  # Returns an array of hashtables with: id, appliesTo, severity, message, when (script text evaluated with $Item)
  $rules = @()

  # Certificates expiring soon
  $rules += @{ id='cert-expiring-90d'; appliesTo='Certificate'; severity='High'
    ; message='Certificate expires within 90 days.'
    ; when='$Item.NotAfter -and ([datetime]$Item.NotAfter -lt (Get-Date).AddDays(90))' }

  # HTTPS binding without certificate dependency
  $rules += @{ id='iis-https-binding-no-cert'; appliesTo='IisBinding'; severity='High'
    ; message='HTTPS binding without a linked certificate.'
    ; when='($Item.Name -like "https*") -and (@($Item.DependsOn).Count -eq 0)' }

  # SMB share root grants wide Full Control
  $rules += @{ id='smb-share-broad-fullcontrol'; appliesTo='SmbAclEntry'; severity='Medium'
    ; message='Share root ACL grants broad Full Control.'
    ; when='(@("Everyone","Authenticated Users") -contains $Item.Identity) -and ($Item.Rights -like "*Full*")' }

  # Scheduled task runs from UNC
  $rules += @{ id='task-runs-unc'; appliesTo='ScheduledTask'; severity='Medium'
    ; message='Task runs an executable from a UNC path.'
    ; when='$Item.ActionExe -like "\\\\*"' }

  return $rules
}

function New-SATMigrationUnits {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][hashtable]$Data)

  # Use ArrayList for PS2 compatibility
  $units = New-Object System.Collections.ArrayList

  function Add-Unit {
    param(
      [string]$Id,[string]$Kind,[string]$Server,[string]$Name,
      [string]$Summary,[string[]]$DependsOn,[double]$Confidence,[hashtable]$Extra
    )
    $h = @{ Id=$Id; Kind=$Kind; Server=$Server; Name=$Name; Summary=$Summary; DependsOn=$DependsOn; Confidence=$Confidence }
    if ($Extra) { foreach($k in $Extra.Keys){ $h[$k] = $Extra[$k] } }
    [void]$units.Add($h)
  }

  function Get-Conf([string]$notes){
    if ([string]::IsNullOrEmpty($notes)) { return 0.8 }
    if ($notes -match 'module|WebAdministration|Get-SmbShare|DhcpServer|Storage') { return 1.0 }
    if ($notes -match 'WMI')    { return 0.8 }
    if ($notes -match 'fallback|appcmd') { return 0.75 }
    return 0.85
  }

  # ------------- DHCP scopes -------------
  if ($Data['Get-SATDHCP']) {
    foreach ($srv in @($Data['Get-SATDHCP'].Keys)) {
      $cap = Get-Conf $Data['Get-SATDHCP'][$srv].Notes
      foreach ($s in @($Data['Get-SATDHCP'][$srv].Scopes)) {
        $sid = $null; $name=$null; $start=$null; $end=$null; $mask=$null; $state=$null
        try { $sid   = $s.ScopeId } catch {}
        try { $name  = $s.Name } catch {}
        try { $start = $s.StartRange } catch {}
        try { $end   = $s.EndRange } catch {}
        try { $mask  = $s.SubnetMask } catch {}
        try { $state = $s.State } catch {}
        Add-Unit -Id ("dhcp:{0}:scope:{1}" -f $srv,$sid) -Kind 'DhcpScope' -Server $srv -Name $name `
          -Summary ("Scope {0} {1}-{2}/{3} ({4})" -f $sid,$start,$end,$mask,$state) `
          -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # ------------- DNS zones -------------
  if ($Data['Get-SATDNS']) {
    foreach ($srv in @($Data['Get-SATDNS'].Keys)) {
      $cap = Get-Conf $Data['Get-SATDNS'][$srv].Notes
      foreach ($z in @($Data['Get-SATDNS'][$srv].Zones)) {
        $zn=$null;$zt=$null;$ds=$null
        try { $zn = $z.ZoneName } catch {}
        try { $zt = $z.ZoneType } catch {}
        try { $ds = $z.IsDsIntegrated } catch {}
        Add-Unit -Id ("dns:{0}:zone:{1}" -f $srv,$zn) -Kind 'DnsZone' -Server $srv -Name $zn `
          -Summary ("Type={0} DSInt={1}" -f $zt,$ds) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # ------------- IIS -------------
  if ($Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $cap = Get-Conf $Data['Get-SATIIS'][$srv].Notes
      # Sites
      foreach ($site in @($Data['Get-SATIIS'][$srv].Sites)) {
        $sn=$null;$st=$null;$ap=$null;$pp=$null
        try { $sn = $site.Name } catch {}
        try { $st = $site.State } catch {}
        try { $ap = $site.AppPool } catch {}
        try { $pp = $site.PhysicalPath } catch {}
        Add-Unit -Id ("iis:{0}:site:{1}" -f $srv,$sn) -Kind 'IisSite' -Server $srv -Name $sn `
          -Summary ("State={0} Path={1}" -f $st,$pp) -DependsOn @("iispool:{0}:{1}" -f $srv,$ap) -Confidence $cap -Extra @{}

        # Bindings
        foreach ($b in @($site.Bindings)) {
          $thumb = $null
          if ($b -and $b.PSObject -and $b.PSObject.Properties) {
            try {
              if ($b.PSObject.Properties['certificateHash']) { $thumb = $b.certificateHash }
              elseif ($b.PSObject.Properties['thumbprint'])  { $thumb = $b.thumbprint }
            } catch {}
          }
          $deps = @(); if ($thumb) { $deps = @("cert:{0}:{1}" -f $srv,$thumb) }

          $prot=$null;$bind=$null
          try { $prot = $b.protocol } catch {}
          try { $bind = $b.bindingInformation } catch {}

          Add-Unit -Id ("iis:{0}:binding:{1}:{2}:{3}" -f $srv,$sn,$prot,$bind) -Kind 'IisBinding' `
            -Server $srv -Name ("{0} {1}" -f $prot,$bind) -Summary ("Binding for {0}" -f $sn) `
            -DependsOn $deps -Confidence $cap -Extra @{}
        }
      }
      # AppPools
      foreach ($p in @($Data['Get-SATIIS'][$srv].AppPools)) {
        $pn=$null;$pst=$null;$rt=$null;$pm=$null
        try { $pn = $p.Name } catch {}
        try { $pst= $p.State } catch {}
        try { $rt = $p.RuntimeVersion } catch {}
        try { $pm = $p.PipelineMode } catch {}
        Add-Unit -Id ("iispool:{0}:{1}" -f $srv,$pn) -Kind 'IisAppPool' -Server $srv -Name $pn `
          -Summary ("State={0} CLR={1} Mode={2}" -f $pst,$rt,$pm) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # ------------- Certificates -------------
  if ($Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $cap = Get-Conf $Data['Get-SATCertificates'][$srv].Notes
      $stores = $Data['Get-SATCertificates'][$srv].Stores
      foreach ($store in @($stores.Keys)) {
        foreach ($c in @($stores[$store])) {
          $thumb=$null;$name=$null;$na=$null
          try { $thumb = $c.Thumbprint } catch {}
          try { $name  = $c.FriendlyName } catch {}
          if (-not $name) { try { $name = $c.Subject } catch {} }
          try { $na    = $c.NotAfter } catch {}
          Add-Unit -Id ("cert:{0}:{1}" -f $srv,$thumb) -Kind 'Certificate' -Server $srv -Name $name `
            -Summary ("{0} NotAfter={1}" -f $store,$na) -DependsOn @() -Confidence $cap -Extra @{ NotAfter=$na }
        }
      }
    }
  }

  # ------------- SMB -------------
  if ($Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $cap = Get-Conf $Data['Get-SATSMB'][$srv].Notes
      foreach ($sh in @($Data['Get-SATSMB'][$srv].Shares)) {
        $nm=$null;$pth=$null;$enc=$null
        try { $nm = $sh.Name } catch {}
        try { $pth= $sh.Path } catch {}
        try { $enc= $sh.EncryptData } catch {}
        Add-Unit -Id ("smb:{0}:share:{1}" -f $srv,$nm) -Kind 'SmbShare' -Server $srv -Name $nm `
          -Summary ("{0} Encrypt={1}" -f $pth,$enc) -DependsOn @() -Confidence $cap -Extra @{}
      }
      foreach ($perm in @($Data['Get-SATSMB'][$srv].Permissions)) {
        $shareName=$null; $pathTop=$null
        try { $shareName = $perm.Share } catch {}
        try { $pathTop   = $perm.Path } catch {}
        $topList = @()
        if ($perm -and $perm.PSObject -and $perm.PSObject.Properties['NtfsTop']) { $topList = @($perm.NtfsTop) }
        foreach ($nt in $topList) {
          $id=$null;$rights=$null;$type=$null
          try { $id = $nt.IdentityReference } catch {}
          try { $rights = $nt.FileSystemRights } catch {}
          try { $type = $nt.AccessControlType } catch {}
          $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}|{1}|{2}" -f $id,$rights,$type)))
          Add-Unit -Id ("smb:{0}:share:{1}:acl:{2}" -f $srv,$shareName,$key) -Kind 'SmbAclEntry' -Server $srv -Name $shareName `
            -Summary ("{0} {1} {2}" -f $id,$type,$rights) -DependsOn @("smb:{0}:share:{1}" -f $srv,$shareName) `
            -Confidence $cap -Extra @{ Identity=$id; Rights=$rights }
        }
      }
    }
  }

  # ------------- Hyper-V -------------
  if ($Data['Get-SATHyperV']) {
    foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
      $cap = Get-Conf $Data['Get-SATHyperV'][$srv].Notes
      foreach ($vm in @($Data['Get-SATHyperV'][$srv].VMs)) {
        $name=$null;$state=$null;$mem=$null;$up=$null
        try { $name = $vm.Name } catch {}
        try { $state= $vm.State } catch {}
        try { $mem  = $vm.MemoryAssigned } catch {}
        try { $up   = $vm.Uptime } catch {}
        Add-Unit -Id ("hv:{0}:vm:{1}" -f $srv,$name) -Kind 'HvVm' -Server $srv -Name $name `
          -Summary ("State={0} Mem={1} Uptime={2}" -f $state,$mem,$up) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # ------------- Printers -------------
  if ($Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      $cap = Get-Conf $Data['Get-SATPrinters'][$srv].Notes
      foreach ($p in @($Data['Get-SATPrinters'][$srv].Printers)) {
        $pn=$null;$drv=$null;$port=$null;$shr=$null
        try { $pn = $p.Name } catch {}
        try { $drv= $p.DriverName } catch {}
        try { $port=$p.PortName } catch {}
        try { $shr = $p.Shared } catch {}
        Add-Unit -Id ("print:{0}:queue:{1}" -f $srv,$pn) -Kind 'PrinterQueue' -Server $srv -Name $pn `
          -Summary ("Shared={0} Driver={1} Port={2}" -f $shr,$drv,$port) -DependsOn @() -Confidence $cap -Extra @{}
      }
    }
  }

  # ------------- Scheduled Tasks -------------
  if ($Data['Get-SATScheduledTasks']) {
    foreach ($srv in @($Data['Get-SATScheduledTasks'].Keys)) {
      $cap = Get-Conf $Data['Get-SATScheduledTasks'][$srv].Notes
      foreach ($t in @($Data['Get-SATScheduledTasks'][$srv].Tasks)) {
        $tp=$null;$tn=$null;$state=$null;$next=$null;$exe=$null
        try { $tp = $t.TaskPath } catch {}
        try { $tn = $t.TaskName } catch {}
        try { $state = $t.State } catch {}
        try { $next  = $t.NextRun } catch {}
        try { $exe   = $t.ActionExe } catch {}
        $idKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}{1}" -f $tp,$tn)))
        Add-Unit -Id ("task:{0}:{1}" -f $srv,$idKey) -Kind 'ScheduledTask' -Server $srv -Name $tn `
          -Summary ("State={0} Next={1} Exec={2}" -f $state,$next,$exe) -DependsOn @() -Confidence $cap -Extra @{ ActionExe=$exe }
      }
    }
  }

  return ,@($units)  # force array
}

function Evaluate-SATReadiness {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][array]$Units,
    [Parameter(Mandatory=$true)][array]$Rules
  )

  $findings = New-Object System.Collections.ArrayList

  foreach ($u in $Units) {
    $appRules = @($Rules | Where-Object { $_.appliesTo -eq $u.Kind })
    foreach ($r in $appRules) {
      $Item = $u
      $ok = $false
      try {
        $sb = [ScriptBlock]::Create($r.when)
        $ok = [bool](& $sb)
      } catch {
        $ok = $false
      }
      if ($ok) {
        [void]$findings.Add(@{
          UnitId   = $u.Id
          Kind     = $u.Kind
          Server   = $u.Server
          Name     = $u.Name
          Severity = $r.severity
          RuleId   = $r.id
          Message  = $r.message
        })
      }
    }
  }

  return ,@($findings)
}
