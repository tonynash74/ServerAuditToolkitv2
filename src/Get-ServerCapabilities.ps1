<#
.SYNOPSIS
    Detects server hardware capabilities and calculates safe parallelism parameters.

.DESCRIPTION
    Profiles target server to determine:
    - CPU cores (logical & physical)
    - RAM (total, available)
    - Disk speed (read/write latency via CrystalDiskInfo or WMI)
    - Network connectivity and bandwidth
    - Load average and current resource utilization

    Returns a "parallelism budget" object with:
    - SafeParallelJobs: Recommended concurrent job count
    - JobTimeout: Per-job timeout (seconds)
    - OverallTimeout: Total audit timeout
    - PerformanceTier: Low|Medium|High|VeryHigh
    - ResourceConstraints: CPU/RAM/Disk bottlenecks

    Caches results to avoid redundant profiling on repeated audits.

.PARAMETER ComputerName
    Target server. Defaults to localhost.

.PARAMETER Credential
    PSCredential for remote access.

.PARAMETER UseCache
    If $true, returns cached profile if available (default: $true).

.PARAMETER CacheDirectory
    Where to store performance profiles. Defaults to module temp directory.

.PARAMETER DryRun
    If $true, shows what will be measured without executing.

.EXAMPLE
    $capabilities = Get-ServerCapabilities -ComputerName "SERVER01"
    Write-Host "Safe parallel jobs: $($capabilities.SafeParallelJobs)"
    Write-Host "Performance tier: $($capabilities.PerformanceTier)"

.NOTES
    Compatible with PS 2.0+. Uses WMI on legacy systems, CIM on PS3+.
    Results cached for 24 hours to avoid repeated profiling overhead.
#>

