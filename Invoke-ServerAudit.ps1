<<<<<<< Updated upstream
[CmdletBinding(SupportsShouldProcess=$false)]
param(
  [string[]]$ComputerName = $env:COMPUTERNAME,
  [string]  $OutDir,
  [switch]  $NoParallel
)

# Robust script root (works even if $PSScriptRoot is null)
$ScriptRoot = if ($PSVersionTable.PSVersion.Major -ge 3 -and $PSScriptRoot) {
  $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
  Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
  (Get-Location).Path
}

# Find the module manifest from common locations (root, src, parent\src) or by search
$manifestCandidates = @(
  (Join-Path $ScriptRoot 'ServerAuditToolkitV2.psd1'),
  (Join-Path $ScriptRoot 'src\ServerAuditToolkitV2.psd1'),
  (Join-Path (Split-Path -Parent $ScriptRoot) 'src\ServerAuditToolkitV2.psd1')
) + (Get-ChildItem -Path $ScriptRoot -Filter 'ServerAuditToolkitV2.psd1' -Recurse -ErrorAction SilentlyContinue |
     Select-Object -First 1 -ExpandProperty FullName)

$manifest = $manifestCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $manifest) {
  throw "Cannot find ServerAuditToolkitV2.psd1 relative to '$ScriptRoot'. Ensure the repo layout is intact."
}

# Compute repo root so OutDir defaults to ...\out regardless of where this wrapper lives
$repoRoot = Split-Path -Parent $manifest
if ($repoRoot -like '*\src') { $repoRoot = Split-Path -Parent $repoRoot }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'out' }

Import-Module $manifest -Force

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Verbose "[SAT] Starting audit for: $($ComputerName -join ', ')"

# Run the orchestrator in the module
$dataset = Invoke-ServerAudit -ComputerName $ComputerName -OutDir $OutDir -NoParallel:$NoParallel -Verbose

# Persist JSON if the module didn’t already
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$base = Join-Path $OutDir "data_$ts"
try {
  if (Get-Command Export-SATData -ErrorAction SilentlyContinue) {
    $null = Export-SATData -Object $dataset -PathBase $base -Depth 6
  } elseif (Get-Command ConvertTo-Json -ErrorAction SilentlyContinue) {
    $dataset | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path ($base + '.json')
  } else {
    $dataset | Export-Clixml -Path ($base + '.clixml')
  }
  Write-Verbose "[SAT] Data saved: $base.(json|clixml)"
} catch {
  Write-Warning "[SAT] Could not persist data: $($_.Exception.Message)"
}

Write-Verbose "[SAT] Done. See outputs in $OutDir"
return $dataset
=======
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

# ... rest of existing code ...
>>>>>>> Stashed changes
