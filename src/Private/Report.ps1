function Write-SATCsv {
  param([Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][array]$Rows)
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

  # Counts & exports
  $servers = @($Data['Get-SATSystem'].Keys)

  # IIS exports
  $iisSitesRows = @()
  $iisPoolsRows = @()
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
  $csvIisSites = Write-SATCsv -OutDir $csvRoot -Name 'iis_sites' -Rows $iisSitesRows
  $csvIisPools = Write-SATCsv -OutDir $csvRoot -Name 'iis_pools' -Rows $iisPoolsRows

  if ($iisSitesRows.Count -gt 0) { $findings += "IIS migration required on $(@($Data['Get-SATIIS'].Keys).Count) server(s): $($iisSitesRows.Count) site(s) discovered." }

  # Hyper-V exports
  $hvVmRows = @()
  foreach ($srv in @($Data['Get-SATHyperV'].Keys)) {
    foreach ($vm in @($Data['Get-SATHyperV'][$srv].VMs)) {
      $hvVmRows += [pscustomobject]@{
        Server=$srv; Name=$vm.Name; State=$vm.State; Memory=$vm.MemoryAssigned; CPU=$vm.CPUUsage; Uptime=$vm.Uptime; Gen=$vm.Generation
      }
    }
  }
  $csvHyperV = Write-SATCsv -OutDir $csvRoot -Name 'hyperv_vms' -Rows $hvVmRows
  if ($hvVmRows.Count -gt 0) { $findings += "Hyper-V migration required on $(@($Data['Get-SATHyperV'].Keys).Count) host(s): $($hvVmRows.Count) VM(s) discovered." }

  # DHCP/DNS checks (existing data)
  if ($Data['Get-SATDHCP']) {
    $scopeCount = 0
    foreach ($srv in @($Data['Get-SATDHCP'].Keys)) { $scopeCount += @($Data['Get-SATDHCP'][$srv].Scopes).Count }
    if ($scopeCount -gt 0) { $findings += "DHCP migration required: $scopeCount scope(s)." }
  }
  if ($Data['Get-SATDNS']) {
    $zoneCount = 0
    foreach ($srv in @($Data['Get-SATDNS'].Keys)) { $zoneCount += @($Data['Get-SATDNS'][$srv].Zones).Count }
    if ($zoneCount -gt 0) { $findings += "DNS migration required: $zoneCount zone(s)." }
  }

  # Markdown (still provide a quick text summary)
  $summary = @"
# ServerAuditToolkitV2 Migration Readiness

Run: $Timestamp

## High-level findings
$(($findings | ForEach-Object { "* $_" }) -join "`n")

## Inventory footprint
- Servers: $($servers.Count)
- IIS: Sites=$($iisSitesRows.Count); AppPools=$($iisPoolsRows.Count)
- Hyper-V: VMs=$($hvVmRows.Count)
- DHCP/DNS: see HTML & CSV exports
"@
  $md = Join-Path $OutDir "summary_$Timestamp.md"
  $summary | Set-Content -Path $md -Encoding UTF8

  # Build Bootstrap HTML
  $jsonPath = Join-Path $OutDir "data_$Timestamp.json"
  if (-not (Test-Path $jsonPath)) {
    # If caller didn't save JSON before, do it now for convenience
    $Data | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $jsonPath
  }

  $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SATv2 Report $Timestamp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
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
            <li><a href='./$(Split-Path $jsonPath -Leaf)'>Raw JSON</a></li>
          </ul>
        </div>
      </div>
    </div>
  </div>

  <hr class="my-4"/>

  <h3>IIS Overview</h3>
  <p class="text-muted">Shows discovered sites and app pools across servers.</p>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Site</th><th>State</th><th>App Pool</th><th>Bindings</th><th>Path</th></tr></thead>
    <tbody>
      $(($iisSitesRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.State)</td><td>$($_.AppPool)</td><td>$($_.Bindings)</td><td>$($_.PhysicalPath)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Hyper-V Overview</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Host</th><th>VM</th><th>State</th><th>Memory</th><th>CPU %</th><th>Uptime</th><th>Gen</th></tr></thead>
    <tbody>
      $(($hvVmRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Name)</td><td>$($_.State)</td><td>$($_.Memory)</td><td>$($_.CPU)</td><td>$($_.Uptime)</td><td>$($_.Gen)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <p class="text-muted">Tip: Use the CSVs for deeper filtering and your migration playbooks.</p>
</div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutDir "report_$Timestamp.html"
  $html | Set-Content -Path $htmlPath -Encoding UTF8

  Write-Log Info "Report written: $htmlPath"
  return @{ Markdown=$md; Html=$htmlPath; CsvRoot=$csvRoot }
}
