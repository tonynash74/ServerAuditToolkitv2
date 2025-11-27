@{
    # PS2-safe manifest (no RootModule/CompatiblePSEditions)
    ModuleToProcess   = 'ServerAuditToolkitV2.psm1'

    GUID              = 'f0b6f1a2-2a1f-4a6f-9b7e-8b6c2a4d22b9'
    Author            = 'ServerAuditToolkitV2 Team'
    CompanyName       = 'ServerAuditToolkit'
    Copyright         = '(c) ServerAuditToolkit. All rights reserved.'
    ModuleVersion     = '2.1.1'
    Description       = 'Windows Server audit toolkit to produce migration readiness datasets and a client-ready HTML report. PS2+ compatible.'
    PowerShellVersion = '2.0'

    # Keep these empty for maximum compatibility
    RequiredModules       = @()
    RequiredAssemblies    = @()
    ScriptsToProcess      = @()
    TypesToProcess        = @()
    FormatsToProcess      = @()
    FileList              = @()
    ModuleList            = @()

    # Export everything; simpler than maintaining a long list across PS2/PS5
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{}
}
