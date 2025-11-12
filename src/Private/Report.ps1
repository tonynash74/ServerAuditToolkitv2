function Write-SATCsv {
  param([Parameter(Mandatory=$true)][string]$OutDir,[Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][array]$Rows)
  try {
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $path = Join-Path $OutDir "$Name.csv"
    if ($Rows -and $Rows.Count -gt 0) { $Rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $path }
    return $path
  } catch { Write-Log Warn "CSV export failed for $Name : $($_.Exception.Message)"; return $null }
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

  $csvRoot = Join-Path $OutDir 'csv'; New-Item -ItemType Directory -Force -Path $csvRoot | Out-Null
  $findingsMsgs = @()  # summary bullets
  $servers = @($Data['Get-SATSystem'].Keys)
  $maxHtmlRows = 200

  # ----- Existing exports (IIS/Hyper-V/SMB/Certificates/Network/Storage/Local Accounts) -----
  # (Assume you already had the prior version with CSVs; we only add Printers here.)

  # ------ Printers CSV ------
  $printerRows=@(); $portRows=@()
  if ($Data['Get-SATPrinters']) {
    foreach ($srv in @($Data['Get-SATPrinters'].Keys)) {
      foreach ($p in @($Data['Get-SATPrinters'][$srv].Printers)) {
        $printerRows += [pscustomobject]@{
          Server=$srv; Name=$p.Name; Shared=$p.Shared; ShareName=$p.ShareName
          Driver=$p.DriverName; Port=$p.PortName; Published=$p.Published; Location=$p.Location; Comment=$p.Comment; Status=$p.PrinterStatus
        }
      }
      foreach ($pt in @($Data['Get-SATPrinters'][$srv].Ports)) {
        $portRows += [pscustomobject]@{
          Server=$srv; Name=$pt.Name
          HostAddress=($pt.PrinterHostAddress ?? $pt.HostAddress)
          PortNumber=$pt.PortNumber; SnmpEnabled=($pt.SnmpEnabled ?? $pt.SNMPEnabled)
        }
      }
    }
  }
  $csvPrinters = if($printerRows){ Write-SATCsv -OutDir $csvRoot -Name 'printers' -Rows $printerRows }
  $csvPorts    = if($portRows){    Write-SATCsv -OutDir $csvRoot -Name 'printer_ports' -Rows $portRows }
  if ($printerRows.Count -gt 0) { $findingsMsgs += "Print server migration required: $($printerRows.Count) queue(s) across $(@($Data['Get-SATPrinters'].Keys).Count) server(s)." }

  # ----- Migration Units (from orchestrator) -----
  $units = if($PSBoundParameters.ContainsKey('Units')){ $Units } else { @() }
  $findings = if($PSBoundParameters.ContainsKey('Findings')){ $Findings } else { @() }

  $csvUnits = if($units){ Write-SATCsv -OutDir $csvRoot -Name 'migration_units' -Rows ($units | Select Id,Kind,Server,Name,Summary,Confidence) }
  $csvFinds = if($findings){ Write-SATCsv -OutDir $csvRoot -Name 'readiness_findings' -Rows ($findings | Select Severity,RuleId,Server,Kind,Name,Message,UnitId) }

  # Confidence buckets
  $hi = @($units | Where-Object { $_.Confidence -ge 0.9 }).Count
  $md = @($units | Where-Object { $_.Confidence -ge 0.7 -and $_.Confidence -lt 0.9 }).Count
  $lo = @($units | Where-Object { $_.Confidence -lt 0.7 }).Count
  $totalUnits = [math]::Max(1, $units.Count)
  $hiPct = [math]::Round(($hi*100.0)/$totalUnits,1)
  $mdPct = [math]::Round(($md*100.0)/$totalUnits,1)
  $loPct = [math]::Round(($lo*100.0)/$totalUnits,1)

  # ---- Minimal Markdown summary (still handy) ----
  $summary = @"
# ServerAuditToolkitV2 Migration Readiness
Run: $Timestamp

## High-level findings
$(($findingsMsgs | ForEach-Object { "* $_" }) -join "`n")

## Inventory footprint
- Servers: $($servers.Count)
- Printers: $($printerRows.Count)
- Migration Units: $($units.Count) (Confidence: ${hiPct}% high, ${mdPct}% medium, ${loPct}% low)
"@
  $md = Join-Path $OutDir "summary_$Timestamp.md"
  $summary | Set-Content -Path $md -Encoding UTF8

  # Ensure JSON exists for convenience
  $jsonPath = Join-Path $OutDir "data_$Timestamp.json"
  if (-not (Test-Path $jsonPath)) { $Data | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $jsonPath }

  # ---- HTML report ----
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
  <h1 class="mb-3">ServerAuditToolkitV2 â€“ Migration Readiness</h1>
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
          <li>Migration Units: $($units.Count)</li>
        </ul>
      </div></div>
    </div>
    <div class="col-md-7">
      <div class="card shadow-sm"><div class="card-body">
        <h5 class="card-title">Quick links</h5>
        <ul>
          $(if($csvUnits){ "<li><a href='./csv/migration_units.csv'>Migration Units CSV</a></li>" })
          $(if($csvFinds){ "<li><a href='./csv/readiness_findings.csv'>Readiness Findings CSV</a></li>" })
          $(if($csvPrinters){ "<li><a href='./csv/printers.csv'>Printers CSV</a></li>" })
          $(if($csvPorts){ "<li><a href='./csv/printer_ports.csv'>Printer Ports CSV</a></li>" })
          <li><a href='./$(Split-Path $jsonPath -Leaf)'>Raw JSON</a></li>
        </ul>
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

  <h3>Top readiness findings</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Severity</th><th>Rule</th><th>Server</th><th>Kind</th><th>Name</th><th>Message</th></tr></thead>
    <tbody>
      $(($findings | Select-Object -First 200 | ForEach-Object {
        "<tr><td>$($_.Severity)</td><td>$($_.RuleId)</td><td>$($_.Server)</td><td>$($_.Kind)</td><td class='truncate' title='$($_.Name)'>$($_.Name)</td><td class='truncate' title='$($_.Message)'>$($_.Message)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Printers (sample)</h3>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Name</th><th>Shared</th><th>Share</th><th>Driver</th><th>Port</th><th>Location</th><th>Status</th></tr></thead>
    <tbody>
      $(($printerRows | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td class='truncate' title='$($_.Name)'>$($_.Name)</td><td>$($_.Shared)</td><td>$($_.ShareName)</td><td class='truncate' title='$($_.Driver)'>$($_.Driver)</td><td>$($_.Port)</td><td class='truncate' title='$($_.Location)'>$($_.Location)</td><td>$($_.Status)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <p class="text-muted">Tip: use CSVs for full lists and filtering.</p>
</div>
</body>
</html>
"@
  $htmlPath = Join-Path $OutDir "report_$Timestamp.html"
  $html | Set-Content -Path $htmlPath -Encoding UTF8
  Write-Log Info "Report written: $htmlPath"

  return @{ Markdown=$md; Html=$htmlPath; CsvRoot=$csvRoot }
}

