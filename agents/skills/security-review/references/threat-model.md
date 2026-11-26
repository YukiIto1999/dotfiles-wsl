# Security Threat Model

## Objective

Establish the repository-scoped threat model at the path defined in `scan-artifacts.md`. If this already exists, confirm its repository identity, scope, and recorded assumptions still match the current target before using it. Preserve supplied authoritative models unchanged unless the user explicitly authorizes an update; otherwise record material freshness or scope gaps separately rather than silently extending them.

`AGENTS.md` can be that authoritative source when it is sufficiently specific about the repository's product surfaces, trust boundaries, attacker-controlled inputs, assumptions, or security scan guidance to serve as the threat model.

If no threat model is provided, generate a repository-scoped threat model to be used in future bug discovery. The threat model should holistically cover the entire repository and should make it obvious:

- what assets or privileges matter
- what trust boundaries exist
- what inputs are attacker-controlled
- what invariants the code must preserve
- what repository-wide failure modes would matter most

## Artifact Resolution

The artifact paths in `scan-artifacts.md` are defaults for this phase.
Explicit user-provided input and output paths take precedence.
If a required input is still missing, stop and ask the user for it before continuing.
Use the shared scan artifact path conventions in `scan-artifacts.md`.

## Workflow

1. Resolve `repo_name`, `security_scans_dir`, and the repository-scoped threat model path using `scan-artifacts.md`.
2. If the repository-scoped threat model already exists and no replacement or update was requested, check its identity and assumptions against current repository evidence. Record unresolved material gaps separately, pass the usable model downstream, and finish this phase without rewriting it. If a gap prevents a conclusion, keep that conclusion conditional.
3. If a threat model or authoritative security scan guidance is provided or referenced and no update was authorized:
   - write it exactly to the repository-scoped threat model path
   - treat that file as the only threat model source of truth
   - do not expand, summarize, or reinterpret it
   - `AGENTS.md` is acceptable here when it is clearly being used as the security scan guidance or threat model source for this scan and is sufficiently repository-specific to stand in for a threat model
4. Otherwise, generate a model for the agreed repository or explicitly requested narrower scope using the checklist below. For an explicitly requested update, change only the authorized scope and preserve supported controls and assumptions; do not turn an update into a wider review.
5. Before finalizing this phase, sanity-check that:
   - the model matches the agreed scope rather than inheriting scope from whichever files were easiest to inspect
   - it describes the primary deployed product, runtime, and privileged workflow surfaces relevant to that scope before narrower examples
   - any vulnerability-class discussion is about repository-context classes, not findings about any current diff
6. Write the exact threat model to the repository-scoped threat model path.

## Threat Model Generation Guidance

Generate and structure the threat model using `threat-model-guidance.md`.

## Hard Rules

- A provided threat model or authoritative security scan guidance is authoritative; edit it only within an explicitly authorized update.
- Threat model generation must stay at repository scope unless the user explicitly asks for narrower scope.
- Do not turn this phase into findings about any current diff.
- Do not let the current scan target, touched subsystem, or changed directories become the center of gravity for this phase unless the user explicitly asks for that narrower scope.
- In large monorepos, avoid centering `personal/`, `test/`, `tests/`, `docs/`, `examples/`, or one-off developer tooling unless repository evidence shows those are real deployed or privileged workflow surfaces.
- Call out trust boundaries and assumptions explicitly.
- Keep references to vulnerability types at the level of repository-context classes, rather than any diff findings.
- Persist the threat model output to the repository-scoped threat model path from `scan-artifacts.md`.
