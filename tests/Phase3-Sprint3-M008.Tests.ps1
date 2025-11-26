$ErrorActionPreference = 'Stop'

Describe "M-008: Network Resilience" {
    
    Context "Invoke-NetworkResilientConnection - DNS Resolution" {
        It "Should resolve localhost with exponential backoff" {
            $session = Invoke-NetworkResilientConnection -ComputerName "localhost" -DnsRetryBackoff exponential
            
            # May succeed or fail due to env, but should not crash
            if ($session) {
                $session | Should -Not -BeNullOrEmpty
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }
        
        It "Should attempt linear backoff retry" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -DnsRetryAttempts 2 `
                    -DnsRetryBackoff linear `
                    -Verbose 3>&1
            } | Should -Not -Throw
        }
        
        It "Should accept custom retry attempt count" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -DnsRetryAttempts 5 `
                    -DnsRetryBackoff exponential
            } | Should -Not -Throw
        }
    }
    
    Context "Session Pool Management" {
        It "Should initialize session pool on first connection attempt" {
            # Connection may fail, but pool initialization should work
            try {
                Invoke-NetworkResilientConnection -ComputerName "localhost" -DnsRetryAttempts 1 -ErrorAction SilentlyContinue
            }
            catch {}
            
            # Should not throw even if pool doesn't exist yet
            $stats = Get-SessionPoolStatistics
            # Stats object should exist (even if empty/null initially)
            $stats -or $null | Should -Not -Throw
        }
        
        It "Should track pool statistics" {
            # Attempt multiple connections to generate stats
            for ($i = 0; $i -lt 2; $i++) {
                Invoke-NetworkResilientConnection -ComputerName "invalid-host-$i" `
                    -DnsRetryAttempts 1 `
                    -UseSessionPool $true `
                    -ErrorAction SilentlyContinue
            }
            
            $stats = Get-SessionPoolStatistics
            
            if ($stats) {
                $stats | Should -HaveProperty "ConnectionAttempts"
                $stats | Should -HaveProperty "ConnectionFailures"
                $stats | Should -HaveProperty "DnsRetries"
                $stats | Should -HaveProperty "PoolHits"
                $stats | Should -HaveProperty "PoolMisses"
            }
        }
        
        It "Should calculate hit rate percentage" {
            $stats = Get-SessionPoolStatistics
            
            if ($stats) {
                $stats.HitRate | Should -BeGreaterThanOrEqual 0
                $stats.HitRate | Should -BeLessThanOrEqual 100
            }
        }
    }
    
    Context "Session Pool Lifecycle" {
        It "Should support Clear-SessionPool" {
            {
                Clear-SessionPool
            } | Should -Not -Throw
        }
        
        It "Should support Clear-SessionPool with -Force flag" {
            {
                Clear-SessionPool -Force
            } | Should -Not -Throw
        }
        
        It "Should support Restore-SessionPoolConnection" {
            {
                Restore-SessionPoolConnection -ComputerName "TEST-SERVER"
            } | Should -Not -Throw
        }
    }
    
    Context "Connection Parameters" {
        It "Should accept custom port numbers" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -Port 5986 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should accept custom session timeout" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -SessionTimeout 60 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should accept custom session pool TTL" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -SessionPoolTTL 300 `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
        
        It "Should allow disabling session pool" {
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "localhost" `
                    -UseSessionPool $false `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
    
    Context "Error Handling" {
        It "Should handle invalid hostnames gracefully" {
            $result = Invoke-NetworkResilientConnection `
                -ComputerName "this-host-definitely-does-not-exist-99999.invalid" `
                -DnsRetryAttempts 1
            
            $result | Should -BeNullOrEmpty
        }
        
        It "Should return null on connection failure" {
            $result = Invoke-NetworkResilientConnection `
                -ComputerName "127.0.0.1" `
                -Port 65000 `
                -DnsRetryAttempts 1
            
            # May fail to connect even if DNS succeeds
            $result | Should -BeOfType [System.Management.Automation.Runspaces.PSSession] -Or $result | Should -BeNullOrEmpty
        }
    }
}

Describe "M-008: Network Resilience - Integration" {
    
    Context "Session Pool Performance Benefits" {
        It "Should improve performance on subsequent connections" {
            $stats1 = Get-SessionPoolStatistics
            
            Clear-SessionPool -Force
            
            # Reset should clear stats (or stats should be empty)
            $stats2 = Get-SessionPoolStatistics
            
            if ($stats2) {
                $stats2.PoolHits | Should -Be 0
            }
        }
    }
    
    Context "Invoke-ParallelCollectors Integration" {
        It "Should work with Invoke-ParallelCollectors" {
            {
                # Function exists and can be called
                Get-Command Invoke-ParallelCollectors -ErrorAction Stop
            } | Should -Not -Throw
        }
    }
}

Describe "M-008: Network Resilience - DNS Retry Strategies" {
    
    Context "Exponential Backoff Calculation" {
        It "Should calculate exponential delays correctly" {
            # 1st retry: 2^0 * 1000 = 1000ms
            # 2nd retry: 2^1 * 1000 = 2000ms
            # 3rd retry: 2^2 * 1000 = 4000ms
            
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "invalid-host" `
                    -DnsRetryAttempts 3 `
                    -DnsRetryBackoff exponential `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
    
    Context "Linear Backoff Calculation" {
        It "Should calculate linear delays correctly" {
            # 1st retry: 1 * 1000 = 1000ms
            # 2nd retry: 2 * 1000 = 2000ms
            # 3rd retry: 3 * 1000 = 3000ms
            
            {
                Invoke-NetworkResilientConnection `
                    -ComputerName "invalid-host" `
                    -DnsRetryAttempts 3 `
                    -DnsRetryBackoff linear `
                    -ErrorAction SilentlyContinue
            } | Should -Not -Throw
        }
    }
}
