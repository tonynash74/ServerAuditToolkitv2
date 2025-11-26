<#
.SYNOPSIS
    Streaming output helpers for large audit runs (M-012).

.DESCRIPTION
    Provides the streaming writer used by Invoke-ServerAudit along with
    reader and consolidation utilities that operate on JSONL output.
    The writer keeps memory usage low by flushing JSON payloads to disk
    and optionally monitoring process memory to auto-throttle buffers.
#>

class StreamingOutputWriter {
    [string]$OutputPath
    [int]$BufferSize
    [int]$OriginalBufferSize
    [int]$FlushIntervalSeconds
    [bool]$EnableMemoryMonitoring
    [int]$MemoryThresholdMB
    [System.Collections.Generic.List[psobject]]$ResultBuffer
    [int]$TotalResultsWritten
    [int]$TotalFlushes
    [datetime]$LastFlushTime
    [bool]$IsFinalized
    [System.IO.StreamWriter]$StreamWriter
    [string]$StreamFile
    [double]$PeakMemoryMB
    [datetime]$StartTime
    [double]$ResultsPerSecond
    [System.Diagnostics.Stopwatch]$Stopwatch

    StreamingOutputWriter(
        [string]$outputPath,
        [int]$bufferSize,
        [int]$flushIntervalSeconds,
        [bool]$enableMemoryMonitoring,
        [int]$memoryThresholdMB
    ) {
        if (-not (Test-Path -LiteralPath $outputPath)) {
            New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
        }

        $this.OutputPath = (Resolve-Path -LiteralPath $outputPath).Path
        $this.BufferSize = $bufferSize
        $this.OriginalBufferSize = $bufferSize
        $this.FlushIntervalSeconds = $flushIntervalSeconds
        $this.EnableMemoryMonitoring = $enableMemoryMonitoring
        $this.MemoryThresholdMB = $memoryThresholdMB
        $this.ResultBuffer = New-Object System.Collections.Generic.List[psobject]
        $this.TotalResultsWritten = 0
        $this.TotalFlushes = 0
        $this.LastFlushTime = Get-Date
        $this.IsFinalized = $false
        $this.PeakMemoryMB = 0
        $this.StartTime = Get-Date
        $this.ResultsPerSecond = 0
        $this.Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $timestamp = '{0:yyyyMMdd-HHmmss-fff}-{1}' -f (Get-Date), (Get-Random -Maximum 10000)
        $this.StreamFile = Join-Path $this.OutputPath "stream_$timestamp.jsonl"
        $this.StreamWriter = [System.IO.StreamWriter]::new($this.StreamFile, $true, [System.Text.Encoding]::UTF8)
    }

    [void] AddResult([psobject]$Result) {
        if ($this.IsFinalized) {
            throw 'finalized'
        }

        if ($null -eq $Result) {
            return
        }

        $this.ResultBuffer.Add($Result)

        $shouldFlush = $this.ResultBuffer.Count -ge $this.BufferSize
        if (-not $shouldFlush -and $this.FlushIntervalSeconds -gt 0) {
            $elapsed = ((Get-Date) - $this.LastFlushTime).TotalSeconds
            $shouldFlush = $elapsed -ge $this.FlushIntervalSeconds
        }

        if ($shouldFlush) {
            $this.Flush()
        }

        if ($this.EnableMemoryMonitoring) {
            $currentMemoryMB = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
            if ($currentMemoryMB -gt $this.PeakMemoryMB) {
                $this.PeakMemoryMB = $currentMemoryMB
            }

            if ($currentMemoryMB -gt $this.MemoryThresholdMB -and $this.BufferSize -gt 1) {
                $this.BufferSize = [Math]::Max(1, [Math]::Floor($this.BufferSize * 0.5))
                Write-Host "[MEMORY] Reduced buffer size to $($this.BufferSize) (Memory: $([math]::Round($currentMemoryMB, 2)) MB)" -ForegroundColor Yellow
            }
        }
    }

    [void] Flush() {
        if ($this.ResultBuffer.Count -eq 0) {
            return
        }

        foreach ($result in $this.ResultBuffer) {
            $json = $result | ConvertTo-Json -Depth 20 -Compress
            $this.StreamWriter.WriteLine($json)
        }

        $this.StreamWriter.Flush()
        $this.TotalResultsWritten += $this.ResultBuffer.Count
        $this.TotalFlushes++
        $this.LastFlushTime = Get-Date
        $this.ResultBuffer.Clear()

        $elapsed = $this.Stopwatch.Elapsed.TotalSeconds
        if ($elapsed -gt 0) {
            $this.ResultsPerSecond = $this.TotalResultsWritten / $elapsed
        }
    }

    [string] Finalize() {
        if ($this.IsFinalized) {
            return $this.StreamFile
        }

        if ($this.ResultBuffer.Count -gt 0) {
            $this.Flush()
        }

        if ($this.StreamWriter) {
            $this.StreamWriter.Close()
            $this.StreamWriter.Dispose()
        }

        if ($this.Stopwatch) {
            $this.Stopwatch.Stop()
        }

        $this.IsFinalized = $true
        return $this.StreamFile
    }

