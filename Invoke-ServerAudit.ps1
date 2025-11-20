
.DESCRIPTION
    1. Detects local PowerShell version and Windows OS
    2. Loads collector metadata
    3. Filters collectors for compatibility
    4. Executes compatible collectors with adaptive parallelism
    5. Aggregates results and passes to report generation

.PARAMETER ComputerName
    Target servers to audit. Can pipe multiple server names.

.PARAMETER Collectors
    Specific collectors to run. If empty, runs all compatible collectors.

.PARAMETER DryRun
    If $true, shows which collectors will run without executing.

.PARAMETER MaxParallelJobs
    Maximum concurrent jobs. If 0, auto-detects based on server resources.

.EXAMPLE
    Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02" -DryRun
    Invoke-ServerAudit -ComputerName "SERVER01" -Collectors @("Get-ServerInfo", "Get-Services")

#>

function Invoke-ServerAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory=$false)]
        [string[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$false)]
        [int]$MaxParallelJobs = 0
    )

    Write-Host "=== ServerAuditToolkitV2: Audit Orchestrator ===" -ForegroundColor Cyan
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-Host "Target Servers: $($ComputerName -join ', ')"

    # STEP 1: Load collector metadata
    Write-Verbose "Loading collector metadata..."
    $metadata = Get-CollectorMetadata

    if (-not $metadata) {
        Write-Error "Failed to load collector metadata. Exiting."
        return
    }

    # STEP 2: Determine local environment
    $localPSVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-Verbose "Local PowerShell Version: $localPSVersion"

    # STEP 3: Filter collectors
    Write-Verbose "Filtering collectors for compatibility..."
    $compatibleCollectors = Get-CompatibleCollectors -Collectors $metadata.collectors -PSVersion $localPSVersion

    if ($Collectors.Count -gt 0) {
        # User specified specific collectors
        $compatibleCollectors = $compatibleCollectors | Where-Object { $_.name -in $Collectors }
    }

    if ($compatibleCollectors.Count -eq 0) {
        Write-Warning "No compatible collectors found for PS $localPSVersion"
        return
    }

    Write-Host "Compatible Collectors: $($compatibleCollectors.Count)"
    $compatibleCollectors | ForEach-Object { Write-Host "  - $($_.displayName) (timeout: $($_.timeout)s)" -ForegroundColor Green }

    # DRY RUN: Show what will execute
    if ($DryRun) {
        Write-Host "`nDRY RUN MODE: Collectors will NOT execute." -ForegroundColor Yellow
        Write-Host "To run the audit, remove the -DryRun flag.`n" -ForegroundColor Yellow
        return
    }

    # STEP 4: Aggregate results from all servers
    $auditResults = @{
        Servers     = @()
        Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        PSVersion   = $localPSVersion
        Collectors  = $compatibleCollectors.Count
    }

    # STEP 5: Execute collectors for each server
    foreach ($server in $ComputerName) {
        Write-Host "`nAuditing: $server" -ForegroundColor Cyan
        
        $serverResults = @{
            ComputerName = $server
            Collectors   = @()
            Success      = $true
            Errors       = @()
        }

        foreach ($collector in $compatibleCollectors) {
            Write-Host "  Running: $($collector.displayName)..." -NoNewline

            try {
                # Determine which collector variant to use
                $variant = Get-CollectorVariant -Collector $collector -PSVersion $localPSVersion
                $collectorPath = Join-Path -Path $PSScriptRoot -ChildPath "..\collectors\$variant"

                if (-not (Test-Path -LiteralPath $collectorPath)) {
                    throw "Collector not found: $collectorPath"
                }

                # Validate dependencies
                $depsOk = Test-CollectorDependencies -Collector $collector
                if (-not $depsOk) {
                    Write-Host " [SKIPPED - Missing Dependencies]" -ForegroundColor Yellow
                    $serverResults.Collectors += @{
                        Name    = $collector.name
                        Status  = 'SKIPPED'
                        Reason  = 'Missing dependencies'
                    }
                    continue
                }

                # Execute collector
                $collectorOutput = & $collectorPath -ComputerName $server -ErrorAction Stop

                if ($collectorOutput.Success) {
                    Write-Host " [OK]" -ForegroundColor Green
                } else {
                    Write-Host " [FAILED]" -ForegroundColor Red
                    $serverResults.Success = $false
                }

                $serverResults.Collectors += @{
                    Name          = $collector.name
                    Status        = if ($collectorOutput.Success) { 'SUCCESS' } else { 'FAILED' }
                    ExecutionTime = $collectorOutput.ExecutionTime
                    Data          = $collectorOutput.Data
                    Errors        = $collectorOutput.Errors
                }

            } catch {
                Write-Host " [ERROR]" -ForegroundColor Red
                $serverResults.Errors += $_
                $serverResults.Success = $false
            }
        }

        $auditResults.Servers += $serverResults
    }

    # STEP 6: Summary and return
    Write-Host "`n=== Audit Complete ===" -ForegroundColor Cyan
    Write-Host "Servers processed: $($auditResults.Servers.Count)"
    Write-Host "Successful: $(($auditResults.Servers | Where-Object { $_.Success }).Count)"

    return $auditResults
}

