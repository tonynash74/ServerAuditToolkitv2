<#
.SYNOPSIS
    Scans for UK Financial data (IBAN, sort codes, etc.).

.DESCRIPTION
    Recursively scans for UK-specific financial information:
    
    Patterns:
    - UK IBAN: GB\d{2}[A-Z]{4}\d{14}
    - UK Sort Code: \d{2}-\d{2}-\d{2}
    - UK Account Number: \d{8}
    - Payment reference patterns
    
    Critical for:
    - FCA (Financial Conduct Authority) compliance
    - PSD2 (Payment Services Directive 2) regulations
    - Data classification for UK financial institutions
    - Risk assessment for financial data breach

.PARAMETER ComputerName
    Target server. Default: localhost.

.PARAMETER Credential
    Domain credentials if needed.

.PARAMETER ScanPath
    Root path to scan. Default: all shares except system shares.

.PARAMETER SamplingPercentage
    % of files to scan. Default: 20.

.PARAMETER DryRun
    Show what would be collected without executing.

.NOTES
    Author:       Tony Nash
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     2025-11-21
    PowerShell:   2.0+
    License:      MIT
    
    @CollectorName: Data-Discovery-FinancialUK
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

function Find-UKFinancialData {
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
            Write-Verbose "DRY-RUN: Would scan for UK Financial data in $ComputerName"
            return @{
                Success       = $true
                CollectorName = 'Data-Discovery-FinancialUK'
                Data          = @()
                ExecutionTime = (Get-Date) - $startTime
                RecordCount   = 0
            }
        }

        $financialFindings = @()

        # Define UK financial patterns
        $patterns = @{
            'UK_IBAN'         = 'GB\d{2}\s?[A-Z]{4}\s?\d{2}\s?\d{2}\s?\d{6}\s?\d{8}'
            'UK_SortCode'     = '\b\d{2}[\s\-]?\d{2}[\s\-]?\d{2}\b'
            'UK_AccountNumber' = '\b\d{8}\b'
            'UK_NI'           = '\b[A-Z]{2}\d{6}[A-D]\b'
        }

        # Determine paths to scan
        if (-not $ScanPath) {
            if ($ComputerName -eq $env:COMPUTERNAME) {
                $shareWmiParams = @{
                    Class       = 'Win32_Share'
                    Filter      = "Type=0 AND NOT Name LIKE '%$%'"
                    ErrorAction = 'SilentlyContinue'
                }
            }
            else {
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
        $scanExtensions = @('*.txt', '*.csv', '*.log', '*.doc', '*.docx', '*.xls', '*.xlsx', '*.pdf', '*.config')

        foreach ($path in $ScanPath) {
            if (-not (Test-Path $path -ErrorAction SilentlyContinue)) {
                continue
            }

            try {
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
                        $content = Get-Content -Path $file.FullName -TotalCount 1000 `
                            -ErrorAction SilentlyContinue | Out-String

                        foreach ($patternName in $patterns.Keys) {
                            $pattern = $patterns[$patternName]
                            $matches = @([regex]::Matches($content, $pattern))

                            if ($matches.Count -gt 0) {
                                $financialFindings += @{
                                    Path         = $file.FullName
                                    FileName     = $file.Name
                                    PatternType  = $patternName
                                    MatchCount   = $matches.Count
                                    RiskLevel    = 'CRITICAL'  # All UK financial data is HIGH risk
                                    FileSize     = $file.Length
                                    LastModified = $file.LastWriteTime
                                }
                            }
                        }
                    }
                    catch {
                        # Continue on error
                    }
                }
            }
            catch {
                # Continue on error
            }
        }

        return @{
            Success       = $true
            CollectorName = 'Data-Discovery-FinancialUK'
            Data          = $financialFindings
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($financialFindings).Count
            Summary       = @{
                CriticalFindings = @($financialFindings).Count
                PathsScanned     = $ScanPath.Count
                Recommendation   = "UK Financial data requires encrypted storage and restricted access (FCA/PSD2 compliant)"
            }
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Data-Discovery-FinancialUK'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}

# Invoke if run directly
if ($MyInvocation.InvocationName -ne '.') {
    Find-UKFinancialData @PSBoundParameters
}
