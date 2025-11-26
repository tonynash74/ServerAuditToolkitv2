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

$moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'ServerAuditToolkitV2.psd1'
if (Test-Path -LiteralPath $moduleManifestPath) {
    try {
        Import-Module -Name $moduleManifestPath -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Failed to import ServerAuditToolkitV2 module: $_"
    }
} else {
    Write-Warning "Module manifest not found at $moduleManifestPath."
}

$MonitorScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'src\Private\Monitor-AuditResources.ps1'
if (Test-Path -LiteralPath $MonitorScriptPath) {
    . $MonitorScriptPath
} else {
    Write-Warning "Monitor-AuditResources.ps1 not found at $MonitorScriptPath. Resource auto-throttling will be unavailable."
}

$CollectorMetadataScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'src\Collectors\Get-CollectorMetadata.ps1'
if (Test-Path -LiteralPath $CollectorMetadataScriptPath) {
    . $CollectorMetadataScriptPath
} else {
    Write-Warning "Get-CollectorMetadata.ps1 not found at $CollectorMetadataScriptPath. Collector discovery will fail."
}

$TestAuditParametersPath = Join-Path -Path $PSScriptRoot -ChildPath 'src\\Private\\Test-AuditParameters.ps1'
if (Test-Path -LiteralPath $TestAuditParametersPath) {
    . $TestAuditParametersPath
} else {
    Write-Warning "Test-AuditParameters.ps1 not found at $TestAuditParametersPath. Parameter validation will be skipped."
}

