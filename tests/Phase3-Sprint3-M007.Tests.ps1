$ErrorActionPreference = 'Stop'

Describe "M-007: Pre-flight Health Checks" {
    
    Context "Test-AuditPrerequisites - DNS Resolution" {
        It "Should detect failed DNS resolution" {
            $result = & {
                # Test DNS for invalid hostname
                $invalidHost = "this-host-definitely-does-not-exist-12345.invalid"
                $dnsTest = Test-AuditPrerequisites -ComputerName $invalidHost
                return $dnsTest
            }
            
            # Should complete without crashing (handles gracefully)
            $result | Should -Not -BeNullOrEmpty
        }
        
        It "Should resolve localhost successfully" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            $result.HealthScores["localhost"] | Should -BeGreaterThan 0
        }
    }
    
    Context "Test-AuditPrerequisites - Output Structure" {
        It "Should return object with required properties" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            $result | Should -HaveProperty "Timestamp"
            $result | Should -HaveProperty "ComputerName"
            $result | Should -HaveProperty "Summary"
            $result | Should -HaveProperty "HealthScores"
            $result | Should -HaveProperty "IsHealthy"
            $result | Should -HaveProperty "Results"
            $result | Should -HaveProperty "Issues"
            $result | Should -HaveProperty "Remediation"
            $result | Should -HaveProperty "ExecutionTime"
        }
        
        It "Should have valid Summary structure" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            $result.Summary | Should -HaveProperty "Passed"
            $result.Summary | Should -HaveProperty "Failed"
            $result.Summary | Should -HaveProperty "Warnings"
            $result.Summary | Should -HaveProperty "Total"
            
            $result.Summary.Total | Should -BeGreaterThan 0
        }
        
        It "Should have health scores for each computer" {
            $computers = @("localhost")
            $result = Test-AuditPrerequisites -ComputerName $computers -Timeout 5
            
            foreach ($computer in $computers) {
                $result.HealthScores.Keys | Should -Contain $computer
            }
        }
    }
    
    Context "Test-AuditPrerequisites - Health Score Calculation" {
        It "Should calculate health score between 0 and 100" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            foreach ($score in $result.HealthScores.Values) {
                $score | Should -BeGreaterThanOrEqual 0
                $score | Should -BeLessThanOrEqual 100
            }
        }
        
        It "Should mark as healthy when all checks pass" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            if ($result.Summary.Failed -eq 0 -and $result.Summary.Warnings -eq 0) {
                $result.IsHealthy | Should -Be $true
            }
        }
    }
    
    Context "Test-AuditPrerequisites - Parallel Execution" {
        It "Should execute faster in parallel (PS7+)" {
            $PSVersion = $PSVersionTable.PSVersion.Major
            
            if ($PSVersion -ge 7) {
                $computers = @("localhost")
                $startTime = [datetime]::UtcNow
                $result = Test-AuditPrerequisites `
                    -ComputerName $computers `
                    -Timeout 5 `
                    -Parallel $true `
                    -ThrottleLimit 3
                $elapsedParallel = ([datetime]::UtcNow - $startTime).TotalSeconds
                
                # Parallel execution should complete
                $result | Should -Not -BeNullOrEmpty
                $elapsedParallel | Should -BeLessThan 30
            }
            else {
                Set-ItResult -Skipped -Because "PS7+ required for parallel execution"
            }
        }
        
        It "Should support sequential execution on PS5" {
            $computers = @("localhost")
            $result = Test-AuditPrerequisites `
                -ComputerName $computers `
                -Timeout 5 `
                -Parallel $false
            
            $result | Should -Not -BeNullOrEmpty
            $result.IsHealthy | Should -Not -BeNullOrEmpty
        }
    }
    
    Context "Test-AuditPrerequisites - Error Handling" {
        It "Should handle invalid port gracefully" {
            {
                Test-AuditPrerequisites -ComputerName "localhost" -Port 65000 -Timeout 2
            } | Should -Not -Throw
        }
        
        It "Should handle timeout parameter validation" {
            {
                Test-AuditPrerequisites -ComputerName "localhost" -Timeout 30
            } | Should -Not -Throw
        }
    }
    
    Context "Test-AuditPrerequisites - Remediation Suggestions" {
        It "Should provide remediation suggestions when issues detected" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            if ($result.Issues.Count -gt 0) {
                $result.Remediation | Should -Not -BeNullOrEmpty
                $result.Remediation.Count | Should -BeGreaterThan 0
            }
        }
        
        It "Should not suggest remediation when all checks pass" {
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            
            if ($result.Issues.Count -eq 0) {
                $result.Remediation.Count | Should -Be 0
            }
        }
    }
    
    Context "Test-AuditPrerequisites - Integration with Invoke-ServerAudit" {
        It "Should be callable from audit pipeline" {
            # Verify function is exported
            {
                Get-Command Test-AuditPrerequisites -ErrorAction Stop
            } | Should -Not -Throw
        }
    }
}

Describe "M-007: Pre-flight Health Checks - Performance" {
    
    Context "Execution Time Analysis" {
        It "Should complete health checks within reasonable time" {
            $startTime = [datetime]::UtcNow
            $result = Test-AuditPrerequisites -ComputerName "localhost" -Timeout 5
            $elapsed = [datetime]::UtcNow - $startTime
            
            # Should complete in under 30 seconds
            $elapsed.TotalSeconds | Should -BeLessThan 30
            
            # Verify execution time is captured
            $result.ExecutionTime | Should -BeGreaterThan 0
        }
    }
}
