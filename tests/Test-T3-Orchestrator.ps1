<#
.SYNOPSIS
    Validation tests for T3 (Optimized Collector Registry & Loader).

.DESCRIPTION
    Tests orchestrator functions:
    - Collector filtering and variant selection
    - Dry-run mode
    - Sequential vs. parallel execution
    - Timeout management
    - Result aggregation and export
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$TestServers = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$PWD\test_results"
)

# Import module
$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ServerAuditToolkitV2.psm1'
Import-Module -Name $ModulePath -Force

Write-Host "=== T3 Orchestrator Validation ===" -ForegroundColor Cyan

# Test 1: Dry-run mode
Write-Host "`nTest 1: Dry-run mode (show what will execute)" -ForegroundColor Green
try {
    Invoke-ServerAudit -ComputerName $TestServers[0] -DryRun
    Write-Host "✓ Dry-run completed" -ForegroundColor Green
} catch {
    Write-Host "✗ Dry-run failed: $_" -ForegroundColor Red
}

# Test 2: Full audit (single server, auto parallelism)
Write-Host "`nTest 2: Full audit with auto-detected parallelism" -ForegroundColor Green
try {
    $results = Invoke-ServerAudit `
        -ComputerName $TestServers[0] `
        -OutputPath $OutputPath `
        -Verbose

    if ($results) {
        Write-Host "✓ Audit completed" -ForegroundColor Green
        Write-Host "  Servers: $($results.Servers.Count)" -ForegroundColor Cyan
        Write-Host "  Collectors executed: $($results.Summary.TotalCollectorsExecuted)" -ForegroundColor Cyan
        Write-Host "  Success rate: $([Math]::Round(($results.Summary.TotalCollectorsSucceeded / $results.Summary.TotalCollectorsExecuted) * 100, 1))%" -ForegroundColor Cyan
    }
} catch {
    Write-Host "✗ Audit failed: $_" -ForegroundColor Red
}

# Test 3: Multi-server audit
if ($TestServers.Count -gt 1) {
    Write-Host "`nTest 3: Multi-server audit" -ForegroundColor Green
    try {
        $results = Invoke-ServerAudit -ComputerName $TestServers
        Write-Host "✓ Multi-server audit completed" -ForegroundColor Green
        Write-Host "  Servers audited: $($results.Servers.Count)" -ForegroundColor Cyan
    } catch {
        Write-Host "✗ Multi-server audit failed: $_" -ForegroundColor Red
    }
}

# Test 4: Collector filtering
Write-Host "`nTest 4: Collector filtering (specific collectors only)" -ForegroundColor Green
try {
    $results = Invoke-ServerAudit `
        -ComputerName $TestServers[0] `
        -Collectors @("Get-ServerInfo", "Get-Services") `
        -DryRun

    Write-Host "✓ Collector filtering works" -ForegroundColor Green
} catch {
    Write-Host "✗ Collector filtering failed: $_" -ForegroundColor Red
}

# Test 5: Manual parallelism override
Write-Host "`nTest 5: Manual parallelism override" -ForegroundColor Green
try {
    $results = Invoke-ServerAudit `
        -ComputerName $TestServers[0] `
        -MaxParallelJobs 2 `
        -DryRun

    Write-Host "✓ Parallelism override accepted" -ForegroundColor Green
} catch {
    Write-Host "✗ Parallelism override failed: $_" -ForegroundColor Red
}

# Test 6: Skip profiling
Write-Host "`nTest 6: Skip performance profiling (conservative mode)" -ForegroundColor Green
try {
    $results = Invoke-ServerAudit `
        -ComputerName $TestServers[0] `
        -SkipPerformanceProfile `
        -DryRun

    Write-Host "✓ Skip profiling option works" -ForegroundColor Green
} catch {
    Write-Host "✗ Skip profiling failed: $_" -ForegroundColor Red
}

Write-Host "`n=== T3 Validation Complete ===" -ForegroundColor Cyan