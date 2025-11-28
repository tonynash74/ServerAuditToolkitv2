<#
.SYNOPSIS
    Orchestrates server audit with adaptive parallelism based on server capabilities.

.DESCRIPTION
    Three-stage audit execution:
    1. DISCOVER: Detect local PS version, filter compatible collectors (T1)
    2. PROFILE: Profile target server capabilities (T2)
    3. EXECUTE: Run collectors with adaptive parallelism and timeout management

    Returns structured audit results with per-collector execution metrics.

.PARAMETER ComputerName
    Target servers to audit. Accepts pipeline input. Defaults to localhost.

.PARAMETER Collectors
    Specific collectors to run (by name, e.g. "Get-ServerInfo", "Get-IISInfo").
    If empty, runs all compatible collectors.

.PARAMETER DryRun
    If $true, shows which collectors will execute without running them.
    Useful for planning and validation.

.PARAMETER MaxParallelJobs
    Override auto-detected parallelism (from T2 profile). Use with caution.
    0 = auto-detect (default); 1-8 = manual override.

.PARAMETER SkipPerformanceProfile
    If $true, skips T2 profiling; uses conservative defaults (1 job, 60s timeout).
    Faster but less optimal parallelism.

.PARAMETER PersistPerformanceProfileCache
    Keeps the cached performance profile files after an audit completes.
    By default, cache files are removed once profiling is done to ensure
    fresh measurements on each run.

.PARAMETER UseCollectorCache
    If $true, loads collectors from cache (if available).
    If $false, always fresh-load collectors.

.PARAMETER CollectorPath
    Custom path to collectors folder. Defaults to module structure.

.PARAMETER OutputPath
    Directory for audit results (JSON, CSV, HTML reports).
    Defaults to $PWD\audit_results.

.PARAMETER LogLevel
    Logging verbosity: 'Verbose', 'Information', 'Warning', 'Error'.

.PARAMETER UseBatchProcessing
    (M-010) Enable batch processing for large environments (50+ servers).
    Processes servers in configurable batches with pipeline parallelism.
    Streams results to disk instead of buffering (memory efficient).

.PARAMETER BatchSize
    (M-010) Number of servers per batch. Default: 10. Range: 1-100.
    Smaller batches = more frequent output; larger batches = better throughput.

.PARAMETER PipelineDepth
    (M-010) Number of concurrent batches in the pipeline. Default: 2. Range: 1-5.
    Overlaps batch processing for faster total execution.
    Example: Depth=2 means batch N processes while batch N+1 collects.

.PARAMETER CheckpointInterval
    (M-010) Save checkpoint every N batches for recovery. Default: 5. Range: 1-50.
    Use checkpoints to resume interrupted audits.

.PARAMETER BatchOutputPath
    (M-010) Directory for batch results and checkpoints.
    Defaults to $OutputPath\batches.

.EXAMPLE
    # Dry-run to see what will execute
    Invoke-ServerAudit -ComputerName "SERVER01" -DryRun

.EXAMPLE
    # Execute audit with auto-detected parallelism
    $results = Invoke-ServerAudit -ComputerName "SERVER01", "SERVER02"
    $results.Servers | Format-Table ComputerName, Success, ParallelismUsed

