<#
.SYNOPSIS
    Loads and filters collector metadata based on server capabilities and PowerShell version.

.DESCRIPTION
    Reads collector-metadata.json and provides functions to:
    - List all collectors with metadata
    - Filter collectors by PowerShell version
    - Filter collectors by Windows OS version
    - Get optimal collector variant for current environment
    - Validate collector dependencies
    
    Caches metadata in memory with 5-minute TTL to reduce file I/O.

.PARAMETER MetadataPath
    Path to collector-metadata.json. Defaults to collectors folder in module root.

.PARAMETER Force
    If $true, bypass cache and reload from disk. Useful for testing or after config changes.

.EXAMPLE
    $metadata = Get-CollectorMetadata
    $compatibleCollectors = $metadata | Where-Object { $_.psVersions -contains '2.0' }

.EXAMPLE
    # Force reload from disk
    $metadata = Get-CollectorMetadata -Force

.NOTES
    Compatible with PowerShell 2.0+
    Caching: Metadata cached for 5 minutes by default. Use -Force to bypass cache.
#>

# Module-level cache (shared across all calls in same session)
$script:MetadataCache = @{
    Data = $null
    Timestamp = $null
    TTLSeconds = 300  # 5 minutes
}

function Get-CollectorMetadata {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string]$MetadataPath,
        
        [Parameter(Mandatory=$false)]
        [switch]$Force
    )

    # Check cache first (unless -Force specified)
    if (-not $Force -and $script:MetadataCache.Data -and $script:MetadataCache.Timestamp) {
        $cacheAge = (Get-Date) - $script:MetadataCache.Timestamp
        if ($cacheAge.TotalSeconds -lt $script:MetadataCache.TTLSeconds) {
            Write-Verbose "Metadata cache hit (age: $($cacheAge.TotalSeconds.ToString('F1'))s, TTL: $($script:MetadataCache.TTLSeconds)s)"
            return $script:MetadataCache.Data
        }
        else {
            Write-Verbose "Metadata cache expired (age: $($cacheAge.TotalSeconds.ToString('F1'))s)"
        }
    }
    elseif ($Force) {
        Write-Verbose "Metadata cache bypass (Force flag)"
    }

    # If not provided, assume standard module structure
    if ([string]::IsNullOrEmpty($MetadataPath)) {
        $ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
        $MetadataPath = Join-Path -Path $ModuleRoot -ChildPath "collectors\collector-metadata.json"
    }

    # Validate file exists
    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        Write-Error "Metadata file not found: $MetadataPath"
        return $null
    }

    # Load JSON (PS2-compatible approach)
    try {
        Write-Verbose "Loading metadata from: $MetadataPath"
        $jsonContent = Get-Content -LiteralPath $MetadataPath -Raw -ErrorAction Stop
        
        # PS2 doesn't have ConvertFrom-Json, so we use a fallback
        if ($PSVersionTable.PSVersion.Major -ge 3) {
            $metadata = $jsonContent | ConvertFrom-Json
        } else {
            # PS2 fallback: use basic JSON parsing (simplified)
            Write-Warning "PowerShell 2.0 detected. Using simplified metadata parser."
            $metadata = Invoke-Expression $jsonContent
        }

        # Cache the result
        $script:MetadataCache.Data = $metadata
        $script:MetadataCache.Timestamp = Get-Date
        Write-Verbose "Metadata cached (TTL: $($script:MetadataCache.TTLSeconds)s)"

        return $metadata
    } catch {
        Write-Error "Failed to load metadata: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Clears the collector metadata cache manually.

.DESCRIPTION
    Resets the in-memory metadata cache. Useful for testing or after external metadata changes.
    The cache also auto-expires after 5 minutes of inactivity.

.EXAMPLE
    Clear-CollectorMetadataCache
    $metadata = Get-CollectorMetadata  # Will reload from disk

.NOTES
    Cache auto-expires after 5 minutes. Manual clear is optional.
#>
function Clear-CollectorMetadataCache {
    [CmdletBinding()]
    param()
    
    $script:MetadataCache.Data = $null
    $script:MetadataCache.Timestamp = $null
    Write-Verbose "Metadata cache cleared"
}

<#
.SYNOPSIS
    Gets cache status and statistics.

.EXAMPLE
    Get-CollectorMetadataCacheStats
    
.OUTPUTS
    PSObject with cache status, age, and TTL information.
#>
function Get-CollectorMetadataCacheStats {
    [CmdletBinding()]
    param()
    
    $stats = @{
        IsCached = $null -ne $script:MetadataCache.Data
        CacheAge = if ($script:MetadataCache.Timestamp) { (Get-Date) - $script:MetadataCache.Timestamp } else { $null }
        TTLSeconds = $script:MetadataCache.TTLSeconds
        IsExpired = $false
    }
    
    if ($stats.CacheAge) {
        $stats.IsExpired = $stats.CacheAge.TotalSeconds -ge $stats.TTLSeconds
    }
    
    return [PSCustomObject]$stats
}

<#
.SYNOPSIS
    Filters collectors by PowerShell version.

.PARAMETER Collectors
    Array of collector objects from metadata.

.PARAMETER PSVersion
    Target PowerShell version (e.g., '2.0', '5.1', '7.0'). Defaults to current session.

.EXAMPLE
    $collectors = Get-CollectorMetadata
    $compatible = Get-CompatibleCollectors -Collectors $collectors.collectors -PSVersion '5.1'
#>
function Get-CompatibleCollectors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
        [object[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [string]$PSVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    )

    $compatible = @()
    foreach ($collector in $Collectors) {
        if ($collector.psVersions -contains $PSVersion) {
            $compatible += $collector
        }
    }

    return $compatible
}

<#
.SYNOPSIS
    Filters collectors by minimum Windows OS version.

.PARAMETER Collectors
    Array of collector objects.

.PARAMETER OSVersion
    Windows Server version identifier (e.g., '2008R2', '2012R2', '2016', '2019', '2022').

.EXAMPLE
    $collectors = Get-CollectorMetadata
    $compatible = Get-CompatibleCollectorsByOS -Collectors $collectors.collectors -OSVersion '2016'
#>
function Get-CompatibleCollectorsByOS {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Collectors,

        [Parameter(Mandatory=$false)]
        [string]$OSVersion
    )

    # If OSVersion not provided, detect current OS
    if ([string]::IsNullOrEmpty($OSVersion)) {
        $osInfo = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($osInfo) {
            $OSVersion = Get-WindowsVersionFromBuild -BuildNumber $osInfo.BuildNumber
        } else {
            Write-Warning "Could not detect OS version. Returning all collectors."
            return $Collectors
        }
    }

    # Define OS version hierarchy (newer = higher value)
    $osVersionMap = @{
        '2008'    = 1
        '2008R2'  = 2
        '2012'    = 3
        '2012R2'  = 4
        '2016'    = 5
        '2019'    = 6
        '2022'    = 7
    }

    $currentOSValue = $osVersionMap[$OSVersion]
    if ([string]::IsNullOrEmpty($currentOSValue)) {
        Write-Warning "Unknown OS version: $OSVersion. Returning all collectors."
        return $Collectors
    }

    $compatible = @()
    foreach ($collector in $Collectors) {
        $minOSValue = $osVersionMap[$collector.minWindowsVersion]
        $maxOSValue = if ($collector.maxWindowsVersion) { $osVersionMap[$collector.maxWindowsVersion] } else { [int]::MaxValue }

        if ($currentOSValue -ge $minOSValue -and $currentOSValue -le $maxOSValue) {
            $compatible += $collector
        }
    }

    return $compatible
}

