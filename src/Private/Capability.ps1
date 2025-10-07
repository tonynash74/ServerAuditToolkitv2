function Get-SATCapability {
  $cap = @{
    PSVersion         = $PSVersionTable.PSVersion.Major
    HasServerMgr      = (Get-Module -ListAvailable -Name ServerManager)
    HasDnsModule      = (Get-Module -ListAvailable -Name DnsServer) -or (Get-Module -ListAvailable -Name DNS)
    HasDhcpModule     = (Get-Module -ListAvailable -Name DhcpServer)
    HasIISModule      = (Get-Module -ListAvailable -Name WebAdministration)
    HasHyperVModule   = (Get-Module -ListAvailable -Name Hyper-V)
    HasSmbModule      = (Get-Module -ListAvailable -Name SmbShare) -or (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)
    HasADModule       = (Get-Module -ListAvailable -Name ActiveDirectory)
    HasNetTCPIP       = (Get-Module -ListAvailable -Name NetTCPIP)
    HasNetLbfo        = (Get-Module -ListAvailable -Name NetLbfo)
    HasStorage        = (Get-Module -ListAvailable -Name Storage)
    HasPrintModule   = (Get-Module -ListAvailable -Name PrintManagement)
    HasScheduledTasks = (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
    HasLocalAccounts  = (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) # Win 10/2016+
    RemotingOn        = (Get-Service WinRM -ErrorAction SilentlyContinue)?.Status -eq 'Running'
  }
  return $cap
}
