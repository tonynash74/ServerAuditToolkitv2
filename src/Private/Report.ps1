function Write-SATCsv {
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][array]$Rows
  )
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $path = Join-Path $OutDir "$Name.csv"
    if ($Rows -and $Rows.Count -gt 0) { $Rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $path }
    return $path
  } catch {
    Write-Log Warn ("CSV export failed for {0} : {1}" -f $Name, $_.Exception.Message)
    return $null
  }
}

function New-SATReport {
  [CmdletBinding()]
  param(
    [hashtable]$Data,
    [array]$Units,
    [array]$Findings,
    [string]$OutDir,
    [string]$Timestamp
  )

  $csvRoot = Join-Path $OutDir 'csv'
  if (-not (Test-Path $csvRoot)) { New-Item -ItemType Directory -Force -Path $csvRoot | Out-Null }
  $findingsMsgs = @()
  $servers = @()
  if ($Data -and $Data.ContainsKey('Get-SATSystem')) { $servers = @($Data['Get-SATSystem'].Keys) }
  $maxHtmlRows = 200

  # ---------- IIS ----------
  $iisSitesRows = @(); $iisPoolsRows=@()
  if ($Data -and $Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $iis = $Data['Get-SATIIS'][$srv]
      foreach ($s in @($iis.Sites)) {
        $btxt = @()
        foreach ($b in @($s.Bindings)) { $btxt += ("{0}|{1}" -f $b.protocol, $b.bindingInformation) }
        $iisSitesRows += New-Object PSObject -Property @{
          Server=$srv; Name=$s.Name; State=$s.State; AppPool=$s.AppPool
          PhysicalPath=$s.PhysicalPath; Bindings=($btxt -join ';')
        }
      }
      foreach ($p in @($iis.AppPools)) {
        $iisPoolsRows += New-Object PSObject -Property @{
          Server=$srv; Name=$p.Name; State=$p.State
          Runtime=$p.RuntimeVersion; Pipeline=$p.PipelineMode; Identity=$p.IdentityType
        }
      }
    }
  }
  $csvIisSites = $null; if($iisSitesRows){ $csvIisSites = Write-SATCsv -OutDir $csvRoot -Name 'iis_sites' -Rows $iisSitesRows }
  $csvIisPools = $null; if($iisPoolsRows){ $csvIisPools = Write-SATCsv -OutDir $csvRoot -Name 'iis_pools' -Rows $iisPoolsRows }
  if ($iisSitesRows -and $iisSitesRows.Count -gt 0) { $findingsMsgs += ("IIS migration required on {0} server(s): {1} site(s)." -f @(@($Data['Get-SATIIS'].Keys).Count), $iisSitesRows.Count) }

  # ---------- Hyper-V ----------
  $hvVmRows = @()
  if ($Data -and $Data['Get-SATHyperV']) {
    foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
      foreach ($vm in @($Data['Get-SATHyperV'][$srv].VMs)) {
        $hvVmRows += New-Object PSObject -Property @{
          Server=$srv; Name=$vm.Name; State=$vm.State; Memory=$vm.MemoryAssigned; CPU=$vm.CPUUsage; Uptime=$vm.Uptime; Gen=$vm.Generation
        }
      }
    }
  }
  $csvHyperV = $null; if($hvVmRows){ $csvHyperV = Write-SATCsv -OutDir $csvRoot -Name 'hyperv_vms' -Rows $hvVmRows }
  if ($hvVmRows -and $hvVmRows.Count -gt 0) { $findingsMsgs += ("Hyper-V migration required on {0} host(s): {1} VM(s)." -f @(@($Data['Get-SATHyperV'].Keys).Count), $hvVmRows.Count) }

  # ---------- DHCP/DNS counts ----------
  if ($Data -and $Data['Get-SATDHCP']) {
    $scopeCount = 0; foreach ($srv in @($Data['Get-SATDHCP'].Keys)) { $scopeCount += @($Data['Get-SATDHCP'][$srv].Scopes).Count }
    if ($scopeCount -gt 0) { $findingsMsgs += ("DHCP migration required: {0} scope(s)." -f $scopeCount) }
  }
  if ($Data -and $Data['Get-SATDNS']) {
    $zoneCount = 0; foreach ($srv in @($Data['Get-SATDNS'].Keys)) { $zoneCount += @($Data['Get-SATDNS'][$srv].Zones).Count }
    if ($zoneCount -gt 0) { $findingsMsgs += ("DNS migration required: {0} zone(s)." -f $zoneCount) }
  }

  # ---------- SMB ----------
  $smbShareRows = @(); $smbAclRows = @()
  if ($Data -and $Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $smb = $Data['Get-SATSMB'][$srv]
      foreach ($sh in @($smb.Shares)) {
        $smbShareRows += New-Object PSObject -Property @{
          Server=$srv; Name=$sh.Name; Path=$sh.Path; Desc=$sh.Description; EncryptData=$sh.EncryptData
        }
      }
      foreach ($perm in @($smb.Permissions)) {
        foreach ($ntfs in @($perm.NtfsTop)) {
          $smbAclRows += New-Object PSObject -Property @{
            Server=$srv; Share=$perm.Share; Path=$perm.Path
            Identity=$ntfs.IdentityReference; Rights=$ntfs.FileSystemRights; Type=$ntfs.AccessControlType; Inherited=$ntfs.IsInherited
          }
        }
      }
    }
  }
  $csvSmbShares = $null; if($smbShareRows){ $csvSmbShares = Write-SATCsv -OutDir $csvRoot -Name 'smb_shares' -Rows $smbShareRows }
  $csvSmbAcls   = $null; if($smbAclRows){   $csvSmbAcls   = Write-SATCsv -OutDir $csvRoot -Name 'smb_ntfs_top' -Rows $smbAclRows }
  if ($smbShareRows -and $smbShareRows.Count -gt 0) { $findingsMsgs += ("File server migration required: {0} share(s) across {1} server(s)." -f $smbShareRows.Count, @(@($Data['Get-SATSMB'].Keys).Count)) }

  # ---------- Certificates ----------
  $certRows = @()
  if ($Data -and $Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $allStores = $Data['Get-SATCertificates'][$srv].Stores
      foreach ($storeName in @($allStores.Keys)) {
        foreach ($cert in @($allStores[$storeName])) {
          $certRows += New-Object PSObject -Property @{
            Server=$srv; Store=$storeName; Subject=$cert.Subject; Thumbprint=$cert.Thumbprint
            NotBefore=$cert.NotBefore; NotAfter=$cert.NotAfter; HasPrivateKey=$cert.HasPrivateKey; FriendlyName=$cert.FriendlyName
          }
        }
      }
    }
  }
  $csvCerts = $null; if($certRows){ $csvCerts = Write-SATCsv -OutDir $csvRoot -Name 'certificates' -Rows $certRows }
  if ($certRows -and $certRows.Count -gt 0) {
    $expiring = (@($certRows | Where-Object { $_.NotAfter -and ([datetime]$_.NotAfter -lt (Get-Date).AddDays(120)) })).Count
    $findingsMsgs += ("Certificates discovered: {0}. Expiring in <120 days: {1}." -f $certRows.Count, $expiring)
  }

  # ---------- AD DS summary ----------
  if ($Data -and $Data['Get-SATADDS'] -and $Data['Get-SATADDS'].ActiveDirectory) {
    $ad = $Data['Get-SATADDS'].ActiveDirectory
    if ($ad.Forest -and $ad.Domain) {
      $findingsMsgs += ("AD Forest: {0} (Mode: {1}); Domain: {2} (Mode: {3}); SYSVOL: {4}." -f $ad.Forest.Name, $ad.Forest.Mode, $ad.Domain.Name, $ad.Domain.Mode, $ad.SysvolReplication)
      if ($ad.SysvolReplication -eq 'FRS') { $findingsMsgs += "Action: migrate SYSVOL from FRS to DFSR before domain/OS upgrades." }
    }
  }

  # ---------- Network ----------
  $netRows = @()
  if ($Data -and $Data['Get-SATNetwork']) {
    foreach ($srv in @($Data['Get-SATNetwork'].Keys)) {
      $n = $Data['Get-SATNetwork'][$srv]
      $adapters = @{}
      foreach ($a in @($n.Adapters)) {
        $name = $null
        if ($a -and $a.PSObject.Properties['Name']) { $name = $a.Name }
        if ($name) { $adapters[$name.ToLower()] = $a }
      }

      foreach ($cfg in @($n.IPConfig)) {
        $alias = $null
        if ($cfg -and $cfg.PSObject.Properties['InterfaceAlias']) { $alias = $cfg.InterfaceAlias }
        if (-not $alias -and $cfg -and $cfg.PSObject.Properties['Description']) { $alias = $cfg.Description }

        $akey = $null; if ($alias) { $akey = $alias.ToLower() }
        $a = $null; if ($akey -and $adapters.ContainsKey($akey)) { $a = $adapters[$akey] }

        $ipv4list = @()
        if ($cfg -and $cfg.PSObject.Properties['IPv4Address']) {
          foreach ($i in @($cfg.IPv4Address)) {
            if ($i -and $i.PSObject -and $i.PSObject.Properties['IPAddress']) { $ipv4list += $i.IPAddress } else { $ipv4list += "$i" }
          }
        } elseif ($cfg -and $cfg.PSObject.Properties['IPv4']) {
          $ipv4list += @($cfg.IPv4)
        }

        $ipv6list = @()
        if ($cfg -and $cfg.PSObject.Properties['IPv6Address']) {
          foreach ($i6 in @($cfg.IPv6Address)) {
            if ($i6 -and $i6.PSObject -and $i6.PSObject.Properties['IPAddress']) { $ipv6list += $i6.IPAddress } else { $ipv6list += "$i6" }
          }
        } elseif ($cfg -and $cfg.PSObject.Properties['IPv6']) {
          $ipv6list += @($cfg.IPv6)
        }

        $gw = $null
        if ($cfg -and $cfg.PSObject.Properties['Ipv4DefaultGateway']) {
          $gobj = $cfg.Ipv4DefaultGateway
          if ($gobj -and $gobj.PSObject -and $gobj.PSObject.Properties['NextHop']) { $gw = $gobj.NextHop }
        }

        $dnslist = @()
        if ($cfg -and $cfg.PSObject.Properties['DNSServer']) {
          foreach ($d in @($cfg.DNSServer)) {
            if ($d -and $d.PSObject -and $d.PSObject.Properties['ServerAddresses']) { $dnslist += $d.ServerAddresses } else { $dnslist += "$d" }
          }
        } elseif ($cfg -and $cfg.PSObject.Properties['DNS']) {
          $dnslist += @($cfg.DNS)
        }

        $mac   = $null; if ($a -and $a.PSObject.Properties['MacAddress']) { $mac = $a.MacAddress }
        $stat  = $null; if ($a -and $a.PSObject.Properties['InterfaceOperationalStatus']) { $stat = $a.InterfaceOperationalStatus }
        $speed = $null; if ($a -and $a.PSObject.Properties['LinkSpeed']) { $speed = $a.LinkSpeed }

        $netRows += New-Object PSObject -Property @{
          Server     = $srv
          Interface  = $alias
          MAC        = $mac
          Status     = $stat
          Speed      = $speed
          IPv4       = ($ipv4list -join ',')
          IPv6       = ($ipv6list -join ',')
          Gateway    = $gw
          DNS        = ($dnslist -join ',')
          DHCP       = (if ($cfg -and $cfg.PSObject.Properties['DHCP']) { $cfg.DHCP } else { $null })
        }
      }
    }
  }
  $csvNetwork = $null; if($netRows){ $csvNetwork = Write-SATCsv -OutDir $csvRoot -Name 'network_adapters' -Rows $netRows }

  # ---------- Storage ----------
  $volRows = @(); $diskRows=@()
  if ($Data -and $Data['Get-SATStorage']) {
    foreach ($srv in @($Data['Get-SATStorage'].Keys)) {
      foreach ($v in @($Data['Get-SATStorage'][$srv].Volumes)) {
        $sizeGB = $null; $freeGB=$null
        if ($v.PSObject.Properties['Size']) { $sizeGB = [math]::Round(($v.Size/1GB),2) }
        if ($v.PSObject.Properties['SizeRemaining']) { $freeGB = [math]::Round(($v.SizeRemaining/1GB),2) }
        $volRows += New-Object PSObject -Property @{
          Server=$srv; Drive=$v.DriveLetter; Label=$v.FileSystemLabel; FS=$v.FileSystem
          SizeGB=$sizeGB; FreeGB=$freeGB; Health=$v.HealthStatus; Path=$v.Path
        }
      }
      foreach ($d in @($Data['Get-SATStorage'][$srv].Disks)) {
        $sizeD = $null; if ($d.PSObject.Properties['Size']) { $sizeD = [math]::Round(($d.Size/1GB),2) }
        $diskRows += New-Object PSObject -Property @{
          Server=$srv; Disk=$d.Number; Model=$d.FriendlyName; Serial=$d.SerialNumber
          Bus=$d.BusType; PartStyle=$d.PartitionStyle; Health=$d.HealthStatus; SizeGB=$sizeD
        }
      }
    }
  }
  $csvVolumes = $null; if($volRows){ $csvVolumes = Write-SATCsv -OutDir $csvRoot -Name 'storage_volumes' -Rows $volRows }
  $csvDisks   = $null; if($diskRows){ $csvDisks   = Write-SATCsv -OutDir $csvRoot -Name 'storage_disks'   -Rows $diskRows }

  # ---------- Local Accounts ----------
  $userRows=@(); $groupRows=@(); $memberRows=@()
  if ($Data -and $Data['Get-SATLocalAccounts']) {
    foreach ($srv in @($Data['Get-SATLocalAccounts'].Keys)) {
      foreach ($u in @($Data['Get-SATLocalAccounts'][$srv].Users)) {
        $userRows += New-Object PSObject -Property @{
          Server=$srv; Name=$u.Name; Enabled=$u.Enabled; LastLogon=$u.LastLogon
          PwdExpires=$u.PasswordExpires; PwdRequired=$u.PasswordRequired; SID=$u.SID
        }
      }
      foreach ($g in @($Data['Get-SATLocalAccounts'][$srv].Groups)) {
        $groupRows += New-Object PSObject -Property @{ Server=$srv; Name=$g.Name; SID=$g.SID }
      }
      foreach ($m in @($Data['Get-SATLocalAccounts'][$srv].Members)) {
        $memberRows += New-Object PSObject -Property @{ Server=$srv; Group=$m.Group; Name=$m.Name; Class=$m.ObjectClass; SID=$m.SID }
      }
    }
  }
  $csvUsers   = $null; if($userRows){   $csvUsers   = Write-SATCsv -OutDir $csvRoot -Name 'local_users'         -Rows $userRows }
  $csvGroups  = $null; if($groupRows){  $csvGroups  = Write-SATCsv -OutDir $csvRoot -Name 'local_groups'        -Rows $groupRows }
  $csvMembers = $null; if($memberRows){ $csvMembers = Write-SATCsv -OutDir $csvRoot -Name 'local_group_members' -Rows $memberRows }

  # ---------- Printers ----------
  $printerRows=@(); $portRows=@()
  if ($Data -and $Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      foreach ($p in @($Data['Get-SATPrinters'][$srv].Printers)) {
        $printerRows += New-Object PSObject -Property @{
          Server=$srv; Name=$p.Name; Shared=$p.Shared; ShareName=$p.ShareName
          Driver=$p.DriverName; Port=$p.PortName; Published=$p.Published; Location=$p.Location; Comment=$p.Comment; Status=$p.PrinterStatus
        }
      }
      foreach ($pt in @($Data['Get-SATPrinters'][$srv].Ports)) {
        $hostAddr = $null
        if ($pt -and $pt.PSObject.Properties['PrinterHostAddress']) { $hostAddr = $pt.PrinterHostAddress }
        elseif ($pt -and $pt.PSObject.Properties['HostAddress'])    { $hostAddr = $pt.HostAddress }

        $snmp = $null
        if ($pt -and $pt.PSObject.Properties['SnmpEnabled']) { $snmp = $pt.SnmpEnabled }
        elseif ($pt -and $pt.PSObject.Properties['SNMPEnabled']) { $snmp = $pt.SNMPEnabled }

        $portRows += New-Object PSObject -Property @{
          Server=$srv; Name=$pt.Name; HostAddress=$hostAddr; PortNumber=$pt.PortNumber; SnmpEnabled=$snmp
        }
      }
    }
  }
  $csvPrinters = $null; if($printerRows){ $csvPrinters = Write-SATCsv -OutDir $csvRoot -Name 'printers' -Rows $printerRows }
  $csvPorts    = $null; if($portRows){    $csvPorts    = Write-SATCsv -OutDir $csvRoot -Name 'printer_ports' -Rows $portRows }

  # ---------- Migration Units / Findings CSV links ----------
  $csvUnits = $null;  if ($Units)   { $csvUnits = Write-SATCsv -OutDir $csvRoot -Name 'migration_units' -Rows ($Units | Select Id,Kind,Server,Name,Summary,Confidence) }
  $csvFinds = $null;  if ($Findings){ $csvFinds = Write-SATCsv -OutDir $csvRoot -Name 'readiness_findings' -Rows ($Findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId) }

  # Confidence buckets (PS2-safe)
  $hi=0; $md=0; $lo=0
  if ($Units) {
    foreach ($u in $Units) {
      if ($u.Confidence -ge 0.9) { $hi++ }
      elseif ($u.Confidence -ge 0.7) { $md++ }
      else { $lo++ }
    }
  }
  $unitCount = 0
  if ($Units) { $unitCount = $Units.Count }
  $totalUnits = [math]::Max(1, $unitCount)
  $hiPct = [math]::Round(($hi*100.0)/$totalUnits,1)
  $mdPct = [math]::Round(($md*100.0)/$totalUnits,1)
  $loPct = [math]::Round(($lo*100.0)/$totalUnits,1)

  # Build quick-links HTML once (avoid inline if inside heredoc)
  $quickLinks = ""
  if ($csvUnits)    { $quickLinks += "<li><a href='./csv/migration_units.csv'>Migration Units CSV</a></li>" }
  if ($csvFinds)    { $quickLinks += "<li><a href='./csv/readiness_findings.csv'>Readiness Findings CSV</a></li>" }
  if ($csvIisSites) { $quickLinks += "<li><a href='./csv/iis_sites.csv'>IIS Sites CSV</a></li>" }
  if ($csvIisPools) { $quickLinks += "<li><a href='./csv/iis_pools.csv'>IIS AppPools CSV</a></li>" }
  if ($csvHyperV)   { $quickLinks += "<li><a href='./csv/hyperv_vms.csv'>Hyper-V VMs CSV</a></li>" }
  if ($csvSmbShares){ $quickLinks += "<li><a href='./csv/smb_shares.csv'>SMB Shares CSV</a></li>" }
  if ($csvSmbAcls)  { $quickLinks += "<li><a href='./csv/smb_ntfs_top.csv'>Top-level NTFS ACL CSV</a></li>" }
  if ($csvCerts)    { $quickLinks += "<li><a href='./csv/certificates.csv'>Certificates CSV</a></li>" }
  if ($csvNetwork)  { $quickLinks += "<li><a href='./csv/network_adapters.csv'>Network Adapters + IPs CSV</a></li>" }
  if ($csvVolumes)  { $quickLinks += "<li><a href='./csv/storage_volumes.csv'>Storage Volumes CSV</a></li>" }
  if ($csvDisks)    { $quickLinks += "<li><a href='./csv/storage_disks.csv'>Storage Disks CSV</a></li>" }
  if ($csvUsers)    { $quickLinks += "<li><a href='./csv/local_users.csv'>Local Users CSV</a></li>" }
  if ($csvGroups)   { $quickLinks += "<li><a href='./csv/local_groups.csv'>Local Groups CSV</a></li>" }
  if ($csvMembers)  { $quickLinks += "<li><a href='./csv/local_group_members.csv'>Local Group Members CSV</a></li>" }

  # ---------- Markdown summary ----------
  $summary = @"