    [pscustomobject] GetStatistics() {
        $elapsedSeconds = $this.Stopwatch.Elapsed.TotalSeconds
        if ($elapsedSeconds -lt 0.01) {
            $elapsedSeconds = 0.01
        }

        $calculatedResultsPerSecond = 0
        if ($elapsedSeconds -gt 0 -and $this.TotalResultsWritten -gt 0) {
            $calculatedResultsPerSecond = $this.TotalResultsWritten / $elapsedSeconds
        }

        return [PSCustomObject]@{
            OutputPath          = $this.OutputPath
            StreamFile          = $this.StreamFile
            TotalResultsWritten = $this.TotalResultsWritten
            TotalFlushes        = $this.TotalFlushes
            BufferSize          = $this.BufferSize
            OriginalBufferSize  = $this.OriginalBufferSize
            PeakMemoryMB        = [Math]::Round($this.PeakMemoryMB, 2)
            ResultsPerSecond    = [Math]::Round($calculatedResultsPerSecond, 2)
            ElapsedSeconds      = [Math]::Round($elapsedSeconds, 2)
            IsFinalized         = $this.IsFinalized
        }
    }
}

function New-StreamingOutputWriter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 1000)]
        [int]$BufferSize = 10,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 600)]
        [int]$FlushIntervalSeconds = 30,

        [Parameter(Mandatory=$false)]
        [bool]$EnableMemoryMonitoring = $false,

        [Parameter(Mandatory=$false)]
        [ValidateRange(50, 4096)]
        [int]$MemoryThresholdMB = 200
    )

    [StreamingOutputWriter]::new(
        $OutputPath,
        $BufferSize,
        $FlushIntervalSeconds,
        [bool]$EnableMemoryMonitoring,
        $MemoryThresholdMB
    )
}

function Read-StreamedResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$StreamFile,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxResults = 0,

        [Parameter()]
        [scriptblock]$Filter
    )

    $results = New-Object System.Collections.Generic.List[psobject]
    $reader = $null
    $acceptedCount = 0

    try {
        $reader = [System.IO.File]::OpenText((Resolve-Path -LiteralPath $StreamFile))

        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $obj = $line | ConvertFrom-Json

            if ($Filter) {
                $include = $false
                try {
                    $filtered = @($obj | Where-Object -FilterScript $Filter)
                    $include = $filtered.Count -gt 0
                }
                catch {
                    $include = [bool](& $Filter $obj)
                }

                if (-not $include) {
                    continue
                }
            }

            $results.Add($obj)
            $acceptedCount++

            if ($MaxResults -gt 0 -and $acceptedCount -ge $MaxResults) {
                break
            }
        }
    }
    finally {
        if ($reader) {
            $reader.Close()
            $reader.Dispose()
        }
    }

    return $results
}