.EXAMPLE
    # Run specific collectors with custom parallelism
    $results = Invoke-ServerAudit `
        -ComputerName "SERVER01" `
        -Collectors @("Get-ServerInfo", "Get-IISInfo") `
        -MaxParallelJobs 2

.EXAMPLE
    # Skip profiling for speed (conservative settings)
    $results = Invoke-ServerAudit -ComputerName "SERVER01" -SkipPerformanceProfile

.NOTES
    PS2.0+ compatible. Maintains backwards compatibility with PS 2.0.
    Uses runspace pools for parallel execution (PS3+); sequential on PS 2.0.
#>

[CmdletBinding(DefaultParameterSetName='Default')]
param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [Alias('Name', 'Server')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false)]
    [string[]]$Collectors,

    [Parameter(Mandatory=$false)]
    [ValidateSet('2.0', '4.0', '5.1', '7.0')]
    [string]$CollectorPSVersion,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, 16)]
    [int]$MaxParallelJobs = 0,

    [Parameter(Mandatory=$false)]
    [switch]$SkipPerformanceProfile,

    [Parameter(Mandatory=$false)]
    [switch]$PersistPerformanceProfileCache,

    [Parameter(Mandatory=$false)]
    [switch]$UseCollectorCache = $true,

    [Parameter(Mandatory=$false)]
    [string]$CollectorPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = (Join-Path -Path $PWD -ChildPath 'audit_results'),

    [Parameter(Mandatory=$false)]
    [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
    [string]$LogLevel = 'Information',

    # M-010: Batch processing parameters
    [Parameter(Mandatory=$false)]
    [switch]$UseBatchProcessing,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$BatchSize = 10,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 5)]
    [int]$PipelineDepth = 2,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 50)]
    [int]$CheckpointInterval = 5,

    [Parameter(Mandatory=$false)]
    [string]$BatchOutputPath,

    # M-012: Streaming output
    [Parameter(Mandatory=$false)]
    [switch]$EnableStreaming,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 100)]
    [int]$StreamBufferSize = 10,

    [Parameter(Mandatory=$false)]
    [ValidateRange(5, 300)]
    [int]$StreamFlushIntervalSeconds = 30,

    [Parameter(Mandatory=$false)]
    [switch]$EnableStreamingMemoryMonitoring,

    [Parameter(Mandatory=$false)]
    [ValidateRange(50, 1000)]
    [int]$StreamingMemoryThresholdMB = 200,

    [Parameter(Mandatory=$false)]
    [string]$StreamOutputPath
)

$moduleImported = $false
$skipModuleBootstrap = $false
if ($env:SAT_SKIP_SATV2_MODULE_IMPORT -eq '1') {
    $skipModuleBootstrap = $true
}

# First, prefer an installed module import by name (normal user scenario)
if (-not $skipModuleBootstrap) {
    try {
        Import-Module -Name 'ServerAuditToolkitV2' -ErrorAction Stop | Out-Null
        $moduleImported = $true
    } catch {
        # Not installed or failed import by name; we'll attempt local manifests next
        $moduleImported = $false
    }

    if (-not $moduleImported) {
        # Look for a local manifest in a few likely locations (script root, script root/src, parent)
        $candidates = @(
            Join-Path -Path $PSScriptRoot -ChildPath 'ServerAuditToolkitV2.psd1'
            Join-Path -Path $PSScriptRoot -ChildPath 'src\ServerAuditToolkitV2.psd1'
            Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'ServerAuditToolkitV2.psd1'
        )

        $foundManifest = $null
        foreach ($cand in $candidates) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $foundManifest = $cand; break }
        }

        if ($foundManifest) {
            try {
                Import-Module -Name $foundManifest -Force -ErrorAction Stop | Out-Null
                Write-Verbose "Imported module from manifest: $foundManifest"
                $moduleImported = $true
            } catch {
                Write-Warning "Failed to import ServerAuditToolkitV2 from local manifest '$foundManifest': $_"
                $moduleImported = $false
            }
        }
    }

    if (-not $moduleImported) {
        # Graceful guidance for users who manually deploy/copy the repo
        $readmePathCandidates = @(
            Join-Path -Path $PSScriptRoot -ChildPath 'README.md'
            Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'README.md'
        )
        $readmePath = $readmePathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

        $installScriptCandidates = @(
            Join-Path -Path $PSScriptRoot -ChildPath 'Install-LocalModule.ps1'
            Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Install-LocalModule.ps1'
        )
        $installScript = $installScriptCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

        Write-Host "`nERROR: Required module 'ServerAuditToolkitV2' is not installed or could not be loaded.`n" -ForegroundColor Red
        Write-Host "To install/import the module locally, you have two options:" -ForegroundColor Yellow
        if ($installScript) {
            Write-Host "  1) From the repository root, run:" -ForegroundColor Cyan
            Write-Host "       PowerShell -NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -Force" -ForegroundColor Cyan
        } else {
            Write-Host "  1) Copy the module folder into a folder listed in `$env:PSModulePath` or run:" -ForegroundColor Cyan
            Write-Host "       Import-Module '<full-path-to>\\ServerAuditToolkitV2.psd1'" -ForegroundColor Cyan
        }
        if ($readmePath) {
            Write-Host "`nSee the README for full guidance: $readmePath`n" -ForegroundColor Cyan
        } else {
            Write-Host "`nSee repository documentation for installation instructions.`n" -ForegroundColor Cyan
        }

        # Exit gracefully when running as a script; if running as a module import, allow import to continue.
        if (-not $ExecutionContext.SessionState.Module) {
            return
        }
    }
} else {
    Write-Verbose 'Skipping ServerAuditToolkitV2 auto-import (module wrapper invocation).'
}

# Load collector helper module once so orchestrator and runspaces share the same functions
$collectorHelperCandidates = @(
    Join-Path -Path $PSScriptRoot -ChildPath 'src\Collectors\CollectorSupport.psm1'
    Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\Collectors\CollectorSupport.psm1'
)

$script:CollectorHelperModulePath = $collectorHelperCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if ($script:CollectorHelperModulePath) {
    try {
        Import-Module -Name $script:CollectorHelperModulePath -Force -ErrorAction Stop | Out-Null
        Write-Verbose "Collector helper module imported from $script:CollectorHelperModulePath"
    } catch {
        Write-Warning "Failed to import collector helper module '$script:CollectorHelperModulePath': $_"
        $script:CollectorHelperModulePath = $null
    }
} else {
    Write-Warning 'Collector helper module not found; variant selection may fail.'
}

$helperScripts = @(
    @{ RelativePath = 'src\Private\Monitor-AuditResources.ps1'; MissingMessage = 'Resource auto-throttling will be unavailable.' },
    @{ RelativePath = 'src\Private\Test-AuditParameters.ps1'; MissingMessage = 'Parameter validation will be skipped.' },
    @{ RelativePath = 'src\Private\New-StreamingOutputWriter.ps1'; MissingMessage = 'Streaming output will be unavailable.' },
    @{ RelativePath = 'src\Private\Test-AuditPrerequisites.ps1'; MissingMessage = 'Health checks will be skipped.' },
    @{ RelativePath = 'src\Private\Invoke-BatchAudit.ps1'; MissingMessage = 'Batch processing will be unavailable.' },
    @{ RelativePath = 'src\Private\Invoke-WithRetry.ps1'; MissingMessage = 'Retry helper unavailable; transient errors will not auto-retry.' },
    @{ RelativePath = 'src\Private\Get-AdjustedTimeout.ps1'; MissingMessage = 'Collector-specific timeout adjustments will use defaults.' },
    @{ RelativePath = 'src\Reporting\New-AuditReport.ps1'; MissingMessage = 'Executive HTML reporting will be unavailable.' },
    @{ RelativePath = 'src\Get-ServerCapabilities.ps1'; MissingMessage = 'Performance profiling (T2) will be unavailable.' }
)

foreach ($helper in $helperScripts) {
    $helperPath = Join-Path -Path $PSScriptRoot -ChildPath $helper.RelativePath
    if (Test-Path -LiteralPath $helperPath) {
        try {
            . $helperPath
        } catch {
            Write-Warning "Failed to load helper at $helperPath. $_"
        }
    } else {
        Write-Warning "Helper script missing at $helperPath. $($helper.MissingMessage)"
    }
}

function ConvertTo-HashtableRecursive {
    param(
        [Parameter(Mandatory=$false)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        $clone = @{}
        foreach ($key in $InputObject.Keys) {
            $stringKey = if ($null -ne $key) { [string]$key } else { '' }
            $clone[$stringKey] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }
        return $clone
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $converted = @{}
        foreach ($key in $InputObject.Keys) {
            $stringKey = if ($null -ne $key) { [string]$key } else { '' }
            $converted[$stringKey] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }
        return $converted
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hashtable = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hashtable[$prop.Name] = ConvertTo-HashtableRecursive -InputObject $prop.Value
        }
        return $hashtable
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        return @(
            foreach ($item in $InputObject) {
                ConvertTo-HashtableRecursive -InputObject $item
            }
        )
    }

    return $InputObject
}

function Convert-ErrorForReport {
    param(
        [Parameter(Mandatory=$false)]
        $ErrorInput
    )

    if ($null -eq $ErrorInput) {
        return $null
    }

    if ($ErrorInput -is [System.Management.Automation.ErrorRecord]) {
        return @{
            Message               = $ErrorInput.Exception.Message
            Category              = $ErrorInput.CategoryInfo.Category.ToString()
            FullyQualifiedErrorId = $ErrorInput.FullyQualifiedErrorId
            TargetObject          = if ($ErrorInput.TargetObject) { "$($ErrorInput.TargetObject)" } else { $null }
            ScriptStackTrace      = $ErrorInput.ScriptStackTrace
            Timestamp             = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    }

    return "$ErrorInput"
}

function Convert-ErrorsForExport {
    param(
        [Parameter(Mandatory=$false)]
        [object[]]$Errors
    )

    if (-not $Errors -or $Errors.Count -eq 0) {
        return @()
    }

    $convertedErrors = @()
    foreach ($errorEntry in $Errors) {
        $normalized = Convert-ErrorForReport -ErrorInput $errorEntry

        if ($null -eq $normalized) {
            continue
        }

        if ($normalized -is [hashtable] -or $normalized -is [System.Collections.IDictionary] -or $normalized -is [pscustomobject]) {
            $convertedErrors += (ConvertTo-HashtableRecursive -InputObject $normalized)
        }
        else {
            $convertedErrors += "$normalized"
        }
    }

    return $convertedErrors
}

function Get-SafeFileName {
    param(
        [Parameter(Mandatory=$false)][string]$Name,
        [Parameter(Mandatory=$false)][string]$Default = 'Server'
    )

    if (-not $Name -or $Name.Trim().Length -eq 0) {
        $Name = $Default
    }

    $safe = $Name -replace '[^A-Za-z0-9_\-]', '_'
    if (-not $safe -or $safe.Trim().Length -eq 0) {
        $safe = $Default
    }

    return $safe
}

function New-ReportIndexHtml {
    param(
        [Parameter(Mandatory=$true)][array]$Reports,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$false)][string]$CompanyName = 'IT Audit',
        [Parameter(Mandatory=$false)][string]$Timestamp
    )

    if (-not $Reports -or $Reports.Count -eq 0) {
        return
    }

    $rows = ''
    foreach ($report in $Reports) {
        $statusText = if ($report.Success) { 'Healthy' } else { 'Attention' }
        $badgeColor = if ($report.Success) { '#4caf50' } else { '#ff9800' }
        $score = if ($null -ne $report.ReadinessScore) { $report.ReadinessScore } else { 'n/a' }
        $rows += "            <tr>\n                <td>$($report.ComputerName)</td>\n                <td>$score</td>\n                <td><span style='color:$badgeColor;font-weight:600;'>$statusText</span></td>\n                <td><a href='$($report.RelativePath)' target='_blank'>Open report</a></td>\n            </tr>\n"
    }

    $ts = if ($Timestamp) { $Timestamp } else { (Get-Date -Format 'yyyyMMdd_HHmmss') }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Audit Executive Summary</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f6fb; margin: 0; padding: 40px; color: #333; }
        .container { max-width: 1200px; margin: 0 auto; background: #fff; border-radius: 8px; box-shadow: 0 15px 40px rgba(0,0,0,0.08); padding: 40px; }
        h1 { margin-top: 0; }
        table { width: 100%; border-collapse: collapse; margin-top: 25px; }
        th, td { padding: 14px 18px; text-align: left; border-bottom: 1px solid #e5e7f1; }
        th { background: #f8f9ff; text-transform: uppercase; font-size: 0.85rem; letter-spacing: 0.08em; }
        tr:hover { background: #f5f7ff; }
        .meta { color: #6b7280; font-size: 0.95rem; }
        .meta span { margin-right: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Executive Summary – $CompanyName</h1>
        <p class="meta">
            <span>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</span>
            <span>Audit window: $ts</span>
            <span>Servers: $($Reports.Count)</span>
        </p>
        <table>
            <thead>
                <tr>
                    <th>Server</th>
                    <th>Readiness</th>
                    <th>Status</th>
                    <th>Report</th>
                </tr>
            </thead>
            <tbody>
$rows            </tbody>
        </table>
    </div>
</body>
</html>
"@

    $html | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
}

function Publish-ServerReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Results,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][string]$Timestamp,
        [Parameter(Mandatory=$false)][string]$CompanyName = 'IT Audit'
    )

    if (-not $Results -or -not $Results.Servers -or $Results.Servers.Count -eq 0) {
        return @()
    }

    if (-not (Get-Command -Name New-AuditReport -ErrorAction SilentlyContinue)) {
        Write-AuditLog 'New-AuditReport not available; skipping HTML generation.' -Level Warning
        return @()
    }

    $reportsRoot = Join-Path -Path $OutputPath -ChildPath 'reports'
    if (-not (Test-Path -LiteralPath $reportsRoot)) {
        New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
    }

    $manifest = @()
    foreach ($serverResult in $Results.Servers) {
        if (-not $serverResult) { continue }

        $safeName = Get-SafeFileName -Name $serverResult.ComputerName -Default 'Server'
        $filePrefix = if ($Timestamp) { "$Timestamp`_$safeName" } else { $safeName }
        $serverJsonPath = Join-Path -Path $reportsRoot -ChildPath ($filePrefix + '.json')
        $serverHtmlPath = Join-Path -Path $reportsRoot -ChildPath ($filePrefix + '.html')

        $collectorPayload = @()
        if ($serverResult.Collectors) {
            foreach ($collector in $serverResult.Collectors) {
                $recordCount = 0
                if ($collector.Data -is [System.Collections.ICollection]) {
                    $recordCount = $collector.Data.Count
                } elseif ($collector.Data) {
                    $recordCount = 1
                }

                $collectorPayload += @{
                    CollectorName = $collector.Name
                    DisplayName   = $collector.DisplayName
                    Status        = $collector.Status
                    ExecutionTime = $collector.ExecutionTime
                    RecordCount   = $recordCount
                    Data          = $collector.Data
                    Summary       = if ($collector.Summary) { $collector.Summary } else { $null }
                    Errors        = $collector.Errors
                }
            }
        }

        $reportPayload = [ordered]@{
            ComputerName = $serverResult.ComputerName
            Timestamp    = $serverResult.ExecutionEndTime
            Summary      = $serverResult.CollectorsSummary
            Data         = $collectorPayload
        }

        try {
            $reportPayload | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $serverJsonPath -Encoding UTF8 -Force
        } catch {
            Write-AuditLog "Failed to write report payload for $($serverResult.ComputerName): $_" -Level Warning
            continue
        }

        $reportResult = $null
        try {
            $reportResult = New-AuditReport -AuditDataPath $serverJsonPath -OutputPath $serverHtmlPath -CompanyName $CompanyName -IncludeDrilldown
        } catch {
            Write-AuditLog "Failed to render HTML report for $($serverResult.ComputerName): $_" -Level Warning
            continue
        }

        $relativePath = Join-Path 'reports' (Split-Path -Path $serverHtmlPath -Leaf)
        $relativePath = $relativePath -replace '\\', '/'

        $manifest += @{
            ComputerName   = $serverResult.ComputerName
            HtmlPath       = $serverHtmlPath
            RelativePath   = $relativePath
            ReadinessScore = if ($reportResult -and $reportResult.ReadinessScore) { $reportResult.ReadinessScore } else { $null }
            Success        = if ($reportResult) { [bool]$reportResult.Success } else { $false }
        }
    }

    if ($manifest.Count -gt 0) {
        $null = New-ReportIndexHtml -Reports $manifest -OutputPath (Join-Path -Path $OutputPath -ChildPath 'report-index.html') -CompanyName $CompanyName -Timestamp $Timestamp
    }

    return $manifest
}

