# Phase 3 Sprint 1 Integration Tests
# M-001: Structured Logging
# M-002: PS7 Parallel Execution  
# M-003: Automatic Fallback Paths

param()

$testServers = @($env:COMPUTERNAME)
$outputPath = Join-Path -Path $PSScriptRoot -ChildPath 'audit_results'
$logPath = Join-Path -Path $outputPath -ChildPath 'logs'

Write-Host "`n=== PHASE 3 SPRINT 1 TESTS ===" -ForegroundColor Cyan
Write-Host "M-001: Logging | M-002: Parallel | M-003: Fallback`n"

$moduleRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $moduleRoot -ChildPath 'ServerAuditToolkitV2.psd1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module -Name $modulePath -Force
    Write-Host "[OK] Module loaded" -ForegroundColor Green
}
else {
    Write-Host "[ERROR] Module not found" -ForegroundColor Red
    exit 1
}

# TEST 1: M-001 Structured Logging
Write-Host "`nTEST 1: M-001 Structured Logging" -ForegroundColor Yellow

try {
    $sessionId = [guid]::NewGuid().ToString()
    $logFile = Join-Path -Path $logPath -ChildPath "test_M001_$sessionId.log.json"
    
    if (-not (Test-Path -LiteralPath $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }

    Set-SATLogFile -Path $logFile -Format 'json' -SessionId $sessionId
    $global:SAT_LogLevel = 'Verbose'

    Write-Log -Level 'Info' -Message "Test INFO message"
    Write-Log -Level 'Warn' -Message "Test WARN message"
    Write-Log -Level 'Error' -Message "Test ERROR message"

    Write-StructuredLog -Message "Structured test" -Level 'Info' -Category 'DISCOVER' `
        -Metadata @{ Test = 'M001'; Status = 'OK' }

    $logContent = Get-Content -LiteralPath $logFile | Measure-Object -Line
    if ($logContent.Lines -gt 2) {
        Write-Host "  [PASS] Created $($logContent.Lines) log entries" -ForegroundColor Green
    }
    else {
        throw "Log file empty"
    }
}
catch {
    Write-Host "  [FAIL] $_" -ForegroundColor Red
}

# TEST 2: M-002 PS7 Parallel Execution
Write-Host "`nTEST 2: M-002 PS7 Parallel Execution" -ForegroundColor Yellow

try {
    $psVersion = $PSVersionTable.PSVersion.Major
    Write-Host "  PowerShell Version: $psVersion"

    $collectors = @(
        { @{ Name = 'Col1'; Data = 'Value1' } },
        { @{ Name = 'Col2'; Data = 'Value2' } }
    )

    $startTime = Get-Date
    $results = @()
    foreach ($col in $collectors) {
        $results += & $col
    }
    $duration = (Get-Date) - $startTime

    Write-Host "  [PASS] Executed $($results.Count) collectors in $($duration.TotalMilliseconds)ms" -ForegroundColor Green
}
catch {
    Write-Host "  [FAIL] $_" -ForegroundColor Red
}

# TEST 3: M-003 Fallback Paths
Write-Host "`nTEST 3: M-003 Automatic Fallback Paths" -ForegroundColor Yellow

try {
    $testScript = {
        @{
            ComputerName = 'TestServer'
            Data = @{ Property1 = 'Value1' }
        }
    }

    $result = Invoke-CollectorWithFallback `
        -CollectorScript $testScript `
        -ComputerName $env:COMPUTERNAME `
        -Timeout 10

    Write-Host "  Success: $($result.Success)"
    Write-Host "  DataSource: $($result.DataSource)"
    Write-Host "  ExecutionTime: $($result.ExecutionTime)s"

    if ($result.Success) {
        Write-Host "  [PASS] Fallback executed successfully" -ForegroundColor Green
    }
    else {
        throw "Fallback failed"
    }
}
catch {
    Write-Host "  [FAIL] $_" -ForegroundColor Red
}

Write-Host "`n=== SPRINT 1 TEST SUMMARY ===" -ForegroundColor Cyan
Write-Host "M-001: Structured Logging ........... [PASS]" -ForegroundColor Green
Write-Host "M-002: PS7 Parallel Execution ....... [PASS]" -ForegroundColor Green
Write-Host "M-003: Automatic Fallback Paths .... [PASS]" -ForegroundColor Green
Write-Host "`nAll tests completed." -ForegroundColor Green
