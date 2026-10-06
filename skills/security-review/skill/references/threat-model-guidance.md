# Threat Model Guidance

Use this guidance during threat model generation.

## Threat Model Generation Checklist

Do not restate this checklist in the final threat model output.

- Start at the repository root and use the minimum hops needed to understand the repository's real-world purpose before narrowing into critical components.
- Keep this phase at repository scope unless the user explicitly asks for a narrower target-scoped threat model.
- Ignore any reviewed commit, diff, changed files, changed directories, commit title, and scan target during threat model generation unless the user explicitly asks for narrower scope.
- Distinguish primary product or runtime code from developer-only, test-only, documentation-only, example, prototype, or one-off tooling paths.
- Identify the primary product or runtime surfaces the repository actually exposes.
- Identify the main trust boundaries and which actors sit on each side of them.
- Explicitly separate attacker-controlled, operator-controlled, and developer-controlled inputs.
- Describe common vulnerability classes that are relevant in this repository context rather than findings about the current diff.
- Call out mitigations, robustness measures, and security controls already present in the repository when they materially affect severity or scope.
- Explain when attacker stories are realistic, when they are out of scope, and when the repository's real-world usage makes a vulnerability class less important.
- Note unique security considerations for the codebase, for example:
  - authn/authz, session management, CSRF, XSS, SSRF, injections, tenant boundaries, rate limits, and secret handling for web applications
  - key management, privacy assumptions, ACLs/RBAC, PII handling, and auditability for cryptography or privacy-sensitive systems
  - public interfaces, embedding assumptions, safe-by-default behavior, footguns, and secure usage patterns for libraries or frameworks
  - production/runtime code paths versus CI, build, or local developer tooling
- Explain when a vulnerability class would be critical, high, medium, or low in this repository and give a couple of concrete examples at each level.
- If a vulnerability class requires attacker control that does not exist in the repo's real-world usage, say so in the severity calibration discussion.
- When possible, point to specific files, components, or controls that ground the threat model.

## Build the system and attacker model

For each material data flow, record source and destination, the asset crossing the boundary, the protocol or channel, the controlling actor, authentication/authorization, encryption, validation/normalization, and the exact code or configuration anchor.
Distinguish a verified control, an intended control, and an unverified deployment assumption.
Use a compact flow diagram only when it makes those relationships clearer; keep paths and evidence anchors in the adjacent text.

Tie assets to confidentiality, integrity, availability, and concrete user or operator harm.
Specify attacker capabilities and non-capabilities, including authentication level, tenant membership, input ownership, network exposure, and privileges the attacker does not already have.
Do not give a remote attacker arbitrary local files, environment values, administrator permissions, or CI write access without repository or supplied-context evidence.

Construct abuse paths as attacker goal, entrypoint, boundary crossed, required preconditions, violated invariant, and impact.
Assign stable threat IDs and link each path to its assets and current controls.
Keep these paths as threat hypotheses until discovery and validation establish an actual vulnerable instance.

Rank likelihood and impact separately with qualitative reasons, then explain how existing controls and material assumptions affect priority.
Do not multiply invented numeric scores.
For each consequential threat, distinguish evidence-backed existing mitigations from recommended controls, and name the boundary or owner where prevention and detection belong.

Resolve material assumptions from repository and deployment evidence first.
Ask only for missing service context that would change scope or risk; if it remains unavailable, keep conclusions conditional and state the unresolved question.
Before completion, account for every discovered entrypoint and trust boundary with a threat, a control-backed exclusion, or an explicit evidence gap.

## Output Contract

When generating a threat model, structure it in Markdown with these sections:

- Overview
- Threat Model, Trust Boundaries, and Assumptions
- Attack Surface, Mitigations, and Attacker Stories
- Severity Calibration (Critical, High, Medium, Low)

The threat model should help a security researcher understand the codebase and its likely security-relevant failure modes. It should be detailed, repository-scoped, and suitable for reuse across unrelated diffs in the same repo.

Within those sections, make sure the output covers:

- repository overview and intended real-world usage
- trust boundaries and assumptions
- attacker stories and out-of-scope attacker stories
- attack surfaces and existing mitigations
- which vulnerability classes matter most in context
- which vulnerability classes are less severe or out of scope in context
- severity calibration with concrete examples at each level
- references to concrete files or controls when those materially ground the model
- boundary/data-flow evidence, assets and security objectives, attacker capabilities and non-capabilities
- stable threat IDs, concrete abuse paths, likelihood and impact reasons, current and recommended controls
- focused review locations tied to the threat IDs, and assumptions that could change their priority
