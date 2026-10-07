# Scan Artifact Paths

Use these shared path conventions for security review workflows unless the user explicitly provides different input or output paths.

## Base Paths

- `repo_name=<basename of repo_root>`
- `security_scans_dir=$HOME/.local/state/dotfiles-wsl/security-scans/<repo_name>`
- `scan_id=<commit>_<scan timestamp>`
- `scan_dir=<security_scans_dir>/<scan_id>`
- `artifacts_dir=<scan_dir>/artifacts`

Record the absolute `repo_root`, inspected revision or working-tree state, and agreed scan scope in each phase output.
`repo_name` is only a directory label, not repository identity; never reuse a stored model or scan from a same-named repository without checking its recorded root and scope.
Choose a new `scan_id` when a bundle already exists rather than overwriting another scan.
Create new scan directories privately with mode `0700` and evidence files with mode `0600`.
Do not change permissions or remove supplied artifacts owned by someone else; if the requested output location cannot protect sensitive evidence, report that boundary.

## Threat Model (Phase 1) Paths

- Repository-scoped threat model: `<security_scans_dir>/threat_model.md`
- Per-scan threat model copy: `<artifacts_dir>/threat_model.md`
- Later scan phases should treat `<artifacts_dir>/threat_model.md` as the source of truth.
- When a repository-scoped threat model already exists, copy it to `<artifacts_dir>/threat_model.md` without alteration for auditability.

## Finding Discovery (Phase 2) Paths

- Runtime inventory: `<artifacts_dir>/runtime_inventory.md`
- Advisory seed research: `<artifacts_dir>/seed_research.md`
- Finding discovery report: `<artifacts_dir>/finding_discovery_report.md`
- Repository-wide exhaustive file checklist: `<artifacts_dir>/exhaustive-file-checklist.md` if applicable
- Repository-wide coverage ledger: `<artifacts_dir>/repository_coverage_ledger.md`
  - This is a coverage artifact, not a findings list: it should include checked surfaces with not_applicable, suppressed, deferred, or reportable dispositions.

## Validation (Phase 3) Paths

- Validation report: `<artifacts_dir>/validation_report.md`
- Validation artifacts: `<artifacts_dir>/validation_artifacts/`

## Attack-Path Analysis (Phase 4) Paths

- Attack-path analysis report: `<artifacts_dir>/attack_path_analysis_report.md`

## Final Report Paths

- Final scan report: `<scan_dir>/report.md`

## Fix Finding Paths

- Fix report, when using an existing scan artifact directory: `<artifacts_dir>/fix_report.md`

## Placement Rules

- Put phase outputs and supporting evidence under `artifacts_dir`.
- Put the final `report.md` directly under `scan_dir`.
- Keep the full scan bundle together under `scan_dir`.
- Keep secrets, credentials, personal content, and unnecessary raw response bodies out of reports. Retain only the minimum private reproduction evidence needed, and return shareable redacted excerpts.
- Retention of the scan bundle is intentional; temporary setup copies and partial outputs that are not evidence may be removed only when created and owned by this scan.
