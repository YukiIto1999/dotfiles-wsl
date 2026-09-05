---
name: security-review
description: "Use when the user asks for a full security review of a pull request, commit, branch, patch, working-tree diff, or repository. Runs distinct phases: threat modeling, finding discovery, validation, attack-path analysis, and final report assembly."
---

# Security Review

Used when a user wants to review a pull request, commit, branch diff, working-tree patch, or repository for security vulnerabilities. Keep the review phases separate and produce a final markdown report.

Keep these phases distinct and run them in linear order:

1. Threat modeling (`references/threat-model.md`)
2. Finding discovery (`references/finding-discovery.md`)
3. Validation (`references/validation.md`)
4. Attack-path analysis (`references/attack-path-analysis.md`)
5. Final report assembly (`references/final-report.md`)

Treat this skill as the top-level orchestrator for the internal phase references plus the final report assembly step. Do not collapse the phases together.

For each phase:
1. Read that phase's reference file in `references/`.
2. Load only the inputs required for that phase.
3. Complete that phase's workflow and checklist.
4. Only then proceed to the next phase.

Do not read ahead into later-phase references until the current phase has completed.
Do not amortize effort across phases: complete each phase to the full depth expected by that phase before moving on.

## Artifact Resolution

The path references in this skill are the default locations for this phase.
If the user explicitly provides a different path for a required input or output, use the user-provided path instead of the corresponding default path referenced in this skill.
By default, use the scan artifact path conventions in `references/scan-artifacts.md` under `$HOME/.local/state/dotfiles-wsl/security-scans/<repo_name>/`.

## Execution Plan

Follow this plan in order. Do not skip ahead to a later phase until the current phase has produced its intended output.

1. Resolve the scan target, `repo_name`, `security_scans_dir`, `scan_id`, `scan_dir`, and `artifacts_dir` using `references/scan-artifacts.md`.
2. Run threat modeling (`references/threat-model.md`) first.
   - Copy the repository-scoped threat model to the per-scan threat model path without alteration for auditability.
   - Treat the per-scan threat model path as the source of truth threat model for later phases.
3. Run finding discovery (`references/finding-discovery.md`) as the second step, against the resolved diff and using the per-scan threat model as context.
   - If discovery produces no technically plausible candidates in a diff-scoped scan, stop there, skip validation and attack-path analysis, and assemble the final markdown report immediately.
   - In repository-wide scans, stop at discovery only when `runtime_inventory.md` exists and the coverage ledger has closed every applicable high-impact and seeded root-control row as `suppressed`, `not_applicable`, or `deferred` with exact reasons. Open, reportable, or unresolved seeded rows continue to validation even when they are not yet numbered as findings.
4. Run validation (`references/validation.md`) as the third step, for each candidate that came out of discovery and, in repository-wide scans, each open, reportable, or deferred seeded/root-control ledger row that still needs closure.
   - Pass the resolved scan scope, discovery notes, and candidate inventory to validation. Validation should preserve or suppress the provided instances; it should not independently decide whether a standalone single-candidate request should become diff-scoped or repository-wide.
   - For repository-wide scans, the exhaustive file checklist and discovery coverage ledger are part of the validation input; the ledger is a coverage artifact, not just a findings tracker. Validation should preserve checked surfaces with not_applicable, suppressed, deferred, and reportable dispositions, and continue the ledger's high-impact sibling checks when needed rather than narrowing to one representative finding.
   - As repository-wide rows are validated, keep the saved validation report current enough that reportable, suppressed, not_applicable, and deferred closure rows survive interruption or later phase summarization, including exact root-control file:line and seed-anchor file:line when distinct.
5. Run attack-path analysis (`references/attack-path-analysis.md`) as the fourth step, for findings and repository-wide validation closure rows that still need reportability, attack-path, and severity analysis after validation. Consult `references/severity-policy.md` for severity calibration.
6. Assemble the final markdown report last using `references/final-report.md` and the outputs of the earlier phases: finding discovery, validation, attack path analysis.

## Finding Fix Handoff

When validated findings are to be fixed, follow `references/fix-finding.md`. Hand off the validated finding, affected security invariant, reproduction evidence, and attack path to the implementation agent.

## Hard Rules

- Keep the phases separate.
- Follow the execution plan in order.
- Use tools to inspect the repository before making decisions.
- Do not emit a finding unless it survives validation and attack-path analysis.
- Avoid destructive commands and broad unbounded scans; prefer targeted, reversible commands.
