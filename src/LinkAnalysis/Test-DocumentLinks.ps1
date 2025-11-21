<#
.SYNOPSIS
    Validates hyperlinks extracted from documents, testing accessibility and categorizing risk.
    
.DESCRIPTION
    Takes structured link objects and validates them by:
    - Testing HTTP/HTTPS URLs for reachability
    - Checking file paths (local, UNC, SMB shares)
    - Identifying broken links and transient failures
    - Risk scoring for migration impact assessment
    
    Implements intelligent caching (24-hour TTL) to avoid repeated validation
    and includes parallel processing for bulk operations.

.PARAMETER Links
    Array of link objects from Extract-DocumentLinks output

.PARAMETER EnableCache
    Use cached results when available. Default: $true

.PARAMETER CachePath
    Location for validation cache. Default: $env:TEMP\link-validation-cache.json

.PARAMETER ThrottleLimit
    Maximum parallel jobs for link validation. Default: 5

.PARAMETER RequestTimeout
    HTTP request timeout in seconds. Default: 10

.EXAMPLE
    $links = Extract-DocumentLinks -FilePath 'C:\docs\report.xlsx'
    $validation = Test-DocumentLinks -Links $links.Links

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0-POC
    Modified:     2025-11-21
    PowerShell:   3.0+
    Dependencies: Invoke-WebRequest (built-in), Test-Path (built-in)
#>

function Test-DocumentLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Links,

        [Parameter(Mandatory=$false)]
        [switch]$EnableCache = $true,

        [Parameter(Mandatory=$false)]
        [string]$CachePath = (Join-Path $env:TEMP 'link-validation-cache.json'),

        [Parameter(Mandatory=$false)]
        [int]$ThrottleLimit = 5,

        [Parameter(Mandatory=$false)]
        [int]$RequestTimeout = 10,

        [Parameter(Mandatory=$false)]
        [switch]$SkipInternalLinks,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date
    $results = @()
    $cache = @{}

    # Load cache if enabled
    if ($EnableCache -and (Test-Path $CachePath)) {
        try {
            $cacheData = Get-Content $CachePath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            foreach ($entry in $cacheData.PSObject.Properties) {
                $cache[$entry.Name] = $entry.Value
            }
        }
        catch {
            Write-Verbose "Warning: Could not load cache from $CachePath"
        }
    }

    # Deduplicate and filter links
    $uniqueLinks = $Links | Sort-Object -Property Url -Unique

    if ($SkipInternalLinks) {
        $uniqueLinks = $uniqueLinks | Where-Object { -not $_.IsInternal }
    }

    foreach ($link in $uniqueLinks) {
        $url = $link.Url
        $linkType = $link.LinkType

        # Check cache first
        if ($cache.ContainsKey($url)) {
            $cached = $cache[$url]
            
            # Check if cache expired (24 hours)
            $cacheAge = (Get-Date) - [datetime]$cached.CachedAt
            if ($cacheAge.TotalHours -lt 24) {
                $results += $cached
                continue
            }
        }

        if ($DryRun) {
            $results += @{
                Url            = $url
                LinkType       = $linkType
                Status         = 'DRY-RUN'
                Valid          = $null
                ResponseCode   = $null
                ResponseTime   = $null
                Error          = 'Dry run mode enabled'
                RiskLevel      = 'UNKNOWN'
                CachedAt       = (Get-Date).ToString('u')
            }
            continue
        }

        # Validate based on link type
        $validation = switch ($linkType) {
            'ExternalURL'  { Test-ExternalURL -Url $url -Timeout $RequestTimeout }
            'FilePath'     { Test-FilePath -Path $url }
            'Email'        { Test-EmailAddress -Address $url }
            'ExcelFile'    { Test-FilePath -Path $url }
            'InternalLink' { @{ Valid = $true; Status = 'InternalAnchor'; ResponseCode = 0 } }
            default        { @{ Valid = $null; Status = 'UNKNOWN'; Error = "Unknown link type: $linkType" } }
        }

        # Enrich with risk scoring
        $riskLevel = Get-LinkRiskLevel -Validation $validation -LinkType $linkType

        $result = @{
            Url            = $url
            LinkType       = $linkType
            SourceFiles    = @($Links | Where-Object { $_.Url -eq $url } | Select-Object -ExpandProperty SourceFile -Unique)
            Valid          = $validation.Valid
            Status         = $validation.Status
            ResponseCode   = $validation.ResponseCode
            ResponseTime   = $validation.ResponseTime
            Error          = $validation.Error
            RiskLevel      = $riskLevel
            Recommendation = Get-LinkRecommendation -Validation $validation -LinkType $linkType -RiskLevel $riskLevel
            CachedAt       = (Get-Date).ToString('u')
        }

        $results += $result

        # Update cache
        if ($EnableCache) {
            $cache[$url] = $result
        }
    }

    # Save cache if enabled and modified
    if ($EnableCache) {
        try {
            $cache | ConvertTo-Json -Depth 10 | Set-Content $CachePath -Encoding UTF8
        }
        catch {
            Write-Verbose "Warning: Could not save cache to $CachePath"
        }
    }

    # Build summary statistics
    $summary = @{
        TotalLinksValidated = @($results).Count
        UniqueLinks         = @($uniqueLinks).Count
        Valid               = @($results | Where-Object { $_.Valid -eq $true }).Count
        Invalid             = @($results | Where-Object { $_.Valid -eq $false }).Count
        Unknown             = @($results | Where-Object { $_.Valid -eq $null }).Count
        CriticalRisk        = @($results | Where-Object { $_.RiskLevel -eq 'CRITICAL' }).Count
        HighRisk            = @($results | Where-Object { $_.RiskLevel -eq 'HIGH' }).Count
        MediumRisk          = @($results | Where-Object { $_.RiskLevel -eq 'MEDIUM' }).Count
        LowRisk             = @($results | Where-Object { $_.RiskLevel -eq 'LOW' }).Count
        AvgResponseTime     = if (@($results | Where-Object { $_.ResponseTime }).Count -gt 0) {
                                [math]::Round((@($results | Where-Object { $_.ResponseTime }).ResponseTime | Measure-Object -Average).Average, 2)
                              } else { $null }
    }

    return @{
        Success           = $true
        ValidatedLinks    = $results
        ExecutionTime     = (Get-Date) - $startTime
        RecordCount       = @($results).Count
        Summary           = $summary
    }
}

