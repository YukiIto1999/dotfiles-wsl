# Authorized Strix Assessment

Use the `security-assessment` Capability's managed `strix` command only when the current discovery or validation phase needs an authorized, isolated runtime assessment.
Routine static review, advisory lookup, and threat-model-only work do not require Strix.
Missing Strix does not disable those paths.
Do not install another scanner or create a second review plan to compensate for a missing runtime.

## Invocation Contract

Before invocation, record these inputs in the current scan bundle:

- Exact authorized target, repository root and revision, owned test environment, allowed actions, exclusions, and permitted network destinations.
- Data permitted to leave the environment for the model provider; installation authorization does not authorize sending private source, credentials, or production data.
- A caller-approved whole-run wall-time and model budget, scan mode, per-agent turn limit, and stop condition appropriate to this target.
- An isolated working copy and private output directory owned by this scan; never pass the active checkout, home directory, or another session's workspace as a writable mount.

Use the approved OpenCode Go subscription with Use balance disabled.
The managed launcher fixes the endpoint, model, image digest, telemetry setting, and sandbox resource limits.
It reads the existing SOPS credential at invocation; do not retrieve its value or place it in an instruction, argument, report, or permanent config.
Upstream persists its connection settings, so the launcher redirects its config to a private per-invocation tmpfs directory and removes that directory on exit.
This is an ephemeral runtime secret file, not a promise that upstream never writes a key.
The native CLI runs in an invocation-owned process group; cleanup sends TERM to that group, allows a two-second grace, then sends KILL to remaining group members and waits for the direct child before removing the config.
INT and TERM cancellation retain exit statuses 130 and 143, and ordinary native exit statuses are preserved.
This cleanup grace is not an assessment wall-time limit and does not clean up Docker sandboxes.

Inspect `strix --help` for the installed release's argument contract.
Select `--scan-mode`, `--max-turns`, and `--max-budget`, and retain the tool-generated run identity; do not inherit the upstream deep/500-turn defaults.
Apply the agreed wall-time using the available process timeout facility.
The native USD budget uses the tool's cost accounting and is not proof of a subscription allowance or billing cap.
Do not change the configured resource caps or provider, retry a refused branch, or broaden the target when preflight, quota, timeout, or runtime setup fails.
Record the failure and continue only with independently available evidence.

Strix owns its internal agent planning and execution.
The review owner supplies the approved scope and acceptance observations, rather than duplicating Strix's agent graph.
Where dependency or image vulnerability coverage is required, explicitly include the bundled Trivy check in that scope and retain its version, scanned input, DB freshness, and result.
Bundling alone does not prove invocation or coverage.

## Evidence Return

Keep the original private run bundle, process exit status, tool run status, interruptions, target and revision, image digest, and observed resource use.
Inspect outputs for sensitive data before copying excerpts into review artifacts.
A zero exit, empty findings list, completed run label, or native help output alone does not prove security or coverage.

At discovery, map each original Strix finding ID to a distinct candidate and the applicable coverage-ledger row, preserving the original source, request, and reproduction locators.
Record checked, skipped, timed-out, and unresolved surfaces in the existing discovery report and coverage ledger.
At validation, use Strix evidence only for the provided candidate or root-control row; retain the exact instance and independently confirm applicability, legitimate behavior, and the security invariant.
Do not turn tool-generated severity or an unverified reproduction into a validated finding.
Resume the existing validation, attack-path analysis, and final-report phases with those returned artifacts.

Stop only jobs and remove only disposable resources owned by this invocation.
Normal cleanup must be observed; if interruption leaves a sandbox, first stop the owned assessment process and use `dotfiles-strix-runtime inspect RUN_ID` and `dotfiles-strix-runtime cleanup RUN_ID` with its recorded run identity.
The runtime operations expose only that run's labelled containers and do not print container environment variables, remove reports, or prune images.
Do not pass another run's identity or control shared provider containers to recover a missing tool.