function Update-AuditSummaryCounters {
    param(
        [hashtable]$Counters,
        [pscustomobject]$ServerResult
    )

    if (-not $Counters -or -not $ServerResult) {
        return
    }

    $Counters.TotalServers++

    if ($null -ne $ServerResult.Success -and [bool]$ServerResult.Success) {
        $Counters.SuccessfulServers++
    }

    # Keep failed-server count in sync with total vs successful to avoid inflation when retries/logging occur
    $Counters.FailedServers = [Math]::Max(0, $Counters.TotalServers - $Counters.SuccessfulServers)

    if ($ServerResult.CollectorsSummary) {
        $Counters.TotalCollectorsExecuted  += [int]($ServerResult.CollectorsSummary.Executed)
        $Counters.TotalCollectorsSucceeded += [int]($ServerResult.CollectorsSummary.Succeeded)
        $Counters.TotalCollectorsFailed    += [int]($ServerResult.CollectorsSummary.Failed)
    }

    if ($ServerResult.ExecutionTimeSeconds) {
        $Counters.TotalExecutionTimeSeconds += [double]$ServerResult.ExecutionTimeSeconds
    }
}

function Invoke-ServerAudit {
    [CmdletBinding(DefaultParameterSetName='Default', SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('Name', 'Server')]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory=$false)]
        [string[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [ValidateSet('2.0', '4.0', '5.1', '7.0')]
        [string]$CollectorPSVersion,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$false)]
        [ValidateRange(0, 16)]
        [int]$MaxParallelJobs = 0,

        [Parameter(Mandatory=$false)]
        [switch]$SkipPerformanceProfile,

        [Parameter(Mandatory=$false)]
        [switch]$UseCollectorCache = $true,

        [Parameter(Mandatory=$false)]
        [string]$CollectorPath,

        [Parameter(Mandatory=$false)]
        [string]$OutputPath = (Join-Path -Path $PWD -ChildPath 'audit_results'),

        [Parameter(Mandatory=$false)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$LogLevel = 'Information',

        # M-010: Batch processing parameters
        [Parameter(Mandatory=$false)]
        [switch]$UseBatchProcessing,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 100)]
        [int]$BatchSize = 10,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 5)]
        [int]$PipelineDepth = 2,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 50)]
        [int]$CheckpointInterval = 5,

        [Parameter(Mandatory=$false)]
        [string]$BatchOutputPath,

        # M-012: Streaming output
        [Parameter(Mandatory=$false)]
        [switch]$EnableStreaming,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 100)]
        [int]$StreamBufferSize = 10,

        [Parameter(Mandatory=$false)]
        [ValidateRange(5, 300)]
        [int]$StreamFlushIntervalSeconds = 30,

        [Parameter(Mandatory=$false)]
        [switch]$EnableStreamingMemoryMonitoring,

        [Parameter(Mandatory=$false)]
        [ValidateRange(50, 1000)]
        [int]$StreamingMemoryThresholdMB = 200,

        [Parameter(Mandatory=$false)]
        [string]$StreamOutputPath
    )

    begin {
        # Initialize audit session
        $auditSession = @{
            SessionId              = [guid]::NewGuid().ToString()
            StartTime              = Get-Date
            LocalPSVersion         = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
            LocalOSVersion         = (Get-OSVersion)
            TotalServersToAudit    = 0
            CollectorMetadata      = $null
            CompatibleCollectors   = @()
            CollectorPsVersion     = $null
            AuditResults           = @{
                Servers             = @()
                Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                PSVersion           = $null
                SessionId           = $null
                CollectorPSVersion  = $null
                PerformanceProfiles = @()
                Summary             = @{}
            }
            SummaryCounters        = @{
                TotalServers                = 0
                SuccessfulServers           = 0
                FailedServers               = 0
                TotalCollectorsExecuted     = 0
                TotalCollectorsSucceeded    = 0
                TotalCollectorsFailed       = 0
                TotalExecutionTimeSeconds   = 0
            }
            StreamingWriter        = $null
        }

        # Setup logging
        Initialize-AuditLogging -SessionId $auditSession.SessionId -LogLevel $LogLevel

        Write-AuditLog "=== ServerAuditToolkitV2 Orchestrator (T3) ===" -Level Information
        Write-AuditLog "Session ID: $($auditSession.SessionId)" -Level Verbose
        Write-AuditLog "Local PS Version: $($auditSession.LocalPSVersion)" -Level Verbose
        Write-AuditLog "Local OS Version: $($auditSession.LocalOSVersion)" -Level Verbose

        # M-009: Start resource monitoring (CPU/Memory throttling)
        Write-AuditLog "M-009: Starting resource monitoring for auto-throttling" -Level Verbose
        try {
            $parallelJobs = if ($MaxParallelJobs -gt 0) { $MaxParallelJobs } else { 3 }
            $resourceMonitorJob = Start-AuditResourceMonitoring `
                -MaxParallelJobs $parallelJobs `
                -CpuThreshold 85 `
                -MemoryThreshold 90 `
                -MonitoringIntervalSeconds 2 `
                -ErrorAction SilentlyContinue
            
            if ($resourceMonitorJob) {
                $auditSession.ResourceMonitorJob = $resourceMonitorJob
                Write-AuditLog "Resource monitoring active (Job ID: $($resourceMonitorJob.Id))" -Level Verbose
            }
        }
        catch {
            Write-AuditLog "Resource monitoring unavailable (non-critical): $_" -Level Warning
        }

        # Load configuration with timeout settings
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath 'data\audit-config.json'
        $config = $null
        if (Test-Path -LiteralPath $configPath) {
            try {
                $config = Get-Content -LiteralPath $configPath | ConvertFrom-Json
                Write-AuditLog "Loaded audit configuration from: $configPath" -Level Verbose
            } catch {
                Write-AuditLog "Failed to load audit configuration: $_" -Level Warning
            }
        }
        $auditSession.Config = $config
        $brandingName = 'IT Audit'
        if ($config -and $config.branding -and $config.branding.companyName) {
            $brandingName = [string]$config.branding.companyName
        }
        $auditSession.AuditResults.CompanyName = $brandingName

        # Resolve collector path
        # Support running the script from different working directories (e.g. a tools folder)
        if ([string]::IsNullOrEmpty($CollectorPath)) {
            $cwd = (Get-Location).ProviderPath
            $collectorCandidates = @(
                (Join-Path -Path $PSScriptRoot -ChildPath 'src\Collectors'),
                (Join-Path -Path $PSScriptRoot -ChildPath '..\collectors'),
                (Join-Path -Path $cwd -ChildPath 'tools\ServerAuditToolkitv2\collectors'),
                (Join-Path -Path $cwd -ChildPath 'tools\collectors'),
                (Join-Path -Path $cwd -ChildPath 'collectors'),
                (Join-Path -Path $cwd -ChildPath 'ServerAuditToolkitv2\collectors'),
                (Join-Path -Path $env:ProgramData -ChildPath 'ServerAuditToolkitv2\collectors')
            )

            if ($env:SAT_COLLECTOR_PATH) { $collectorCandidates += $env:SAT_COLLECTOR_PATH }

            # Resolve any candidate paths (handle relative paths gracefully)
            $CollectorPath = $null
            foreach ($cand in $collectorCandidates) {
                if (-not $cand) { continue }
                try {
                    $resolved = Resolve-Path -LiteralPath $cand -ErrorAction Stop
                    if ($resolved) { $CollectorPath = $resolved.ProviderPath; break }
                } catch {
                    # ignore and continue searching
                }
            }
        } else {
            # User provided a CollectorPath - resolve absolute/relative references
            try {
                $resolved = Resolve-Path -LiteralPath $CollectorPath -ErrorAction Stop
                $CollectorPath = $resolved.ProviderPath
            } catch {
                # Try resolving relative to the script location
                try {
                    $candidate = Join-Path -Path $PSScriptRoot -ChildPath $CollectorPath
                    $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
                    $CollectorPath = $resolved.ProviderPath
                } catch {
                    Write-AuditLog "Collector path provided but not found: $CollectorPath" -Level Warning
                }
            }
        }

        if (-not $CollectorPath -or -not (Test-Path -LiteralPath $CollectorPath)) {
            Write-AuditLog "Collector path not found: $CollectorPath" -Level Error
            throw "Collector path not found: $CollectorPath"
        }

        Write-AuditLog "Collector path: $CollectorPath" -Level Verbose

        # Create output directory
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            try {
                [void](New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop)
                Write-AuditLog "Created output directory: $OutputPath" -Level Verbose
            } catch {
                Write-AuditLog "Failed to create output directory: $_" -Level Error
                throw
            }
        }

        # Configure streaming output
        $streamingConfig = $null
        if ($config -and $config.output -and $config.output.streaming) {
            $streamingConfig = $config.output.streaming
        }
        $streamingEnabled = if ($PSBoundParameters.ContainsKey('EnableStreaming')) {
            [bool]$EnableStreaming
        } elseif ($streamingConfig) {
            [bool]$streamingConfig.streamResults
        } else {
            $false
        }

        $effectiveStreamBufferSize = if ($PSBoundParameters.ContainsKey('StreamBufferSize')) {
            $StreamBufferSize
        } elseif ($streamingConfig -and $streamingConfig.bufferSize) {
            [int]$streamingConfig.bufferSize
        } else {
            10
        }

        $effectiveStreamFlushSeconds = if ($PSBoundParameters.ContainsKey('StreamFlushIntervalSeconds')) {
            $StreamFlushIntervalSeconds
        } elseif ($streamingConfig -and $streamingConfig.flushIntervalSeconds) {
            [int]$streamingConfig.flushIntervalSeconds
        } else {
            30
        }

        $effectiveMemoryMonitoring = if ($PSBoundParameters.ContainsKey('EnableStreamingMemoryMonitoring')) {
            [bool]$EnableStreamingMemoryMonitoring
        } elseif ($streamingConfig) {
            [bool]$streamingConfig.enableMemoryMonitoring
        } else {
            $false
        }

        $effectiveMemoryThresholdMB = if ($PSBoundParameters.ContainsKey('StreamingMemoryThresholdMB')) {
            $StreamingMemoryThresholdMB
        } elseif ($streamingConfig -and $streamingConfig.memoryThresholdMB) {
            [int]$streamingConfig.memoryThresholdMB
        } else {
            200
        }

        $effectiveStreamOutputPath = if ($PSBoundParameters.ContainsKey('StreamOutputPath') -and -not [string]::IsNullOrEmpty($StreamOutputPath)) {
            $StreamOutputPath
        } elseif ($streamingConfig -and $streamingConfig.outputDirectory) {
            $streamingConfig.outputDirectory
        } else {
            Join-Path -Path $OutputPath -ChildPath 'streaming'
        }

        if (-not [System.IO.Path]::IsPathRooted($effectiveStreamOutputPath)) {
            $effectiveStreamOutputPath = Join-Path -Path $OutputPath -ChildPath $effectiveStreamOutputPath
        }

        if ($streamingEnabled) {
            if (-not (Test-Path -LiteralPath $effectiveStreamOutputPath)) {
                [void](New-Item -ItemType Directory -Path $effectiveStreamOutputPath -Force -ErrorAction Stop)
                Write-AuditLog "Created streaming output directory: $effectiveStreamOutputPath" -Level Verbose
            }

            try {
                $auditSession.StreamingWriter = New-StreamingOutputWriter `
                    -OutputPath $effectiveStreamOutputPath `
                    -BufferSize $effectiveStreamBufferSize `
                    -FlushIntervalSeconds $effectiveStreamFlushSeconds `
                    -EnableMemoryMonitoring:$effectiveMemoryMonitoring `
                    -MemoryThresholdMB $effectiveMemoryThresholdMB

                $auditSession.AuditResults.Streaming = @{
                    Enabled              = $true
                    StreamFile           = $auditSession.StreamingWriter.StreamFile
                    OutputPath           = $effectiveStreamOutputPath
                    BufferSize           = $effectiveStreamBufferSize
                    FlushIntervalSeconds = $effectiveStreamFlushSeconds
                    MemoryMonitoring     = $effectiveMemoryMonitoring
                }

                Write-AuditLog "M-012: Streaming output enabled (buffer=$effectiveStreamBufferSize, flush=${effectiveStreamFlushSeconds}s)" -Level Information
            }
            catch {
                Write-AuditLog "Failed to initialize streaming output: $_" -Level Error
                throw
            }
        }

        # ====== STAGE 1: DISCOVER ======
        Write-AuditLog "STAGE 1: DISCOVER (Collector Compatibility)" -Level Information

        try {
            # Load metadata
            Write-AuditLog "Loading collector metadata..." -Level Verbose
            $auditSession.CollectorMetadata = Get-CollectorMetadata
            
            if (-not $auditSession.CollectorMetadata) {
                throw "Failed to load collector metadata."
            }

            Write-AuditLog "Loaded $($auditSession.CollectorMetadata.collectors.Count) collector definitions" -Level Verbose

            # Filter by PS version
            $effectivePsVersion = $null

            if ($PSBoundParameters.ContainsKey('CollectorPSVersion')) {
                $effectivePsVersion = $CollectorPSVersion
                Write-AuditLog "User override: forcing collector PS version $effectivePsVersion" -Level Information
            } else {
                $effectivePsVersion = $auditSession.LocalPSVersion
                try {
                    $parsedVersion = [version]$auditSession.LocalPSVersion
                    if ($parsedVersion.Major -ge 6) {
                        $effectivePsVersion = '5.1'
                        Write-AuditLog "No PS$($parsedVersion.Major) collectors defined; falling back to PS 5.1 compatibility set." -Level Warning
                    }
                } catch {}
            }

            if (-not $effectivePsVersion) {
                $effectivePsVersion = '5.1'
            }

            $auditSession.CollectorPsVersion = $effectivePsVersion
            $auditSession.AuditResults.CollectorPSVersion = $effectivePsVersion

            Write-AuditLog "Filtering collectors for PS $effectivePsVersion..." -Level Verbose
            $auditSession.CompatibleCollectors = Get-CompatibleCollectors `
                -Collectors $auditSession.CollectorMetadata.collectors `
                -PSVersion $effectivePsVersion

            if ($auditSession.CompatibleCollectors.Count -eq 0) {
                throw "No collectors compatible with PS $effectivePsVersion"
            }

            Write-AuditLog "Found $($auditSession.CompatibleCollectors.Count) compatible collectors" -Level Information

            # Filter by user selection
            if ($Collectors.Count -gt 0) {
                Write-AuditLog "Filtering by user selection: $($Collectors -join ', ')" -Level Verbose
                $auditSession.CompatibleCollectors = $auditSession.CompatibleCollectors | Where-Object { $Collectors -contains $_.name }

                if ($auditSession.CompatibleCollectors.Count -eq 0) {
                    throw "No compatible collectors match user selection: $($Collectors -join ', ')"
                }
            }

            # Display compatible collectors
            Write-AuditLog "Compatible collectors:" -Level Information
            $auditSession.CompatibleCollectors | ForEach-Object {
                Write-AuditLog "  - $($_.displayName) (variants: $($_.psVersions -join ', '))" -Level Information
            }

        } catch {
            Write-AuditLog "DISCOVER stage failed: $_" -Level Error
            throw
        }

        $auditSession.AuditResults.PSVersion = $auditSession.LocalPSVersion
        $auditSession.AuditResults.SessionId = $auditSession.SessionId
    }

    process {
        # ====== STAGE 2: PROFILE & EXECUTE ======
        
        # Validate input parameters early
        try {
            Write-AuditLog "Validating input parameters..." -Level Verbose
            Test-AuditParameters -ComputerName $ComputerName
        } catch {
            Write-AuditLog "Parameter validation failed: $_" -Level Error
            throw
        }

        # M-010: Batch processing for large environments
        if ($UseBatchProcessing -and $ComputerName.Count -gt $BatchSize) {
            Write-AuditLog "M-010: Batch processing mode enabled for $($ComputerName.Count) servers (batch size: $BatchSize)" -Level Information
            
            try {
                # Setup batch output path
                if ([string]::IsNullOrEmpty($BatchOutputPath)) {
                    $BatchOutputPath = Join-Path -Path $OutputPath -ChildPath 'batches'
                }
                
                if (-not (Test-Path -LiteralPath $BatchOutputPath)) {
                    [void](New-Item -ItemType Directory -Path $BatchOutputPath -Force -ErrorAction Stop)
                    Write-AuditLog "Created batch output directory: $BatchOutputPath" -Level Verbose
                }

                $batchResultCallback = $null
                $callbackWriter = $auditSession.StreamingWriter
                $callbackCounters = $auditSession.SummaryCounters
                if ($callbackWriter) {
                    $batchResultCallback = {
                        param($batchData)

                        if (-not $batchData -or -not $batchData.Results) {
                            return
                        }

                        foreach ($serverResult in $batchData.Results) {
                            if (-not $serverResult) { continue }
                            $null = $callbackWriter.AddResult($serverResult)
                            Update-AuditSummaryCounters -Counters $callbackCounters -ServerResult $serverResult
                        }

                        # Release batch memory once streamed
                        $batchData.Results = @()
                    }
                }
                
                # Execute batch audit
                $batchParams = @{
                    Servers            = $ComputerName
                    Collectors         = $auditSession.CompatibleCollectors
                    BatchSize          = $BatchSize
                    PipelineDepth      = $PipelineDepth
                    CheckpointInterval = $CheckpointInterval
                    OutputPath         = $BatchOutputPath
                    ErrorAction        = 'Stop'
                }

                if ($batchResultCallback) {
                    $batchParams.ResultCallback = $batchResultCallback
                }

                $batchResults = Invoke-BatchAudit @batchParams
                
                # Store batch results
                if ($batchResults) {
                    $auditSession.BatchResults = $batchResults
                    Write-AuditLog "Batch processing complete: $($batchResults.TotalBatches) batches, $($batchResults.SuccessfulBatches) successful" -Level Information

                    if ($batchResults.BatchResults) {
                        foreach ($batch in $batchResults.BatchResults) {
                            if (-not $batch.Results) { continue }
                            foreach ($serverResult in $batch.Results) {
                                if ($auditSession.StreamingWriter -and -not $batchResultCallback) {
                                    $null = $auditSession.StreamingWriter.AddResult($serverResult)
                                }
                                elseif (-not $auditSession.StreamingWriter) {
                                    $auditSession.AuditResults.Servers += $serverResult
                                }

                                if (-not $batchResultCallback) {
                                    Update-AuditSummaryCounters -Counters $auditSession.SummaryCounters -ServerResult $serverResult
                                }
                            }

                            if ($auditSession.StreamingWriter) {
                                $batch.Results = @()
                            }
                        }
                    }
                }

                if ($auditSession.StreamingWriter -and -not $auditSession.StreamingWriter.IsFinalized) {
                    $streamFilePath = $auditSession.StreamingWriter.Finalize()
                    $auditSession.AuditResults.Streaming.StreamFile = $streamFilePath
                    $auditSession.AuditResults.Streaming.Statistics = $auditSession.StreamingWriter.GetStatistics()
                }

                $auditSession.AuditResults.Summary = @{
                    TotalServers             = $auditSession.SummaryCounters.TotalServers
                    SuccessfulServers        = $auditSession.SummaryCounters.SuccessfulServers
                    FailedServers            = $auditSession.SummaryCounters.FailedServers
                    TotalCollectorsExecuted  = $auditSession.SummaryCounters.TotalCollectorsExecuted
                    TotalCollectorsSucceeded = $auditSession.SummaryCounters.TotalCollectorsSucceeded
                    TotalCollectorsFailed    = $auditSession.SummaryCounters.TotalCollectorsFailed
                    AverageFetchTimeSeconds  = if ($auditSession.SummaryCounters.TotalServers -gt 0) { [Math]::Round($auditSession.SummaryCounters.TotalExecutionTimeSeconds / $auditSession.SummaryCounters.TotalServers, 2) } else { 0 }
                    DurationSeconds          = [Math]::Round(((Get-Date) - $auditSession.StartTime).TotalSeconds, 2)
                }
                
                return $auditSession.AuditResults
                
            } catch {
                Write-AuditLog "Batch processing failed: $_" -Level Error
                throw
            }
        }

        # ====== STAGE 1.5: HEALTH CHECK ======
        Write-AuditLog "STAGE 1.5: HEALTH CHECK (Pre-flight Validation)" -Level Information
        try {
            Write-AuditLog "Running prerequisite health checks for $($ComputerName.Count) server(s)..." -Level Information
            $healthReport = Test-AuditPrerequisites `
                -ComputerName $ComputerName `
                -Port 5985 `
                -Timeout 10 `
                -ThrottleLimit 3
            
            # Log health check results
            Write-AuditLog "Health check completed: Passed=$($healthReport.Summary.Passed) Failed=$($healthReport.Summary.Failed) Warnings=$($healthReport.Summary.Warnings)" -Level Information
            
            if (-not $healthReport.IsHealthy) {
                Write-AuditLog "Warning: health check issues detected" -Level Warning
                foreach ($issue in $healthReport.Issues) {
                    Write-AuditLog "  - $issue" -Level Warning
                }
                
                if ($healthReport.Summary.Failed -gt 0) {
                    Write-AuditLog "Critical health check failures detected. Audit cannot proceed without addressing these issues:" -Level Error
                    foreach ($remediation in $healthReport.Remediation | Select-Object -Unique) {
                        Write-AuditLog "  Hint: $remediation" -Level Error
                    }
                    throw "Pre-flight health check failed for $($healthReport.Summary.Failed) server(s)"
                }
            }
            else {
                Write-AuditLog "All servers passed health checks. Proceeding with audit." -Level Information
            }
            
            # Store health report in audit session for later reporting
            $auditSession.HealthReport = $healthReport
            
        } catch {
            Write-AuditLog "Health check stage failed: $_" -Level Error
            throw
        }
        
        foreach ($server in $ComputerName) {
            Write-AuditLog "====================================" -Level Information
            Write-AuditLog "Server: $server" -Level Information

            $serverResults = @{
                ComputerName           = $server
                Collectors             = @()
                Success                = $true
                ExecutionStartTime     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                ExecutionEndTime       = $null
                ExecutionTimeSeconds   = 0
                PerformanceProfile     = $null
                ParallelismUsed        = 1
                TimeoutUsed            = 60
                Errors                 = @()
                Warnings               = @()
                CollectorsSummary      = @{
                    Total    = $auditSession.CompatibleCollectors.Count
                    Executed = 0
                    Succeeded = 0
                    Failed   = 0
                    Skipped  = 0
                }
            }

            $serverStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                # Stage 2a: PROFILE (T2)
                if (-not $SkipPerformanceProfile) {
                    Write-AuditLog "STAGE 2a: PROFILE (Server Capabilities, T2)" -Level Information
                    
                    try {
                        Write-AuditLog "Profiling $server..." -Level Verbose
                        $profile = Invoke-WithRetry -Command {
                            Get-ServerCapabilities -ComputerName $server -UseCache:$true
                        } -Description "Server profiling on $server" -MaxRetries 3

                        if ($profile.Success) {
                            Write-AuditLog "Profile complete: Tier=$($profile.PerformanceTier), Jobs=$($profile.SafeParallelJobs), Timeout=$($profile.JobTimeoutSec)s" -Level Information
                            
                            if ($profile.ResourceConstraints.Count -gt 0) {
                                Write-AuditLog "Resource constraints detected:" -Level Warning
                                $profile.ResourceConstraints | ForEach-Object {
                                    Write-AuditLog "  Warning: $_" -Level Warning
                                    $serverResults.Warnings += $_
                                }
                            }

                            $serverResults.PerformanceProfile = $profile
                            $auditSession.AuditResults.PerformanceProfiles += @{
                                ComputerName = $server
                                Profile      = $profile
                            }
                        } else {
                            Write-AuditLog "Profile failed; using conservative defaults" -Level Warning
                            $serverResults.Warnings += "Profiling failed; using conservative parallelism"
                        }

                    } catch {
                        Write-AuditLog "Profiling error: $_" -Level Warning
                        $serverResults.Warnings += "Profiling exception: $_"
                    }
                } else {
                    Write-AuditLog "Skipping performance profile (user requested)" -Level Information
                }

                # Determine parallelism & timeout
                if ($MaxParallelJobs -gt 0) {
                    # User override
                    $serverResults.ParallelismUsed = $MaxParallelJobs
                    $serverResults.TimeoutUsed = 90  # default when overridden
                    Write-AuditLog "Using user-specified parallelism: $($MaxParallelJobs) jobs" -Level Verbose
                } elseif ($serverResults.PerformanceProfile -and $serverResults.PerformanceProfile.Success) {
                    # T2 auto-detect
                    $serverResults.ParallelismUsed = $serverResults.PerformanceProfile.SafeParallelJobs
                    $serverResults.TimeoutUsed = $serverResults.PerformanceProfile.JobTimeoutSec
                    Write-AuditLog "Using T2-detected parallelism: $($serverResults.ParallelismUsed) jobs, $($serverResults.TimeoutUsed)s timeout" -Level Verbose
                } else {
                    # Conservative defaults
                    $serverResults.ParallelismUsed = 1
                    $serverResults.TimeoutUsed = 60
                    Write-AuditLog "Using conservative defaults: 1 job, 60s timeout" -Level Verbose
                }

                # Stage 2b: EXECUTE (T3)
                Write-AuditLog "STAGE 2b: EXECUTE (Run Collectors, T3)" -Level Information
                Write-AuditLog "Executing $($auditSession.CompatibleCollectors.Count) collectors with parallelism=$($serverResults.ParallelismUsed)" -Level Information

                # Build timeout configuration for collectors
                $timeoutConfig = @{}
                if ($auditSession.Config -and $auditSession.Config.execution.timeout.collectorTimeouts) {
                    $collectorTimeouts = $auditSession.Config.execution.timeout.collectorTimeouts
                    if ($collectorTimeouts -and $collectorTimeouts.PSObject -and $collectorTimeouts.PSObject.Properties.Count -gt 0) {
                        foreach ($prop in $collectorTimeouts.PSObject.Properties) {
                            $timeoutConfig[$prop.Name] = ConvertTo-HashtableRecursive -InputObject $prop.Value
                        }
                    }
                }
                if ($timeoutConfig.Count -eq 0) {
                    $timeoutConfig = $null
                }

                $collectorPsVersion = if ($auditSession.CollectorPsVersion) {
                    $auditSession.CollectorPsVersion
                } else {
                    $auditSession.LocalPSVersion
                }

                $collectorResults = Invoke-CollectorExecution `
                    -Server $server `
                    -Collectors $auditSession.CompatibleCollectors `
                    -Parallelism $serverResults.ParallelismUsed `
                    -TimeoutSeconds $serverResults.TimeoutUsed `
                    -TimeoutConfig $timeoutConfig `
                    -PSVersion $collectorPsVersion `
                    -IsSlowServer:($serverResults.PerformanceProfile.ResourceConstraints.Count -gt 0) `
                    -DryRun:$DryRun `
                    -CollectorPath $CollectorPath

                # Aggregate results
                foreach ($result in $collectorResults) {
                    $serverResults.Collectors += $result
                    $serverResults.CollectorsSummary.Executed += 1

                    if ($result.Status -eq 'SUCCESS') {
                        $serverResults.CollectorsSummary.Succeeded += 1
                    } elseif ($result.Status -eq 'FAILED') {
                        $serverResults.CollectorsSummary.Failed += 1
                        $serverResults.Success = $false
                    } elseif ($result.Status -eq 'SKIPPED') {
                        $serverResults.CollectorsSummary.Skipped += 1
                    }

                    if ($result.Errors -and $result.Errors.Count -gt 0) {
                        foreach ($err in $result.Errors) {
                            $serverResults.Errors += (Convert-ErrorForReport -ErrorInput $err)
                        }
                    }
                }

            } catch {
                Write-AuditLog "Server audit failed: $_" -Level Error
                $serverResults.Success = $false
                $serverResults.Errors += (Convert-ErrorForReport -ErrorInput $_)
            } finally {
                $serverStopwatch.Stop()
                $serverResults.ExecutionEndTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $serverResults.ExecutionTimeSeconds = [Math]::Round($serverStopwatch.Elapsed.TotalSeconds, 2)

                if (-not $SkipPerformanceProfile -and -not $PersistPerformanceProfileCache) {
                    try {
                        $removed = Remove-ServerCapabilityCache -ComputerName $server
                        if ($removed) {
                            Write-AuditLog "Cleared performance profile cache for $server" -Level Verbose
                        }
                    } catch {
                        Write-AuditLog "Failed to clear performance profile cache for $server: $_" -Level Warning
                    }
                }
            }

            # Add to audit results / stream
            Update-AuditSummaryCounters -Counters $auditSession.SummaryCounters -ServerResult $serverResults

            if ($auditSession.StreamingWriter) {
                $null = $auditSession.StreamingWriter.AddResult($serverResults)
            }
            else {
                $auditSession.AuditResults.Servers += $serverResults
            }
            
            Write-AuditLog "Server audit complete in $($serverResults.ExecutionTimeSeconds)s: $($serverResults.CollectorsSummary.Succeeded)/$($serverResults.CollectorsSummary.Total) collectors succeeded" -Level Information
        }
    }

    end {
        # ====== STAGE 3: FINALIZE ======
        Write-AuditLog "STAGE 3: FINALIZE (Aggregate Results)" -Level Information

        try {
            if ($auditSession.StreamingWriter -and -not $auditSession.StreamingWriter.IsFinalized) {
                $streamFilePath = $auditSession.StreamingWriter.Finalize()
                $auditSession.AuditResults.Streaming.StreamFile = $streamFilePath
                $auditSession.AuditResults.Streaming.Statistics = $auditSession.StreamingWriter.GetStatistics()
            }

            # Calculate summary statistics
            $serverCollection = @($auditSession.AuditResults.Servers)
            if ($serverCollection.Count -gt 0) {
                $successfulServers = ($serverCollection | Where-Object { $_.Success -eq $true }).Count
                $failedServers = $serverCollection.Count - $successfulServers
                $auditSession.AuditResults.Summary = @{
                    TotalServers             = $serverCollection.Count
                    SuccessfulServers        = $successfulServers
                    FailedServers            = $failedServers
                    TotalCollectorsExecuted  = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Executed } | Measure-Object -Sum).Sum
                    TotalCollectorsSucceeded = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Succeeded } | Measure-Object -Sum).Sum
                    TotalCollectorsFailed    = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Failed } | Measure-Object -Sum).Sum
                    AverageFetchTimeSeconds  = [Math]::Round(($serverCollection | ForEach-Object { $_.ExecutionTimeSeconds } | Measure-Object -Average).Average, 2)
                    DurationSeconds          = [Math]::Round(((Get-Date) - $auditSession.StartTime).TotalSeconds, 2)
                }
            }
            elseif ($auditSession.SummaryCounters.TotalServers -gt 0) {
                $successfulServers = [int]$auditSession.SummaryCounters.SuccessfulServers
                $failedServers = [Math]::Max(0, $auditSession.SummaryCounters.TotalServers - $successfulServers)
                $auditSession.AuditResults.Summary = @{
                    TotalServers             = $auditSession.SummaryCounters.TotalServers
                    SuccessfulServers        = $successfulServers
                    FailedServers            = $failedServers
                    TotalCollectorsExecuted  = $auditSession.SummaryCounters.TotalCollectorsExecuted
                    TotalCollectorsSucceeded = $auditSession.SummaryCounters.TotalCollectorsSucceeded
                    TotalCollectorsFailed    = $auditSession.SummaryCounters.TotalCollectorsFailed
                    AverageFetchTimeSeconds  = if ($auditSession.SummaryCounters.TotalServers -gt 0) { [Math]::Round($auditSession.SummaryCounters.TotalExecutionTimeSeconds / $auditSession.SummaryCounters.TotalServers, 2) } else { 0 }
                    DurationSeconds          = [Math]::Round(((Get-Date) - $auditSession.StartTime).TotalSeconds, 2)
                }
            }
            else {
                $auditSession.AuditResults.Summary = @{
                    TotalServers             = 0
                    SuccessfulServers        = 0
                    FailedServers            = 0
                    TotalCollectorsExecuted  = 0
                    TotalCollectorsSucceeded = 0
                    TotalCollectorsFailed    = 0
                    AverageFetchTimeSeconds  = 0
                    DurationSeconds          = [Math]::Round(((Get-Date) - $auditSession.StartTime).TotalSeconds, 2)
                }
            }

            # Export results
            Write-AuditLog "Exporting audit results to $OutputPath..." -Level Information
            Export-AuditResults `
                -Results $auditSession.AuditResults `
                -OutputPath $OutputPath `
                -SkipServerDetails:$DryRun

            # Display summary
            Write-AuditLog "====================================" -Level Information
            Write-AuditLog "=== Audit Summary ===" -Level Information
            Write-AuditLog "Servers audited: $($auditSession.AuditResults.Summary.TotalServers)" -Level Information
            Write-AuditLog "Successful: $($auditSession.AuditResults.Summary.SuccessfulServers) | Failed: $($auditSession.AuditResults.Summary.FailedServers)" -Level Information
            Write-AuditLog "Collectors executed: $($auditSession.AuditResults.Summary.TotalCollectorsSucceeded)/$($auditSession.AuditResults.Summary.TotalCollectorsExecuted)" -Level Information
            Write-AuditLog "Duration: $($auditSession.AuditResults.Summary.DurationSeconds)s" -Level Information
            Write-AuditLog "Results exported to: $OutputPath" -Level Information

            # M-009: Stop resource monitoring
            if ($auditSession.ResourceMonitorJob) {
                try {
                    Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
                    $resourceStats = Get-AuditResourceStatistics -ErrorAction SilentlyContinue
                    if ($resourceStats) {
                        Write-AuditLog "Resource Monitoring: Throttle events=$($resourceStats.TotalThrottleEvents) Recovery events=$($resourceStats.TotalRecoveryEvents)" -Level Verbose
                    }
                }
                catch {
                    Write-AuditLog "Failed to stop resource monitoring: $_" -Level Warning
                }
            }

            return $auditSession.AuditResults

        } catch {
            Write-AuditLog "Finalization failed: $_" -Level Error
            throw
        }
    }
}

