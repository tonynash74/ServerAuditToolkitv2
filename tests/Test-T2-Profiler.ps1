<#
.SYNOPSIS
    Validation tests for T2 (Server Performance Profiler).

.DESCRIPTION
    Tests profiler functions on localhost and optionally remote servers.
    Validates caching, constraint detection, and parallelism calculation.
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$TestServers = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false)]
    [switch]$SkipCache
)

# Import module
$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ServerAuditToolkitV2.psm1'
Import-Module -Name $ModulePath -Force

Write-Host "=== T2 Profiler Validation ===" -ForegroundColor Cyan

foreach ($server in $TestServers) {
    Write-Host "`nTesting: $server" -ForegroundColor Green

    # Test 1: Profile capabilities
    Write-Host "  Test 1: Get-ServerCapabilities..."
    try {
        $cap = Get-ServerCapabilities -ComputerName $server -UseCache:(-not $SkipCache)
        if ($cap.Success) {
            Write-Host "    ✓ Profile successful" -ForegroundColor Green
            Write-Host "      Tier: $($cap.PerformanceTier) | Jobs: $($cap.SafeParallelJobs) | Timeout: $($cap.JobTimeoutSec)s"
        } else {
            Write-Host "    ✗ Profile failed: $($cap.Errors -join ', ')" -ForegroundColor Red
        }
    } catch {
        Write-Host "    ✗ Exception: $_" -ForegroundColor Red
    }

    # Test 2: CPU detection
    Write-Host "  Test 2: Get-ProcessorInfo..."
    try {
        $cpu = Get-ProcessorInfo -ComputerName $server
        if ($cpu) {
            Write-Host "    ✓ CPU detected: $($cpu.Model) ($($cpu.LogicalCores) logical cores)" -ForegroundColor Green
        } else {
            Write-Host "    ✗ CPU not detected" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ✗ Exception: $_" -ForegroundColor Red
    }

    # Test 3: RAM detection
    Write-Host "  Test 3: Get-RAMInfo..."
    try {
        $ram = Get-RAMInfo -ComputerName $server
        if ($ram) {
            Write-Host "    ✓ RAM detected: $([Math]::Round($ram.TotalMB / 1024, 1))GB total, $($ram.UsagePercent)% used" -ForegroundColor Green
        } else {
            Write-Host "    ✗ RAM not detected" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ✗ Exception: $_" -ForegroundColor Red
    }

    # Test 4: Disk performance
    Write-Host "  Test 4: Get-DiskPerformance..."
    try {
        $disk = Get-DiskPerformance -ComputerName $server
        if ($disk) {
            Write-Host "    ✓ Disk detected: Read $($disk.ReadLatencyMs)ms, Free $($disk.AverageFreePercent)%" -ForegroundColor Green
        } else {
            Write-Host "    ✗ Disk not detected" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ✗ Exception: $_" -ForegroundColor Red
    }

    # Test 5: Network connectivity
    Write-Host "  Test 5: Test-NetworkConnectivity..."
    try {
        $net = Test-NetworkConnectivity -ComputerName $server
        if ($net) {
            Write-Host "    ✓ Network: $($net.Connectivity), $($net.LatencyMs)ms latency" -ForegroundColor Green
        } else {
            Write-Host "    ✗ Network test failed" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ✗ Exception: $_" -ForegroundColor Red
    }

    # Test 6: Constraint detection
    Write-Host "  Test 6: Resource constraints..."
    if ($cap -and $cap.ResourceConstraints.Count -gt 0) {
        Write-Host "    ℹ Constraints detected:" -ForegroundColor Yellow
        $cap.ResourceConstraints | ForEach-Object { Write-Host "      - $_" -ForegroundColor Yellow }
    } else {
        Write-Host "    ✓ No constraints detected" -ForegroundColor Green
    }

    # Test 7: Cache behavior
    if (-not $SkipCache) {
        Write-Host "  Test 7: Caching..."
        try {
            $cap1 = Get-ServerCapabilities -ComputerName $server -UseCache:$true
            $cap2 = Get-ServerCapabilities -ComputerName $server -UseCache:$true
            if ($cap2.CachedResult) {
                Write-Host "    ✓ Cache working correctly" -ForegroundColor Green
            } else {
                Write-Host "    ⚠ Second call not cached (may have expired)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "    ✗ Cache test failed: $_" -ForegroundColor Red
        }
    }
}

Write-Host "`n=== T2 Validation Complete ===" -Foreground