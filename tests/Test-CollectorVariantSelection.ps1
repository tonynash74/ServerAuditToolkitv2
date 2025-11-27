<#
.SYNOPSIS
    Basic variant selection tests for Get-CollectorVariant.
.DESCRIPTION
    Lightweight assertions without external test frameworks.
    Verifies fallback and optimized selection for collectors with variants.
.NOTES
    Run: pwsh -File .\tests\Test-CollectorVariantSelection.ps1
#>

function Assert-Equal {
    param(
        [Parameter(Mandatory=$true)]$Actual,
        [Parameter(Mandatory=$true)]$Expected,
        [string]$Message = ''
    )
    if ($Actual -ne $Expected) {
        Write-Host "[FAIL] $Message Expected='$Expected' Actual='$Actual'" -ForegroundColor Red
        $script:Failures++
    } else {
        Write-Host "[PASS] $Message => '$Actual'" -ForegroundColor Green
    }
}

$script:Failures = 0

# Mock collector objects emulating metadata structure
$collectorIIS = [pscustomobject]@{
    name        = 'Get-IISInfo'
    displayName = 'IIS Info'
    filename    = 'Get-IISInfo.ps1'
    variants    = @{ '2.0'='Get-IISInfo.ps1'; '5.1'='Get-IISInfo-PS5.ps1' }
    psVersions  = @('2.0','5.1')
    dependencies = @()
}

$collectorServices = [pscustomobject]@{
    name        = 'Get-Services'
    displayName = 'Services'
    filename    = 'Get-Services.ps1'
    variants    = @{ '2.0'='Get-Services.ps1'; '5.1'='Get-Services-PS5.ps1' }
    psVersions  = @('2.0','5.1')
    dependencies = @()
}

$collectorServerInfo = [pscustomobject]@{
    name        = 'Get-ServerInfo'
    displayName = 'Server Info'
    filename    = 'Get-ServerInfo-PS5.ps1'
    variants    = @{ '5.1'='Get-ServerInfo-PS5.ps1' }
    psVersions  = @('5.1')
    dependencies = @()
}

$collectorSQL = [pscustomobject]@{
    name        = 'Get-SQLServerInfo'
    displayName = 'SQL Server Info'
    filename    = 'Get-SQLServerInfo.ps1'
    variants    = @{ '2.0'='Get-SQLServerInfo.ps1'; '5.1'='Get-SQLServerInfo-PS5.ps1' }
    psVersions  = @('2.0','5.1')
    dependencies = @()
}

# Load collector helper module if functions not already available
if (-not (Get-Command Get-CollectorVariant -ErrorAction SilentlyContinue)) {
    $collectorModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Collectors\CollectorSupport.psm1'
    Import-Module -Name $collectorModulePath -Force -ErrorAction Stop
}

Write-Host "\n=== Variant Selection Tests ===" -ForegroundColor Cyan

# Optimized selection on 5.1
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorIIS -PSVersion '5.1') -Expected 'Get-IISInfo-PS5.ps1' -Message 'IIS PS5 optimized'
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorServices -PSVersion '5.1') -Expected 'Get-Services-PS5.ps1' -Message 'Services PS5 optimized'
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorSQL -PSVersion '5.1') -Expected 'Get-SQLServerInfo-PS5.ps1' -Message 'SQL PS5 optimized'

# Baseline selection on 2.0
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorIIS -PSVersion '2.0') -Expected 'Get-IISInfo.ps1' -Message 'IIS PS2 baseline'
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorServices -PSVersion '2.0') -Expected 'Get-Services.ps1' -Message 'Services PS2 baseline'
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorSQL -PSVersion '2.0') -Expected 'Get-SQLServerInfo.ps1' -Message 'SQL PS2 baseline'

# Fallback when only higher variant exists
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorServerInfo -PSVersion '2.0') -Expected 'Get-ServerInfo-PS5.ps1' -Message 'ServerInfo fallback to PS5 variant when PS2 requested'
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorServerInfo -PSVersion '7.0') -Expected 'Get-ServerInfo-PS5.ps1' -Message 'ServerInfo fallback to PS5 variant when PS7 requested'

# Higher version request (7.0) should fallback to 5.1 variant for collectors without 7.0
Assert-Equal -Actual (Get-CollectorVariant -Collector $collectorIIS -PSVersion '7.0') -Expected 'Get-IISInfo-PS5.ps1' -Message 'IIS PS7 fallback'

Write-Host "\nFailures: $script:Failures" -ForegroundColor Yellow
if ($script:Failures -gt 0) { exit 1 } else { Write-Host "All variant tests passed." -ForegroundColor Green }
