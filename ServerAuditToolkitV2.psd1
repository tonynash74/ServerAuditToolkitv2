@{
    # Root-level manifest that redirects to the implementation in /src
    ModuleToProcess   = 'src\ServerAuditToolkitV2.psm1'

    GUID              = 'a8a5b1d6-7b9a-4f1f-9c2f-7c2f3f0b1e4a'
    Author            = 'ServerAuditToolkitV2 Team'
    CompanyName       = 'ServerAuditToolkit'
    Copyright         = '(c) ServerAuditToolkit. All rights reserved.'
    ModuleVersion     = '1.0.0.0'
    Description       = 'Wrapper manifest that loads the PS2-safe module from /src.'

    PowerShellVersion = '2.0'

    RequiredModules       = @()
    RequiredAssemblies    = @()
    ScriptsToProcess      = @()
    TypesToProcess        = @()
    FormatsToProcess      = @()
    FileList              = @()
    ModuleList            = @()

    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{}
}