<#
.SYNOPSIS
    Returns the optimal collector variant for the current environment.

.PARAMETER Collector
    A single collector object from metadata.

.PARAMETER PSVersion
    Target PowerShell version. Defaults to current session.

.EXAMPLE
    $collector = $metadata.collectors[0]
    $variant = Get-CollectorVariant -Collector $collector -PSVersion '5.1'
    # Returns: "Get-ServerInfo-PS5.ps1"

.NOTES
    Falls back to lower PS version if higher version variant unavailable.
#>
function Get-CollectorVariant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
        [object]$Collector,

        [Parameter(Mandatory=$false)]
        [string]$PSVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    )

    # Check if variant exists for exact version
    if ($Collector.variants -and $Collector.variants.$PSVersion) {
        return $Collector.variants.$PSVersion
    }

    # Fallback: find highest compatible version less than requested
    $psVersions = @('2.0', '4.0', '5.1', '7.0') | Where-Object { $_ -le $PSVersion }
    [array]::Reverse($psVersions)

    foreach ($version in $psVersions) {
        if ($Collector.variants -and $Collector.variants.$version) {
            Write-Verbose "Requested PS $PSVersion variant not found. Falling back to PS $version variant."
            return $Collector.variants.$version
        }
    }

    # Ultimate fallback: use default filename
    Write-Warning "No variant found for PS $PSVersion. Using default: $($Collector.filename)"
    return $Collector.filename
}