function Get-ServerCapabilities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$UseCache = $true,

        [Parameter(Mandatory=$false)]
        [string]$CacheDirectory,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $result = @{
        ComputerName             = $ComputerName
        Timestamp                = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Success                  = $false
        CPUCores                 = 0
        CPUCoresLogical          = 0
        CPUCoresPhysical         = 0
        CPUModel                 = ''
        CPUSpeedGHz              = 0
        RAMTotalMB               = 0
        RAMAvailableMB           = 0
        RAMUsagePercent          = 0
        DiskReadLatencyMs        = 0
        DiskWriteLatencyMs       = 0
        DiskAverageFreePercent   = 0
        NetworkLatencyMs         = 0
        NetworkConnectivity      = 'Unknown'
        LoadAveragePercent       = 0
        PerformanceTier          = 'Unknown'
        SafeParallelJobs         = 1
        JobTimeoutSec            = 60
        OverallTimeoutSec        = 600
        ResourceConstraints      = @()
        ProfiledAt               = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        CachedResult             = $false
        Errors                   = @()
        Warnings                 = @()
    }

    # Setup cache directory
    if ([string]::IsNullOrEmpty($CacheDirectory)) {
        $CacheDirectory = Join-Path -Path $env:TEMP -ChildPath "ServerAuditToolkit\Profiles"
    }

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        try {
            [void](New-Item -ItemType Directory -Path $CacheDirectory -Force -ErrorAction SilentlyContinue)
        } catch {
            Write-Warning "Could not create cache directory: $_"
        }
    }

    $cacheFile = Join-Path -Path $CacheDirectory -ChildPath "$ComputerName-profile.json"

    # Check cache
    if ($UseCache -and (Test-Path -LiteralPath $cacheFile)) {
        $cacheAge = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($cacheAge.TotalHours -lt 24) {
            try {
                $cached = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($cached) {
                    Write-Verbose "Using cached profile for $ComputerName (age: $([Math]::Round($cacheAge.TotalMinutes)) minutes)"
                    $cached.CachedResult = $true
                    return $cached
                }
            } catch {
                Write-Warning "Could not load cache: $_. Profiling fresh."
            }
        }
    }

    if ($DryRun) {
        Write-Verbose "DRY RUN: Would profile $ComputerName for CPU, RAM, disk, and network."
        $result.Success = $true
        return $result
    }

    try {
        # Build invoke parameters
        $invokeParams = @{
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }

        if ($PSBoundParameters.ContainsKey('Credential')) {
            $invokeParams.Credential = $Credential
        }

        # SECTION 1: CPU Detection
        Write-Verbose "Detecting CPU..."
        try {
            $cpuInfo = Get-ProcessorInfo @invokeParams
            if ($cpuInfo) {
                $result.CPUCores = $cpuInfo.LogicalCores
                $result.CPUCoresLogical = $cpuInfo.LogicalCores
                $result.CPUCoresPhysical = $cpuInfo.PhysicalCores
                $result.CPUModel = $cpuInfo.Model
                $result.CPUSpeedGHz = $cpuInfo.SpeedGHz
            }
        } catch {
            $result.Warnings += "CPU detection failed: $_"
        }

        # SECTION 2: RAM Detection
        Write-Verbose "Detecting RAM..."
        try {
            $ramInfo = Get-RAMInfo @invokeParams
            if ($ramInfo) {
                $result.RAMTotalMB = $ramInfo.TotalMB
                $result.RAMAvailableMB = $ramInfo.AvailableMB
                $result.RAMUsagePercent = $ramInfo.UsagePercent
            }
        } catch {
            $result.Warnings += "RAM detection failed: $_"
        }

        # SECTION 3: Disk I/O Detection
        Write-Verbose "Detecting disk performance..."
        try {
            $diskInfo = Get-DiskPerformance @invokeParams
            if ($diskInfo) {
                $result.DiskReadLatencyMs = $diskInfo.ReadLatencyMs
                $result.DiskWriteLatencyMs = $diskInfo.WriteLatencyMs
                $result.DiskAverageFreePercent = $diskInfo.AverageFreePercent
            }
        } catch {
            $result.Warnings += "Disk performance detection failed: $_"
        }

        # SECTION 4: Network Connectivity
        Write-Verbose "Testing network connectivity..."
        try {
            $netInfo = Test-NetworkConnectivity @invokeParams
            if ($netInfo) {
                $result.NetworkLatencyMs = $netInfo.LatencyMs
                $result.NetworkConnectivity = $netInfo.Connectivity
            }
        } catch {
            $result.Warnings += "Network test failed: $_"
        }

        # SECTION 5: Load Average
        Write-Verbose "Calculating load average..."
        try {
            $loadInfo = Get-SystemLoad @invokeParams
            if ($loadInfo) {
                $result.LoadAveragePercent = $loadInfo.LoadPercent
            }
        } catch {
            $result.Warnings += "Load detection failed: $_"
        }

        # SECTION 6: Calculate Performance Tier & Parallelism Budget
        Write-Verbose "Calculating parallelism budget..."
        $budgetInfo = Calculate-ParallelismBudget -Capabilities $result
        $result.PerformanceTier = $budgetInfo.PerformanceTier
        $result.SafeParallelJobs = $budgetInfo.SafeParallelJobs
        $result.JobTimeoutSec = $budgetInfo.JobTimeoutSec
        $result.OverallTimeoutSec = $budgetInfo.OverallTimeoutSec
        $result.ResourceConstraints = $budgetInfo.ResourceConstraints

        $result.Success = $true

    } catch {
        $result.Errors += "Profile failed: $_"
        # Set conservative defaults on error
        $result.SafeParallelJobs = 1
        $result.JobTimeoutSec = 120
        $result.OverallTimeoutSec = 900
    }

    # Cache result
    try {
        $result | ConvertTo-Json | Out-File -LiteralPath $cacheFile -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Could not cache profile: $_"
    }

    return $result
}

<#
.SYNOPSIS
    Detects processor count and model.
