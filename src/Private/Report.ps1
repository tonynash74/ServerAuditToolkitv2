function Write-SATCsv {
  param(
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][array]$Rows
  )
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $path = Join-Path $OutDir "$Name.csv"
    if ($Rows -and $Rows.Count -gt 0) { $Rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $path }
    return $path
  } catch {
    Write-Log Warn "CSV export failed for $Name : $($_.Exception.Message)"
    return $null
  }
}

function New-SATReport {
  [CmdletBinding()]
  param(
    [hashtable]$Data,
    [string]$OutDir,
    [string]$Timestamp
  )

  $csvRoot = Join-Path $OutDir 'csv'
  New-Item -ItemType Directory -Force -Path $csvRoot | Out-Null
  $findings = @()
  $servers  = @($Data['Get-SATSystem'].Keys)
  $maxHtmlRows = 200  # avoid giant pages

  # ---------- IIS ----------
  $iisSitesRows = @()
  $iisPoolsRows = @()
  if ($Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $iis = $Data['Get-SATIIS'][$srv]
      foreach ($s in @($iis.Sites)) {
        $iisSitesRows += [pscustomobject]@{
          Server=$srv; Name=$s.Name; State=$s.State; AppPool=$s.AppPool
          PhysicalPath=$s.PhysicalPath
          Bindings=((@($s.Bindings) | ForEach-Object { "$($_.protocol)|$($_.bindingInformation)" }) -join ';')
        }
      }
      foreach ($p in @($iis.AppPools)) {
        $iisPoolsRows += [pscustomobject]@{
          Server=$srv; Name=$p.Name; State=$p.State
          Runtime=$p.RuntimeVersion; Pipeline=$p.PipelineMode; Identity=$p.IdentityType
        }
      }
    }
  }
  $csvIisSites = if($iisSitesRows){ Write-SATCsv -OutDir $csvRoot -Name 'iis_sites' -Rows $iisSitesRows }
  $csvIisPools = if($iisPoolsRows){ Write-SATCsv -OutDir $csvRoot -Name 'iis_pools' -Rows $iisPoolsRows }
  if ($iisSitesRows.Count -gt 0) { $findings += "IIS migration required on $(@($Data['Get-SATIIS'].Keys).Count) server(s): $($iisSitesRows.Count) site(s)." }

  # ---------- Hyper-V ----------
  $hvVmRows = @()
  if ($Data['Get-SATHyperV']) {
    foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
      foreach ($vm in @($Data['Get-SATHyperV'][$srv].VMs)) {
        $hvVmRows += [pscustomobject]@{
          Server=$srv; Name=$vm.Name; State=$vm.State; Memory=$vm.MemoryAssigned; CPU=$vm.CPUUsage; Uptime=$vm.Uptime; Gen=$vm.Generation
        }
      }
    }
  }
  $csvHyperV = if($hvVmRows){ Write-SATCsv -OutDir $csvRoot -Name 'hyperv_vms' -Rows $hvVmRows }
  if ($hvVmRows.Count -gt 0) { $findings += "Hyper-V migration required on $(@($Data['Get-SATHyperV'].Keys).Count) host(s): $($hvVmRows.Count) VM(s)." }

  # ---------- DNS/DHCP (counts only) ----------
  if ($Data['Get-SATDHCP']) {
    $scopeCount = 0; foreach ($srv in @($Data['Get-SATDHCP'].Keys)) { $scopeCount += @($Data['Get-SATDHCP'][$srv].Scopes).Count }
    if ($scopeCount -gt 0) { $findings += "DHCP migration required: $scopeCount scope(s)." }
  }
  if ($Data['Get-SATDNS']) {
    $zoneCount = 0; foreach ($srv in @($Data['Get-SATDNS'].Keys)) { $zoneCount += @($Data['Get-SATDNS'][$srv].Zones).Count }
    if ($zoneCount -gt 0) { $findings += "DNS migration required: $zoneCount zone(s)." }
  }

  # ---------- SMB ----------
  $smbShareRows = @(); $smbAclRows = @()
  if ($Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $smb = $Data['Get-SATSMB'][$srv]
      foreach ($sh in @($smb.Shares)) {
        $smbShareRows += [pscustomobject]@{
          Server=$srv; Name=$sh.Name; Path=$sh.Path; Desc=$sh.Description; EncryptData=$sh.EncryptData
        }
      }
      foreach ($perm in @($smb.Permissions)) {
        foreach ($ntfs in @($perm.NtfsTop)) {
          $smbAclRows += [pscustomobject]@{
            Server=$srv; Share=$perm.Share; Path=$perm.Path
            Identity=$ntfs.IdentityReference; Rights=$ntfs.FileSystemRights; Type=$ntfs.AccessControlType; Inherited=$ntfs.IsInherited
          }
        }
      }
    }
  }
  $csvSmbShares = if($smbShareRows){ Write-SATCsv -OutDir $csvRoot -Name 'smb_shares' -Rows $smbShareRows }
  $csvSmbAcls   = if($smbAclRows){   Write-SATCsv -OutDir $csvRoot -Name 'smb_ntfs_top' -Rows $smbAclRows }
  if ($smbShareRows.Count -gt 0) { $findings += "File server migration required: $($smbShareRows.Count) share(s) across $(@($Data['Get-SATSMB'].Keys).Count) server(s)." }

  # ---------- Certificates ----------
  $certRows = @()
  if ($Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $allStores = $Data['Get-SATCertificates'][$srv].Stores
      foreach ($storeName in @($allStores.Keys)) {
        foreach ($cert in @($allStores[$storeName])) {
          $certRows += [pscustomobject]@{
            Server=$srv; Store=$storeName; Subject=$cert.Subject; Thumbprint=$cert.Thumbprint
            NotBefore=$cert.NotBefore; NotAfter=$cert.NotAfter; HasPrivateKey=$cert.HasPrivateKey; FriendlyName=$cert.FriendlyName
          }
        }
      }
    }
  }
  $csvCerts = if($certRows){ Write-SATCsv -OutDir $csvRoot -Name 'certificates' -Rows $certRows }
  if ($certRows.Count -gt 0) {
    $expiring = ($certRows | Where-Object { $_.NotAfter -lt (Get-Date).AddDays(120) }).Count
    $findings += "Certificates discovered: $($certRows.Count). Expiring in <120 days: $expiring."
  }

  # ---------- AD DS summary ----------
  $ad = $Data['Get-SATADDS']?['ActiveDirectory']
  if ($ad) {
    $findings += "AD Forest: $($ad.Forest.Name) (Mode: $($ad.Forest.Mode)); Domain: $($ad.Domain.Name) (Mode: $($ad.Domain.Mode)); SYSVOL: $($ad.SysvolReplication)."
    if ($ad.SysvolReplication -eq 'FRS') { $findings += "Action: migrate SYSVOL from FRS to DFSR before domain/OS upgrades." }
  }

  # ---------- NEW: Network Adapters + IPs ----------
  $netRows = @()
  if ($Data['Get-SATNetwork']) {
    foreach ($srv in @($Data['Get-SATNetwork'].Keys)) {
      $n = $Data['Get-SATNetwork'][$srv]
      # Normalize adapters by alias/name for lookup
      $adapters = @{}
      foreach ($a in @($n.Adapters)) { if ($a.Name) { $adapters[$a.Name.ToLower()] = $a } }

      foreach ($cfg in @($n.IPConfig)) {
        $alias = if($cfg.InterfaceAlias){ $cfg.InterfaceAlias } else { $cfg.Description }
        $key   = if($alias){ $alias.ToLower() } else { $null }
        $a     = if($key -and $adapters.ContainsKey($key)){ $adapters[$key] } else { $null }

        # flatten IPs
        $ipv4 = @()
        if ($cfg.IPv4Address) {
          foreach ($i in @($cfg.IPv4Address)) { $ipv4 += ($i.IPAddress ?? $i) }
        } elseif ($cfg.IPv4) { $ipv4 += @($cfg.IPv4) }

        $ipv6 = @()
        if ($cfg.IPv6Address) {
          foreach ($i in @($cfg.IPv6Address)) { $ipv6 += ($i.IPAddress ?? $i) }
        } elseif ($cfg.IPv6) { $ipv6 += @($cfg.IPv6) }

        $gw  = ($cfg.Ipv4DefaultGateway?.NextHop) -join ','
        $dns = @()
        if ($cfg.DNSServer) { foreach ($d in @($cfg.DNSServer)) { $dns += ($d.ServerAddresses ?? $d) } }
        elseif ($cfg.DNS)   { $dns += $cfg.DNS }

        $netRows += [pscustomobject]@{
          Server     = $srv
          Interface  = $alias
          MAC        = ($a?.MacAddress)
          Status     = ($a?.InterfaceOperationalStatus)
          Speed      = ($a?.LinkSpeed)
          IPv4       = ($ipv4 -join ',')
          IPv6       = ($ipv6 -join ',')
          Gateway    = $gw
          DNS        = ($dns -join ',')
          DHCP       = $cfg.DHCP
        }
      }
    }
  }
  $csvNetwork = if($netRows){ Write-SATCsv -OutDir $csvRoot -Name 'network_adapters' -Rows $netRows }

  # ---------- NEW: Storage (Volumes + Disks) ----------
  $volRows = @(); $diskRows=@()
  if ($Data['Get-SATStorage']) {
    foreach ($srv in @($Data['Get-SATStorage'].Keys)) {
      foreach ($v in @($Data['Get-SATStorage'][$srv].Volumes)) {
        $volRows += [pscustomobject]@{
          Server=$srv; Drive=$v.DriveLetter; Label=$v.FileSystemLabel; FS=$v.FileSystem
          SizeGB=[math]::Round(($v.Size/1GB),2); FreeGB=[math]::Round(($v.SizeRemaining/1GB),2)
          Health=$v.HealthStatus; Path=$v.Path
        }
      }
      foreach ($d in @($Data['Get-SATStorage'][$srv].Disks)) {
        $diskRows += [pscustomobject]@{
          Server=$srv; Disk=$d.Number; Model=$d.FriendlyName; Serial=$d.SerialNumber
          Bus=$d.BusType; PartStyle=$d.PartitionStyle; Health=$d.HealthStatus; SizeGB=[math]::Round(($d.Size/1GB),2)
        }
      }
    }
  }
  $csvVolumes = if($volRows){ Write-SATCsv -OutDir $csvRoot -Name 'storage_volumes' -Rows $volRows }
  $csvDisks   = if($diskRows){ Write-SATCsv -OutDir $csvRoot -Name 'storage_disks'   -Rows $diskRows }

  # ---------- NEW: Local Users/Groups ----------
  $userRows=@(); $groupRows=@(); $memberRows=@()
  if ($Data['Get-SATLocalAccounts']) {
    foreach ($srv in @($Data['Get-SATLocalAccounts'].Keys)) {
      foreach ($u in @($Data['Get-SATLocalAccounts'][$srv].Users)) {
        $userRows += [pscustomobject]@{
          Server=$srv; Name=$u.Name; Enabled=$u.Enabled; LastLogon=$u.LastLogon
          PwdExpires=$u.PasswordExpires; PwdRequired=$u.PasswordRequired; SID=$u.SID
        }
      }
      foreach ($g in @($Data['Get-SATLocalAccounts'][$srv].Groups)) {
        $groupRows += [pscustomobject]@{ Server=$srv; Name=$g.Name; SID=$g.SID }
      }
      foreach ($m in @($Data['Get-SATLocalAccounts'][$srv].Members)) {
        $memberRows += [pscustomobject]@{ Server=$srv; Group=$m.Group; Name=$m.Name; Class=$m.ObjectClass; SID=$m.SID }
      }
    }
  }
  $csvUsers   = if($userRows){   Write-SATCsv -OutDir $csvRoot -Name 'local_users'        -Rows $userRows }
  $csvGroups  = if($groupRows){  Write-SATCsv -OutDir $csvRoot -Name 'local_groups'       -Rows $groupRows }
  $csvMembers = if($memberRows){ Write-SATCsv -OutDir $csvRoot -Name 'local_group_members'-Rows $memberRows }

  # ---------- Markdown quick summary ----------
  $summary = @"
