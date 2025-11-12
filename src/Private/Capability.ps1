function Get-SATCapability {
  $cap = @{
    PSVersion         = (Get-SATPSMajor)
    HasServerMgr      = (Test-SATModule 'ServerManager')
    HasDnsModule      = (Test-SATModule 'DnsServer') -or (Test-SATModule 'DNS')
    HasDhcpModule     = (Test-SATModule 'DhcpServer')
    HasIISModule      = (Test-SATModule 'WebAdministration')
    HasHyperVModule   = (Test-SATModule 'Hyper-V')
    HasSmbModule      = (Test-SATModule 'SmbShare') -or ([bool](Get-Command Get-SmbShare -ErrorAction SilentlyContinue))
    HasADModule       = (Test-SATModule 'ActiveDirectory')
    HasNetTCPIP       = (Test-SATModule 'NetTCPIP')
    HasNetLbfo        = (Test-SATModule 'NetLbfo')
    HasStorage        = (Test-SATModule 'Storage')
    HasScheduledTasks = [bool](Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
    HasLocalAccounts  = [bool](Get-Command Get-LocalUser -ErrorAction SilentlyContinue)
    HasPrintModule    = (Test-SATModule 'PrintManagement')
    RemotingOn        = (Get-SATServiceStatus 'WinRM') -eq 'Running'
  }
  return $cap
}