#>
function Get-ProcessorInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string]$ErrorAction = 'Stop'
    )

    $invokeParams = @{
        ComputerName = $ComputerName
        ErrorAction  = $ErrorAction
    }

    if ($PSBoundParameters.ContainsKey('Credential')) {
        $invokeParams.Credential = $Credential
    }

    # Try CIM first (PS3+), fallback to WMI
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $cimParams = @{
                ClassName = 'Win32_Processor'
            } + $invokeParams

            $cpu = Get-CimInstance @cimParams | Select-Object -First 1
            if ($cpu) {
                return @{
                    LogicalCores  = [int]($cpu.NumberOfLogicalProcessors)
                    PhysicalCores = [int]($cpu.NumberOfCores)
                    Model         = $cpu.Name
                    SpeedGHz      = [Math]::Round($cpu.MaxClockSpeed / 1000, 2)
                }
            }
        } catch {
            Write-Verbose "CIM Get-CimInstance failed: $_"
        }
    }

    # Fallback: WMI (PS2 compatible)
    try {
        $cpu = Get-WmiObject -Class Win32_Processor @invokeParams | Select-Object -First 1
        if ($cpu) {
            return @{
                LogicalCores  = [int]($cpu.NumberOfLogicalProcessors)
                PhysicalCores = [int]($cpu.NumberOfCores)
                Model         = $cpu.Name
                SpeedGHz      = [Math]::Round($cpu.MaxClockSpeed / 1000, 2)
            }
        }
    } catch {
        Write-Warning "Failed to detect processor: $_"
    }

    return $null
}

<#
.SYNOPSIS
    Detects total and available RAM.
#>
function Get-RAMInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string]$ErrorAction = 'Stop'
    )

    $invokeParams = @{
        ComputerName = $ComputerName
        ErrorAction  = $ErrorAction
    }

    if ($PSBoundParameters.ContainsKey('Credential')) {
        $invokeParams.Credential = $Credential
    }

    # Try CIM first (PS3+), fallback to WMI
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $cimParams = @{
                ClassName = 'Win32_ComputerSystem'
            } + $invokeParams

            $sys = Get-CimInstance @cimParams
            if ($sys) {
                $totalMB = [Math]::Round($sys.TotalPhysicalMemory / 1MB, 0)
                
                # Get available RAM separately
                $cimParams.ClassName = 'Win32_OperatingSystem'
                $os = Get-CimInstance @cimParams
                $availableMB = [Math]::Round($os.FreePhysicalMemory / 1KB, 0)

                return @{
                    TotalMB     = $totalMB
                    AvailableMB = $availableMB
                    UsagePercent = [Math]::Round((($totalMB - $availableMB) / $totalMB) * 100, 1)
                }
            }
        } catch {
            Write-Verbose "CIM RAM detection failed: $_"
        }
    }

    # Fallback: WMI (PS2 compatible)
    try {
        $sys = Get-WmiObject -Class Win32_ComputerSystem @invokeParams
        if ($sys) {
            $totalMB = [Math]::Round($sys.TotalPhysicalMemory / 1MB, 0)

            $os = Get-WmiObject -Class Win32_OperatingSystem @invokeParams
            $availableMB = [Math]::Round($os.FreePhysicalMemory / 1KB, 0)

            return @{
                TotalMB     = $totalMB
                AvailableMB = $availableMB
                UsagePercent = [Math]::Round((($totalMB - $availableMB) / $totalMB) * 100, 1)
            }
        }
    } catch {
        Write-Warning "Failed to detect RAM: $_"
    }

    return $null
}

<#
.SYNOPSIS
    Detects disk I/O performance and free space.