<#
.SYNOPSIS
    Executes collectors for a single server with adaptive parallelism.

.NOTES
    Internal function used by Invoke-ServerAudit.
    Handles PS version-specific execution, timeout management, and error recovery.
#>
function Invoke-CollectorExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Server,

        [Parameter(Mandatory=$true)]
        [object[]]$Collectors,

        [Parameter(Mandatory=$true)]
        [int]$Parallelism,

        [Parameter(Mandatory=$true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory=$false)]
        [hashtable]$TimeoutConfig,

        [Parameter(Mandatory=$false)]
        [string]$PSVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)",

        [Parameter(Mandatory=$false)]
        [switch]$IsSlowServer,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$true)]
        [string]$CollectorPath
    )

    $results = @()
    try {
        $psVersionParsed = [version]$PSVersion
    } catch {
        $psVersionParsed = [version]'2.0'
    }
    $psVersionDisplay = $psVersionParsed.ToString()
    $psVersionMajor = $psVersionParsed.Major

    # PS2 or single-threaded mode
    if ($PSVersionTable.PSVersion.Major -le 2 -or $Parallelism -le 1) {
        Write-AuditLog "Using sequential execution (PS $psVersionDisplay or Parallelism=1)" -Level Verbose

        foreach ($collector in $Collectors) {
            # Calculate adaptive timeout for this collector
            $collectorTimeout = $TimeoutSeconds
            if ($TimeoutConfig) {
                $collectorTimeout = Get-AdjustedTimeout `
                    -CollectorName $collector.name `
                    -PSVersion $psVersionMajor `
                    -TimeoutConfig $TimeoutConfig `
                    -IsSlowServer:$IsSlowServer
            }

            $collectorResult = Invoke-SingleCollector `
                -Server $Server `
                -Collector $collector `
                -TimeoutSeconds $collectorTimeout `
                -DryRun:$DryRun `
                -CollectorPath $CollectorPath `
                -PSVersion $psVersionDisplay

            $results += $collectorResult
        }
    } else {
        # PS3+ parallel execution via runspace pool
        Write-AuditLog "Using parallel execution ($Parallelism jobs)" -Level Verbose

        $results = Invoke-ParallelCollectors `
            -Server $Server `
            -Collectors $Collectors `
            -MaxJobs $Parallelism `
            -TimeoutSeconds $TimeoutSeconds `
            -TimeoutConfig $TimeoutConfig `
            -PSVersion $psVersionDisplay `
            -IsSlowServer:$IsSlowServer `
            -DryRun:$DryRun `
            -CollectorPath $CollectorPath `
            -CollectorHelperModulePath $script:CollectorHelperModulePath
    }

    return $results
}