# ServerAuditToolkitV2 Migration Readiness

Run: $Timestamp

## High-level findings
$(($findings | ForEach-Object { "* $_" }) -join "`n")

## Inventory footprint
- Servers: $($servers.Count)
- IIS: Sites=$($iisSitesRows.Count); AppPools=$($iisPoolsRows.Count)
- Hyper-V: VMs=$($hvVmRows.Count)
- SMB: Shares=$($smbShareRows.Count)
- Certs: $($certRows.Count)
- Volumes: $($volRows.Count); Disks: $($diskRows.Count)
- Local Users: $($userRows.Count); Groups: $($groupRows.Count)
"@
  $md = Join-Path $OutDir "summary_$Timestamp.md"
  $summary | Set-Content -Path $md -Encoding UTF8

  # Ensure JSON exists for convenience
  $jsonPath = Join-Path $OutDir "data_$Timestamp.json"
  if (-not (Test-Path $jsonPath)) {
  $Data | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $jsonPath
  }

  # ---------- HTML (Bootstrap) ----------
  $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SATv2 Report $Timestamp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
  .table { font-size: 0.9rem; }
  .truncate { max-width: 380px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
</head>
<body class="bg-light">
<div class="container my-4">
  <h1 class="mb-3">ServerAuditToolkitV2 – Migration Readiness</h1>
  <p class="text-muted">Run: $Timestamp</p>

  <div class="alert alert-info">
    <strong>High-level findings</strong>
    <ul>
      $(($findings | ForEach-Object { "<li>$($_)</li>" }) -join "`n")
    </ul>
  </div>

  <div class="row g-3">
    <div class="col-md-4">
      <div class="card shadow-sm">
        <div class="card-body">
          <h5 class="card-title">Inventory footprint</h5>
          <ul class="mb-0">
            <li>Servers: $($servers.Count)</li>
            <li>IIS: $($iisSitesRows.Count) site(s), $($iisPoolsRows.Count) pool(s)</li>
            <li>Hyper-V: $($hvVmRows.Count) VM(s)</li>
            <li>SMB: $($smbShareRows.Count) share(s)</li>
            <li>Volumes/Disks: $($volRows.Count)/$($diskRows.Count)</li>
            <li>Local users/groups: $($userRows.Count)/$($groupRows.Count)</li>
          </ul>
        </div>
      </div>
    </div>

    <div class="col-md-8">
      <div class="card shadow-sm">
        <div class="card-body">
          <h5 class="card-title">Quick links</h5>
          <ul>
            $(if($csvIisSites){ "<li><a href='./csv/iis_sites.csv'>IIS Sites CSV</a></li>" })
            $(if($csvIisPools){ "<li><a href='./csv/iis_pools.csv'>IIS AppPools CSV</a></li>" })
            $(if($csvHyperV){ "<li><a href='./csv/hyperv_vms.csv'>Hyper-V VMs CSV</a></li>" })
            $(if($csvSmbShares){ "<li><a href='./csv/smb_shares.csv'>SMB Shares CSV</a></li>" })
            $(if($csvSmbAcls){ "<li><a href='./csv/smb_ntfs_top.csv'>Top-level NTFS ACL CSV</a></li>" })
            $(if($csvCerts){ "<li><a href='./csv/certificates.csv'>Certificates CSV</a></li>" })
            $(if($csvNetwork){ "<li><a href='./csv/network_adapters.csv'>Network Adapters + IPs CSV</a></li>" })
            $(if($csvVolumes){ "<li><a href='./csv/storage_volumes.csv'>Storage Volumes CSV</a></li>" })
            $(if($csvDisks){ "<li><a href='./csv/storage_disks.csv'>Storage Disks CSV</a></li>" })
            $(if($csvUsers){ "<li><a href='./csv/local_users.csv'>Local Users CSV</a></li>" })
            $(if($csvGroups){ "<li><a href='./csv/local_groups.csv'>Local Groups CSV</a></li>" })
            $(if($csvMembers){ "<li><a href='./csv/local_group_members.csv'>Local Group Members CSV</a></li>" })
            <li><a href='./$(Split-Path $jsonPath -Leaf)'>Raw JSON</a></li>
          </ul>
        </div>
      </div>
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

  <h3 class="mt-4">Storage – Disks</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Disk</th><th>Model</th><th>Serial</th><th>Bus</th><th>PartStyle</th><th>Health</th><th>Size (GB)</th></tr></thead>
    <tbody>
      $(($diskRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Disk)</td><td>$($_.Model)</td><td>$($_.Serial)</td><td>$($_.Bus)</td><td>$($_.PartStyle)</td><td>$($_.Health)</td><td>$($_.SizeGB)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Local Users & Groups</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Name</th><th>Type/Enabled</th><th>Last Logon / SID</th></tr></thead>
    <tbody>
      $(($userRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.Enabled)</td><td title='$($_.SID)'>$($_.LastLogon)</td></tr>"
      }) -join "`n")
      $(($groupRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>Group</td><td title='$($_.SID)'></td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Certificates</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Store</th><th>Subject</th><th>Thumbprint</th><th>Not After</th><th>Private Key</th></tr></thead>
    <tbody>
      $(($certRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Store)</td><td>$($_.Subject)</td><td>$($_.Thumbprint)</td><td>$($_.NotAfter)</td><td>$($_.HasPrivateKey)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <hr class="my-4"/>
  <p class="text-muted">Generated by ServerAuditToolkitV2</p>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
"@

  # Write HTML report
  $htmlPath = Join-Path $OutDir "report_$Timestamp.html"
  $html | Set-Content -Path $htmlPath -Encoding UTF8

  return $htmlPath
}