# ServerAuditToolkitV2 Migration Readiness
Run: $Timestamp
"@
  $md = Join-Path $OutDir "summary_$Timestamp.md"
  $summary | Set-Content -Path $md -Encoding UTF8

  # ---------- HTML ----------
  $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SATv2 Report $Timestamp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
<style>.table{font-size:.9rem}.truncate{max-width:380px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}</style>
</head>
<body class="bg-light">
<div class="container my-4">
  <h1 class="mb-3">ServerAuditToolkitV2 – Migration Readiness</h1>
  <p class="text-muted">Run: $Timestamp</p>

  <div class="alert alert-info">
    <strong>High-level findings</strong>
    <ul>$(($findingsMsgs | ForEach-Object { "<li>$($_)</li>" }) -join "`n")</ul>
  </div>

  <div class="row g-3">
    <div class="col-md-5">
      <div class="card shadow-sm"><div class="card-body">
        <h5 class="card-title">Inventory footprint</h5>
        <ul class="mb-0">
          <li>Servers: $($servers.Count)</li>
          <li>Printers: $($printerRows.Count)</li>
          <li>Migration Units: $unitCount</li>
        </ul>
      </div></div>
    </div>
    <div class="col-md-7">
      <div class="card shadow-sm"><div class="card-body">
        <h5 class="card-title">Quick links</h5>
        <ul>$quickLinks</ul>
      </div></div>
    </div>
  </div>

  <div class="card shadow-sm mt-3">
    <div class="card-body">
      <h5 class="card-title">Discovery confidence</h5>
      <div class="progress" style="height:24px">
        <div class="progress-bar bg-success" role="progressbar" style="width: ${hiPct}%">${hiPct}% high</div>
        <div class="progress-bar bg-warning" role="progressbar" style="width: ${mdPct}%">${mdPct}% medium</div>
        <div class="progress-bar bg-danger"  role="progressbar" style="width: ${loPct}%">${loPct}% low</div>
      </div>
      <small class="text-muted">Confidence reflects collection path (module > WMI > fallback).</small>
    </div>
  </div>

  <hr class="my-4"/>

  <h3>IIS Overview</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Site</th><th>State</th><th>App Pool</th><th>Bindings</th><th>Path</th></tr></thead>
    <tbody>
      $(($iisSitesRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.State)</td><td>$($_.AppPool)</td><td class='truncate' title='$($_.Bindings)'>$($_.Bindings)</td><td class='truncate' title='$($_.PhysicalPath)'>$($_.PhysicalPath)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Hyper-V Overview</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Host</th><th>VM</th><th>State</th><th>Memory</th><th>CPU %</th><th>Uptime</th><th>Gen</th></tr></thead>
    <tbody>
      $(($hvVmRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.State)</td><td>$($_.Memory)</td><td>$($_.CPU)</td><td>$($_.Uptime)</td><td>$($_.Gen)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Network – Adapters & IPs</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Interface</th><th>MAC</th><th>Status</th><th>Speed</th><th>IPv4</th><th>IPv6</th><th>Gateway</th><th>DNS</th><th>DHCP</th></tr></thead>
    <tbody>
      $(($netRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td class='truncate' title='$($_.Interface)'>$($_.Interface)</td><td>$($_.MAC)</td><td>$($_.Status)</td><td>$($_.Speed)</td><td class='truncate' title='$($_.IPv4)'>$($_.IPv4)</td><td class='truncate' title='$($_.IPv6)'>$($_.IPv6)</td><td>$($_.Gateway)</td><td class='truncate' title='$($_.DNS)'>$($_.DNS)</td><td>$($_.DHCP)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Storage – Volumes</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Drive</th><th>Label</th><th>FS</th><th>Size (GB)</th><th>Free (GB)</th><th>Health</th><th>Path</th></tr></thead>
    <tbody>
      $(($volRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Drive)</td><td>$($_.Label)</td><td>$($_.FS)</td><td>$($_.SizeGB)</td><td>$($_.FreeGB)</td><td>$($_.Health)</td><td class='truncate' title='$($_.Path)'>$($_.Path)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Local Accounts – Users</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>User</th><th>Enabled</th><th>Last Logon</th><th>Pwd Expires</th><th>Pwd Required</th><th>SID</th></tr></thead>
    <tbody>
      $(($userRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.Enabled)</td><td>$($_.LastLogon)</td><td>$($_.PwdExpires)</td><td>$($_.PwdRequired)</td><td class='truncate' title='$($_.SID)'>$($_.SID)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Local Accounts – Groups</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Group</th><th>SID</th></tr></thead>
    <tbody>
      $(($groupRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td class='truncate' title='$($_.SID)'>$($_.SID)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Printers</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Name</th><th>Shared</th><th>Share</th><th>Driver</th><th>Port</th><th>Location</th><th>Status</th></tr></thead>
    <tbody>
      $(($printerRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td class='truncate' title='$($_.Name)'>$($_.Name)</td><td>$($_.Shared)</td><td>$($_.ShareName)</td><td class='truncate' title='$($_.Driver)'>$($_.Driver)</td><td>$($_.Port)</td><td class='truncate' title='$($_.Location)'>$($_.Location)</td><td>$($_.Status)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>
</div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutDir "report_$Timestamp.html"
  $html | Set-Content -Path $htmlPath -Encoding UTF8
  Write-Log Info ("Report written: {0}" -f $htmlPath)

  return @{ Markdown=(Join-Path $OutDir "summary_$Timestamp.md"); Html=$htmlPath; CsvRoot=$csvRoot }
}