<#
.SYNOPSIS
    Executes a single collector with timeout and error handling.
#>
function Invoke-SingleCollector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Server,

        [Parameter(Mandatory=$true)]
        [object]$Collector,

        [Parameter(Mandatory=$true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$true)]
        [string]$CollectorPath,

        [Parameter(Mandatory=$true)]
        [string]$PSVersion
    )

    $result = @{
        Name           = $Collector.name
        DisplayName    = $Collector.displayName
        Status         = 'PENDING'
        ExecutionTime  = 0
        Data           = $null
        Errors         = @()
    }

    try {
        Write-AuditLog "  Running: $($Collector.displayName)..." -NoNewline -Level Information
        # Variant selection and logging
        $requestedVersion = $PSVersion
        $variant = Get-CollectorVariant -Collector $Collector -PSVersion $requestedVersion
        $baselineVariant = $Collector.filename
        $collectorScriptPath = Join-Path -Path $CollectorPath -ChildPath $variant
        if ($variant -ne $baselineVariant) {
            Write-AuditLog " (variant: $variant)" -Level Verbose
        } else {
            Write-AuditLog " (baseline: $variant)" -Level Verbose
        }
        if ($DryRun) {
            Write-AuditLog " [DRY-RUN -> $variant]" -Level Information
            $result.Status = 'DRY-RUN'
            return $result
        }
        # Validate collector exists
        if (-not (Test-Path -LiteralPath $collectorScriptPath)) {
            throw "Collector not found: $collectorScriptPath"
        }

        # Validate dependencies
        if (-not (Test-CollectorDependencies -Collector $Collector)) {
            Write-AuditLog " [SKIPPED - Dependencies]" -Level Information
            $result.Status = 'SKIPPED'
            $result.Errors += "Missing dependencies: $($Collector.dependencies -join ', ')"
            return $result
        }

        # Execute collector
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $collectorOutput = & $collectorScriptPath -ComputerName $Server -ErrorAction Stop

            $stopwatch.Stop()
            $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

            if ($collectorOutput -and $collectorOutput.Success) {
                Write-AuditLog " [OK - $($result.ExecutionTime)s]" -Level Information
                $result.Status = 'SUCCESS'
                $result.Data = $collectorOutput.Data
            } else {
                Write-AuditLog " [FAILED]" -Level Information
                $result.Status = 'FAILED'
                if ($collectorOutput.Errors) {
                    foreach ($err in $collectorOutput.Errors) {
                        $result.Errors += (Convert-ErrorForReport -ErrorInput $err)
                    }
                }
            }
        } catch {
            $stopwatch.Stop()
            $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
            Write-AuditLog " [ERROR - $($result.ExecutionTime)s]" -Level Information
            $result.Status = 'FAILED'
            $result.Errors += (Convert-ErrorForReport -ErrorInput $_)
        }

    } catch {
        Write-AuditLog " [ERROR]" -Level Information
        $result.Status = 'FAILED'
        $result.Errors += (Convert-ErrorForReport -ErrorInput $_)
    }

    return $result
}

