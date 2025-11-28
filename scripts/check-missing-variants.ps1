<#
.SYNOPSIS
    Lists collector variants declared in metadata that are missing on disk.
#>
[CmdletBinding()]
param(
    [string]$CollectorRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\src\Collectors'),
    [switch]$AsJson
)

$collectorRootResolved = Resolve-Path -Path $CollectorRoot -ErrorAction Stop
$metadataPath = Join-Path -Path $collectorRootResolved -ChildPath 'collector-metadata.json'
if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Metadata file not found at $metadataPath"
}

$metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
$missing = @()
foreach ($collector in $metadata.collectors) {
    if ($null -eq $collector.variants) { continue }

    foreach ($variant in $collector.variants.PSObject.Properties) {
        $variantPath = Join-Path -Path $collectorRootResolved -ChildPath $variant.Value
        if (-not (Test-Path -LiteralPath $variantPath)) {
            $missing += [pscustomobject]@{
                Collector = $collector.name
                Version   = $variant.Name
                File      = $variant.Value
            }
        }
    }
}

if ($missing.Count -eq 0) {
    Write-Host 'All collector variants referenced in metadata exist.' -ForegroundColor Green
    return
}

$sortedMissing = $missing | Sort-Object Collector, Version
if ($AsJson) {
    $sortedMissing | ConvertTo-Json -Depth 3
} else {
    $sortedMissing | Format-Table -AutoSize
}
Write-Host "Missing variant count: $($missing.Count)" -ForegroundColor Yellow