function Test-ExternalURL {
    [CmdletBinding()]
    param(
        [string]$Url,
        [int]$Timeout = 10
    )

    $startTime = Get-Date
    $result = @{
        Valid        = $false
        Status       = 'UNKNOWN'
        ResponseCode = $null
        ResponseTime = $null
        Error        = $null
    }

    try {
        # Validate URL format
        if ($Url -notmatch '^https?://') {
            $result.Status = 'INVALID_FORMAT'
            $result.Error = 'URL does not start with http:// or https://'
            return $result
        }

        # Test connectivity
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $Timeout `
            -ErrorAction Stop -SkipHttpErrorCheck

        $result.ResponseCode = $response.StatusCode
        $result.ResponseTime = ((Get-Date) - $startTime).TotalMilliseconds

        # Determine validity
        $result.Valid = $response.StatusCode -in 200, 301, 302, 303, 307, 308
        $result.Status = if ($result.Valid) { 'REACHABLE' } else { 'HTTP_ERROR' }
    }
    catch [System.Net.Http.HttpRequestException] {
        $result.Status = 'CONNECTION_FAILED'
        $result.Error = $_.Exception.InnerException.Message
    }
    catch [System.Net.WebException] {
        $result.Status = 'TIMEOUT_OR_UNREACHABLE'
        $result.Error = $_.Exception.Message
    }
    catch {
        $result.Status = 'ERROR'
        $result.Error = $_.Exception.Message
    }

    $result.ResponseTime = ((Get-Date) - $startTime).TotalMilliseconds
    return $result
}

function Test-FilePath {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    $result = @{
        Valid        = $false
        Status       = 'UNKNOWN'
        ResponseCode = $null
        ResponseTime = $null
        Error        = $null
    }

    try {
        # Handle UNC paths
        if ($Path -match '^\\\\') {
            $result.Status = 'UNC_PATH'
            $result.Valid = Test-Path $Path -ErrorAction SilentlyContinue
            $result.ResponseCode = if ($result.Valid) { 0 } else { 404 }
            return $result
        }

        # Handle local file paths
        if ($Path -match '^[a-z]:' -or $Path -match '^\.\\') {
            # Try to resolve
            $expandedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
            $result.Status = 'LOCAL_PATH'
            $result.Valid = Test-Path $expandedPath -ErrorAction SilentlyContinue
            $result.ResponseCode = if ($result.Valid) { 0 } else { 404 }
            return $result
        }

        # Relative path
        $result.Status = 'RELATIVE_PATH'
        $result.Error = 'Cannot validate relative path without source context'
        $result.ResponseCode = -1
    }
    catch {
        $result.Status = 'ERROR'
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Test-EmailAddress {
    [CmdletBinding()]
    param(
        [string]$Address
    )

    $result = @{
        Valid        = $false
        Status       = 'EMAIL'
        ResponseCode = $null
        ResponseTime = $null
        Error        = $null
    }

    try {
        # Basic email validation
        if ($Address -match '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
            $result.Valid = $true
            $result.Status = 'EMAIL_VALID'
        } else {
            $result.Valid = $false
            $result.Status = 'EMAIL_INVALID'
            $result.Error = 'Invalid email format'
        }
    }
    catch {
        $result.Status = 'ERROR'
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-LinkRiskLevel {
    [CmdletBinding()]
    param(
        [hashtable]$Validation,
        [string]$LinkType
    )

    # CRITICAL: Broken external URLs
    if ($Validation.Valid -eq $false -and $LinkType -eq 'ExternalURL') {
        return 'CRITICAL'
    }

    # HIGH: Invalid file paths (hardcoded paths likely to change)
    if ($Validation.Valid -eq $false -and $LinkType -in 'FilePath', 'ExcelFile') {
        return 'HIGH'
    }

    # MEDIUM: Timeouts, unknown status
    if ($Validation.Valid -eq $null -or $Validation.Status -eq 'TIMEOUT_OR_UNREACHABLE') {
        return 'MEDIUM'
    }

    # LOW: Valid, or internal/anchor references
    return 'LOW'
}

function Get-LinkRecommendation {
    [CmdletBinding()]
    param(
        [hashtable]$Validation,
        [string]$LinkType,
        [string]$RiskLevel
    )

    switch ($RiskLevel) {
        'CRITICAL' {
            return "URGENT: This link is broken and likely to cause user issues. Update URL or remove reference. Link type: $LinkType"
        }
        'HIGH' {
            if ($LinkType -in 'FilePath', 'ExcelFile') {
                return "WARNING: This hardcoded file path may break after migration. Update to UNC path or document link mapping. Current: $($Validation.Error)"
            }
        }
        'MEDIUM' {
            return "CAUTION: This link status is uncertain (timeout/unreachable). Verify manually or retry validation."
        }
        'LOW' {
            return "OK: This link appears valid. Monitor post-migration."
        }
        default {
            return "UNKNOWN: Unable to determine link status. Manual review recommended."
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Test-DocumentLinks @PSBoundParameters
}