<#
.SYNOPSIS
    Executes collectors in parallel via runspace pool (PS3+).
#>
function Invoke-ParallelCollectors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Server,

        [Parameter(Mandatory=$true)]
        [object[]]$Collectors,

        [Parameter(Mandatory=$true)]
        [int]$MaxJobs,

        [Parameter(Mandatory=$true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory=$false)]
        [hashtable]$TimeoutConfig,

        [Parameter(Mandatory=$false)]
        [switch]$IsSlowServer,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$true)]
        [string]$CollectorPath,

        [Parameter(Mandatory=$true)]
        [string]$PSVersion,

        [Parameter(Mandatory=$false)]
        [string]$CollectorHelperModulePath
    )

    try {
        $psVersionParsed = [version]$PSVersion
    } catch {
        $psVersionParsed = [version]'2.0'
    }
    $psVersionDisplay = $psVersionParsed.ToString()
    $psVersionMajor = $psVersionParsed.Major

    $initialSession = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($funcName in @('Invoke-SingleCollector', 'Write-AuditLog', 'Convert-ErrorForReport')) {
        $func = Get-Command -Name $funcName -CommandType Function -ErrorAction Stop
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry ($funcName, $func.Definition)
        $initialSession.Commands.Add($entry)
    }

    # Create runspace pool
    $RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxJobs,
        $initialSession
    )
    $RunspacePool.Open()

    $jobs = @()
    $results = @()

    try {
        # Queue collector jobs
        foreach ($collector in $Collectors) {
            $collectorTimeout = $TimeoutSeconds
            if ($TimeoutConfig) {
                $collectorTimeout = Get-AdjustedTimeout `
                    -CollectorName $collector.name `
                    -PSVersion $psVersionMajor `
                    -TimeoutConfig $TimeoutConfig `
                    -IsSlowServer:$IsSlowServer
            }

            $powerShell = [System.Management.Automation.PowerShell]::Create()
            $powerShell.RunspacePool = $RunspacePool

            # Add collector invocation script
            [void]$powerShell.AddScript({
                param($Server, $Collector, $CollectorTimeout, $CollectorPath, $PSVersion, $CollectorModulePath, $DryRunFlag)

                if (-not $CollectorModulePath -or -not (Test-Path -LiteralPath $CollectorModulePath)) {
                    throw "Collector helper module not found at $CollectorModulePath"
                }

                Import-Module -Name $CollectorModulePath -Force -ErrorAction Stop | Out-Null

                Invoke-SingleCollector `
                    -Server $Server `
                    -Collector $Collector `
                    -TimeoutSeconds $CollectorTimeout `
                    -DryRun:$DryRunFlag `
                    -CollectorPath $CollectorPath `
                    -PSVersion $PSVersion
            })

            $powerShell.AddArgument($Server)
            $powerShell.AddArgument($Collector)
            $powerShell.AddArgument($collectorTimeout)
            $powerShell.AddArgument($CollectorPath)
            $powerShell.AddArgument($psVersionDisplay)
            $powerShell.AddArgument($CollectorHelperModulePath)
            $powerShell.AddArgument($DryRun)

            $asyncHandle = $powerShell.BeginInvoke()

            $jobs += @{
                PowerShell   = $powerShell
                AsyncHandle  = $asyncHandle
                Collector    = $Collector
                StartTime    = Get-Date
            }
        }

        # Collect results with timeout management
        foreach ($job in $jobs) {
            $elapsed = (Get-Date) - $job.StartTime

            try {
                $jobResult = $job.PowerShell.EndInvoke($job.AsyncHandle)
                $results += $jobResult
            } catch {
                $results += @{
                    Name           = $job.Collector.name
                    DisplayName    = $job.Collector.displayName
                    Status         = 'FAILED'
                    ExecutionTime  = [Math]::Round($elapsed.TotalSeconds, 2)
                    Data           = $null
                    Errors         = @($_)
                }
            } finally {
                $job.PowerShell.Dispose()
            }
        }

    } finally {
        $RunspacePool.Close()
        $RunspacePool.Dispose()
    }

    return $results
}