<#
.SYNOPSIS
    Validates that all dependencies for a collector are available.

.PARAMETER Collector
    A single collector object.

.EXAMPLE
    $collector = $metadata.collectors[0]
    Test-CollectorDependencies -Collector $collector

.NOTES
    Returns $true if all dependencies available, $false otherwise.
#>
function Test-CollectorDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
        [object]$Collector
    )

    if ($Collector.dependencies.Count -eq 0) {
        return $true
    }

    $allAvailable = $true
    foreach ($dependency in $Collector.dependencies) {
        # Check for Windows feature or module
        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            $feature = Get-WindowsFeature -Name $dependency -ErrorAction SilentlyContinue
            if ($feature -and $feature.Installed) {
                Write-Verbose "Dependency available: $dependency"
            } else {
                Write-Warning "Dependency missing: $dependency (required for $($Collector.name))"
                $allAvailable = $false
            }
        } else {
            # Fallback: check if module exists
            if (-not (Get-Module -Name $dependency -ListAvailable -ErrorAction SilentlyContinue)) {
                Write-Warning "Dependency missing: $dependency (required for $($Collector.name))"
                $allAvailable = $false
            }
        }
    }

    return $allAvailable
}

<#
.SYNOPSIS
    Converts Windows build number to server version name.

.PARAMETER BuildNumber
    Windows build number (e.g., 6.1 = 2008R2, 6.3 = 2012R2, 10.0 = 2016+).

.NOTES
    Helper function for OS detection.
#>
function Get-WindowsVersionFromBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$BuildNumber
    )

    # Extract major.minor from build string (e.g., "6.1.7601" -> 6.1)
    $majorMinor = $BuildNumber.Split('.')[0..1] -join '.'

    # Map build to Windows Server version
    switch -Exact ($majorMinor) {
        '6.0' { return '2008' }
        '6.1' { return '2008R2' }
        '6.2' { return '2012' }
        '6.3' { return '2012R2' }
        '10.0' {
            # Windows Server 2016+ (need to check actual build)
            $buildNum = [int]($BuildNumber.Split('.')[2])
            if ($buildNum -ge 20348) { return '2022' }
            elseif ($buildNum -ge 17763) { return '2019' }
            else { return '2016' }
        }
        default { return 'Unknown' }
    }
}

<#
.SYNOPSIS
    Gets a comprehensive summary of all available collectors.

.PARAMETER Metadata
    Metadata object from Get-CollectorMetadata.

.EXAMPLE
    $metadata = Get-CollectorMetadata
    Get-CollectorSummary -Metadata $metadata
#>
function Get-CollectorSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
        [object]$Metadata
    )

    $summary = @{
        TotalCollectors = $Metadata.collectors.Count
        Categories = @{}
        PSVersions = @{}
        EstimatedTotalExecutionTime = 0
    }

    foreach ($collector in $Metadata.collectors) {
        # Count by category
        if ($summary.Categories[$collector.category]) {
            $summary.Categories[$collector.category] += 1
        } else {
            $summary.Categories[$collector.category] = 1
        }

        # Count by PS version
        foreach ($psVer in $collector.psVersions) {
            if ($summary.PSVersions[$psVer]) {
                $summary.PSVersions[$psVer] += 1
            } else {
                $summary.PSVersions[$psVer] = 1
            }
        }

        # Sum execution times
        $summary.EstimatedTotalExecutionTime += $collector.estimatedExecutionTime
    }

    return $summary
}

# Export functions
Export-ModuleMember -Function @(
    'Get-CollectorMetadata',
    'Clear-CollectorMetadataCache',
    'Get-CollectorMetadataCacheStats',
    'Get-CompatibleCollectors',
    'Get-CompatibleCollectorsByOS',
    'Get-CollectorVariant',
    'Test-CollectorDependencies',
    'Get-WindowsVersionFromBuild',
    'Get-CollectorSummary'
)