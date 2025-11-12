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
    Write-Log Warn ("CSV export failed for {0}: {1}" -f $Name, $_.Exception.Message)
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

  Write-Log Info ("Report generation started")

  # paths
  $csvDir = Join-Path $OutDir 'csv'
  if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Force -Path $csvDir | Out-Null }
  $reportPath = Join-Path $OutDir ("report_{0}.html" -f $Timestamp)

  # helpers (PS2-safe)
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

  # ---------------- CSV MATERIALIZATION ----------------
  # System (simple)
  $sysRows = @()
  if ($Data['Get-SATSystem']) {
    foreach ($srv in @($Data['Get-SATSystem'].Keys)) {
      $d = $Data['Get-SATSystem'][$srv]
      if ($d) {
        $os = $null; $build=$null; $arch=$null; $uptime=$null; $domain=$null
        try { $os = $d.OS } catch {}
        try { $build = $d.Build } catch {}
        try { $arch = $d.Architecture } catch {}
        try { $uptime = $d.Uptime } catch {}
        try { $domain = $d.Domain } catch {}
        $sysRows += New-Object PSObject -Property @{
          Server=$srv; OS=$os; Build=$build; Arch=$arch; Uptime=$uptime; Domain=$domain
        }
      }
    }
  }
  if ($sysRows){ Write-SATCsv -OutDir $csvDir -Name 'system' -Rows $sysRows }

  # Network adapters (requested)
  $netRows = @()
  if ($Data['Get-SATNetwork']) {
    foreach ($srv in @($Data['Get-SATNetwork'].Keys)) {
      $d = $Data['Get-SATNetwork'][$srv]
      if ($d -and $d.Adapters) {
        foreach ($a in $d.Adapters) {
          $ip = $null; $gw=$null; $dns=$null; $dhcp=$null; $mac=$null; $name=$null
          try { $ip  = ($a.IPv4 -join ', ') } catch {}
          try { $gw  = ($a.Gateway -join ', ') } catch {}
          try { $dns = ($a.Dns -join ', ') } catch {}
          try { $dhcp = $a.DhcpEnabled } catch {}
          try { $mac = $a.MacAddress } catch {}
          try { $name = $a.Name } catch {}
          $netRows += New-Object PSObject -Property @{
            Server=$srv; Name=$name; MAC=$mac; IPv4=$ip; Gateway=$gw; DNS=$dns; DHCP=$dhcp
          }
        }
      }
    }
  }
  if ($netRows){ Write-SATCsv -OutDir $csvDir -Name 'network_adapters' -Rows $netRows }

  # Storage volumes (requested)
  $volRows = @(); $diskRows=@()
  if ($Data['Get-SATStorage']) {
    foreach ($srv in @($Data['Get-SATStorage'].Keys)) {
      $d = $Data['Get-SATStorage'][$srv]
      if ($d -and $d.Volumes) {
        foreach ($v in $d.Volumes) {
          $volRows += New-Object PSObject -Property @{
            Server=$srv; Drive=$v.Drive; Label=$v.Label; FS=$v.FileSystem; SizeGB=$v.SizeGB; FreeGB=$v.FreeGB; BitLocker=$v.BitLocker
          }
        }
      }
      if ($d -and $d.Disks) {
        foreach ($dk in $d.Disks) {
          $diskRows += New-Object PSObject -Property @{
            Server=$srv; Number=$dk.Number; Model=$dk.Model; SizeGB=$dk.SizeGB; MediaType=$dk.MediaType
          }
        }
      }
    }
  }
  if ($volRows ){ Write-SATCsv -OutDir $csvDir -Name 'storage_volumes' -Rows $volRows }
  if ($diskRows){ Write-SATCsv -OutDir $csvDir -Name 'storage_disks'   -Rows $diskRows }

  # Local users/groups/members (requested)
  $userRows=@(); $groupRows=@(); $memberRows=@()
  if ($Data['Get-SATLocalAccounts']) {
    foreach ($srv in @($Data['Get-SATLocalAccounts'].Keys)) {
      $d = $Data['Get-SATLocalAccounts'][$srv]
      if ($d -and $d.Users) {
        foreach ($u in $d.Users) {
          $userRows += New-Object PSObject -Property @{
            Server=$srv; Name=$u.Name; SID=$u.SID; Enabled=$u.Enabled; Description=$u.Description
          }
        }
      }
      if ($d -and $d.Groups) {
        foreach ($g in $d.Groups) {
          $groupRows += New-Object PSObject -Property @{
            Server=$srv; Name=$g.Name; SID=$g.SID; Description=$g.Description
          }
        }
      }
      if ($d -and $d.GroupMembers) {
        foreach ($m in $d.GroupMembers) {
          $memberRows += New-Object PSObject -Property @{
            Server=$srv; Group=$m.Group; Member=$m.Member; Type=$m.Type
          }
        }
      }
    }
  }
  if ($userRows  ){ Write-SATCsv -OutDir $csvDir -Name 'local_users'         -Rows $userRows }
  if ($groupRows ){ Write-SATCsv -OutDir $csvDir -Name 'local_groups'        -Rows $groupRows }
  if ($memberRows){ Write-SATCsv -OutDir $csvDir -Name 'local_group_members' -Rows $memberRows }

  # IIS
  $iisSites=@(); $iisPools=@()
  if ($Data['Get-SATIIS']) {
    foreach ($srv in @($Data['Get-SATIIS'].Keys)) {
      $d = $Data['Get-SATIIS'][$srv]
      if ($d -and $d.Sites) {
        foreach ($s in $d.Sites) {
          $bind = $null; try { $bind = ($s.Bindings | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join '; ' } catch {}
          $iisSites += New-Object PSObject -Property @{
            Server=$srv; Name=$s.Name; State=$s.State; AppPool=$s.AppPool; Path=$s.PhysicalPath; Bindings=$bind
          }
        }
      }
      if ($d -and $d.AppPools) {
        foreach ($p in $d.AppPools) {
          $iisPools += New-Object PSObject -Property @{
            Server=$srv; Name=$p.Name; State=$p.State; Runtime=$p.RuntimeVersion; Pipeline=$p.PipelineMode
          }
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
      $d = $Data['Get-SATHyperV'][$srv]
      if ($d -and $d.VMs) {
        foreach ($vm in $d.VMs) {
          $vmRows += New-Object PSObject -Property @{
            Server=$srv; Name=$vm.Name; State=$vm.State; MemoryMB=$vm.MemoryAssigned; Uptime=$vm.Uptime; Generation=$vm.Generation
          }
        }
      }
    }
  }
  if ($vmRows){ Write-SATCsv -OutDir $csvDir -Name 'hyperv_vms' -Rows $vmRows }

  # SMB
  $shareRows=@()
  if ($Data['Get-SATSMB']) {
    foreach ($srv in @($Data['Get-SATSMB'].Keys)) {
      $d = $Data['Get-SATSMB'][$srv]
      if ($d -and $d.Shares) {
        foreach ($sh in $d.Shares) {
          $shareRows += New-Object PSObject -Property @{
            Server=$srv; Name=$sh.Name; Path=$sh.Path; Description=$sh.Description; Encrypt=$sh.EncryptData
          }
        }
      }
    }
  }
  if ($shareRows){ Write-SATCsv -OutDir $csvDir -Name 'smb_shares' -Rows $shareRows }

  # Certificates
  $certRows=@()
  if ($Data['Get-SATCertificates']) {
    foreach ($srv in @($Data['Get-SATCertificates'].Keys)) {
      $d = $Data['Get-SATCertificates'][$srv]
      if ($d -and $d.Stores) {
        foreach ($store in @($d.Stores.Keys)) {
          foreach ($c in @($d.Stores[$store])) {
            $certRows += New-Object PSObject -Property @{
              Server=$srv; Store=$store; Thumbprint=$c.Thumbprint; FriendlyName=$c.FriendlyName; Subject=$c.Subject; NotBefore=$c.NotBefore; NotAfter=$c.NotAfter
            }
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
      $d = $Data['Get-SATScheduledTasks'][$srv]
      if ($d -and $d.Tasks) {
        foreach ($t in $d.Tasks) {
          $taskRows += New-Object PSObject -Property @{
            Server=$srv; Path=$t.TaskPath; Name=$t.TaskName; State=$t.State; NextRun=$t.NextRun; Exec=$t.ActionExe
          }
        }
      }
    }
  }
  if ($taskRows){ Write-SATCsv -OutDir $csvDir -Name 'scheduled_tasks' -Rows $taskRows }

  # Printers
  $prtRows=@(); $portRows=@()
  if ($Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      $d = $Data['Get-SATPrinters'][$srv]
      if ($d -and $d.Printers) {
        foreach ($p in $d.Printers) {
          $prtRows += New-Object PSObject -Property @{
            Server=$srv; Name=$p.Name; Shared=$p.Shared; ShareName=$p.ShareName; Driver=$p.DriverName; Port=$p.PortName; Location=$p.Location; Status=$p.PrinterStatus
          }
        }
      }
      if ($d -and $d.Ports) {
        foreach ($pp in $d.Ports) {
          $portRows += New-Object PSObject -Property @{
            Server=$srv; Name=$pp.Name; HostAddress=$pp.HostAddress; PortNumber=$pp.PortNumber; SnmpEnabled=$pp.SnmpEnabled
          }
        }
      }
    }
  }
  if ($prtRows ){ Write-SATCsv -OutDir $csvDir -Name 'printers'      -Rows $prtRows }
  if ($portRows){ Write-SATCsv -OutDir $csvDir -Name 'printer_ports' -Rows $portRows }

  # Exchange (new)
  $exSvc=@(); $exDb=@()
  if ($Data['Get-SATExchange']) {
    foreach ($srv in @($Data['Get-SATExchange'].Keys)) {
      $d = $Data['Get-SATExchange'][$srv]
      if ($d -and $d.Services) {
        foreach ($s in $d.Services) {
          $exSvc += New-Object PSObject -Property @{
            Server=$srv; Name=$s.Name; State=$s.State; StartMode=$s.StartMode; PathName=$s.PathName
          }
        }
      }
      if ($d -and $d.Databases) {
        foreach ($db in $d.Databases) {
          $exDb += New-Object PSObject -Property @{
            Server=$srv; Name=$db.Name; Mounted=$db.Mounted; Size=$db.Size; EdbPath=$db.EdbPath; LogPath=$db.LogPath
          }
        }
      }
    }
  }
  if ($exSvc){ Write-SATCsv -OutDir $csvDir -Name 'exchange_services'  -Rows $exSvc }
  if ($exDb ){ Write-SATCsv -OutDir $csvDir -Name 'exchange_databases' -Rows $exDb  }

  # SQL Server (new)
  $sqlInst=@(); $sqlSvc=@()
  if ($Data['Get-SATSQLServer']) {
    foreach ($srv in @($Data['Get-SATSQLServer'].Keys)) {
      $d = $Data['Get-SATSQLServer'][$srv]
      if ($d -and $d.Instances) {
        foreach ($i in $d.Instances) {
          $sqlInst += New-Object PSObject -Property @{
            Server=$srv; Instance=$i.Instance; Edition=$i.Edition; Version=$i.Version; PatchLevel=$i.PatchLevel; Build=$i.Build; Clustered=$i.Clustered; DataRoot=$i.DataRoot; LogRoot=$i.LogRoot; SqlServiceState=$i.SqlServiceState; AgentServiceState=$i.AgentServiceState; VersionString=$i.VersionString
          }
        }
      }
      if ($d -and $d.Services) {
