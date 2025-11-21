# Contributing to ServerAuditToolkitV2

Thank you for considering contributing to **ServerAuditToolkitV2**! This document provides guidelines for developing, testing, and submitting new collectors, features, and fixes.

---

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Workflow](#development-workflow)
4. [PowerShell Code Standards](#powershell-code-standards)
5. [Creating a New Collector](#creating-a-new-collector)
6. [Testing](#testing)
7. [Submitting a Pull Request](#submitting-a-pull-request)
8. [License](#license)

---

## Code of Conduct

- Be respectful and professional in all interactions
- Assume good intent from other contributors
- Focus on the code, not the person
- Help create a welcoming environment for all skill levels

---

## Getting Started

### Prerequisites

- **Git** (for cloning and working with the repository)
- **PowerShell 5.1+** (recommended for development)
- **Pester** (testing framework): `Install-Module -Name Pester -Force`
- **PSScriptAnalyzer** (linting): `Install-Module -Name PSScriptAnalyzer -Force`

### Setup

```powershell
# Clone the repository
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
cd ServerAuditToolkitv2

# Create a feature branch
git checkout -b feature/my-new-collector
```

---

## Development Workflow

### 1. Plan Your Contribution

Before writing code, check:
- **Existing collectors**: Does one already do what you want?
- **Open issues/discussions**: Is this already being discussed?
- **Architecture**: Does your idea fit the T1-T4 design?

### 2. Create Your Feature Branch

```powershell
# Use descriptive branch names
git checkout -b feature/add-nps-collector
git checkout -b fix/timeout-logic
git checkout -b docs/update-troubleshooting
```

### 3. Make Changes

Follow the [PowerShell Code Standards](#powershell-code-standards) below.

### 4. Test Locally

```powershell
# Run linter
Invoke-ScriptAnalyzer -Path src/Collectors/Get-MyCollector.ps1 `
    -Settings PSScriptAnalyzerSettings.psd1

# Run tests
Invoke-Pester tests/ -Verbose
```

### 5. Commit & Push

```powershell
# Commit with clear message
git commit -m "feat: add Get-NPSInfo collector for NPS server auditing"

# Push to your fork
git push origin feature/add-nps-collector
```

### 6. Open a Pull Request

See [Submitting a Pull Request](#submitting-a-pull-request) below.

---

## PowerShell Code Standards

### File Structure & Header

**All PowerShell scripts must include this header** (customized with your info):

```powershell
<#
.SYNOPSIS
    Brief one-line description.

.DESCRIPTION
    Longer description of functionality. Include:
    - What the script/collector does
    - What information it collects
    - Performance considerations (if applicable)

.PARAMETER ComputerName
    Target server name or IP address. Accepts pipeline input.

.PARAMETER Credential
    PSCredential object for remote authentication (if applicable).

.PARAMETER DryRun
    If $true, validates prerequisites without collecting data.

.EXAMPLE
    # Simple example
    .\Get-MyCollector.ps1

.EXAMPLE
    # Example with parameters
    .\Get-MyCollector.ps1 -ComputerName "SERVER01" -DryRun

.OUTPUTS
    [PSObject]
    Returns a custom object with properties:
    - Success: [bool] Execution status
    - Data: [object] Collected information
    - Error: [string] Error message (if failed)
    - ExecutionTime: [timespan] How long it took

.NOTES
    Author:       [Your Name]
    Organization: inTEC Group
    Version:      1.0.0
    Modified:     [Date in YYYY-MM-DD format]
    PowerShell:   [Minimum version, e.g., 2.0, 5.1, 7.0]
    License:      MIT

    Description of any special considerations, dependencies, or gotchas.

.LINK
    https://github.com/tonynash74/ServerAuditToolkitv2

#>
```

### Collector Metadata Tags

Embed these tags in comment block after help section:

```powershell
# @CollectorName: Get-MyCollector
# @PSVersions: 2.0,4.0,5.1,7.0
# @MinWindowsVersion: 2008R2
# @MaxWindowsVersion:
# @Dependencies: Module1,Module2
# @Timeout: 30
# @Category: core|application|infrastructure|compliance
# @Critical: true|false
```

**Tags Explained:**
| Tag | Example | Purpose |
|-----|---------|---------|
| `@CollectorName` | `Get-ServerInfo` | Unique identifier for this collector |
| `@PSVersions` | `2.0,5.1,7.0` | PowerShell versions supported |
| `@MinWindowsVersion` | `2008R2` | Earliest Windows Server version |
| `@MaxWindowsVersion` | (blank) | Latest Windows version (blank = unlimited) |
| `@Dependencies` | `WebAdministration` | Required modules/features |
| `@Timeout` | `30` | Max execution seconds |
| `@Category` | `application` | Classification for grouping |
| `@Critical` | `true` | Is this essential for migration decisions? |

### Code Style

- **Indentation**: 4 spaces (no tabs)
- **Line length**: Max 120 characters (soft limit; hard limit 150)
- **Variable naming**: PascalCase for objects, camelCase for internal vars
  ```powershell
  $ComputerName  # Parameter (PascalCase)
  $localVariable # Internal (camelCase)
  ```

- **Functions**: Use `function` keyword, full names (no aliases)
  ```powershell
  # ✅ Good
  function Get-ServerInfo {
      $result = Get-WmiObject -Class Win32_OperatingSystem
      return $result
  }

  # ❌ Bad
  function Get-Info { gwmi Win32_OperatingSystem }
  ```

- **Error handling**: Always use try-catch
  ```powershell
  try {
      $data = Get-CimInstance -ClassName Win32_OperatingSystem `
          -ComputerName $ComputerName -ErrorAction Stop
      return @{ Success = $true; Data = $data }
  }
  catch {
      return @{ Success = $false; Error = $_.Exception.Message }
  }
  ```

- **Logging**: Use structured format where possible
  ```powershell
  $logEntry = @{
      Timestamp   = Get-Date -Format 'o'
      Level       = 'Information'
      Message     = "Collected data from $ComputerName"
      CollectorName = 'Get-ServerInfo'
  }
  Write-Verbose ($logEntry | ConvertTo-Json -Compress)
  ```

- **Return format**: Standardized
  ```powershell
  return @{
      Success       = $true
      CollectorName = 'Get-ServerInfo'
      Data          = $data
      ExecutionTime = (Get-Date) - $startTime
      RecordCount   = @($data).Count
  }
  ```

---

## Creating a New Collector

### Step 1: Copy Template

```powershell
Copy-Item src/Collectors/Collector-Template.ps1 `
    src/Collectors/Get-MyCollector.ps1
```

### Step 2: Implement Core Logic

```powershell
function Get-MyCollector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [switch]$DryRun
    )

    $startTime = Get-Date

    try {
        # Your collection logic here
        $data = Get-SomeInfo -ComputerName $ComputerName

        return @{
            Success       = $true
            CollectorName = 'Get-MyCollector'
            Data          = $data
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = @($data).Count
        }
    }
    catch {
        return @{
            Success       = $false
            CollectorName = 'Get-MyCollector'
            Error         = $_.Exception.Message
            ExecutionTime = (Get-Date) - $startTime
            RecordCount   = 0
        }
    }
}
```

### Step 3: Create PS 5.1+ Variant (Optional)

If PS 5.1+ offers performance improvements (e.g., CIM vs WMI):

```powershell
# Copy to Get-MyCollector-PS5.ps1
# Replace Get-WmiObject with Get-CimInstance
# Use modern error handling ($PSItem instead of $_)
# Update @CollectorName tag to include -PS5
```

Example:
```powershell
# ❌ PS 2.0 version (slow)
$data = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName

# ✅ PS 5.1+ version (fast, CIM protocol)
$data = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName
```

### Step 4: Register in Metadata

Edit `src/Collectors/collector-metadata.json`:

```json
{
  "name": "Get-MyCollector",
  "displayName": "My Collector",
  "description": "Description of what this collects",
  "filename": "Get-MyCollector.ps1",
  "category": "application",
  "psVersions": ["2.0", "4.0", "5.1", "7.0"],
  "minWindowsVersion": "2008R2",
  "maxWindowsVersion": null,
  "dependencies": ["ModuleName"],
  "timeout": 30,
  "estimatedExecutionTime": 15,
  "criticalForMigration": true,
  "variants": {
    "2.0": "Get-MyCollector.ps1",
    "5.1": "Get-MyCollector-PS5.ps1"
  }
}
```

### Step 5: Test

```powershell
# Test locally
.\src\Collectors\Get-MyCollector.ps1

# Test with orchestrator
.\Invoke-ServerAudit.ps1 -Collectors @("Get-MyCollector") -DryRun
```

---

## Testing

### Unit Tests

Create `tests/unit/Get-MyCollector.Tests.ps1`:

```powershell
Describe 'Get-MyCollector' {
    It 'Should return Success=true on valid input' {
        $result = & .\src\Collectors\Get-MyCollector.ps1 -ComputerName $env:COMPUTERNAME
        $result.Success | Should -Be $true
    }

    It 'Should include required properties' {
        $result = & .\src\Collectors\Get-MyCollector.ps1
        $result.PSObject.Properties.Name | Should -Contain 'Success'
        $result.PSObject.Properties.Name | Should -Contain 'Data'
        $result.PSObject.Properties.Name | Should -Contain 'ExecutionTime'
    }

    It 'Should timeout gracefully' {
        # Mock slow operation
        $result = & .\src\Collectors\Get-MyCollector.ps1 -ComputerName '192.0.2.1'
        $result.ExecutionTime.TotalSeconds | Should -BeLessThan 60
    }
}
```

### Integration Tests

Create `tests/integration/Invoke-ServerAudit.Integration.Tests.ps1`:

```powershell
Describe 'Invoke-ServerAudit Integration' {
    It 'Should execute all collectors without error' {
        $result = .\Invoke-ServerAudit.ps1 -ComputerName $env:COMPUTERNAME
        $result.Servers[0].Success | Should -Be $true
    }

    It 'Should run max 3 concurrent servers' {
        $servers = @('SERVER01', 'SERVER02', 'SERVER03', 'SERVER04')
        # Verify concurrency is throttled to 3
    }
}
```

### Run Tests

```powershell
# Run all tests
Invoke-Pester tests/ -Verbose

# Run specific test
Invoke-Pester tests/unit/Get-MyCollector.Tests.ps1

# Run with coverage
Invoke-Pester tests/ -CodeCoverage src/Collectors/*.ps1
```

---

## Submitting a Pull Request

### Before You Submit

- [ ] Code follows [PowerShell Code Standards](#powershell-code-standards)
- [ ] All tests pass: `Invoke-Pester tests/`
- [ ] Linter passes: `Invoke-ScriptAnalyzer -Path src/Collectors/...`
- [ ] Help documentation is complete (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLES`)
- [ ] Collector metadata is registered in `collector-metadata.json`
- [ ] Changes are committed with clear, descriptive messages

### PR Title Format

```
type(scope): description

Examples:
- feat(collector): add Get-NPSInfo collector for NPS server auditing
- fix(orchestrator): resolve timeout handling for long-running collectors
- docs(readme): update troubleshooting section with WinRM errors
- test(parallel): add unit tests for max 3 concurrent job throttling
```

**Types**: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `ci`  
**Scopes**: `collector`, `orchestrator`, `lib`, `test`, `docs`, etc.

### PR Description Template

```markdown
## Description
Brief explanation of what this PR does.

## Type of Change
- [ ] New collector
- [ ] Bug fix
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Refactoring

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Tested on PowerShell 5.1
- [ ] Tested on PowerShell 7.x
- [ ] Tested on Windows Server [version]

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] No new warnings generated
- [ ] Tests pass locally

## Related Issue
Closes #[issue number]
```

---

## License

By contributing to ServerAuditToolkitV2, you agree that your contributions will be licensed under the same MIT license as the project.

---

## Questions?

- 📖 See `docs/DEVELOPMENT.md` for detailed development guide
- 💬 Start a discussion: https://github.com/tonynash74/ServerAuditToolkitv2/discussions
- 🐛 Report issues: https://github.com/tonynash74/ServerAuditToolkitv2/issues

Thank you for contributing! 🙏
