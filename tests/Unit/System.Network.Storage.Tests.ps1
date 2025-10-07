Import-Module "$PSScriptRoot/../../src/ServerAuditToolkitV2.psd1" -Force

Describe 'System/Network/Storage collectors' {
  BeforeAll { $cap = Get-SATCapability; $me = $env:COMPUTERNAME }

  It 'Get-SATSystem emits hashtable' {
    (Get-SATSystem -ComputerName $me -Capability $cap) | Should -BeOfType Hashtable
  }
  It 'Get-SATNetwork emits hashtable' {
    (Get-SATNetwork -ComputerName $me -Capability $cap) | Should -BeOfType Hashtable
  }
  It 'Get-SATStorage emits hashtable' {
    (Get-SATStorage -ComputerName $me -Capability $cap) | Should -BeOfType Hashtable
  }
  It 'Get-SATScheduledTasks emits hashtable' {
    (Get-SATScheduledTasks -ComputerName $me -Capability $cap -MaxTasksPerServer 50) | Should -BeOfType Hashtable
  }
  It 'Get-SATLocalAccounts emits hashtable' {
    (Get-SATLocalAccounts -ComputerName $me -Capability $cap -MaxMembersPerGroup 50) | Should -BeOfType Hashtable
  }
}