function Consolidate-StreamingResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$StreamFile,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter()]
        [bool]$IncludeCSV = $true,

        [Parameter()]
        [bool]$IncludeHTML = $true
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $timestamp = Get-Date
    $suffix = '{0:yyyyMMdd-HHmmss-fff}' -f $timestamp
    $jsonOutput = Join-Path $OutputPath "audit_consolidated_$suffix.json"
    $csvOutput = if ($IncludeCSV) { Join-Path $OutputPath "audit_summary_$suffix.csv" } else { $null }
    $htmlOutput = if ($IncludeHTML) { Join-Path $OutputPath "audit_summary_$suffix.html" } else { $null }

    $reader = $null
    $jsonWriter = $null
    $htmlWriter = $null
    $csvBuffer = if ($IncludeCSV) { New-Object System.Collections.Generic.List[psobject] } else { $null }
    $csvFlushThreshold = 200
    $csvFlusher = {
        param(
            [System.Collections.Generic.List[psobject]]$buffer,
            [string]$path
        )

        if ($buffer.Count -eq 0) {
            return
        }

        $append = Test-Path -LiteralPath $path
        $buffer | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Append:$append
        $buffer.Clear()
    }

    $resultsCount = 0
    $successCount = 0
    $failureCount = 0

    try {
        $reader = [System.IO.File]::OpenText((Resolve-Path -LiteralPath $StreamFile))
        $jsonWriter = [System.IO.StreamWriter]::new($jsonOutput, $false, [System.Text.Encoding]::UTF8)

        $timestampJson = (Get-Date -Format 'o') | ConvertTo-Json
        $streamSourceJson = (Resolve-Path -LiteralPath $StreamFile).Path | ConvertTo-Json

        $jsonWriter.WriteLine('{')
        $jsonWriter.WriteLine("  ""timestamp"": $timestampJson,")
        $jsonWriter.WriteLine("  ""streamSource"": $streamSourceJson,")
        $jsonWriter.WriteLine('  "results": [')

        if ($IncludeHTML) {
            $htmlWriter = [System.IO.StreamWriter]::new($htmlOutput, $false, [System.Text.Encoding]::UTF8)
            $htmlWriter.WriteLine('<!DOCTYPE html>')
            $htmlWriter.WriteLine('<html>')
            $htmlWriter.WriteLine('<head>')
            $htmlWriter.WriteLine('    <title>Audit Results Summary</title>')
            $htmlWriter.WriteLine('    <style>body { font-family: Arial; margin: 20px; } table { border-collapse: collapse; width: 100%; } th, td { border: 1px solid #ddd; padding: 8px; }</style>')
            $htmlWriter.WriteLine('</head>')
            $htmlWriter.WriteLine('<body>')
            $htmlWriter.WriteLine('    <h1>Audit Results Summary</h1>')
            $htmlWriter.WriteLine('    <table>')
            $htmlWriter.WriteLine('        <tr><th>Computer Name</th><th>Status</th><th>Execution Time (s)</th><th>Collectors</th><th>Errors</th></tr>')
        }

        $isFirst = $true
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $trimmed = $line.Trim()
            $obj = $trimmed | ConvertFrom-Json

            if (-not $isFirst) {
                $jsonWriter.WriteLine(',')
            }
            else {
                $isFirst = $false
            }

            $jsonWriter.Write('    ')
            $jsonWriter.Write($trimmed)

            $resultsCount++
            if ($obj.success) { $successCount++ } else { $failureCount++ }

            $collectorCount = 0
            if ($obj.collectors -is [System.Collections.IEnumerable]) {
                try {
                    $collectorCount = @($obj.collectors).Count
                }
                catch {
                    $collectorCount = 0
                }
            }
            elseif ($obj.collectors -and $obj.collectors.PSObject) {
                $collectorCount = @($obj.collectors.PSObject.Properties).Count
            }

            $errorCount = 0
            if ($obj.summary -and $obj.summary.failureCount) {
                $errorCount = $obj.summary.failureCount
            }

            if ($IncludeCSV) {
                $flatEntry = [PSCustomObject]@{
                    ComputerName   = $obj.computerName
                    Success        = $obj.success
                    ExecutionTime  = $obj.executionTimeSeconds
                    CollectorCount = $collectorCount
                    ErrorCount     = $errorCount
                }
                $csvBuffer.Add($flatEntry)
                if ($csvBuffer.Count -ge $csvFlushThreshold) {
                    & $csvFlusher $csvBuffer $csvOutput
                }
            }

            if ($htmlWriter) {
                $statusLabel = if ($obj.success) { '&check; Success' } else { '&times; Failed' }
                $htmlWriter.WriteLine('        <tr>')
                $htmlWriter.WriteLine("            <td>$($obj.computerName)</td>")
                $htmlWriter.WriteLine("            <td>$statusLabel</td>")
                $htmlWriter.WriteLine("            <td>$($obj.executionTimeSeconds)</td>")
                $htmlWriter.WriteLine("            <td>$collectorCount</td>")
                $htmlWriter.WriteLine("            <td>$errorCount</td>")
                $htmlWriter.WriteLine('        </tr>')
            }
        }

        $jsonWriter.WriteLine()
        $jsonWriter.WriteLine('  ],')
        $jsonWriter.WriteLine("  ""resultsCount"": $resultsCount")
        $jsonWriter.WriteLine('}')

        if ($IncludeCSV) {
            & $csvFlusher $csvBuffer $csvOutput
            Write-Host "[CONSOLIDATION] Wrote CSV summary: $csvOutput" -ForegroundColor Green
        }

        if ($htmlWriter) {
            $htmlWriter.WriteLine('    </table>')
            $htmlWriter.WriteLine('    <div class="summary">')
            $htmlWriter.WriteLine("        <p><strong>Total Servers:</strong> $resultsCount</p>")
            $htmlWriter.WriteLine("        <p><strong>Successful:</strong> $successCount</p>")
            $htmlWriter.WriteLine("        <p><strong>Failed:</strong> $failureCount</p>")
            $htmlWriter.WriteLine("        <p><strong>Generated:</strong> $(Get-Date -Format 'g')</p>")
            $htmlWriter.WriteLine('    </div>')
            $htmlWriter.WriteLine('</body>')
            $htmlWriter.WriteLine('</html>')
            Write-Host "[CONSOLIDATION] Wrote HTML summary: $htmlOutput" -ForegroundColor Green
        }

        Write-Host "[CONSOLIDATION] Wrote consolidated JSON: $jsonOutput" -ForegroundColor Green
    }
    finally {
        if ($reader) {
            $reader.Close()
            $reader.Dispose()
        }
        if ($jsonWriter) {
            $jsonWriter.Flush()
            $jsonWriter.Dispose()
        }
        if ($htmlWriter) {
            $htmlWriter.Flush()
            $htmlWriter.Dispose()
        }
    }

    [PSCustomObject]@{
        JsonFile     = $jsonOutput
        CsvFile      = $csvOutput
        HtmlFile     = $htmlOutput
        ResultsCount = $resultsCount
        Successful   = $successCount
        Failed       = $failureCount
    }
}

if ($MyInvocation.MyCommand.Module) {
    Export-ModuleMember -Function @(
        'New-StreamingOutputWriter',
        'Read-StreamedResults',
        'Consolidate-StreamingResults'
    )
}
