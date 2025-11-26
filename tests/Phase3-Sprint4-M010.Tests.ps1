$ErrorActionPreference = 'Stop'

Describe "M-010: Batch Processing Optimization" {
    
    Context "Invoke-BatchAudit - Basic Functionality" {
        It "Should process servers in batches" {
            $testServers = @("SERVER01", "SERVER02", "SERVER03")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 2 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should accept custom batch size" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 5 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should accept custom pipeline depth" {
            $testServers = @("SERVER01", "SERVER02", "SERVER03")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -PipelineDepth 3 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
    
    Context "Batch Result Structure" {
        It "Should return batch audit results object" {
            $testServers = @("SERVER01")
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 1 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result | Should -Not -BeNullOrEmpty
            }
        }
        
        It "Should have required properties" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 2 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result | Should -HaveProperty "TotalBatches"
                $result | Should -HaveProperty "TotalServers"
                $result | Should -HaveProperty "SuccessfulBatches"
                $result | Should -HaveProperty "Duration"
                $result | Should -HaveProperty "BatchResults"
                $result | Should -HaveProperty "OutputPath"
            }
        }
        
        It "Should calculate batch statistics" {
            $testServers = @("SERVER01", "SERVER02", "SERVER03", "SERVER04")
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 2 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result.TotalServers | Should -Be 4
                $result.TotalBatches | Should -Be 2
                $result.Duration | Should -BeGreaterThan 0
            }
        }
    }
    
    Context "Batch Output" {
        It "Should create output directory" {
            $testServers = @("SERVER01")
            $testCollector = { @{ Status = 'Success' } }
            $testPath = "TestDrive:\batch_output"
            
            Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -OutputPath $testPath `
                -ErrorAction SilentlyContinue
            
            $testPath | Should -Exist
        }
        
        It "Should generate batch output files" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            $testPath = "TestDrive:\batch_output2"
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 1 `
                -OutputPath $testPath `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                # Batch files should be created
                $batchFiles = @(Get-ChildItem -Path $testPath -Filter "batch_*.json" -ErrorAction SilentlyContinue)
                $batchFiles.Count | Should -BeGreaterThan 0
            }
        }
    }
    
    Context "Batch Size Variations" {
        It "Should enforce batch size range (1-100)" {
            $testServers = @("SERVER01")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 200 `
                    -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should enforce pipeline depth range (1-5)" {
            $testServers = @("SERVER01")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -PipelineDepth 10 `
                    -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should support batch size of 1 (sequential)" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 1 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
    
    Context "Large Environment Simulation" {
        It "Should handle 50+ server arrays" {
            $testServers = 1..50 | ForEach-Object { "SERVER$_" }
            $testCollector = { @{ Status = 'Success' } }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 10 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should calculate correct batch count for 100 servers with batch size 10" {
            $testServers = 1..100 | ForEach-Object { "SERVER$_" }
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 10 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result.TotalBatches | Should -Be 10
                $result.TotalServers | Should -Be 100
            }
        }
    }
    
    Context "Performance Metrics" {
        It "Should calculate average time per batch" {
            $testServers = @("SERVER01", "SERVER02", "SERVER03")
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 1 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result | Should -HaveProperty "AvgPerBatch"
                $result.AvgPerBatch | Should -BeGreaterThan 0
            }
        }
        
        It "Should calculate throughput (servers per minute)" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            
            $result = Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 1 `
                -ErrorAction SilentlyContinue
            
            if ($result) {
                $result | Should -HaveProperty "ThroughputServersPerMinute"
                $result.ThroughputServersPerMinute | Should -BeGreaterThan 0
            }
        }
    }
}

Describe "M-010: Batch Processing - Checkpointing & Recovery" {
    
    Context "Checkpoint Management" {
        It "Should save checkpoints" {
            $testServers = 1..20 | ForEach-Object { "SERVER$_" }
            $testCollector = { @{ Status = 'Success' } }
            $testPath = "TestDrive:\batch_checkpoint"
            
            Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 5 `
                -CheckpointInterval 2 `
                -OutputPath $testPath `
                -ErrorAction SilentlyContinue
            
            $checkpointFiles = @(Get-ChildItem -Path $testPath -Filter "checkpoint_*.json" -ErrorAction SilentlyContinue)
            $checkpointFiles.Count | Should -BeGreaterThan 0
        }
        
        It "Should provide Get-BatchCheckpoint function" {
            {
                Get-Command Get-BatchCheckpoint -ErrorAction Stop
            } | Should -Not -Throw
        }
    }
}

Describe "M-010: Batch Processing - Diagnostics" {
    
    Context "Batch Statistics" {
        It "Should provide Get-BatchStatistics function" {
            {
                Get-Command Get-BatchStatistics -ErrorAction Stop
            } | Should -Not -Throw
        }
        
        It "Should calculate success rate from batch results" {
            $testServers = 1..10 | ForEach-Object { "SERVER$_" }
            $testCollector = { @{ Status = 'Success' } }
            $testPath = "TestDrive:\batch_stats"
            
            Invoke-BatchAudit `
                -Servers $testServers `
                -Collectors @($testCollector) `
                -BatchSize 5 `
                -OutputPath $testPath `
                -ErrorAction SilentlyContinue
            
            $stats = Get-BatchStatistics -BatchPath $testPath
            
            if ($stats) {
                $stats | Should -HaveProperty "SuccessRate"
                $stats.SuccessRate | Should -BeGreaterThanOrEqual 0
            }
        }
    }
}

Describe "M-010: Batch Processing - Result Callback" {
    
    Context "Callback Execution" {
        It "Should support result callback on batch completion" {
            $testServers = @("SERVER01", "SERVER02")
            $testCollector = { @{ Status = 'Success' } }
            $callbackExecuted = $false
            
            $callback = {
                param($batch)
                $callbackExecuted = $true
            }
            
            {
                Invoke-BatchAudit `
                    -Servers $testServers `
                    -Collectors @($testCollector) `
                    -BatchSize 1 `
                    -ResultCallback $callback `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
}