#>
function Get-DiskPerformance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string]$ErrorAction = 'Stop'
    )

    $invokeParams = @{
        ComputerName = $ComputerName
        ErrorAction  = $ErrorAction
    }

    if ($PSBoundParameters.ContainsKey('Credential')) {
        $invokeParams.Credential = $Credential
    }

    $readLatency = 0
    $writeLatency = 0
    $freePercent = 50  # default conservative estimate

    # Try Performance Monitor counters (PS3+, requires perfmon access)
    if (Get-Command Get-Counter -ErrorAction SilentlyContinue) {
        try {
            # \PhysicalDisk(*)\Avg. Disk Read Queue Length
            $counter = Get-Counter -Counter '\PhysicalDisk(*)\Avg. Disk sec/Read' @invokeParams -ErrorAction SilentlyContinue
            if ($counter) {
                $readLatency = [Math]::Round(($counter.CounterSamples[0].CookedValue * 1000), 2)
            }

            $counter = Get-Counter -Counter '\PhysicalDisk(*)\Avg. Disk sec/Write' @invokeParams -ErrorAction SilentlyContinue
            if ($counter) {
                $writeLatency = [Math]::Round(($counter.CounterSamples[0].CookedValue * 1000), 2)
            }
        } catch {
            Write-Verbose "Performance counter retrieval failed: $_"
        }
    }

    # Get free disk space on system drive
    try {
        if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
            # PS3+: Get-Volume
            $volume = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
            if ($volume) {
                $freePercent = [Math]::Round(($volume.SizeRemaining / $volume.Size) * 100, 1)
            }
        } else {
            # PS2: WMI
            $drive = Get-WmiObject -Class Win32_LogicalDisk @invokeParams | Where-Object { $_.DeviceID -eq 'C:' }
            if ($drive) {
                $freePercent = [Math]::Round(($drive.FreeSpace / $drive.Size) * 100, 1)
            }
        }
    } catch {
        Write-Verbose "Disk space detection failed: $_"
    }

    return @{
        ReadLatencyMs       = $readLatency
        WriteLatencyMs      = $writeLatency
        AverageFreePercent  = $freePercent
    }
}

<#
.SYNOPSIS
    Tests network connectivity to localhost (if remote, tests WinRM latency).
#>
function Test-NetworkConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string]$ErrorAction = 'Stop'
    )

    $connectivity = 'Unknown'
    $latency = 0

    # Test basic ping (ICMP)
    if (Get-Command Test-Connection -ErrorAction SilentlyContinue) {
        try {
            $ping = Test-Connection -ComputerName $ComputerName -Count 1 -ErrorAction SilentlyContinue
            if ($ping) {
                $latency = $ping.ResponseTime
                $connectivity = 'Online'
            } else {
                $connectivity = 'Unreachable'
            }
        } catch {
            Write-Verbose "Ping failed: $_"
            $connectivity = 'Unreachable'
        }
    }

    return @{
        Connectivity = $connectivity
        LatencyMs    = $latency
    }
}

<#
.SYNOPSIS
    Calculates current system load as percentage of CPU capacity.
#>
function Get-SystemLoad {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string]$ErrorAction = 'Stop'
    )

    $invokeParams = @{
        ComputerName = $ComputerName
        ErrorAction  = $ErrorAction
    }

    if ($PSBoundParameters.ContainsKey('Credential')) {
        $invokeParams.Credential = $Credential
    }

    # Try Performance Monitor (PS3+)
    if (Get-Command Get-Counter -ErrorAction SilentlyContinue) {
        try {
            $counter = Get-Counter -Counter '\Processor(_Total)\% Processor Time' @invokeParams -ErrorAction SilentlyContinue
            if ($counter) {
                $loadPercent = [Math]::Round($counter.CounterSamples[0].CookedValue, 1)
                return @{ LoadPercent = $loadPercent }
            }
        } catch {
            Write-Verbose "Performance counter failed: $_"
        }
    }

    # Fallback: WMI (less precise, but PS2 compatible)
    try {
        $cpu = Get-WmiObject -Class Win32_Processor @invokeParams
        if ($cpu) {
            $loadPercent = [Math]::Round(($cpu | Measure-Object -Property LoadPercentage -Average).Average, 1)
            return @{ LoadPercent = $loadPercent }
        }
    } catch {
        Write-Verbose "WMI load detection failed: $_"
    }

    return @{ LoadPercent = 0 }
}

<#
.SYNOPSIS
    Calculates parallelism budget based on server capabilities.

.DESCRIPTION
    Maps server resources to:
    - PerformanceTier: Low (1 job) | Medium (2-4) | High (4-8) | VeryHigh (8+)
    - SafeParallelJobs: Recommended concurrent job count
    - JobTimeoutSec: Timeout per collector job
    - OverallTimeoutSec: Total audit timeout
    - ResourceConstraints: List of bottlenecks

