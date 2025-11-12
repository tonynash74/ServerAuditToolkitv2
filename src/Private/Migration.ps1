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
