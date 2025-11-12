# src/Private/Report.ps1  (PS2-safe)

function Write-SATCsv {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][array]$Rows
  )
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    if ($Rows -and $Rows.Count -gt 0) {
      $path = Join-Path $OutDir ($Name + '.csv')
      $Rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $path
    }
  } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log Warn ("CSV export failed for {0}: {1}" -f $Name, $_.Exception.Message)
    } else {
      Write-Verbose ("CSV export failed for {0}: {1}" -f $Name, $_.Exception.Message)
    }
  }
}

function New-SATReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][hashtable]$Data,
    [Parameter(Mandatory=$false)][array]$Units,
    [Parameter(Mandatory=$false)][array]$Findings,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [Parameter(Mandatory=$true)][string]$Timestamp
  )

  if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
    Write-Log Info ("Report generation started")
  } else {
    Write-Verbose "Report generation started"
  }

  # Paths
  $csvDir = Join-Path $OutDir 'csv'
  if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Force -Path $csvDir | Out-Null }
  $reportPath = Join-Path $OutDir ("report_{0}.html" -f $Timestamp)

  # Helpers
  function _HtmlEnc([string]$s){
    if ($null -eq $s) { return '' }
    $t = $s -replace '&','&amp;'
    $t = $t -replace '<','&lt;'
    $t = $t -replace '>','&gt;'
    return $t
  }
  function _Row($arr){
    $line = "<tr>"
    foreach($v in $arr){ $line += "<td>" + (_HtmlEnc ([string]$v)) + "</td>" }
    $line += "</tr>"
    return $line
  }
  function _Header($arr){
    $line = "<tr>"
    foreach($v in $arr){ $line += "<th>" + (_HtmlEnc ([string]$v)) + "</th>" }
    $line += "</tr>"
    return $line
  }
  function _TableFromRows($title,$headers,$rows,$maxRows){
    $id = (_HtmlEnc ($title -replace '\s','-')).ToLower()
    $html = "<h3 id='$id'>" + (_HtmlEnc $title) + "</h3><div class='table-responsive'>"
    $html += "<table class='table table-sm table-striped table-hover align-middle'><thead>"
    $html += _Header $headers
    $html += "</thead><tbody>"
    $i = 0
    foreach ($r in $rows) {
      if ($i -ge $maxRows) { break }
      $vals = @()
      foreach ($h in $headers) {
        $val = $null
        if ($r -and $r.PSObject -and $r.PSObject.Properties[$h]) { $val = $r.$h }
        $vals += $val
      }
      $html += _Row $vals
      $i++
    }
    $html += "</tbody></table></div>"
    return $html
  }

  $maxHtmlRows = 200

  # ---------- Gather + CSV ----------
  # System
  $sysRows=@()
  if ($Data['Get-SATSystem']) {
    foreach ($srv in @($Data['Get-SATSystem'].Keys)) {
      $d=$Data['Get-SATSystem'][$srv]
      if ($d) {
        $os=$null;$build=$null;$arch=$null;$uptime=$null;$domain=$null
        try { $os=$d.OS } catch {}
        try { $build=$d.Build } catch {}
        try { $arch=$d.Architecture } catch {}
        try { $uptime=$d.Uptime } catch {}
        try { $domain=$d.Domain } catch {}
        $sysRows += New-Object PSObject -Property @{Server=$srv;OS=$os;Build=$build;Arch=$arch;Uptime=$uptime;Domain=$domain}
      }
    }
  }
  if ($sysRows){ Write-SATCsv -OutDir $csvDir -Name 'system' -Rows $sysRows }

  # Network
  $netRows=@()
  if ($Data['Get-SATNetwork']) {
    foreach ($srv in @($Data['Get-SATNetwork'].Keys)) {
      $d=$Data['Get-SATNetwork'][$srv]
      if ($d -and $d.Adapters) {
        foreach ($a in $d.Adapters) {
          $ip=$null;$gw=$null;$dns=$null;$dhcp=$null;$mac=$null;$name=$null
          try { $ip=($a.IPv4 -join ', ') } catch {}
          try { $gw=($a.Gateway -join ', ') } catch {}
          try { $dns=($a.Dns -join ', ') } catch {}
          try { $dhcp=$a.DhcpEnabled } catch {}
          try { $mac=$a.MacAddress } catch {}
          try { $name=$a.Name } catch {}
          $netRows += New-Object PSObject -Property @{Server=$srv;Name=$name;MAC=$mac;IPv4=$ip;Gateway=$gw;DNS=$dns;DHCP=$dhcp}
        }
      }
    }
  }
  if ($netRows){ Write-SATCsv -OutDir $csvDir -Name 'network_adapters' -Rows $netRows }

  # Storage
  $volRows=@();$diskRows=@()
  if ($Data['Get-SATStorage']) {
    foreach ($srv in @($Data['Get-SATStorage'].Keys)) {
      $d=$Data['Get-SATStorage'][$srv]
      if ($d -and $d.Volumes) {
        foreach ($v in $d.Volumes) {
          $volRows += New-Object PSObject -Property @{Server=$srv;Drive=$v.Drive;Label=$v.Label;FS=$v.FileSystem;SizeGB=$v.SizeGB;FreeGB=$v.FreeGB;BitLocker=$v.BitLocker}
        }
      }
      if ($d -and $d.Disks) {
        foreach ($dk in $d.Disks) {
          $diskRows += New-Object PSObject -Property @{Server=$srv;Number=$dk.Number;Model=$dk.Model;SizeGB=$dk.SizeGB;MediaType=$dk.MediaType}
        }
      }
    }
  }
  if ($volRows ){ Write-SATCsv -OutDir $csvDir -Name 'storage_volumes' -Rows $volRows }
  if ($diskRows){ Write-SATCsv -OutDir $csvDir -Name 'storage_disks'   -Rows $diskRows }

  # Local Accounts
  $userRows=@();$groupRows=@();$memberRows=@()
  if ($Data['Get-SATLocalAccounts']) {
    foreach ($srv in @($Data['Get-SATLocalAccounts'].Keys)) {
      $d=$Data['Get-SATLocalAccounts'][$srv]
      if ($d -and $d.Users)  { foreach ($u in $d.Users)  { $userRows  += New-Object PSObject -Property @{Server=$srv;Name=$u.Name;SID=$u.SID;Enabled=$u.Enabled;Description=$u.Description} } }
      if ($d -and $d.Groups) { foreach ($g in $d.Groups) { $groupRows += New-Object PSObject -Property @{Server=$srv;Name=$g.Name;SID=$g.SID;Description=$g.Description} } }
      if ($d -and $d.GroupMembers) {
        foreach ($m in $d.GroupMembers) { $memberRows += New-Object PSObject -Property @{Server=$srv;Group=$m.Group;Member=$m.Member;Type=$m.Type} }
      }
    }
  }
  if ($userRows  ){ Write-SATCsv -OutDir $csvDir -Name 'local_users'         -Rows $userRows }
  if ($groupRows ){ Write-SATCsv -OutDir $csvDir -Name 'local_groups'        -Rows $groupRows }
  if ($memberRows){ Write-SATCsv -OutDir $csvDir -Name 'local_group_members' -Rows $memberRows }

  # IIS
  $iisSites=@();$iisPools=@()
  if ($Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $d=$Data['Get-SATIIS'][$srv]
      if ($d -and $d.Sites) {
        foreach ($s in $d.Sites) {
          $bind=$null; try { $bind = ($s.Bindings | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join '; ' } catch {}
          $iisSites += New-Object PSObject -Property @{Server=$srv;Name=$s.Name;State=$s.State;AppPool=$s.AppPool;Path=$s.PhysicalPath;Bindings=$bind}
        }
      }
      if ($d -and $d.AppPools) {
        foreach ($p in $d.AppPools) {
          $iisPools += New-Object PSObject -Property @{Server=$srv;Name=$p.Name;State=$p.State;Runtime=$p.RuntimeVersion;Pipeline=$p.PipelineMode}
        }
      }
    }
  }
  if ($iisSites){ Write-SATCsv -OutDir $csvDir -Name 'iis_sites' -Rows $iisSites }
  if ($iisPools){ Write-SATCsv -OutDir $csvDir -Name 'iis_pools' -Rows $iisPools }

  # Hyper-V
  $vmRows=@()
  if ($Data['Get-SATHyperV']) {
    foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
      $d=$Data['Get-SATHyperV'][$srv]
      if ($d -and $d.VMs) {
        foreach ($vm in $d.VMs) {
          $vmRows += New-Object PSObject -Property @{Server=$srv;Name=$vm.Name;State=$vm.State;MemoryMB=$vm.MemoryAssigned;Uptime=$vm.Uptime;Generation=$vm.Generation}
        }
      }
    }
  }
  if ($vmRows){ Write-SATCsv -OutDir $csvDir -Name 'hyperv_vms' -Rows $vmRows }

  # SMB
  $shareRows=@()
  if ($Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $d=$Data['Get-SATSMB'][$srv]
      if ($d -and $d.Shares) {
        foreach ($sh in $d.Shares) {
          $shareRows += New-Object PSObject -Property @{Server=$srv;Name=$sh.Name;Path=$sh.Path;Description=$sh.Description;Encrypt=$sh.EncryptData}
        }
      }
    }
  }
  if ($shareRows){ Write-SATCsv -OutDir $csvDir -Name 'smb_shares' -Rows $shareRows }

  # Certificates
  $certRows=@()
  if ($Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $d=$Data['Get-SATCertificates'][$srv]
      if ($d -and $d.Stores) {
        foreach ($store in @($d.Stores.Keys)) {
          foreach ($c in @($d.Stores[$store])) {
            $certRows += New-Object PSObject -Property @{Server=$srv;Store=$store;Thumbprint=$c.Thumbprint;FriendlyName=$c.FriendlyName;Subject=$c.Subject;NotBefore=$c.NotBefore;NotAfter=$c.NotAfter}
          }
        }
      }
    }
  }
  if ($certRows){ Write-SATCsv -OutDir $csvDir -Name 'certificates' -Rows $certRows }

  # Scheduled Tasks
  $taskRows=@()
  if ($Data['Get-SATScheduledTasks']) {
    foreach ($srv in @($Data['Get-SATScheduledTasks'].Keys)) {
      $d=$Data['Get-SATScheduledTasks'][$srv]
      if ($d -and $d.Tasks) {
        foreach ($t in $d.Tasks) {
          $taskRows += New-Object PSObject -Property @{Server=$srv;Path=$t.TaskPath;Name=$t.TaskName;State=$t.State;NextRun=$t.NextRun;Exec=$t.ActionExe}
        }
      }
    }
  }
  if ($taskRows){ Write-SATCsv -OutDir $csvDir -Name 'scheduled_tasks' -Rows $taskRows }

  # Printers
  $prtRows=@();$portRows=@()
  if ($Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      $d=$Data['Get-SATPrinters'][$srv]
      if ($d -and $d.Printers) {
        foreach ($p in $d.Printers) {
          $prtRows += New-Object PSObject -Property @{Server=$srv;Name=$p.Name;Shared=$p.Shared;ShareName=$p.ShareName;Driver=$p.DriverName;Port=$p.PortName;Location=$p.Location;Status=$p.PrinterStatus}
        }
      }
      if ($d -and $d.Ports) {
        foreach ($pp in $d.Ports) {
          $portRows += New-Object PSObject -Property @{Server=$srv;Name=$pp.Name;HostAddress=$pp.HostAddress;PortNumber=$pp.PortNumber;SnmpEnabled=$pp.SnmpEnabled}
        }
      }
    }
  }
  if ($prtRows ){ Write-SATCsv -OutDir $csvDir -Name 'printers'      -Rows $prtRows }
  if ($portRows){ Write-SATCsv -OutDir $csvDir -Name 'printer_ports' -Rows $portRows }

  # Exchange
  $exSvc=@();$exDb=@();$exMeta=@()
  if ($Data['Get-SATExchange']) {
    foreach ($srv in @($Data['Get-SATExchange'].Keys)) {
      $d=$Data['Get-SATExchange'][$srv]
      if ($d) { $exMeta += New-Object PSObject -Property @{Server=$srv;Version=$d.Version;Edition=$d.Edition;Roles=((@($d.Roles) -join ', '))} }
      if ($d -and $d.Services){ foreach ($s in $d.Services) { $exSvc += New-Object PSObject -Property @{Server=$srv;Name=$s.Name;State=$s.State;StartMode=$s.StartMode;PathName=$s.PathName} } }
      if ($d -and $d.Databases){ foreach ($db in $d.Databases) { $exDb += New-Object PSObject -Property @{Server=$srv;Name=$db.Name;Mounted=$db.Mounted;Size=$db.Size;EdbPath=$db.EdbPath;LogPath=$db.LogPath} } }
    }
  }
  if ($exSvc){ Write-SATCsv -OutDir $csvDir -Name 'exchange_services'  -Rows $exSvc }
  if ($exDb ){ Write-SATCsv -OutDir $csvDir -Name 'exchange_databases' -Rows $exDb  }
  if ($exMeta){ Write-SATCsv -OutDir $csvDir -Name 'exchange_server'   -Rows $exMeta }

  # SQL Server
  $sqlInst=@();$sqlSvc=@()
  if ($Data['Get-SATSQLServer']) {
    foreach ($srv in @($Data['Get-SATSQLServer'].Keys)) {
      $d=$Data['Get-SATSQLServer'][$srv]
      if ($d -and $d.Instances){ foreach ($i in $d.Instances) { $sqlInst += New-Object PSObject -Property @{Server=$srv;Instance=$i.Instance;Edition=$i.Edition;Version=$i.Version;PatchLevel=$i.PatchLevel;Build=$i.Build;Clustered=$i.Clustered;DataRoot=$i.DataRoot;LogRoot=$i.LogRoot;SqlServiceState=$i.SqlServiceState;AgentServiceState=$i.AgentServiceState;VersionString=$i.VersionString} } }
      if ($d -and $d.Services ){ foreach ($s in $d.Services)  { $sqlSvc  += New-Object PSObject -Property @{Server=$srv;Name=$s.Name;Display=$s.Display;State=$s.State;StartMode=$s.StartMode;PathName=$s.PathName} } }
    }
  }
  if ($sqlInst){ Write-SATCsv -OutDir $csvDir -Name 'sql_instances' -Rows $sqlInst }
  if ($sqlSvc ){ Write-SATCsv -OutDir $csvDir -Name 'sql_services'  -Rows $sqlSvc  }

  # SBS Extras
  $wsusRow=@();$wsusSvc=@()
  if ($Data['Get-SATWSUS']) {
    foreach ($srv in @($Data['Get-SATWSUS'].Keys)) {
      $d=$Data['Get-SATWSUS'][$srv]
      if ($d){ $wsusRow += New-Object PSObject -Property @{Server=$srv;Version=$d.Version;DBBackend=$d.DBBackend;SQLServer=$d.SQLServer;SQLDB=$d.SQLDB;ContentDir=$d.ContentDir} }
      if ($d -and $d.Services){ foreach ($s in $d.Services){ $wsusSvc += New-Object PSObject -Property @{Server=$srv;Name=$s.Name;Display=$s.Display;State=$s.State;StartMode=$s.StartMode;PathName=$s.PathName} } }
    }
  }
  if ($wsusRow){ Write-SATCsv -OutDir $csvDir -Name 'wsus' -Rows $wsusRow }
  if ($wsusSvc){ Write-SATCsv -OutDir $csvDir -Name 'wsus_services' -Rows $wsusSvc }

  $spDb=@();$spSvc=@();$spSites=@()
  if ($Data['Get-SATSharePoint']) {
    foreach ($srv in @($Data['Get-SATSharePoint'].Keys)) {
      $d=$Data['Get-SATSharePoint'][$srv]
      if ($d -and $d.Databases){ foreach ($x in $d.Databases){ $spDb += New-Object PSObject -Property @{Server=$srv;Name=$x.Name;ServerName=$x.Server;Type=$x.Type;Size=$x.Size} } }
      if ($d -and $d.Services ){ foreach ($x in $d.Services ){ $spSvc += New-Object PSObject -Property @{Server=$srv;Name=$x.Name;Display=$x.Display;State=$x.State;StartMode=$x.StartMode} } }
      if ($d -and $d.Sites    ){ foreach ($x in $d.Sites    ){ $spSites += New-Object PSObject -Property @{Server=$srv;Url=$x.Url;ApplicationPool=$x.ApplicationPool} } }
    }
  }
  if ($spDb){ Write-SATCsv -OutDir $csvDir -Name 'sharepoint_databases' -Rows $spDb }
  if ($spSvc){ Write-SATCsv -OutDir $csvDir -Name 'sharepoint_services'  -Rows $spSvc }
  if ($spSites){ Write-SATCsv -OutDir $csvDir -Name 'sharepoint_sites'   -Rows $spSites }

  $rras=@()
  if ($Data['Get-SATRRAS']) {
    foreach ($srv in @($Data['Get-SATRRAS'].Keys)) {
      $d=$Data['Get-SATRRAS'][$srv]
      if ($d){ $rras += New-Object PSObject -Property @{Server=$srv;ServiceState=$d.ServiceState;Mode=$d.Mode;Ports=$d.Ports;ActiveVPN=$d.ActiveVPN} }
    }
  }
  if ($rras){ Write-SATCsv -OutDir $csvDir -Name 'rras' -Rows $rras }

  $fax=@();$faxDev=@()
  if ($Data['Get-SATFax']) {
    foreach ($srv in @($Data['Get-SATFax'].Keys)) {
      $d=$Data['Get-SATFax'][$srv]
      if ($d){ $fax += New-Object PSObject -Property @{Server=$srv;Service=$d.Service} }
      if ($d -and $d.Devices){ foreach ($x in $d.Devices){ $faxDev += New-Object PSObject -Property @{Server=$srv;Name=$x.Name;Port=$x.Port;Driver=$x.Driver;Shared=$x.Shared} } }
    }
  }
  if ($fax){ Write-SATCsv -OutDir $csvDir -Name 'fax' -Rows $fax }
  if ($faxDev){ Write-SATCsv -OutDir $csvDir -Name 'fax_devices' -Rows $faxDev }

  $pop3=@()
  if ($Data['Get-SATPOP3Connector']) {
    foreach ($srv in @($Data['Get-SATPOP3Connector'].Keys)) {
      $d=$Data['Get-SATPOP3Connector'][$srv]
      if ($d){ $pop3 += New-Object PSObject -Property @{Server=$srv;ServiceState=$d.ServiceState;Schedule=$d.Schedule;Accounts=$d.Accounts} }
    }
  }
  if ($pop3){ Write-SATCsv -OutDir $csvDir -Name 'pop3_connector' -Rows $pop3 }

  $rwa=@();$rwaBind=@();$rwaIssues=@()
  if ($Data['Get-SATRWA']) {
    foreach ($srv in @($Data['Get-SATRWA'].Keys)) {
      $d=$Data['Get-SATRWA'][$srv]
      if ($d){ $rwa += New-Object PSObject -Property @{Server=$srv;SiteName=$d.SiteName;Physical=$d.Physical} }
      if ($d -and $d.Bindings){ foreach ($x in $d.Bindings){ $rwaBind += New-Object PSObject -Property @{Server=$srv;Protocol=$x.Protocol;Binding=$x.Binding;Thumbprint=$x.Thumbprint} } }
      if ($d -and $d.CertIssues){ foreach ($i in $d.CertIssues){ $rwaIssues += New-Object PSObject -Property @{Server=$srv;Issue=$i} } }
    }
  }
  if ($rwa){ Write-SATCsv -OutDir $csvDir -Name 'rwa' -Rows $rwa }
  if ($rwaBind){ Write-SATCsv -OutDir $csvDir -Name 'rwa_bindings' -Rows $rwaBind }
  if ($rwaIssues){ Write-SATCsv -OutDir $csvDir -Name 'rwa_cert_issues' -Rows $rwaIssues }

  $lob=@()
  if ($Data['Get-SATLOBSignatures']) {
    foreach ($srv in @($Data['Get-SATLOBSignatures'].Keys)) {
      $d=$Data['Get-SATLOBSignatures'][$srv]
      if ($d -and $d.Hits){ foreach ($h in $d.Hits){ $lob += New-Object PSObject -Property @{Server=$srv;Key=$h.Key;Pattern=$h.Pattern;Count=$h.Count} } }
    }
  }
  if ($lob){ Write-SATCsv -OutDir $csvDir -Name 'lob_signatures' -Rows $lob }

  # ---------- Quick Links ----------
  $quickLinks=@()
  function _qlAdd([string]$file,[string]$label){
    $p = Join-Path $OutDir $file
    if (Test-Path $p) { $quickLinks += ("<li><a href='./{0}'>{1}</a></li>" -f (_HtmlEnc $file), (_HtmlEnc $label)) }
  }
  if ($sysRows){ _qlAdd 'csv/system.csv' 'System CSV' }
  if ($netRows){ _qlAdd 'csv/network_adapters.csv' 'Network Adapters CSV' }
  if ($volRows){ _qlAdd 'csv/storage_volumes.csv' 'Storage Volumes CSV' }
  if ($diskRows){ _qlAdd 'csv/storage_disks.csv' 'Storage Disks CSV' }
  if ($userRows){ _qlAdd 'csv/local_users.csv' 'Local Users CSV' }
  if ($groupRows){ _qlAdd 'csv/local_groups.csv' 'Local Groups CSV' }
  if ($memberRows){ _qlAdd 'csv/local_group_members.csv' 'Local Group Members CSV' }
  if ($iisSites){ _qlAdd 'csv/iis_sites.csv' 'IIS Sites CSV' }
  if ($iisPools){ _qlAdd 'csv/iis_pools.csv' 'IIS App Pools CSV' }
  if ($vmRows){ _qlAdd 'csv/hyperv_vms.csv' 'Hyper-V VMs CSV' }
  if ($shareRows){ _qlAdd 'csv/smb_shares.csv' 'SMB Shares CSV' }
  if ($certRows){ _qlAdd 'csv/certificates.csv' 'Certificates CSV' }
  if ($taskRows){ _qlAdd 'csv/scheduled_tasks.csv' 'Scheduled Tasks CSV' }
  if ($prtRows){ _qlAdd 'csv/printers.csv' 'Printers CSV' }
  if ($portRows){ _qlAdd 'csv/printer_ports.csv' 'Printer Ports CSV' }
  if ($exSvc){ _qlAdd 'csv/exchange_services.csv' 'Exchange Services CSV' }
  if ($exDb){ _qlAdd 'csv/exchange_databases.csv' 'Exchange Databases CSV' }
  if ($exMeta){ _qlAdd 'csv/exchange_server.csv' 'Exchange Server CSV' }
  if ($sqlInst){ _qlAdd 'csv/sql_instances.csv' 'SQL Instances CSV' }
  if ($sqlSvc){ _qlAdd 'csv/sql_services.csv' 'SQL Services CSV' }
  if ($wsusRow){ _qlAdd 'csv/wsus.csv' 'WSUS CSV' }
  if ($wsusSvc){ _qlAdd 'csv/wsus_services.csv' 'WSUS Services CSV' }
  if ($spDb){ _qlAdd 'csv/sharepoint_databases.csv' 'SharePoint Databases CSV' }
  if ($spSvc){ _qlAdd 'csv/sharepoint_services.csv' 'SharePoint Services CSV' }
  if ($spSites){ _qlAdd 'csv/sharepoint_sites.csv' 'SharePoint Sites CSV' }
  if ($rras){ _qlAdd 'csv/rras.csv' 'RRAS CSV' }
  if ($fax){ _qlAdd 'csv/fax.csv' 'Fax CSV' }
  if ($faxDev){ _qlAdd 'csv/fax_devices.csv' 'Fax Devices CSV' }
  if ($pop3){ _qlAdd 'csv/pop3_connector.csv' 'POP3 Connector CSV' }
  if ($rwa){ _qlAdd 'csv/rwa.csv' 'RWA CSV' }
  if ($rwaBind){ _qlAdd 'csv/rwa_bindings.csv' 'RWA Bindings CSV' }
  if ($rwaIssues){ _qlAdd 'csv/rwa_cert_issues.csv' 'RWA Cert Issues CSV' }
  if ($lob){ _qlAdd 'csv/lob_signatures.csv' 'LOB Signatures CSV' }
  _qlAdd 'csv/data_shares.csv' 'Data Discovery: Shares CSV'
  _qlAdd 'csv/data_folders.csv' 'Data Discovery: Folders CSV'
  _qlAdd 'csv/data_filetypes.csv' 'Data Discovery: Filetypes CSV'
  $ddFile = "report_data_{0}.html" -f $Timestamp
  if (Test-Path (Join-Path $OutDir $ddFile)) { $quickLinks += ("<li><a href='./{0}'>Data Discovery Report</a></li>" -f (_HtmlEnc $ddFile)) }
  $satFile = "sat_{0}.log" -f $Timestamp
  $conFile = "console_{0}.txt" -f $Timestamp
  if (Test-Path (Join-Path $OutDir $satFile)) { $quickLinks += ("<li><a href='./{0}'>Run Log</a></li>" -f (_HtmlEnc $satFile)) }
  if (Test-Path (Join-Path $OutDir $conFile)) { $quickLinks += ("<li><a href='./{0}'>Console Transcript</a></li>" -f (_HtmlEnc $conFile)) }
  $qlHtml = "<ul class='small mb-0'>" + ($quickLinks -join "`n") + "</ul>"

  # ---------- Executive Summary / KPIs ----------
  $serverCount = @($Data.Keys).Count
  $muCount = 0; if ($Units){ $muCount = $Units.Count }
  $fHigh=0;$fMed=0;$fLow=0
  if ($Findings) {
    foreach ($f in $Findings){
      $sev=$null; try{$sev=$f.Severity}catch{}
      if ($sev -eq 'High'){$fHigh++}
      elseif ($sev -eq 'Medium'){$fMed++}
      else {$fLow++}
    }
  }
  $iisCount = 0; if ($iisSites){ $iisCount = $iisSites.Count }
  $vmCount  = 0; if ($vmRows)  { $vmCount  = $vmRows.Count }
  $smbCount = 0; if ($shareRows){$smbCount = $shareRows.Count}
  $sqlCount = 0; if ($sqlInst){ $sqlCount = $sqlInst.Count }
  $exDbCount= 0; if ($exDb){ $exDbCount = $exDb.Count }

  $expSoon = 0
  if ($Findings){
    foreach ($f in $Findings){
      $rid=$null; try{$rid=$f.RuleId}catch{}
      if ($rid -eq 'cert-expiring-90d'){ $expSoon++ }
    }
  }

  # Top findings (sorted)
  $topFindRows = @()
  if ($Findings -and $Findings.Count -gt 0) {
    $sevOrder = @{High=1;Medium=2;Low=3}
    $sorted = $Findings | Sort-Object @{Expression={ if ($sevOrder.ContainsKey($_.Severity)){$sevOrder[$_.Severity]} else {4} }}, Server, Kind
    $i=0
    foreach ($f in $sorted) {
      if ($i -ge 25) { break }
      $topFindRows += New-Object PSObject -Property @{
        Severity=$f.Severity; RuleId=$f.RuleId; Server=$f.Server; Kind=$f.Kind; Name=$f.Name; Message=$f.Message
      }
      $i++
    }
  }

  # TOC
  $toc = @(
    "<li><a href='#executive-summary'>Executive Summary</a></li>",
    "<li><a href='#top-findings'>Top Findings</a></li>",
    "<li><a href='#quick-links'>Quick Links</a></li>",
    "<li class='mt-2'><strong>Platform</strong></li>",
    "<li><a href='#system-per-server'>System</a></li>",
    "<li><a href='#network-adapters'>Network</a></li>",
    "<li><a href='#storage-volumes'>Storage</a></li>",
    "<li><a href='#local-users'>Local Accounts</a></li>",
    "<li class='mt-2'><strong>Workloads</strong></li>",
    "<li><a href='#iis-sites'>IIS</a></li>",
    "<li><a href='#hyper-v-vms'>Hyper-V</a></li>",
    "<li><a href='#smb-shares'>SMB Shares</a></li>",
    "<li><a href='#certificates'>Certificates</a></li>",
    "<li><a href='#scheduled-tasks'>Scheduled Tasks</a></li>",
    "<li><a href='#printers'>Printers</a></li>",
    "<li class='mt-2'><strong>SBS Extras</strong></li>",
    "<li><a href='#exchange-services'>Exchange</a></li>",
    "<li><a href='#sql-instances'>SQL Server</a></li>",
    "<li><a href='#wsus-csv'>WSUS</a></li>",
    "<li><a href='#sharepoint-databases'>SharePoint</a></li>",
    "<li><a href='#rras-csv'>RRAS</a></li>",
    "<li><a href='#rwa-csv'>RWA</a></li>",
    "<li><a href='#lob-signatures-csv'>LOB Signatures</a></li>"
  )
  $tocHtml = "<ul class='nav flex-column small'>" + ($toc -join "`n") + "</ul>"

  # Body
  $body = ""
  $body += "<h2 id='executive-summary'>Executive Summary</h2>"
  $body += "<div class='row g-3'>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>Servers</div><div class='display-6'>$serverCount</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>Migration Units</div><div class='display-6'>$muCount</div></div></div></div>"
  $body += "<div class='col-12 col-lg-6'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small mb-1'>Findings</div><span class='badge bg-danger me-2'>High $fHigh</span><span class='badge bg-warning text-dark me-2'>Medium $fMed</span><span class='badge bg-secondary'>Low $fLow</span></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>IIS Sites</div><div class='h3 mb-0'>$iisCount</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>Hyper-V VMs</div><div class='h3 mb-0'>$vmCount</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>SMB Shares</div><div class='h3 mb-0'>$smbCount</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>Certs &lt; 90d</div><div class='h3 mb-0'>$expSoon</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>SQL Instances</div><div class='h3 mb-0'>$sqlCount</div></div></div></div>"
  $body += "<div class='col-6 col-lg-3'><div class='card shadow-sm'><div class='card-body'><div class='text-muted small'>Exchange DBs</div><div class='h3 mb-0'>$exDbCount</div></div></div></div>"
  $body += "</div>"

  $body += "<h2 id='top-findings' class='mt-4'>Top Findings</h2>"
  if ($topFindRows -and $topFindRows.Count -gt 0) {
    $body += _TableFromRows "Top Findings (max 25)" @('Severity','RuleId','Server','Kind','Name','Message') $topFindRows 25
  } else {
    $body += "<p class='text-muted'>No findings to show.</p>"
  }

  $body += "<h2 id='quick-links' class='mt-4'>Quick Links</h2>"
  $body += $qlHtml

  # Platform tables
  if ($sysRows){ $body += _TableFromRows "System (per server)" @('Server','OS','Build','Arch','Uptime','Domain') $sysRows $maxHtmlRows }
  if ($netRows){ $body += _TableFromRows "Network Adapters" @('Server','Name','MAC','IPv4','Gateway','DNS','DHCP') $netRows $maxHtmlRows }
  if ($volRows){ $body += _TableFromRows "Storage Volumes" @('Server','Drive','Label','FS','SizeGB','FreeGB','BitLocker') $volRows $maxHtmlRows }
  if ($userRows){ $body += _TableFromRows "Local Users" @('Server','Name','SID','Enabled','Description') $userRows $maxHtmlRows }
  if ($groupRows){ $body += _TableFromRows "Local Groups" @('Server','Name','SID','Description') $groupRows $maxHtmlRows }
  if ($memberRows){ $body += _TableFromRows "Local Group Members" @('Server','Group','Member','Type') $memberRows $maxHtmlRows }

  # Workloads
  if ($iisSites){ $body += _TableFromRows "IIS Sites" @('Server','Name','State','AppPool','Path','Bindings') $iisSites $maxHtmlRows }
  if ($iisPools){ $body += _TableFromRows "IIS App Pools" @('Server','Name','State','Runtime','Pipeline') $iisPools $maxHtmlRows }
  if ($vmRows){ $body += _TableFromRows "Hyper-V VMs" @('Server','Name','State','MemoryMB','Uptime','Generation') $vmRows $maxHtmlRows }
  if ($shareRows){ $body += _TableFromRows "SMB Shares" @('Server','Name','Path','Description','Encrypt') $shareRows $maxHtmlRows }
  if ($certRows){ $body += _TableFromRows "Certificates" @('Server','Store','Thumbprint','FriendlyName','Subject','NotBefore','NotAfter') $certRows $maxHtmlRows }
  if ($taskRows){ $body += _TableFromRows "Scheduled Tasks" @('Server','Path','Name','State','NextRun','Exec') $taskRows $maxHtmlRows }
  if ($prtRows){ $body += _TableFromRows "Printers" @('Server','Name','Shared','ShareName','Driver','Port','Location','Status') $prtRows $maxHtmlRows }
  if ($portRows){ $body += _TableFromRows "Printer Ports" @('Server','Name','HostAddress','PortNumber','SnmpEnabled') $portRows $maxHtmlRows }

  # SBS extras
  if ($exMeta){ $body += _TableFromRows "Exchange Server" @('Server','Version','Edition','Roles') $exMeta $maxHtmlRows }
  if ($exSvc){  $body += _TableFromRows "Exchange Services" @('Server','Name','State','StartMode','PathName') $exSvc $maxHtmlRows }
  if ($exDb){   $body += _TableFromRows "Exchange Databases" @('Server','Name','Mounted','Size','EdbPath','LogPath') $exDb $maxHtmlRows }
  if ($sqlInst){$body += _TableFromRows "SQL Instances" @('Server','Instance','Edition','Version','PatchLevel','Build','Clustered','DataRoot','LogRoot','SqlServiceState','AgentServiceState','VersionString') $sqlInst $maxHtmlRows }
  if ($sqlSvc){ $body += _TableFromRows "SQL Services" @('Server','Name','Display','State','StartMode','PathName') $sqlSvc $maxHtmlRows }
  if ($wsusRow){$body += _TableFromRows "WSUS" @('Server','Version','DBBackend','SQLServer','SQLDB','ContentDir') $wsusRow $maxHtmlRows }
  if ($wsusSvc){$body += _TableFromRows "WSUS Services" @('Server','Name','Display','State','StartMode','PathName') $wsusSvc $maxHtmlRows }
  if ($spDb){   $body += _TableFromRows "SharePoint Databases" @('Server','Name','ServerName','Type','Size') $spDb $maxHtmlRows }
  if ($spSvc){  $body += _TableFromRows "SharePoint Services" @('Server','Name','Display','State','StartMode') $spSvc $maxHtmlRows }
  if ($spSites){$body += _TableFromRows "SharePoint Sites" @('Server','Url','ApplicationPool') $spSites $maxHtmlRows }
  if ($rras){   $body += _TableFromRows "RRAS" @('Server','ServiceState','Mode','Ports','ActiveVPN') $rras $maxHtmlRows }
  if ($rwa){    $body += _TableFromRows "RWA" @('Server','SiteName','Physical') $rwa $maxHtmlRows }
  if ($rwaBind){$body += _TableFromRows "RWA Bindings" @('Server','Protocol','Binding','Thumbprint') $rwaBind $maxHtmlRows }
  if ($rwaIssues){$body += _TableFromRows "RWA Cert Issues" @('Server','Issue') $rwaIssues $maxHtmlRows }
  if ($fax){    $body += _TableFromRows "Fax Service" @('Server','Service') $fax $maxHtmlRows }
  if ($faxDev){ $body += _TableFromRows "Fax Devices" @('Server','Name','Port','Driver','Shared') $faxDev $maxHtmlRows }
  if ($pop3){   $body += _TableFromRows "POP3 Connector" @('Server','ServiceState','Schedule','Accounts') $pop3 $maxHtmlRows }
  if ($lob){    $body += _TableFromRows "LOB Signatures" @('Server','Key','Pattern','Count') $lob $maxHtmlRows }

  # HTML
  $serversStr = _HtmlEnc ((@($Data.Keys) -join ', '))
  $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ServerAuditToolkitV2 Report $Timestamp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