<#
.SYNOPSIS
    Initializes audit logging for the session.
#>
function Initialize-AuditLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$false)]
        [string]$LogLevel = 'Information'
    )

    $script:AuditLogFile = Join-Path -Path $env:TEMP -ChildPath "SAT_$SessionId.log"
    $script:AuditLogLevel = $LogLevel
}

<#
.SYNOPSIS
    Writes audit log entry (to file and console).
#>
function Write-AuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [Parameter()]
        [switch]$NoNewline
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to file
    if ($script:AuditLogFile) {
        Add-Content -LiteralPath $script:AuditLogFile -Value $logEntry -ErrorAction SilentlyContinue
    }

    # Write to console based on level
    switch ($Level) {
        'Verbose' {
            if ($NoNewline) {
                Write-Host $Message -ForegroundColor DarkGray -NoNewline
            } else {
                Write-Verbose $Message
            }
        }
        'Information' {
            if ($NoNewline) {
                Write-Host $Message -ForegroundColor Cyan -NoNewline
            } else {
                Write-Host $Message -ForegroundColor Cyan
            }
        }
        'Warning' {
            if ($NoNewline) {
                Write-Host $Message -ForegroundColor Yellow -NoNewline
            } else {
                Write-Host $Message -ForegroundColor Yellow
            }
        }
        'Error' {
            if ($NoNewline) {
                Write-Host $Message -ForegroundColor Red -NoNewline
            } else {
                Write-Host $Message -ForegroundColor Red
            }
        }
    }
}

