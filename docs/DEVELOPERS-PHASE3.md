# ServerAuditToolkitV2 — Developers Guide (Phase 3)

**Complete Developer Reference for Phase 3**

---

## 📚 Documentation Index

### Getting Started
- **README.md** — Full architecture, quick-start, troubleshooting
- **DEVELOPMENT.md** — Technical architecture and design patterns
- **CONTRIBUTING.md** — Code standards, PR process, testing

### Phase 3 API Reference
- **docs/API-REFERENCE.md** — Complete API documentation for all Phase 3 functions
  - Core functions (Invoke-ServerAudit, collectors)
  - M-001-M-014 API reference with parameters and examples
  - Integration examples and best practices
  - Troubleshooting guide

### Phase 3 Features
- **M-013**: Comprehensive API documentation (500+ lines)
- **M-014**: Health diagnostics engine (450+ lines)
  - Automated health scoring (0-100 scale)
  - Issue detection (4 categories: Performance, Resources, Connectivity, Configuration)
  - Auto-remediation suggestions
  - Interactive HTML dashboard

### Module Architecture
- Location: `src/Private/` and `src/Collectors/`
- Main orchestrator: `Invoke-ServerAudit.ps1`
- Module manifest: `ServerAuditToolkitV2.psd1`
- Configuration: `data/audit-config.json`

### Testing
- Location: `tests/` directory
- Test files: `*.Tests.ps1`
- Run all tests: `Invoke-Pester tests/ -PassThru`

---

## 🔧 Key Components

### Orchestrator
```powershell
# Main entry point
.\Invoke-ServerAudit.ps1 -ComputerName $servers -UseBatchProcessing
```

### Health Diagnostics (M-014)
```powershell
$results = .\Invoke-ServerAudit.ps1 -ComputerName "SERVER01"
$health = New-AuditHealthDiagnostics -AuditResults $results
# Returns: Score (0-100), Issues (4 categories), Recommendations, Auto-remediation scripts
```

### API Reference
See **docs/API-REFERENCE.md** for:
- All public functions and signatures
- Parameter documentation
- Return types and examples
- Integration patterns
- Real-world usage scenarios

---

## 🎯 Development Roadmap

**Complete** (13/14):
- ✅ M-001-M-011: Infrastructure, resilience, batch processing, error analysis
- ✅ M-013-M-014: Documentation, health diagnostics

**Deferred** (1/14):
- ⏳ M-012: Output streaming (future optimization)

---

## 📞 Support

For questions on Phase 3 development:
1. Check docs/API-REFERENCE.md for function signatures
2. Review src/Private/New-AuditHealthDiagnostics.ps1 for health engine implementation
3. See tests/Phase3-Sprint4-M014.Tests.ps1 for usage examples
4. Open an issue on GitHub

---

*Last Updated: November 26, 2025*  
*Version: v2.2.0-RC (Phase 3 Complete - 13/14 Enhancements)*
