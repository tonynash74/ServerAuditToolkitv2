function New-SATDataDiscoveryReport {
  [CmdletBinding()]
  param(
    [hashtable]$Data,
    [string]$OutDir,
    [string]$Timestamp
  )

  try {
    $csvRoot = Join-Path $OutDir 'csv'
    if (-not (Test-Path $csvRoot)) { New-Item -ItemType Directory -Force -Path $csvRoot | Out-Null }

    $rowsShare  = @()
    $rowsFolder = @()
    $rowsTypes  = @()

    if ($Data -and $Data['Get-SATDataDiscovery']) {
      foreach ($srv in @($Data['Get-SATDataDiscovery'].Keys)) {
        $d = $Data['Get-SATDataDiscovery'][$srv]
        if ($d.Shares)  { $rowsShare  += $d.Shares }
        if ($d.Folders) { $rowsFolder += $d.Folders }
        if ($d.FileTypes){$rowsTypes  += $d.FileTypes }
      }
    }

    # CSVs
    $csvShares  = Join-Path $csvRoot 'data_shares.csv'
    $csvFolders = Join-Path $csvRoot 'data_folders.csv'
    $csvTypes   = Join-Path $csvRoot 'data_filetypes.csv'

    if ($rowsShare)  { $rowsShare  | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvShares }
    if ($rowsFolder) { $rowsFolder | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvFolders }
    if ($rowsTypes)  { $rowsTypes  | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvTypes }

    # HTML
    $maxHtmlRows = 300
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SATv2 Data Discovery $Timestamp</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
<style>.table{font-size:.9rem}.truncate{max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}</style>
</head>
<body class="bg-light">
<div class="container my-4">
  <h1 class="mb-3">ServerAuditToolkitV2 – Data Discovery</h1>
  <p class="text-muted">Run: $Timestamp</p>

  <div class="alert alert-secondary">
    <strong>What is this?</strong> This report scans SMB shares on each server and classifies activity levels:
    <span class="badge bg-success">Hot ≤30d</span>,
    <span class="badge bg-warning text-dark">Warm 31–180d</span>,
    <span class="badge bg-info text-dark">Cold 181–365d</span>,
    <span class="badge bg-secondary">Frozen &gt;365d</span>.
    It also highlights likely <em>Profiles</em>, <em>Documents</em>, <em>SoftwareDist</em>, and <em>LOBBinaries</em>.
  </div>

  <h3>Shares overview</h3>
  <p>CSV: <a href="./csv/data_shares.csv">data_shares.csv</a></p>
  <table class="table table-sm table-striped align-middle">
    <thead><tr>
      <th>Server</th><th>Share</th><th>Path</th><th>Category</th><th class="text-end">Files</th><th class="text-end">Size (GB)</th>
      <th class="text-end">Hot%</th><th class="text-end">Warm%</th><th class="text-end">Cold%</th><th class="text-end">Frozen%</th>
      <th>Newest</th><th>Oldest</th><th class="text-end">Binary%</th><th class="text-end">Docs%</th><th>Notes</th>
    </tr></thead>
    <tbody>
      $(($rowsShare | Sort-Object Server, Share | Select-Object -First $maxHtmlRows | ForEach-Object {
        $gb=[math]::Round(($_.TotalBytes/1GB),2)
        "<tr>
          <td>$($_.Server)</td><td>$($_.Share)</td>
          <td class='truncate' title='$($_.Path)'>$($_.Path)</td>
          <td>$($_.Category)</td>
          <td class='text-end'>$($_.TotalFiles)</td><td class='text-end'>$gb</td>
          <td class='text-end'>$($_.HotPct)</td><td class='text-end'>$($_.WarmPct)</td><td class='text-end'>$($_.ColdPct)</td><td class='text-end'>$($_.FrozenPct)</td>
          <td>$($_.Newest)</td><td>$($_.Oldest)</td>
          <td class='text-end'>$($_.BinaryPct)</td><td class='text-end'>$($_.OfficePct)</td>
          <td>$($_.Notes)</td>
        </tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Top folders (by size)</h3>
  <p>CSV: <a href="./csv/data_folders.csv">data_folders.csv</a></p>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Share</th><th>Folder</th><th class="text-end">Files</th><th class="text-end">Size (GB)</th><th class="text-end">Hot%</th><th class="text-end">Warm%</th><th class="text-end">Cold%</th><th class="text-end">Frozen%</th></tr></thead>
    <tbody>
      $(($rowsFolder | Sort-Object Server, Share, @{e='Bytes';d=$true} | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Share)</td><td class='truncate' title='$($_.Folder)'>$($_.Folder)</td><td class='text-end'>$($_.Files)</td><td class='text-end'>$([math]::Round(($_.Bytes/1GB),2))</td><td class='text-end'>$($_.HotPct)</td><td class='text-end'>$($_.WarmPct)</td><td class='text-end'>$($_.ColdPct)</td><td class='text-end'>$($_.FrozenPct)</td></tr>"
      }) -join "`n")
    </tbody>
  </table>

  <h3 class="mt-4">Top filetypes (by size)</h3>
  <p>CSV: <a href="./csv/data_filetypes.csv">data_filetypes.csv</a></p>
  <table class="table table-sm table-striped">
    <thead><tr><th>Server</th><th>Share</th><th>Ext</th><th class="text-end">Files</th><th class="text-end">Size (GB)</th></tr></thead>
    <tbody>
      $(($rowsTypes | Sort-Object Server, Share, @{e='Bytes';d=$true} | Select-Object -First $maxHtmlRows | ForEach-Object {
        "<tr><td>$($_.Server)</td><td>$($_.Share)</td><td>$($_.Ext)</td><td class='text-end'>$($_.Files)</td><td class='text-end'>$([math]::Round(($_.Bytes/1GB),2))</td></tr>"
      }) -join "`n")
    </tbody>
  </table>
</div>
</body>
</html>
"@

    $htmlPath = Join-Path $OutDir ("report_data_{0}.html" -f $Timestamp)
    $html | Set-Content -Path $htmlPath -Encoding UTF8
    Write-Log Info ("Data Discovery report written: {0}" -f $htmlPath)
    return @{ Html=$htmlPath; CsvRoot=$csvRoot }
  } catch {
    Write-Log Warn ("Data Discovery report failed: {0}" -f $_.Exception.Message)
    return $null
  }
}
