<#
.SYNOPSIS
    Scans file system for PII (SSN, credit cards, email addresses).

.DESCRIPTION
    Recursively scans file shares and specified directories for personally identifiable
    information patterns:
    
    Patterns:
    - Social Security Numbers: \d{3}-\d{2}-\d{4}
    - Credit Cards: \d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}
    - Email Addresses: \b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b
    - Phone Numbers: \b(\d{3}[-.]?)?\d{3}[-.]?\d{4}\b
    
    Uses sampling to avoid scanning massive files. Scans:
    - Text files (.txt, .csv, .log, .doc, .docx, .xls, .xlsx, .pdf)
    - Database exports
    - Application config files
    
    Critical for:
    - GDPR/CCPA compliance
    - Data classification
    - Risk assessment
    - PII inventory before deletion/migration

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER ScanPath
    Root path to scan. Default: all shares except system shares.

.PARAMETER SamplingPercentage
    % of files to scan (to save time on large shares). Default: 20.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Data-Discovery-PII
    @PSVersions: 2.0,4.0,5.1,7.0
    @MinWindowsVersion: 2003
    @MaxWindowsVersion:
    @Dependencies:
    @Timeout: 300
    @Category: compliance
    @Critical: true
    @Priority: TIER4
    @EstimatedExecutionTime: 120
#>

function Find-PIIData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [string[]]$ScanPath,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 100)]
        [int]$SamplingPercentage = 20,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        if ($DryRun) {
            Write-Verbose "DRY-RUN: Would scan for PII in $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Data-Discovery-PII'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $piiFindings = @()

        # Define PII patterns
        $patterns = @{
            'SSN'        = '\d{3}-\d{2}-\d{4}'
            'CreditCard' = '\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}'
            'Email'      = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'
            'PhoneNumber' = '\b(\d{3}[-.]?)?\d{3}[-.]?\d{4}\b'
        }

        # Determine paths to scan
        if (-not $ScanPath) {
            if ($ComputerName -eq $env:COMPUTERNAME) {
                # Local shares
                $shareWmiParams = @{
                    Class       = 'Win32_Share'
                    Filter      = "Type=0 AND NOT Name LIKE '%$%'"  # Type 0 = disk drive, exclude hidden shares
                    ErrorAction = 'SilentlyContinue'
                }
            }
            else {
                # Remote shares
                $shareWmiParams = @{
                    Class        = 'Win32_Share'
                    ComputerName = $ComputerName
                    Filter       = "Type=0 AND NOT Name LIKE '%$%'"
                    ErrorAction  = 'SilentlyContinue'
                }

                if ($Credential) {
                    $shareWmiParams['Credential'] = $Credential
                }
            }

            $shares = Get-WmiObject @shareWmiParams
            if ($shares) {
                if ($shares -isnot [array]) {
                    $shares = @($shares)
                }
                $ScanPath = $shares | ForEach-Object { $_.Path }
            }
        }

        # Scan files
        $scanExtensions = @('*.txt', '*.csv', '*.log', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.pdf', '*.config', '*.ini')

        foreach ($path in $ScanPath) {
            if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
                continue
            }

            try {
                # Get all eligible files
                $files = Get-ChildItem -Path $path -Recurse -Include $scanExtensions `
                    -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }

                if ($files -isnot [array]) {
                    $files = @($files)
                }

                # Apply sampling
                $sampleSize = [Math]::Max(1, [int]($files.Count * ($SamplingPercentage / 100)))
                $filesToScan = $files | Get-Random -Count $sampleSize

                foreach ($file in $filesToScan) {
                    try {
                        # Read first 10 KB to avoid massive files
                        $content = Get-Content -Path $file.FullName -TotalCount 1000 `
                            -ErrorAction SilentlyContinue | Out-String

                        # Scan for patterns
                        foreach ($patternName in $patterns.Keys) {
                            $pattern = $patterns[$patternName]
                            $matches = @([regex]::Matches($content, $pattern))

                            if ($matches.Count -gt 0) {
                                $piiFindings += @{
                                    Path           = $file.FullName
                                    FileName       = $file.Name
                                    PatternType    = $patternName
                                    MatchCount     = $matches.Count
                                    RiskLevel      = switch ($patternName) {
                                        'SSN'        { 'CRITICAL' }
                                        'CreditCard' { 'CRITICAL' }
                                        'Email'      { 'MEDIUM' }
                                        'PhoneNumber' { 'LOW' }
                                    }
                                    FileSize       = $file.Length
                                    LastModified   = $file.LastWriteTime
                                }
                            }
                        }
                    }
                    catch {
                        # Continue on file read error
                    }
                }
            }
            catch {
                # Continue on directory scan error
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Data-Discovery-PII'
            Data          = $piiFindings
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($piiFindings).Count
            Summary       = @{
                CriticalFindings = @($piiFindings | Where-Object { $_.RiskLevel -eq 'CRITICAL' }).Count
                MediumFindings   = @($piiFindings | Where-Object { $_.RiskLevel -eq 'MEDIUM' }).Count
                LowFindings      = @($piiFindings | Where-Object { $_.RiskLevel -eq 'LOW' }).Count
                PathsScanned     = $ScanPath.Count
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Data-Discovery-PII'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Find-PIIData @PSBoundParameters
}
