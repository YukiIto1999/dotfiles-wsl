{ lib, ... }:

{
  dotfiles.agents.enabled = lib.mkForce [
    "antigravity"
    "claude"
    "codex"
    "opencode"
    "missing-agent"
  ];
}