<#
.SYNOPSIS
    Gets local OS version from registry/WMI.
#>
function Get-OSVersion {
    [CmdletBinding()]
    param()

    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            return (Get-WindowsVersionFromBuild -BuildNumber $os.BuildNumber)
        } else {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
            return (Get-WindowsVersionFromBuild -BuildNumber $os.BuildNumber)
        }
    } catch {
        return 'Unknown'
    }
}

<#
.SYNOPSIS
    Exports audit results to JSON, CSV, and HTML.
#>
function Export-AuditResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Results,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath,

        [Parameter()]
        [switch]$SkipServerDetails
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Export JSON (raw data)
    $jsonPath = Join-Path -Path $OutputPath -ChildPath "audit_$timestamp.json"
    $hasServers = $Results.ContainsKey('Servers') -and $Results.Servers
    $shouldExportFull = -not $SkipServerDetails -and $hasServers -and $Results.Servers.Count -gt 0
    try {
        if ($shouldExportFull) {
            $metaProperties = @(
                @{ Name = 'PSVersion';           Value = $Results.PSVersion;           Depth = 2 },
                        @{ Name = 'CollectorPSVersion';  Value = $Results.CollectorPSVersion;  Depth = 2 },
                @{ Name = 'SessionId';           Value = $Results.SessionId;           Depth = 2 },
                @{ Name = 'Timestamp';           Value = if ($Results.Timestamp) { [string]$Results.Timestamp } else { $null }; Depth = 2 },
                @{ Name = 'Summary';             Value = if ($Results.Summary) { ConvertTo-HashtableRecursive -InputObject $Results.Summary } else { $null }; Depth = 8 },
                @{ Name = 'PerformanceProfiles'; Value = if ($Results.PerformanceProfiles) { ConvertTo-HashtableRecursive -InputObject $Results.PerformanceProfiles } else { @() }; Depth = 8 }
            )

            $writer = New-Object System.IO.StreamWriter($jsonPath, $false, [System.Text.Encoding]::UTF8)
            try {
                $writer.WriteLine('{')
                for ($i = 0; $i -lt $metaProperties.Count; $i++) {
                    $prop = $metaProperties[$i]
                    $valueJson = $prop.Value | ConvertTo-Json -Depth $prop.Depth -Compress
                    $writer.WriteLine("  `"$($prop.Name)`": $valueJson,")
                }

                $writer.WriteLine('  "Servers": [')
                for ($i = 0; $i -lt $Results.Servers.Count; $i++) {
                    $serverResult = $Results.Servers[$i]
                    $serverSerializable = ConvertTo-HashtableRecursive -InputObject $serverResult
                    $serverSerializable['Errors'] = Convert-ErrorsForExport -Errors $serverResult.Errors
                    $serverJson = $serverSerializable | ConvertTo-Json -Depth 12 -Compress
                    if ($i -lt ($Results.Servers.Count - 1)) {
                        $writer.WriteLine("    $serverJson,")
                    }
                    else {
                        $writer.WriteLine("    $serverJson")
                    }
                }
                $writer.WriteLine('  ]')
                $writer.WriteLine('}')
            }
            finally {
                $writer.Dispose()
            }
        }
        else {
            $summaryOnly = [ordered]@{
                PSVersion           = $Results.PSVersion
                        CollectorPSVersion  = $Results.CollectorPSVersion
                SessionId           = $Results.SessionId
                Timestamp           = $Results.Timestamp
                Summary             = $Results.Summary
                PerformanceProfiles = $Results.PerformanceProfiles
                Servers             = @()
                Notes               = 'Server-level details omitted (dry run or no collector data).'
            }
            $summaryOnly | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding UTF8 -Force
        }
        Write-AuditLog "Exported: $jsonPath" -Level Verbose
    } catch {
        Write-AuditLog "Failed to export JSON: $_" -Level Warning
    }

    # Export CSV (per-server summary)
    $csvPath = Join-Path -Path $OutputPath -ChildPath "audit_summary_$timestamp.csv"
    try {
        if (-not $SkipServerDetails -and $hasServers -and $Results.Servers.Count -gt 0) {
            $Results.Servers | Select-Object `
                ComputerName,
                Success,
                ParallelismUsed,
                TimeoutUsed,
                ExecutionTimeSeconds,
                @{Name='CollectorsSucceeded'; Expression={$_.CollectorsSummary.Succeeded}},
                @{Name='CollectorsFailed'; Expression={$_.CollectorsSummary.Failed}} |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Force
        }
        else {
            "ComputerName,Success,ParallelismUsed,TimeoutUsed,ExecutionTimeSeconds,CollectorsSucceeded,CollectorsFailed" | `
                Out-File -LiteralPath $csvPath -Encoding UTF8 -Force
        }

        Write-AuditLog "Exported: $csvPath" -Level Verbose
    } catch {
        Write-AuditLog "Failed to export CSV: $_" -Level Warning
    }

    # Generate per-server HTML reports and index
    if (-not $SkipServerDetails -and $hasServers -and $Results.Servers.Count -gt 0) {
        try {
            $companyName = if ($Results.CompanyName) { $Results.CompanyName } else { 'IT Audit' }
            $reportManifest = Publish-ServerReports -Results $Results -OutputPath $OutputPath -Timestamp $timestamp -CompanyName $companyName
            if ($reportManifest -and $reportManifest.Count -gt 0) {
                Write-AuditLog "Generated $($reportManifest.Count) HTML report(s) at $(Join-Path $OutputPath 'reports')" -Level Information
            }
        } catch {
            Write-AuditLog "Failed to generate HTML reports: $_" -Level Warning
        }
    }

    # Display summary table
    Write-Host "`n" -ForegroundColor Cyan
    $Results.Servers | Select-Object `
        ComputerName,
        Success,
        ParallelismUsed,
        @{Name='Collectors'; Expression={"$($_.CollectorsSummary.Succeeded)/$($_.CollectorsSummary.Total)"}},
        ExecutionTimeSeconds |
    Format-Table -AutoSize
}

# Auto-run when executed directly (not imported as a module)
if (-not $ExecutionContext.SessionState.Module) {
    return Invoke-ServerAudit @PSBoundParameters
}

# Export public functions when loaded as a module
if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function @('Invoke-ServerAudit')
}