<#
.SYNOPSIS
    Calculates adaptive timeout for collectors based on PowerShell version and server load.

.DESCRIPTION
    Adjusts collector timeout values for optimal performance:
    
    1. Selects base timeout appropriate for PowerShell version
       - PS 2.0/4.0: Slowest, full WMI overhead
       - PS 5.1: ~50% faster with CIM optimization
       - PS 7.x: ~60% faster still with async/parallel
    
    2. Applies adaptive multiplier for slow/loaded servers
       - CPU > 80% or Memory > 85%: Add 50-100% to timeout
    
    3. Respects collector-specific configuration
       - High I/O collectors (DataDiscovery) get more slack
       - Network collectors (DNS, DHCP) use aggressive timeouts

.PARAMETER CollectorName
    Name of the collector (e.g., "Get-ServerInfo", "85-DataDiscovery").
    Required.

.PARAMETER PSVersion
    PowerShell version major number (2, 4, 5, 7).
    If not provided, uses current $PSVersionTable.PSVersion.Major

.PARAMETER TimeoutConfig
    Hash table mapping collector names to timeout configs.
    Expected format:
    @{
        "Get-ServerInfo" = @{
            "timeoutPs2" = 20
            "timeoutPs5" = 10
            "timeoutPs7" = 8
            "adaptive" = $true
            "slowServerMultiplier" = 1.5
        }
    }

.PARAMETER IsSlowServer
    If $true, applies slowServerMultiplier to timeout.
    Recommended: Detect via CPU/Memory usage or parameter.

.EXAMPLE
    $timeout = Get-AdjustedTimeout `
        -CollectorName "Get-ServerInfo" `
        -PSVersion 5 `
        -TimeoutConfig $config `
        -IsSlowServer $false
    
    # Result: 10 seconds (PS5 baseline)

.EXAMPLE
    $timeout = Get-AdjustedTimeout `
        -CollectorName "85-DataDiscovery" `
        -PSVersion 5 `
        -TimeoutConfig $config `
        -IsSlowServer $true
    
    # Result: 360 seconds (180s * 2.0 multiplier for high I/O on slow server)

.OUTPUTS
    [int]
    Timeout in seconds.

.NOTES
    Default fallback: 120 seconds if no config found.
    All results are rounded integers.
    Logging uses Write-Verbose for tracing.

.LINK
    Invoke-ServerAudit
#>

function Get-AdjustedTimeout {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectorName,

        [Parameter(Mandatory=$false)]
        [ValidateSet(2, 4, 5, 7)]
        [int]$PSVersion,

        [Parameter(Mandatory=$false)]
        [hashtable]$TimeoutConfig,

        [Parameter(Mandatory=$false)]
        [switch]$IsSlowServer
    )

    # Default PS version if not provided
    if ($PSVersion -eq 0) {
        $PSVersion = $PSVersionTable.PSVersion.Major
    }

    # Default fallback
    $timeout = 120

    # Look up collector config
    if ($TimeoutConfig -and $TimeoutConfig.ContainsKey($CollectorName)) {
        $config = $TimeoutConfig[$CollectorName]
        
        # Select PS-specific timeout
        $psKey = "timeoutPs$PSVersion"
        
        if ($config.ContainsKey($psKey)) {
            $timeout = $config[$psKey]
            Write-Verbose "Using PS$PSVersion-specific timeout for '$CollectorName': $timeout seconds"
        }
        elseif ($config.ContainsKey('timeoutPs2')) {
            # Fallback to PS 2.0 baseline
            $timeout = $config.timeoutPs2
            Write-Verbose "PS$PSVersion timeout not found for '$CollectorName', using PS2 baseline: $timeout seconds"
        }

        # Apply adaptive multiplier if enabled and server is slow
        if ($config.adaptive -and $IsSlowServer) {
            $multiplier = $config.slowServerMultiplier
            if ($null -eq $multiplier) {
                $multiplier = 1.5
            }
            
            $originalTimeout = $timeout
            $timeout = [math]::Round($timeout * $multiplier)
            
            Write-Verbose ("Adjusted timeout for slow server '{0}': {1}s -> {2}s (multiplier: {3})" -f `
                $CollectorName, $originalTimeout, $timeout, $multiplier)
        }
    }
    else {
        Write-Verbose "No specific config for '$CollectorName', using default timeout: $timeout seconds"
    }

    # Ensure minimum 5 seconds, maximum 600 seconds (10 min)
    if ($timeout -lt 5) {
        Write-Warning "Timeout for '$CollectorName' too low ($timeout s), raising to 5s"
        $timeout = 5
    }
    elseif ($timeout -gt 600) {
        Write-Warning "Timeout for '$CollectorName' too high ($timeout s), capping at 600s"
        $timeout = 600
    }

    return $timeout
}