$StreamingWriterPath = Join-Path -Path $PSScriptRoot -ChildPath 'src\\Private\\New-StreamingOutputWriter.ps1'
if (Test-Path -LiteralPath $StreamingWriterPath) {
    . $StreamingWriterPath
} else {
    Write-Warning "New-StreamingOutputWriter.ps1 not found at $StreamingWriterPath. Streaming output will be unavailable."
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

    if ($ServerResult.Success) {
        $Counters.SuccessfulServers++
    }
    else {
        $Counters.FailedServers++
    }

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
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [Alias('Name', 'Server')]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory=$false)]
        [string[]]$Collectors,

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
            AuditResults           = @{
                Servers             = @()
                Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                PSVersion           = $null
                SessionId           = $null
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

        # Resolve collector path
        if ([string]::IsNullOrEmpty($CollectorPath)) {
            $collectorCandidates = @(
                (Join-Path -Path $PSScriptRoot -ChildPath 'src\Collectors'),
                (Join-Path -Path $PSScriptRoot -ChildPath '..\collectors')
            )

            $CollectorPath = $collectorCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
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
            $effectivePsVersion = $auditSession.LocalPSVersion
            try {
                $parsedVersion = [version]$auditSession.LocalPSVersion
                if ($parsedVersion.Major -ge 6) {
                    $effectivePsVersion = '5.1'
                    Write-AuditLog "No PS$($parsedVersion.Major) collectors defined; falling back to PS 5.1 compatibility set." -Level Warning
                }
            } catch {}

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
                $auditSession.CompatibleCollectors = $auditSession.CompatibleCollectors | Where-Object { $_.name -in $Collectors }

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
                -Parallel $true `
                -ThrottleLimit 3 `
                -Verbose:($LogLevel -eq 'Verbose')
            
            # Log health check results
            Write-AuditLog "Health check completed: Passed=$($healthReport.Summary.Passed) Failed=$($healthReport.Summary.Failed) Warnings=$($healthReport.Summary.Warnings)" -Level Information
            
            if (-not $healthReport.IsHealthy) {
                Write-AuditLog "⚠ Health check warnings detected:" -Level Warning
                foreach ($issue in $healthReport.Issues) {
                    Write-AuditLog "  - $issue" -Level Warning
                }
                
                if ($healthReport.Summary.Failed -gt 0) {
                    Write-AuditLog "❌ Critical health check failures detected. Audit cannot proceed without addressing these issues:" -Level Error
                    foreach ($remediation in $healthReport.Remediation | Select-Object -Unique) {
                        Write-AuditLog "  💡 $remediation" -Level Error
                    }
                    throw "Pre-flight health check failed for $($healthReport.Summary.Failed) server(s)"
                }
            }
            else {
                Write-AuditLog "✓ All servers passed health checks. Proceeding with audit." -Level Information
            }
            
            # Store health report in audit session for later reporting
            $auditSession.HealthReport = $healthReport
            
        } catch {
            Write-AuditLog "Health check stage failed: $_" -Level Error
            throw
        }
        
        foreach ($server in $ComputerName) {
            Write-AuditLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level Information
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
                                    Write-AuditLog "  ⚠ $_" -Level Warning
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
                    $timeoutConfig = $auditSession.Config.execution.timeout.collectorTimeouts
                }

                $collectorResults = Invoke-CollectorExecution `
                    -Server $server `
                    -Collectors $auditSession.CompatibleCollectors `
                    -Parallelism $serverResults.ParallelismUsed `
                    -TimeoutSeconds $serverResults.TimeoutUsed `
                    -TimeoutConfig $timeoutConfig `
                    -PSVersion $auditSession.LocalPSVersion `
                    -IsSlowServer $($serverResults.PerformanceProfile.ResourceConstraints.Count -gt 0) `
                    -DryRun:$DryRun `
                    -CollectorPath $CollectorPath `
                    -PSVersion $auditSession.LocalPSVersion

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
                        $serverResults.Errors += $result.Errors
                    }
                }

            } catch {
                Write-AuditLog "Server audit failed: $_" -Level Error
                $serverResults.Success = $false
                $serverResults.Errors += $_
            } finally {
                $serverStopwatch.Stop()
                $serverResults.ExecutionEndTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                $serverResults.ExecutionTimeSeconds = [Math]::Round($serverStopwatch.Elapsed.TotalSeconds, 2)
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
            $serverCollection = $auditSession.AuditResults.Servers
            if ($serverCollection.Count -gt 0) {
                $auditSession.AuditResults.Summary = @{
                    TotalServers             = $serverCollection.Count
                    SuccessfulServers        = ($serverCollection | Where-Object { $_.Success }).Count
                    FailedServers            = ($serverCollection | Where-Object { -not $_.Success }).Count
                    TotalCollectorsExecuted  = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Executed } | Measure-Object -Sum).Sum
                    TotalCollectorsSucceeded = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Succeeded } | Measure-Object -Sum).Sum
                    TotalCollectorsFailed    = ($serverCollection | ForEach-Object { $_.CollectorsSummary.Failed } | Measure-Object -Sum).Sum
                    AverageFetchTimeSeconds  = [Math]::Round(($serverCollection | ForEach-Object { $_.ExecutionTimeSeconds } | Measure-Object -Average).Average, 2)
                    DurationSeconds          = [Math]::Round(((Get-Date) - $auditSession.StartTime).TotalSeconds, 2)
                }
            }
            elseif ($auditSession.SummaryCounters.TotalServers -gt 0) {
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
            Export-AuditResults -Results $auditSession.AuditResults -OutputPath $OutputPath

            # Display summary
            Write-AuditLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level Information
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
        [int]$PSVersion = $PSVersionTable.PSVersion.Major,

        [Parameter(Mandatory=$false)]
        [switch]$IsSlowServer,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun,

        [Parameter(Mandatory=$true)]
        [string]$CollectorPath
    )

    $results = @()

    # PS2 or single-threaded mode
    if ($PSVersionTable.PSVersion.Major -le 2 -or $Parallelism -le 1) {
        Write-AuditLog "Using sequential execution (PS $PSVersion or Parallelism=1)" -Level Verbose

        foreach ($collector in $Collectors) {
            # Calculate adaptive timeout for this collector
            $collectorTimeout = $TimeoutSeconds
            if ($TimeoutConfig) {
                $collectorTimeout = Get-AdjustedTimeout `
                    -CollectorName $collector.name `
                    -PSVersion $PSVersion `
                    -TimeoutConfig $TimeoutConfig `
                    -IsSlowServer:$IsSlowServer
            }

            $collectorResult = Invoke-SingleCollector `
                -Server $Server `
                -Collector $collector `
                -TimeoutSeconds $collectorTimeout `
                -DryRun:$DryRun `
                -CollectorPath $CollectorPath `
                -PSVersion $PSVersion

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
            -PSVersion $PSVersion `
            -IsSlowServer:$IsSlowServer `
            -DryRun:$DryRun `
            -CollectorPath $CollectorPath
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
        # Get optimal variant
        $variant = Get-CollectorVariant -Collector $Collector -PSVersion $PSVersion
        $collectorScriptPath = Join-Path -Path $CollectorPath -ChildPath $variant

        Write-AuditLog "  Running: $($Collector.displayName)..." -NoNewline -Level Information

        if ($DryRun) {
            Write-AuditLog " [DRY-RUN]" -Level Information
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
                    $result.Errors += $collectorOutput.Errors
                }
            }
        } catch {
            $stopwatch.Stop()
            $result.ExecutionTime = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
            Write-AuditLog " [ERROR - $($result.ExecutionTime)s]" -Level Information
            $result.Status = 'FAILED'
            $result.Errors += $_
        }

    } catch {
        Write-AuditLog " [ERROR]" -Level Information
        $result.Status = 'FAILED'
        $result.Errors += $_
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
        [switch]$DryRun,

        [Parameter(Mandatory=$true)]
        [string]$CollectorPath,

        [Parameter(Mandatory=$true)]
        [string]$PSVersion
    )

    # Create runspace pool
    $RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxJobs,
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    )
    $RunspacePool.Open()

    $jobs = @()
    $results = @()

    try {
        # Queue collector jobs
        foreach ($collector in $Collectors) {
            $powerShell = [System.Management.Automation.PowerShell]::Create()
            $powerShell.RunspacePool = $RunspacePool

            # Add collector invocation script
            [void]$powerShell.AddScript({
                param($Server, $Collector, $TimeoutSeconds, $CollectorPath, $PSVersion, $ScriptRoot)

                # Re-import functions in runspace
                . (Join-Path -Path $ScriptRoot -ChildPath 'src\Collectors\Get-CollectorMetadata.ps1')

                Invoke-SingleCollector `
                    -Server $Server `
                    -Collector $Collector `
                    -TimeoutSeconds $TimeoutSeconds `
                    -DryRun:$false `
                    -CollectorPath $CollectorPath `
                    -PSVersion $PSVersion
            })

            $powerShell.AddArgument($Server)
            $powerShell.AddArgument($Collector)
            $powerShell.AddArgument($TimeoutSeconds)
            $powerShell.AddArgument($CollectorPath)
            $powerShell.AddArgument($PSVersion)
            $powerShell.AddArgument($PSScriptRoot)

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
        [string]$Level = 'Information'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to file
    if ($script:AuditLogFile) {
        Add-Content -LiteralPath $script:AuditLogFile -Value $logEntry -ErrorAction SilentlyContinue
    }

    # Write to console based on level
    switch ($Level) {
        'Verbose'   { Write-Verbose $Message }
        'Information' { Write-Host $Message -ForegroundColor Cyan }
        'Warning'   { Write-Host $Message -ForegroundColor Yellow }
        'Error'     { Write-Host $Message -ForegroundColor Red }
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
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Export JSON (raw data)
    $jsonPath = Join-Path -Path $OutputPath -ChildPath "audit_$timestamp.json"
    try {
        $Results | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $jsonPath -Encoding UTF8 -Force
        Write-AuditLog "Exported: $jsonPath" -Level Verbose
    } catch {
        Write-AuditLog "Failed to export JSON: $_" -Level Warning
    }

    # Export CSV (per-server summary)
    $csvPath = Join-Path -Path $OutputPath -ChildPath "audit_summary_$timestamp.csv"
    try {
        $Results.Servers | Select-Object `
            ComputerName,
            Success,
            ParallelismUsed,
            TimeoutUsed,
            ExecutionTimeSeconds,
            @{Name='CollectorsSucceeded'; Expression={$_.CollectorsSummary.Succeeded}},
            @{Name='CollectorsFailed'; Expression={$_.CollectorsSummary.Failed}} |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Force

        Write-AuditLog "Exported: $csvPath" -Level Verbose
    } catch {
        Write-AuditLog "Failed to export CSV: $_" -Level Warning
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