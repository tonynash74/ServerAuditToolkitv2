# CollectorSupport.psm1
# Provides an importable module wrapper for collector helper functions.

$moduleDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$metadataScript = Join-Path -Path $moduleDir -ChildPath 'Get-CollectorMetadata.ps1'

if (-not (Test-Path -LiteralPath $metadataScript)) {
    throw "Collector metadata helpers not found at $metadataScript"
}

. $metadataScript
