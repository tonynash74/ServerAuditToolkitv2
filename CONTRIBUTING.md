git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
git checkout -b feature/my-new-collector
git checkout -b feature/add-nps-collector
git checkout -b fix/timeout-logic
git checkout -b docs/update-troubleshooting
git commit -m "feat: add Get-NPSInfo collector for NPS server auditing"
git push origin feature/add-nps-collector
# Contributing to ServerAuditToolkitV2

Thanks for helping improve **ServerAuditToolkitV2**. This guide reflects the current repository layout (root `ServerAuditToolkitV2.psd1` + root `ServerAuditToolkitV2.psm1`, nested collector helper module, unified orchestrator roadmap) as of v2.1.1.

---

## Contents

1. [Code of Conduct](#code-of-conduct)
2. [Quick Start](#quick-start)
3. [Repository Architecture](#repository-architecture)
4. [Development Workflow](#development-workflow)
5. [PowerShell Standards](#powershell-standards)
6. [Collector Authoring Guide](#collector-authoring-guide)
7. [Testing Matrix](#testing-matrix)
8. [Pull Request Checklist](#pull-request-checklist)
9. [License & Support](#license--support)

---

## Code of Conduct

We follow the standard open-source etiquette:

- Be respectful and assume positive intent.
- Keep the discussion focused on code, testing, and user outcomes.
- Offer constructive feedback and document rationale for design decisions.
- Look out for newcomers—explain acronyms and reference docs when useful.

---

## Quick Start

### Prerequisites

- **Git** for source control.
- **PowerShell 7.2+** (primary dev shell). We maintain compatibility down to 2.0, but development/testing is easiest on pwsh 7.x and Windows PowerShell 5.1.
- **Modules** (install once per machine):
  ```powershell
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
  Install-Module Pester -Scope CurrentUser -Force
  ```

### Clone & Prep

```powershell
git clone https://github.com/tonynash74/ServerAuditToolkitv2.git
cd ServerAuditToolkitv2

# Optional: install locally for ModulePath imports
pwsh -NoProfile -File .\Install-LocalModule.ps1 -Force

# Start a branch
git checkout -b feat/<short-description>
```

---

## Repository Architecture

Key paths (relative to repo root):

| Path | Purpose |
|------|---------|
| `ServerAuditToolkitV2.psd1` | Root manifest (exports module + nested collector helpers). |
| `ServerAuditToolkitV2.psm1` | Module entry point (imports `src` folders, health checks). |
| `src/Collectors/CollectorSupport.psm1` | Importable helper module (metadata loader, variant selection, dependency checks). Automatically loaded via manifest `NestedModules`. |
| `Invoke-ServerAudit.ps1` | Unified orchestrator script (auto PS-version detection, variant selection, streaming/dry-run support). |
| `tests/Test-CollectorVariantSelection.ps1` | Lightweight regression test covering variant logic (called in CI). |
| `.github/workflows/powershell-ci.yml` | Windows runner pipeline (lint, module import, variant test). |

When you add a collector or helper:

- **Metadata & helpers** live under `src/Collectors`.
- **Private/orchestrator helpers** stay under `src/Private` or the main module if cross-cutting.
- **Docs** go to `docs/` or `README.md` depending on scope.

---

## Development Workflow

1. **Align Scope**
   - Search existing issues/discussions to avoid duplicate work.
   - Confirm feature fits the staged architecture (T1 = discovery, T2 = profiling, T3 = orchestration, T4 = reporting).

2. **Branch Naming**
   ```
   feat/<topic>          # new collector or feature
   fix/<issue>           # bug fix
   docs/<section>        # documentation-only change
   test/<target>         # test harness updates
   ci/<pipeline>         # workflow changes
   ```

3. **Coding Loop**
   - Keep commits focused and descriptive.
   - Prefer small PRs (<= ~400 LOC) unless refactoring demands more.

4. **Local Quality Gate**
   ```powershell
   # Lint entire tree with repo settings
   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

   # Variant regression test (mirrors CI job)
   pwsh -NoProfile -File .\tests\Test-CollectorVariantSelection.ps1

   # Run targeted Pester suites (unit/integration as appropriate)
   Invoke-Pester -Path .\tests -CI -Output Detailed
   ```

5. **Push & PR**
   - Push regularly; open a Draft PR early for visibility if work spans multiple days.
   - Ensure the GitHub Actions checks pass before requesting review.

---

## PowerShell Standards

### Script Header Template

Every `.ps1` collector or helper must expose readable help metadata:

```powershell
<#
.SYNOPSIS
    Short description.
.DESCRIPTION
    Longer description with data collected, constraints, and notable dependencies.
.PARAMETER ComputerName
    Default target (often `$env:COMPUTERNAME`).
.PARAMETER Credential
    Optional PSCredential parameter if remoting supported.
.PARAMETER DryRun
    Outline dry-run semantics.
.EXAMPLE
    .\Get-Example.ps1 -ComputerName SERVER01
.OUTPUTS
    [PSCustomObject] containing Success/Data/Error fields.
.NOTES
    Author, Version, LastModified (YYYY-MM-DD), MinPowerShell.
.LINK
    https://github.com/tonynash74/ServerAuditToolkitv2
#>
```

### Metadata Tags

Immediately below the comment block, add tags used by `collector-metadata.json` ingestion:

```powershell
# @CollectorName: Get-Example
# @PSVersions: 2.0,5.1,7.0
# @MinWindowsVersion: 2012R2
# @MaxWindowsVersion:
# @Dependencies: WebAdministration
# @Timeout: 45
# @Category: infrastructure
# @Critical: true
```

### Style Highlights

- **Indentation**: 4 spaces, no tabs.
- **Line length**: Soft limit 120 characters.
- **Naming**: PascalCase parameters/functions, camelCase locals.
- **Error handling**: Always wrap remote calls in `try { ... } catch { ... }` and return structured objects.
- **Logging**: Use `Write-AuditLog` or `Write-Verbose` with meaningful context; avoid `Write-Host` in collectors.
- **Return contract**: `@{ Success = [bool]; CollectorName = ''; Data = <obj>; Errors = @(); ExecutionTime = <ts> }`.

---

## Collector Authoring Guide

1. **Start from Template**
   ```powershell
   Copy-Item .\src\Collectors\Collector-Template.ps1 .\src\Collectors\Get-MyCollector.ps1
   ```

2. **Implement Logic**
   - Capture `Start-Sleep`/IO operations carefully; keep execution predictable.
   - Use CIM (`Get-CimInstance`) for PS 5.1+ variants when possible.
   - Support `-ComputerName`, `-Credential`, and `-DryRun` for orchestration parity.

3. **Create Version Variants (optional)**
   - Name PS 5.1+ optimized scripts `Get-Name-PS5.ps1`.
   - Update `variants` map inside `collector-metadata.json` so the orchestrator can pick the best file.

4. **Update Metadata**
   Add entry to `src/Collectors/collector-metadata.json` with descriptions, PS version support, timeouts, dependencies, etc.

5. **Run Local Tests** (see [Testing Matrix](#testing-matrix)).

6. **Document**
   If the collector exposes user-facing behavior, update `docs/API-REFERENCE.md` and `README.md` as appropriate.

---

## Testing Matrix

| Layer | Command | Purpose |
|-------|---------|---------|
| Linting | `Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1` | Enforces repo-wide rules (alias ban, formatting, security checks). |
| Variant Regression | `pwsh -NoProfile -File tests/Test-CollectorVariantSelection.ps1` | Confirms `CollectorSupport.psm1` + metadata produce expected variant filenames (mirrors CI). |
| Unit / Collector Tests | `Invoke-Pester -Path tests/unit -CI` | Validate individual collectors or helper functions; add new specs under `tests/unit`. |
| Integration | `Invoke-Pester -Path tests/integration -CI` | Exercise `Invoke-ServerAudit.ps1` across sample scenarios (batch, streaming, dry-run). |
| Manual Sanity | `.	ests	ools
un-samples.ps1` (if available) or direct `Invoke-ServerAudit.ps1 -DryRun` | Useful before releasing or tagging. |

**CI Expectations**

GitHub Actions (`powershell-ci.yml`) runs on PRs:

1. Import manifest + install to runner Modules path.
2. Run PSScriptAnalyzer (errors/warnings fail the build).
3. Execute `tests/Test-CollectorVariantSelection.ps1`.
4. (Optional future) Hook for `Invoke-Pester` suites—feel free to add when contributing tests.

Keep pipelines green by running the same commands locally before pushing.

---

## Pull Request Checklist

Before requesting review:

- [ ] Code follows [PowerShell Standards](#powershell-standards) and includes help/metadata blocks.
- [ ] Variant mappings updated in `collector-metadata.json` when adding collectors.
- [ ] Relevant docs updated (README, docs/API-REFERENCE.md, Quick Reference, etc.).
- [ ] Added or updated tests; ran `Invoke-Pester` for affected suites.
- [ ] Ran `Invoke-ScriptAnalyzer` and resolved findings.
- [ ] Ran `pwsh -NoProfile -File tests/Test-CollectorVariantSelection.ps1` (required when touching collectors/metadata/orchestrator).
- [ ] Commit messages follow `type(scope): summary` (e.g., `feat(collector): add Get-NPSInfo` or `ci(workflow): run variant test`).

**PR Description Template**

```markdown
## Summary
- Short bullet list of changes.

## Testing
- [ ] Invoke-ScriptAnalyzer
- [ ] Variant self-test (tests/Test-CollectorVariantSelection.ps1)
- [ ] Invoke-Pester (list suites)
- [ ] Manual `Invoke-ServerAudit -DryRun`

## Risks / Rollback
- Note any migration considerations or manual steps.

## Issue Reference
Fixes #<ID>
```

---

## License & Support

- Contributions are released under the existing **MIT License** (see `LICENSE`).
- Need guidance? Check `docs/DEVELOPMENT.md`, start a discussion on GitHub, or open an issue.
- For architecture or release planning questions, reference `QUICK-REFERENCE.md` and the documents under `docs/`.


Thanks for keeping ServerAuditToolkitV2 healthy and production-ready! 🙏