<style>
body{padding:0}
.sidebar{position:sticky; top:1rem}
.section{margin-top:2rem}
.table{font-size:.9rem}
.badge{font-size:.85rem}
.card .display-6{font-size:2.25rem}
</style>
</head>
<body>
<div class="container-fluid">
  <div class="row">
    <nav class="col-lg-3 col-xl-2 d-none d-lg-block bg-light border-end min-vh-100">
      <div class="p-3">
        <h5 class="mb-3">Contents</h5>
        <div class="sidebar">$tocHtml</div>
      </div>
    </nav>
    <main class="col-12 col-lg-9 col-xl-10 p-4">
      <h1 class="mb-1">ServerAuditToolkitV2</h1>
      <p class="text-muted mb-4">Generated: $Timestamp &middot; Servers: $serversStr</p>
      $body
      <hr class="mt-5">
      <p class="text-muted small">Report generated by ServerAuditToolkitV2. CSV exports and raw logs are available in the output folder.</p>
    </main>
  </div>
</div>
</body>
</html>
"@

  try {
    Set-Content -Encoding UTF8 -Path $reportPath -Value $html
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log Info ("Report written: {0}" -f $reportPath)
    } else {
      Write-Verbose ("Report written: {0}" -f $reportPath)
    }
  } catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
      Write-Log Error ("Failed to write report: {0}" -f $_.Exception.Message)
    } else {
      Write-Error ("Failed to write report: {0}" -f $_.Exception.Message)
    }
  }

  return $reportPath
}
