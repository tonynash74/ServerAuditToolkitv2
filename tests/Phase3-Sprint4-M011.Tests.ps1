$ErrorActionPreference = 'Stop'

Describe "M-011: Error Aggregation & Metrics Dashboard" {
    
    Context "Error Extraction & Categorization" {
        It "Should extract errors from audit results" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Connection timeout')
                        Collectors = @()
                    }
                )
            }
            
            {
                New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            } | Should -Not -Throw
        }
        
        It "Should categorize connectivity errors" {
            {
                Get-ErrorCategory -ErrorMessage "Connection refused"
            } | Should -Not -Throw
        }
        
        It "Should categorize DNS errors" {
            $category = Get-ErrorCategory -ErrorMessage "DNS resolution failed"
            $category | Should -Be "DNS"
        }
        
        It "Should categorize authentication errors" {
            $category = Get-ErrorCategory -ErrorMessage "Access denied: invalid credentials"
            $category | Should -Be "Authentication"
        }
        
        It "Should categorize timeout errors" {
            $category = Get-ErrorCategory -ErrorMessage "Operation timed out after 30 seconds"
            $category | Should -Be "Timeout"
        }
        
        It "Should categorize WinRM errors" {
            $category = Get-ErrorCategory -ErrorMessage "WinRM service not available"
            $category | Should -Be "WinRM"
        }
    }
    
    Context "Error Severity Classification" {
        It "Should classify critical errors" {
            $severity = Get-ErrorSeverity -ErrorMessage "Critical failure: cannot continue"
            $severity | Should -Be "Critical"
        }
        
        It "Should classify high severity errors" {
            $severity = Get-ErrorSeverity -ErrorMessage "Error: operation failed"
            $severity | Should -Be "High"
        }
        
        It "Should classify medium severity errors" {
            $severity = Get-ErrorSeverity -ErrorMessage "Warning: possible issue detected"
            $severity | Should -Be "Medium"
        }
        
        It "Should classify low severity errors" {
            $severity = Get-ErrorSeverity -ErrorMessage "Information message"
            $severity | Should -Be "Low"
        }
    }
    
    Context "Dashboard Creation" {
        It "Should create dashboard object with required properties" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @()
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{
                            Executed = 10
                            Succeeded = 9
                            Failed = 1
                        }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard | Should -HaveProperty "GeneratedAt"
            $dashboard | Should -HaveProperty "SessionId"
            $dashboard | Should -HaveProperty "TotalErrors"
            $dashboard | Should -HaveProperty "ErrorsByType"
            $dashboard | Should -HaveProperty "ErrorsByCollector"
            $dashboard | Should -HaveProperty "SuccessRate"
            $dashboard | Should -HaveProperty "AffectedServers"
            $dashboard | Should -HaveProperty "Recommendations"
        }
        
        It "Should calculate success rate correctly" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @()
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{
                            Executed = 10
                            Succeeded = 8
                            Failed = 2
                        }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.SuccessRate | Should -Be 80
        }
        
        It "Should identify affected servers" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Connection error')
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 3; Failed = 2 }
                    },
                    @{
                        ComputerName = 'SERVER02'
                        Errors = @()
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 5; Failed = 0 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.AffectedServers.Count | Should -Be 1
            $dashboard.AffectedServers[0] | Should -Be 'SERVER01'
        }
    }
    
    Context "Error Aggregation by Type" {
        It "Should count errors by type" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Connection timeout', 'DNS resolution failed')
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 3; Failed = 2 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.ErrorsByType.Timeout | Should -Be 1
            $dashboard.ErrorsByType.DNS | Should -Be 1
        }
    }
    
    Context "Collector Error Tracking" {
        It "Should track errors by collector" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @()
                        Collectors = @(
                            @{ Name = 'Get-SystemInfo'; Errors = @('Collection failed'); ExecutionTime = 1.5 },
                            @{ Name = 'Get-NetworkInfo'; Errors = @('Timeout'); ExecutionTime = 30 }
                        )
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 2; Succeeded = 0; Failed = 2 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.ErrorsByCollector.ContainsKey('Get-SystemInfo') | Should -Be $true
            $dashboard.ErrorsByCollector['Get-SystemInfo'].Total | Should -Be 1
        }
    }
    
    Context "Severity Distribution" {
        It "Should classify errors by severity" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Critical failure', 'Error: operation failed', 'Warning: issue detected')
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 2; Failed = 3 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.ErrorsBySeverity.Critical | Should -Be 1
            $dashboard.ErrorsBySeverity.High | Should -Be 1
            $dashboard.ErrorsBySeverity.Medium | Should -Be 1
        }
    }
    
    Context "Error Trending" {
        It "Should analyze error trends" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('DNS error', 'DNS error', 'DNS error')
                        Collectors = @()
                        ExecutionStartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        CollectorsSummary = @{ Executed = 5; Succeeded = 2; Failed = 3 }
                    },
                    @{
                        ComputerName = 'SERVER02'
                        Errors = @('Connection error')
                        Collectors = @()
                        ExecutionStartTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        CollectorsSummary = @{ Executed = 5; Succeeded = 4; Failed = 1 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.Trending.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "HTML Dashboard Generation" {
        It "Should generate HTML dashboard" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Test error')
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 4; Failed = 1 }
                    }
                )
            }
            
            $outputPath = "TestDrive:\dashboard"
            
            $dashboard = New-ErrorMetricsDashboard `
                -AuditResults $mockResults `
                -OutputPath $outputPath `
                -GenerateHTML `
                -ExportJSON:$false
            
            $dashboard.Files.Count | Should -BeGreaterThan 0
        }
        
        It "Should create dashboard directory if needed" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @()
            }
            
            $outputPath = "TestDrive:\new_dashboard_output"
            
            {
                New-ErrorMetricsDashboard `
                    -AuditResults $mockResults `
                    -OutputPath $outputPath `
                    -GenerateHTML `
                    -ExportJSON:$false -ErrorAction Stop
            } | Should -Not -Throw
            
            $outputPath | Should -Exist
        }
    }
    
    Context "JSON Export" {
        It "Should export dashboard to JSON" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @()
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 5; Succeeded = 5; Failed = 0 }
                    }
                )
            }
            
            $outputPath = "TestDrive:\json_export"
            
            $dashboard = New-ErrorMetricsDashboard `
                -AuditResults $mockResults `
                -OutputPath $outputPath `
                -GenerateHTML:$false `
                -ExportJSON
            
            $jsonFiles = @(Get-ChildItem -Path $outputPath -Filter "*.json" -ErrorAction SilentlyContinue)
            $jsonFiles.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Recommendations Generation" {
        It "Should generate recommendations for low success rate" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @()
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 10; Succeeded = 7; Failed = 3 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $dashboard.Recommendations.Count | Should -BeGreaterThan 0
        }
        
        It "Should generate recommendations for connectivity errors" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Errors = @('Connection error', 'Connection error', 'Connection error', 'Connection error', 'Connection error', 'Connection error')
                        Collectors = @()
                        ExecutionStartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        CollectorsSummary = @{ Executed = 10; Succeeded = 3; Failed = 7 }
                    }
                )
            }
            
            $dashboard = New-ErrorMetricsDashboard -AuditResults $mockResults -GenerateHTML:$false -ExportJSON:$false
            
            $connRecs = $dashboard.Recommendations | Where-Object { $_.Issue -match 'connectivity|connection' }
            $connRecs.Count | Should -BeGreaterThan 0
        }
    }
}

Describe "M-011: Error Metrics Dashboard - Helper Functions" {
    
    Context "Get-ErrorCategory Function" {
        It "Should be available" {
            {
                Get-Command Get-ErrorCategory -ErrorAction Stop
            } | Should -Not -Throw
        }
    }
    
    Context "Get-ErrorSeverity Function" {
        It "Should be available" {
            {
                Get-Command Get-ErrorSeverity -ErrorAction Stop
            } | Should -Not -Throw
        }
    }
    
    Context "Error Category Edge Cases" {
        It "Should handle empty error message" {
            $category = Get-ErrorCategory -ErrorMessage ""
            $category | Should -Be "Other"
        }
        
        It "Should handle long error message" {
            $longError = "A" * 1000 + " connection timeout error"
            $category = Get-ErrorCategory -ErrorMessage $longError
            $category | Should -Be "Timeout"
        }
    }
}
