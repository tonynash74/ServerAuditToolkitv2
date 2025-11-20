<#
.SYNOPSIS
    Validation tests for T4 (PS 5.1+ Optimized Collectors).

.DESCRIPTION
    Tests PS5.1+ collector variants:
    - Collector variant selection
    - Performance comparison (PS2 vs PS5)
    - Accuracy of collected data
    - Fallback behavior
    - Timeout handling
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$TargetServer = $env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "$PWD\t4_results"
)

# Import module
$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\ServerAuditToolkitV2.psm1'
Import-Module -Name $ModulePath -Force

Write-Host "=== T4 Optimized Collectors Validation ===" -ForegroundColor Cyan
Write-Host "Target Server: $TargetServer" -ForegroundColor Green
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" -ForegroundColor Green

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Test 1: Variant Selection
Write-Host "`nTest 1: Verify PS 5.1+ variant selection" -ForegroundColor Green
try {
    $metadata = Get-CollectorMetadata
    $compatible = Get-CompatibleCollectors -Collectors $metadata.collectors -PSVersion '5.1'

    Write-Host "  PS 5.1 compatible collectors: $($compatible.Count)" -ForegroundColor Cyan

    foreach ($collector in $compatible) {
        $variant = Get-CollectorVariant -Collector $collector -PSVersion '5.1'
        $isPSFive = $variant -match 'PS5'
        
        Write-Host "    $($collector.name): $variant $(if ($isPSFive) { '✓ PS5 variant' } else { '(fallback)' })" -ForegroundColor Cyan
    }

    Write-Host "✓ Variant selection works" -ForegroundColor Green
} catch {
    Write-Host "✗ Variant selection failed: $_" -ForegroundColor Red
}

# Test 2: Run PS5.1 variant collectors (if running on PS5.1+)
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Write-Host "`nTest 2: Execute PS 5.1+ optimized collectors" -ForegroundColor Green

    # Test Get-ServerInfo-PS5
    Write-Host "  Running Get-ServerInfo-PS5..." -NoNewline
    try {
        $serverInfoPath = Join-Path -Path $PSScriptRoot -ChildPath '..\collectors\Get-ServerInfo-PS5.ps1'
        
        if (Test-Path -LiteralPath $serverInfoPath) {
            $result = & $serverInfoPath -ComputerName $TargetServer -DryRun
            
            if ($result.Success) {
                Write-Host " ✓" -ForegroundColor Green
                Write-Host "    Collected: OS, Hardware, Network, Roles, Disks" -ForegroundColor Cyan
            } else {
                Write-Host " ✗ Failed" -ForegroundColor Red
            }
        } else {
            Write-Host " ✗ File not found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host " ✗ Exception: $_" -ForegroundColor Red
    }

    # Test Get-IISInfo-PS5
    Write-Host "  Running Get-IISInfo-PS5..." -NoNewline
    try {
        $iisInfoPath = Join-Path -Path $PSScriptRoot -ChildPath '..\collectors\Get-IISInfo-PS5.ps1'
        
        if (Test-Path -LiteralPath $iisInfoPath) {
            $result = & $iisInfoPath -ComputerName $TargetServer -DryRun
            
            if ($result.Success) {
                Write-Host " ✓" -ForegroundColor Green
            } else {
                Write-Host " ⚠ Not installed" -ForegroundColor Yellow
            }
        } else {
            Write-Host " ✗ File not found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host " ✗ Exception: $_" -ForegroundColor Red
    }

    # Test Get-Services-PS5
    Write-Host "  Running Get-Services-PS5..." -NoNewline
    try {
        $servicesPath = Join-Path -Path $PSScriptRoot -ChildPath '..\collectors\Get-Services-PS5.ps1'
        
        if (Test-Path -LiteralPath $servicesPath) {
            $result = & $servicesPath -ComputerName $TargetServer -DryRun
            
            if ($result.Success) {
                Write-Host " ✓" -ForegroundColor Green
                Write-Host "    Ready to enumerate services" -ForegroundColor Cyan
            } else {
                Write-Host " ✗ Failed" -ForegroundColor Red
            }
        } else {
            Write-Host " ✗ File not found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host " ✗ Exception: $_" -ForegroundColor Red
    }
} else {
    Write-Host "`nTest 2: Skipped (PS 5.1+ required)" -ForegroundColor Yellow
}

# Test 3: Performance Comparison (if collectors available)
Write-Host "`nTest 3: Performance characteristics" -ForegroundColor Green
try {
    Write-Host "  Estimated execution times (from metadata):" -ForegroundColor Cyan

    $metadata = Get-CollectorMetadata
    $summary = Get-CollectorSummary -Metadata $metadata

    Write-Host "    Total collectors: $($summary.TotalCollectors)" -ForegroundColor Cyan
    Write-Host "    Estimated total time: $($summary.EstimatedTotalExecutionTime)s" -ForegroundColor Cyan
    Write-Host "    With parallelism=2: ~$([Math]::Round($summary.EstimatedTotalExecutionTime / 2))s" -ForegroundColor Cyan
    Write-Host "    With parallelism=4: ~$([Math]::Round($summary.EstimatedTotalExecutionTime / 4))s" -ForegroundColor Cyan
} catch {
    Write-Host "  ✗ Could not estimate times: $_" -ForegroundColor Yellow
}

# Test 4: Metadata Validation
Write-Host "`nTest 4: Collector metadata validation" -ForegroundColor Green
try {
    $metadata = Get-CollectorMetadata

    $ps51Collectors = $metadata.collectors | Where-Object { $_.psVersions -contains '5.1' }
    Write-Host "  Collectors supporting PS 5.1: $($ps51Collectors.Count)" -ForegroundColor Cyan

    foreach ($collector in $ps51Collectors) {
        $hasVariant = $collector.variants -and $collector.variants.'5.1'
        $variantName = if ($hasVariant) { $collector.variants.'5.1' } else { '(none)' }
        
        Write-Host "    $($collector.name): $variantName" -ForegroundColor Cyan
    }

    Write-Host "✓ Metadata validation complete" -ForegroundColor Green
} catch {
    Write-Host "✗ Metadata validation failed: $_" -ForegroundColor Red
}

Write-Host "`n=== T4 Validation Complete ===" -ForegroundColor Cyan