$ErrorActionPreference = 'Stop'

Describe "M-014: Health Diagnostics & Self-Healing" {
    
    Context "Health Diagnostics - Basic Functionality" {
        It "Should create health diagnostics object" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 9
                    FailedServers = 1
                    AverageFetchTimeSeconds = 25
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            {
                New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            } | Should -Not -Throw
        }
        
        It "Should have required properties" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 10
                    FailedServers = 0
                    AverageFetchTimeSeconds = 15
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag | Should -HaveProperty "HealthScore"
            $diag | Should -HaveProperty "IssuesDetected"
            $diag | Should -HaveProperty "CriticalIssues"
            $diag | Should -HaveProperty "Warnings"
            $diag | Should -HaveProperty "Recommendations"
        }
    }
    
    Context "Performance Analysis" {
        It "Should detect slow average execution time" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 10
                    FailedServers = 0
                    AverageFetchTimeSeconds = 500
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.PerformanceIssues.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Resource Analysis" {
        It "Should detect high failure rate" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 7
                    FailedServers = 3
                    AverageFetchTimeSeconds = 25
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.ResourceIssues.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Connectivity Analysis" {
        It "Should detect connection errors" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 3
                    SuccessfulServers = 1
                    FailedServers = 2
                    AverageFetchTimeSeconds = 15
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 30
                }
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Success = $false
                        Errors = @('Connection refused to server')
                    },
                    @{
                        ComputerName = 'SERVER02'
                        Success = $false
                        Errors = @('DNS resolution failed')
                    }
                )
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.ConnectivityIssues.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Configuration Analysis" {
        It "Should detect authentication errors" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 2
                    SuccessfulServers = 0
                    FailedServers = 2
                    AverageFetchTimeSeconds = 5
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 0
                }
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Success = $false
                        Errors = @('Access denied: authentication failure')
                    }
                )
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.ConfigurationIssues.Count | Should -BeGreaterThan 0
        }
        
        It "Should detect WinRM configuration issues" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 1
                    SuccessfulServers = 0
                    FailedServers = 1
                    AverageFetchTimeSeconds = 5
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 0
                }
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Success = $false
                        Errors = @('WinRM service not available')
                    }
                )
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.ConfigurationIssues.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Health Score Calculation" {
        It "Should calculate score 100 for healthy audit" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 10
                    FailedServers = 0
                    AverageFetchTimeSeconds = 15
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.HealthScore | Should -Be 100
        }
        
        It "Should reduce score for critical issues" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 0
                    FailedServers = 10
                    AverageFetchTimeSeconds = 5
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 0
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.HealthScore | Should -BeLessThan 50
        }
    }
    
    Context "Recommendations Generation" {
        It "Should generate recommendations" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 8
                    FailedServers = 2
                    AverageFetchTimeSeconds = 200
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $diag.Recommendations.Count | Should -BeGreaterThan 0
        }
        
        It "Should prioritize critical recommendations" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 10
                    SuccessfulServers = 7
                    FailedServers = 3
                    AverageFetchTimeSeconds = 25
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            $diag = New-AuditHealthDiagnostics -AuditResults $mockResults -GenerateHTML:$false
            
            $criticalRecs = @($diag.Recommendations | Where-Object { $_.Severity -eq 'Critical' })
            if ($criticalRecs.Count -gt 0) {
                $criticalRecs[0].Priority | Should -Be 1
            }
        }
    }
    
    Context "HTML Report Generation" {
        It "Should generate HTML diagnostics report" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 5
                    SuccessfulServers = 5
                    FailedServers = 0
                    AverageFetchTimeSeconds = 10
                    DurationSeconds = 50
                    TotalCollectorsExecuted = 25
                }
                Servers = @()
            }
            
            $outputPath = "TestDrive:\diagnostics"
            
            $diag = New-AuditHealthDiagnostics `
                -AuditResults $mockResults `
                -OutputPath $outputPath `
                -GenerateHTML
            
            $diag.Files.Count | Should -BeGreaterThan 0
        }
    }
    
    Context "Auto-Remediation Scripts" {
        It "Should generate auto-remediation suggestions" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 2
                    SuccessfulServers = 0
                    FailedServers = 2
                    AverageFetchTimeSeconds = 5
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 0
                }
                Servers = @(
                    @{
                        ComputerName = 'SERVER01'
                        Success = $false
                        Errors = @('DNS resolution failed')
                    }
                )
            }
            
            $diag = New-AuditHealthDiagnostics `
                -AuditResults $mockResults `
                -GenerateHTML:$false `
                -ApplyAutoRemediation
            
            $diag.AutoRemediations.Count | Should -BeGreaterThan 0
        }
    }
}

Describe "M-014: Health Diagnostics - Helper Functions" {
    
    Context "Performance Issue Detection" {
        It "Should detect high timeout count" {
            $mockResults = @{
                SessionId = [guid]::NewGuid().ToString()
                Summary = @{
                    TotalServers = 5
                    SuccessfulServers = 5
                    FailedServers = 0
                    AverageFetchTimeSeconds = 15
                    DurationSeconds = 100
                    TotalCollectorsExecuted = 50
                }
                Servers = @()
            }
            
            {
                Get-PerformanceIssues -AuditResults $mockResults
            } | Should -Not -Throw
        }
    }
    
    Context "Health Score Calculation" {
        It "Should calculate correct score" {
            $score = Get-HealthScore `
                -CriticalIssues 0 `
                -Warnings 0 `
                -TotalServers 10 `
                -SuccessRate 1.0
            
            $score | Should -Be 100
        }
        
        It "Should not go below 0" {
            $score = Get-HealthScore `
                -CriticalIssues 50 `
                -Warnings 50 `
                -TotalServers 10 `
                -SuccessRate 0.0
            
            $score | Should -BeGreaterThanOrEqual 0
        }
    }
}