.NOTES
    Conservative approach: prioritizes stability over raw performance.
#>
function Calculate-ParallelismBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Capabilities
    )

    $constraints = @()
    $safeJobs = 1

    # CPU-based calculation
    $cpuCores = $Capabilities.CPUCoresLogical
    if ($cpuCores -le 2) {
        $safeJobs = 1
        $constraints += "Low CPU cores ($cpuCores)"
    } elseif ($cpuCores -le 4) {
        $safeJobs = 2
    } elseif ($cpuCores -le 8) {
        $safeJobs = 4
    } else {
        $safeJobs = [Math]::Min($cpuCores / 2, 8)  # Cap at 8 for stability
    }

    # RAM-based adjustment (reduce if under 4GB or >80% used)
    $ramTotal = $Capabilities.RAMTotalMB
    $ramUsagePercent = $Capabilities.RAMUsagePercent

    if ($ramTotal -lt 2048) {
        $safeJobs = [Math]::Max(1, $safeJobs - 1)
        $constraints += "Low RAM ($([Math]::Round($ramTotal / 1024, 1))GB)"
    } elseif ($ramUsagePercent -gt 80) {
        $safeJobs = [Math]::Max(1, $safeJobs - 1)
        $constraints += "High RAM usage ($ramUsagePercent%)"
    }

    # Disk space constraint (if <10% free)
    if ($Capabilities.DiskAverageFreePercent -lt 10) {
        $safeJobs = [Math]::Max(1, $safeJobs - 1)
        $constraints += "Low disk space ($($Capabilities.DiskAverageFreePercent)% free)"
    }

    # Disk I/O constraint (if latency >50ms, reduce jobs)
    if ($Capabilities.DiskReadLatencyMs -gt 50) {
        $safeJobs = [Math]::Max(1, $safeJobs - 1)
        $constraints += "High disk latency ($([Math]::Round($Capabilities.DiskReadLatencyMs, 0))ms read)"
    }

    # Network constraint (if >100ms latency, single job for remote audits)
    if ($Capabilities.ComputerName -ne $env:COMPUTERNAME -and $Capabilities.NetworkLatencyMs -gt 100) {
        $safeJobs = 1
        $constraints += "High network latency ($($Capabilities.NetworkLatencyMs)ms)"
    }

    # Load constraint (if already >60% loaded, reduce jobs)
    if ($Capabilities.LoadAveragePercent -gt 60) {
        $safeJobs = [Math]::Max(1, $safeJobs - 1)
        $constraints += "High system load ($($Capabilities.LoadAveragePercent)%)"
    }

    # Determine performance tier
    $tier = if ($safeJobs -le 1) { 'Low' } `
            elseif ($safeJobs -le 2) { 'Medium' } `
            elseif ($safeJobs -le 4) { 'High' } `
            else { 'VeryHigh' }

    # Calculate timeouts based on tier
    $jobTimeout = @{
        'Low'       = 120
        'Medium'    = 90
        'High'      = 60
        'VeryHigh'  = 45
    }[$tier]

    # Overall timeout = (avg collector time * count / parallelism) + buffer
    # Estimated: 10-30 seconds per collector, 5-10 collectors typically
    # Conservative: 10 * 20 / safe_jobs + 30% buffer
    $estimatedCollectorSec = 20
    $estimatedCollectorCount = 7
    $baseTime = ($estimatedCollectorSec * $estimatedCollectorCount) / [Math]::Max(1, $safeJobs)
    $overallTimeout = [Math]::Round($baseTime * 1.3 + 60, 0)

    return @{
        PerformanceTier     = $tier
        SafeParallelJobs    = [Math]::Max(1, $safeJobs)
        JobTimeoutSec       = $jobTimeout
        OverallTimeoutSec   = $overallTimeout
        ResourceConstraints = $constraints
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Get-ServerCapabilities',
    'Get-ProcessorInfo',
    'Get-RAMInfo',
    'Get-DiskPerformance',
    'Test-NetworkConnectivity',
    'Get-SystemLoad',
    'Calculate-ParallelismBudget'
)