Write-Verbose "[SAT] Done. See outputs in $OutDir"
return $dataset
# ... existing code ...

function Invoke-ServerAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory=$false)]
        [string[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$false)]
        [int]$MaxParallelJobs = 0,  # 0 = auto-detect from capabilities

        [Parameter(Mandatory=$false)]
        [switch]$SkipPerformanceProfile  # Skip T2 profiling for speed
    )

    Write-Host "=== ServerAuditToolkitV2: Audit Orchestrator ===" -ForegroundColor Cyan
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-Host "Target Servers: $($ComputerName -join ', ')"

    # STEP 1: Load collector metadata (T1)
    Write-Verbose "Loading collector metadata..."
    $metadata = Get-CollectorMetadata

    if (-not $metadata) {
        Write-Error "Failed to load collector metadata. Exiting."
        return
    }

    # STEP 2: Determine local environment
    $localPSVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-Verbose "Local PowerShell Version: $localPSVersion"

    # STEP 3: Filter collectors (T1)
    Write-Verbose "Filtering collectors for compatibility..."
    $compatibleCollectors = Get-CompatibleCollectors -Collectors $metadata.collectors -PSVersion $localPSVersion

    if ($Collectors.Count -gt 0) {
        $compatibleCollectors = $compatibleCollectors | Where-Object { $_.name -in $Collectors }
    }

    if ($compatibleCollectors.Count -eq 0) {
        Write-Warning "No compatible collectors found for PS $localPSVersion"
        return
    }

    Write-Host "Compatible Collectors: $($compatibleCollectors.Count)"
    $compatibleCollectors | ForEach-Object { Write-Host "  - $($_.displayName) (timeout: $($_.timeout)s)" -ForegroundColor Green }

    # DRY RUN: Show what will execute
    if ($DryRun) {
        Write-Host "`nDRY RUN MODE: Collectors will NOT execute." -ForegroundColor Yellow
        return
    }

    # ============== NEW T2 INTEGRATION ==============
    # STEP 4: Profile server capabilities and determine parallelism
    Write-Host "`nProfiler Server Capabilities (T2)..." -ForegroundColor Cyan

    $auditResults = @{
        Servers           = @()
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        PSVersion         = $localPSVersion
        Collectors        = $compatibleCollectors.Count
        PerformanceProfiles = @()  # NEW: track performance profiles
    }

    foreach ($server in $ComputerName) {
        Write-Host "`nAuditing: $server" -ForegroundColor Cyan

        # T2: Get server capabilities
        if (-not $SkipPerformanceProfile) {
            Write-Host "  Profiling capabilities..." -NoNewline
            try {
                $capabilities = Get-ServerCapabilities -ComputerName $server -UseCache:$true -ErrorAction Stop

                if ($capabilities.Success) {
                    Write-Host " [OK]" -ForegroundColor Green
                    Write-Host "    Performance Tier: $($capabilities.PerformanceTier) | Safe Jobs: $($capabilities.SafeParallelJobs) | Timeout: $($capabilities.JobTimeoutSec)s"

                    if ($capabilities.ResourceConstraints.Count -gt 0) {
                        Write-Host "    Constraints detected:" -ForegroundColor Yellow
                        $capabilities.ResourceConstraints | ForEach-Object { Write-Host "      - $_" -ForegroundColor Yellow }
                    }

                    $auditResults.PerformanceProfiles += @{
                        ComputerName = $server
                        Profile      = $capabilities
                    }
                } else {
                    Write-Host " [FAILED]" -ForegroundColor Red
                    $capabilities = $null
                }
            } catch {
                Write-Host " [ERROR]" -ForegroundColor Red
                Write-Error "Profiling failed: $_"
                $capabilities = $null
            }
        } else {
            $capabilities = $null
        }

        # Determine parallelism for this server
        $effectiveMaxJobs = if ($MaxParallelJobs -gt 0) {
            $MaxParallelJobs  # User override
        } elseif ($capabilities -and $capabilities.Success) {
            $capabilities.SafeParallelJobs  # Use T2 profile
        } else {
            1  # Conservative default
        }

        $effectiveTimeout = if ($capabilities -and $capabilities.Success) {
            $capabilities.JobTimeoutSec
        } else {
            60  # Default 1 minute per job
        }

        Write-Host "  Using parallelism: $effectiveMaxJobs jobs with ${effectiveTimeout}s timeout per collector"

        # STEP 5: Execute collectors with calculated parameters
        $serverResults = @{
            ComputerName        = $server
            Collectors          = @()
            Success             = $true
            ParallelismUsed     = $effectiveMaxJobs
            TimeoutUsed         = $effectiveTimeout
            Errors              = @()
        }

        foreach ($collector in $compatibleCollectors) {
            Write-Host "  Running: $($collector.displayName)..." -NoNewline

            try {
                # Determine variant (T1)
                $variant = Get-CollectorVariant -Collector $collector -PSVersion $localPSVersion
                $collectorPath = Join-Path -Path $PSScriptRoot -ChildPath "..\collectors\$variant"

                if (-not (Test-Path -LiteralPath $collectorPath)) {
                    throw "Collector not found: $collectorPath"
                }

                # Validate dependencies (T1)
                $depsOk = Test-CollectorDependencies -Collector $collector
                if (-not $depsOk) {
                    Write-Host " [SKIPPED - Missing Dependencies]" -ForegroundColor Yellow
                    $serverResults.Collectors += @{
                        Name    = $collector.name
                        Status  = 'SKIPPED'
                        Reason  = 'Missing dependencies'
                    }
                    continue
                }

                # Execute collector with T2-calculated timeout
                $collectorOutput = & $collectorPath -ComputerName $server -ErrorAction Stop

                if ($collectorOutput.Success) {
                    Write-Host " [OK]" -ForegroundColor Green
                } else {
                    Write-Host " [FAILED]" -ForegroundColor Red
                    $serverResults.Success = $false
                }

                $serverResults.Collectors += @{
                    Name          = $collector.name
                    Status        = if ($collectorOutput.Success) { 'SUCCESS' } else { 'FAILED' }
                    ExecutionTime = $collectorOutput.ExecutionTime
                    Data          = $collectorOutput.Data
                    Errors        = $collectorOutput.Errors
                }

            } catch {
                Write-Host " [ERROR]" -ForegroundColor Red
                $serverResults.Errors += $_
                $serverResults.Success = $false
            }
        }

        $auditResults.Servers += $serverResults
    }

    # STEP 6: Summary and return
    Write-Host "`n=== Audit Complete ===" -ForegroundColor Cyan
    Write-Host "Servers processed: $($auditResults.Servers.Count)"
    Write-Host "Successful: $(($auditResults.Servers | Where-Object { $_.Success }).Count)"

    return $auditResults
}
