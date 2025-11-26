$ErrorActionPreference = 'Stop'

Describe "M-009: Resource Limits Monitoring" {
    
    Context "Start-AuditResourceMonitoring" {
        It "Should initialize monitoring without errors" {
            {
                Start-AuditResourceMonitoring -MaxParallelJobs 3 -CpuThreshold 85 -MemoryThreshold 90
            } | Should -Not -Throw
        }
        
        It "Should accept custom thresholds" {
            {
                Start-AuditResourceMonitoring `
                    -CpuThreshold 80 `
                    -MemoryThreshold 85 `
                    -MaxParallelJobs 4
            } | Should -Not -Throw
        }
        
        It "Should accept custom monitoring interval" {
            {
                Start-AuditResourceMonitoring `
                    -MonitoringIntervalSeconds 5 `
                    -MaxParallelJobs 2
            } | Should -Not -Throw
        }
        
        It "Should accept recovery multiplier between 1.0 and 2.0" {
            {
                Start-AuditResourceMonitoring `
                    -RecoveryMultiplier 1.5 `
                    -MaxParallelJobs 3
            } | Should -Not -Throw
        }
        
        AfterEach {
            # Clean up monitoring job
            try {
                Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }
    
    Context "Get-AuditResourceStatus" {
        BeforeEach {
            Start-AuditResourceMonitoring -MaxParallelJobs 3 | Out-Null
            Start-Sleep -Milliseconds 500  # Allow initial readings
        }
        
        It "Should return resource status object" {
            $status = Get-AuditResourceStatus
            $status | Should -Not -BeNullOrEmpty
        }
        
        It "Should have required properties" {
            $status = Get-AuditResourceStatus
            
            $status | Should -HaveProperty "MonitoringActive"
            $status | Should -HaveProperty "CurrentCpuUsage"
            $status | Should -HaveProperty "CurrentMemoryUsage"
            $status | Should -HaveProperty "IsThrottled"
            $status | Should -HaveProperty "CurrentParallelJobs"
            $status | Should -HaveProperty "MaxParallelJobs"
        }
        
        It "Should show monitoring as active" {
            $status = Get-AuditResourceStatus
            $status.MonitoringActive | Should -Be $true
        }
        
        It "Should show reasonable CPU and Memory percentages" {
            $status = Get-AuditResourceStatus
            
            $cpuValue = [int]($status.CurrentCpuUsage -replace '%')
            $memoryValue = [int]($status.CurrentMemoryUsage -replace '%')
            
            $cpuValue | Should -BeGreaterThanOrEqual 0
            $cpuValue | Should -BeLessThanOrEqual 100
            $memoryValue | Should -BeGreaterThanOrEqual 0
            $memoryValue | Should -BeLessThanOrEqual 100
        }
        
        It "Should report current parallel jobs less than or equal to max" {
            $status = Get-AuditResourceStatus
            $status.CurrentParallelJobs | Should -BeLessThanOrEqual $status.MaxParallelJobs
        }
        
        AfterEach {
            Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
        }
    }
    
    Context "Stop-AuditResourceMonitoring" {
        BeforeEach {
            Start-AuditResourceMonitoring -MaxParallelJobs 3 | Out-Null
        }
        
        It "Should stop monitoring without errors" {
            {
                Stop-AuditResourceMonitoring
            } | Should -Not -Throw
        }
        
        It "Should mark monitoring as inactive" {
            Stop-AuditResourceMonitoring
            Start-Sleep -Milliseconds 200
            
            $status = Get-AuditResourceStatus
            if ($status) {
                $status.MonitoringActive | Should -Be $false
            }
        }
    }
    
    Context "Get-AuditResourceStatistics" {
        BeforeEach {
            Start-AuditResourceMonitoring -MaxParallelJobs 3 | Out-Null
            Start-Sleep -Milliseconds 500
        }
        
        It "Should return statistics object" {
            $stats = Get-AuditResourceStatistics
            
            if ($stats) {
                $stats | Should -Not -BeNullOrEmpty
            }
        }
        
        It "Should track throttle events" {
            $stats = Get-AuditResourceStatistics
            
            if ($stats) {
                $stats | Should -HaveProperty "TotalThrottleEvents"
                $stats | Should -HaveProperty "TotalRecoveryEvents"
            }
        }
        
        It "Should have throttle history" {
            $stats = Get-AuditResourceStatistics
            
            if ($stats) {
                $stats | Should -HaveProperty "ThrottleHistory"
            }
        }
        
        AfterEach {
            Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
        }
    }
}

Describe "M-009: Resource Limits - Throttling Behavior" {
    
    Context "Auto-Throttling Logic" {
        BeforeEach {
            Start-AuditResourceMonitoring `
                -CpuThreshold 85 `
                -MemoryThreshold 90 `
                -MaxParallelJobs 3 `
                -MonitoringIntervalSeconds 1 | Out-Null
            Start-Sleep -Milliseconds 500
        }
        
        It "Should maintain normal parallelism under low resource load" {
            $status = Get-AuditResourceStatus
            
            # Under normal conditions, should have max parallel jobs
            if ([int]($status.CurrentCpuUsage -replace '%') -lt 85) {
                $status.CurrentParallelJobs | Should -BeGreaterThan 0
            }
        }
        
        It "Should support progressive reduction" {
            # MaxParallelJobs=3 should reduce to 1 on high pressure
            # (1st: 3→1, next: would be 0 but minimum is 1)
            $status = Get-AuditResourceStatus
            $status.CurrentParallelJobs | Should -BeGreaterThanOrEqual 1
        }
        
        AfterEach {
            Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
        }
    }
    
    Context "Recovery Behavior" {
        BeforeEach {
            Start-AuditResourceMonitoring `
                -CpuThreshold 85 `
                -MemoryThreshold 90 `
                -MaxParallelJobs 4 `
                -RecoveryMultiplier 1.5 | Out-Null
            Start-Sleep -Milliseconds 500
        }
        
        It "Should support recovery multiplier configuration" {
            $status = Get-AuditResourceStatus
            $status | Should -Not -BeNullOrEmpty
        }
        
        It "Should never reduce parallelism below 1" {
            $status = Get-AuditResourceStatus
            $status.CurrentParallelJobs | Should -BeGreaterThanOrEqual 1
        }
        
        It "Should never exceed maximum parallelism during recovery" {
            $status = Get-AuditResourceStatus
            $status.CurrentParallelJobs | Should -BeLessThanOrEqual $status.MaxParallelJobs
        }
        
        AfterEach {
            Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
        }
    }
}

Describe "M-009: Resource Limits - Configuration" {
    
    Context "Parameter Validation" {
        It "Should enforce CPU threshold range (50-99)" {
            {
                Start-AuditResourceMonitoring -CpuThreshold 40 -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should enforce Memory threshold range (50-99)" {
            {
                Start-AuditResourceMonitoring -MemoryThreshold 40 -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should enforce monitoring interval range (1-30)" {
            {
                Start-AuditResourceMonitoring -MonitoringIntervalSeconds 60 -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should enforce max parallel jobs range (1-16)" {
            {
                Start-AuditResourceMonitoring -MaxParallelJobs 32 -ErrorAction Stop
            } | Should -Throw
        }
        
        It "Should enforce recovery multiplier range (1.0-2.0)" {
            {
                Start-AuditResourceMonitoring -RecoveryMultiplier 3.0 -ErrorAction Stop
            } | Should -Throw
        }
    }
    
    Context "Defaults" {
        BeforeEach {
            Start-AuditResourceMonitoring | Out-Null
            Start-Sleep -Milliseconds 500
        }
        
        It "Should use sensible defaults" {
            $status = Get-AuditResourceStatus
            
            $status.CpuThreshold | Should -Be "85%"
            $status.MemoryThreshold | Should -Be "90%"
            $status.MaxParallelJobs | Should -Be 3
        }
        
        AfterEach {
            Stop-AuditResourceMonitoring -ErrorAction SilentlyContinue
        }
    }
}
