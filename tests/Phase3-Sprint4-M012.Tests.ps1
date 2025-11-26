<#
.SYNOPSIS
    Test suite for M-012: Output Streaming & Memory Reduction
.DESCRIPTION
    Comprehensive tests validating streaming output functionality,
    memory optimization, and integration with batch processing.
#>

Describe "M-012: Output Streaming & Memory Reduction" -Tag "Phase3", "OutputStreaming" {
    
    BeforeAll {
        # Import streaming writer functionality
        . "$PSScriptRoot\..\src\Private\New-StreamingOutputWriter.ps1"
        
        # Create temporary test directory
        $global:TestOutputPath = Join-Path $env:TEMP "M012-Tests-$(Get-Random)"
        New-Item -ItemType Directory -Path $global:TestOutputPath -Force | Out-Null
    }
    
    AfterAll {
        # Cleanup test directory
        if (Test-Path $global:TestOutputPath) {
            Remove-Item -Path $global:TestOutputPath -Recurse -Force
        }
    }
    
    <# BASIC FUNCTIONALITY TESTS #>
    
    Context "Streaming Writer Initialization" {
        
        It "Creates streaming writer with default parameters" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath
            $writer | Should -Not -BeNullOrEmpty
            $writer.OutputPath | Should -Be $global:TestOutputPath
            $writer.BufferSize | Should -Be 10
            $writer.FlushIntervalSeconds | Should -Be 30
        }
        
        It "Creates streaming file in output directory" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath
            Test-Path $writer.StreamFile | Should -Be $true
        }
        
        It "Initializes with custom buffer size" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 5
            $writer.BufferSize | Should -Be 5
        }
        
        It "Initializes with custom flush interval" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -FlushIntervalSeconds 60
            $writer.FlushIntervalSeconds | Should -Be 60
        }
    }
    
    Context "Adding and Flushing Results" {
        
        It "Adds single result to buffer" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 10
            $testResult = [PSCustomObject]@{ 
                computerName = "SERVER01"
                success = $true
                executionTimeSeconds = 45
            }
            $writer.AddResult($testResult)
            $writer.ResultBuffer.Count | Should -Be 1
        }
        
        It "Automatically flushes when buffer is full" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 3
            
            # Add 4 results (should trigger auto-flush at 3)
            for ($i = 1; $i -le 4; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                    index = $i
                }
                $writer.AddResult($result)
            }
            
            $writer.TotalFlushes | Should -BeGreaterThan 0
        }
        
        It "Manual flush writes all buffered results" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 100
            
            # Add 5 results without triggering auto-flush
            for ($i = 1; $i -le 5; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                }
                $writer.AddResult($result)
            }
            
            $writer.ResultBuffer.Count | Should -Be 5
            $writer.Flush()
            $writer.ResultBuffer.Count | Should -Be 0
            $writer.TotalResultsWritten | Should -Be 5
        }
        
        It "Prevents adding results after finalization" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath
            $writer.Finalize()
            
            {
                $result = [PSCustomObject]@{ computerName = "SERVER01" }
                $writer.AddResult($result)
            } | Should -Throw "finalized"
        }
    }
    
    Context "Streaming File Format" {
        
        It "Writes results in JSONL format (one JSON per line)" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 3
            
            # Add 3 results
            for ($i = 1; $i -le 3; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Verify file contains valid JSONL
            $lines = @(Get-Content $writer.StreamFile)
            $lines.Count | Should -Be 3
            
            # Each line should be valid JSON
            foreach ($line in $lines) {
                { $line | ConvertFrom-Json } | Should -Not -Throw
            }
        }
    }
    
    <# MEMORY OPTIMIZATION TESTS #>
    
    Context "Memory Monitoring and Optimization" {
        
        It "Tracks peak memory usage when monitoring enabled" {
            $writer = New-StreamingOutputWriter `
                -OutputPath $global:TestOutputPath `
                -BufferSize 5 `
                -EnableMemoryMonitoring $true
            
            # Add multiple results
            for ($i = 1; $i -le 20; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER$('{0:D2}' -f $i)"
                    success = $true
                    data = ("X" * 1000) # 1KB of data
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            $writer.PeakMemoryMB | Should -BeGreaterThan 0
        }
        
        It "Reduces buffer size under memory pressure" {
            $writer = New-StreamingOutputWriter `
                -OutputPath $global:TestOutputPath `
                -BufferSize 50 `
                -EnableMemoryMonitoring $true `
                -MemoryThresholdMB 100  # Very low threshold to trigger immediately
            
            # Add many results to trigger memory pressure
            for ($i = 1; $i -le 100; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER$('{0:D3}' -f $i)"
                    success = $true
                    largeData = ("X" * 5000) # 5KB per result
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Buffer size should have been reduced
            $writer.BufferSize | Should -BeLessThan $writer.OriginalBufferSize
        }
    }
    
    <# RESULT READING TESTS #>
    
    Context "Reading Streamed Results" {
        
        It "Reads all results from streaming file" {
            # Create streaming file with results
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 5; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                    index = $i
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Read results back
            $readResults = Read-StreamedResults -StreamFile $writer.StreamFile
            $readResults.Count | Should -Be 5
            $readResults[0].index | Should -Be 1
        }
        
        It "Applies filter when reading results" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 5; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = if ($i % 2 -eq 0) { $true } else { $false }
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Read only successful results
            $readResults = Read-StreamedResults `
                -StreamFile $writer.StreamFile `
                -Filter { $_.success -eq $true }
            
            $readResults.Count | Should -Be 2
        }
        
        It "Limits results with MaxResults parameter" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 10; $i++) {
                $result = [PSCustomObject]@{ index = $i }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Read only first 3 results
            $readResults = Read-StreamedResults -StreamFile $writer.StreamFile -MaxResults 3
            $readResults.Count | Should -Be 3
        }
            It "Respects MaxResults even when filter skips entries" {
                $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2

                for ($i = 1; $i -le 6; $i++) {
                    $result = [PSCustomObject]@{
                        computerName = "SERVER0$i"
                        success = ($i % 2 -eq 0)
                    }
                    $writer.AddResult($result)
                }

                $writer.Finalize()

                $filtered = Read-StreamedResults `
                    -StreamFile $writer.StreamFile `
                    -Filter { $_.success } `
                    -MaxResults 2

                $filtered.Count | Should -Be 2
                $filtered | ForEach-Object { $_.success | Should -BeTrue }
            }
    }
    
    <# CONSOLIDATION TESTS #>
    
    Context "Consolidating Streaming Results" {
        
        It "Creates consolidated JSON from streaming file" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 3; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Consolidate
            $consolidation = Consolidate-StreamingResults `
                -StreamFile $writer.StreamFile `
                -OutputPath $global:TestOutputPath `
                -IncludeCSV $false `
                -IncludeHTML $false
            
            Test-Path $consolidation.JsonFile | Should -Be $true
            $consolidation.ResultsCount | Should -Be 3
                $consolidation.Successful | Should -Be 3
                $consolidation.Failed | Should -Be 0
        }
        
        It "Generates CSV export during consolidation" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 3; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                    executionTimeSeconds = 30 + $i
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Consolidate with CSV
            $consolidation = Consolidate-StreamingResults `
                -StreamFile $writer.StreamFile `
                -OutputPath $global:TestOutputPath `
                -IncludeCSV $true `
                -IncludeHTML $false
            
            Test-Path $consolidation.CsvFile | Should -Be $true
                $consolidation.ResultsCount | Should -Be 3
        }
        
        It "Generates HTML summary during consolidation" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 2
            
            for ($i = 1; $i -le 3; $i++) {
                $result = [PSCustomObject]@{ 
                    computerName = "SERVER0$i"
                    success = $true
                }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            
            # Consolidate with HTML
            $consolidation = Consolidate-StreamingResults `
                -StreamFile $writer.StreamFile `
                -OutputPath $global:TestOutputPath `
                -IncludeCSV $false `
                -IncludeHTML $true
            
            Test-Path $consolidation.HtmlFile | Should -Be $true
                $consolidation.ResultsCount | Should -Be 3
        }
    }
    
    <# STATISTICS TESTS #>
    
    Context "Streaming Statistics" {
        
        It "Provides accurate statistics after completion" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 5
            
            for ($i = 1; $i -le 12; $i++) {
                $result = [PSCustomObject]@{ index = $i }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            $stats = $writer.GetStatistics()
            
            $stats.TotalResultsWritten | Should -Be 12
            $stats.TotalFlushes | Should -BeGreaterThan 0
            $stats.IsFinalized | Should -Be $true
        }
        
        It "Calculates results per second throughput" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath -BufferSize 1
            
            # Add 10 results
            for ($i = 1; $i -le 10; $i++) {
                $result = [PSCustomObject]@{ index = $i }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            $stats = $writer.GetStatistics()
            
            $stats.ResultsPerSecond | Should -BeGreaterThan 0
            $stats.ElapsedSeconds | Should -BeGreaterThan 0
        }
    }
    
    <# INTEGRATION TESTS #>
    
    Context "Integration with Batch Processing" {
        
        It "Handles large batch with streaming without excessive memory" {
            $writer = New-StreamingOutputWriter `
                -OutputPath $global:TestOutputPath `
                -BufferSize 5 `
                -EnableMemoryMonitoring $true
            
            # Simulate 100-server batch
            for ($i = 1; $i -le 100; $i++) {
                $result = [PSCustomObject]@{
                    computerName = "SERVER$('{0:D3}' -f $i)"
                    success = $true
                    executionTimeSeconds = [Random]::new().Next(30, 120)
                    collectors = @("Get-ServerInfo", "Get-IISInfo", "Get-Services")
                    data = "Audit data for server $i"
                }
                $writer.AddResult($result)
                
                # Simulate some delay
                Start-Sleep -Milliseconds 5
            }
            
            $writer.Finalize()
            $stats = $writer.GetStatistics()
            
            $stats.TotalResultsWritten | Should -Be 100
            # Peak memory should be reasonable (under 500MB for this simulation)
            $stats.PeakMemoryMB | Should -BeLessThan 500
        }
    }
    
    <# ERROR HANDLING TESTS #>
    
    Context "Error Handling and Edge Cases" {
        
        It "Handles empty streaming file gracefully" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath
            $writer.Finalize()
            
            # Read empty file should not throw
            $results = Read-StreamedResults -StreamFile $writer.StreamFile
            $results.Count | Should -Be 0
        }
        
        It "Handles finalization multiple times idempotently" {
            $writer = New-StreamingOutputWriter -OutputPath $global:TestOutputPath
            
            $result = [PSCustomObject]@{ test = "data" }
            $writer.AddResult($result)
            
            # Finalize twice - second should be no-op
            $writer.Finalize()
            { $writer.Finalize() } | Should -Not -Throw
        }
        
        It "Handles very small buffer sizes" {
            $writer = New-StreamingOutputWriter `
                -OutputPath $global:TestOutputPath `
                -BufferSize 1
            
            # Add 5 results with buffer size of 1 = 5 auto-flushes
            for ($i = 1; $i -le 5; $i++) {
                $result = [PSCustomObject]@{ index = $i }
                $writer.AddResult($result)
            }
            
            $writer.Finalize()
            $stats = $writer.GetStatistics()
            
            $stats.TotalResultsWritten | Should -Be 5
            $stats.TotalFlushes | Should -Be 5
        }
    }
}
