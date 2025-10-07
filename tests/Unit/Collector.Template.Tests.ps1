Import-Module "$PSScriptRoot/../../src/ServerAuditToolkitV2.psd1" -Force
Describe 'Collector template' {
  It 'Get-SATRolesFeatures returns hashtable' {
    $cap = Get-SATCapability
    $r = Get-SATRolesFeatures -ComputerName $env:COMPUTERNAME -Capability $cap
    $r | Should -BeOfType Hashtable
    $r[$env:COMPUTERNAME] | Should -Not -BeNullOrEmpty
  }
}
