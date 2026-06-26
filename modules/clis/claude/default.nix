{ config, seedConfig, ... }:

let
  cfg = config.my;
in
{
  my.clis.claude = {
    binary = "claude";
    rulesFile = ".claude/CLAUDE.md";
    skillsDir = ".claude/skills";
    agentsDir = ".claude/agents";
    buildAgent = _: srcPath: srcPath;
    gatewayFile = null;
    install = {
      kind = "installer-script";
      scriptUrl = "https://claude.ai/install.sh";
    };
  };

  environment.etc."claude-code/managed-settings.json".source = ./managed-settings.json;

  home-manager.users.${cfg.username} =
    { lib, ... }:
    {
      home.activation.seedClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        seedConfig ".claude/settings.json" ./settings.json
      );

      # claude は ~/.claude.json を runtime 所有するため gateway を imperative 登録
      # claude バイナリ欠落でも後続 activation を止めない if ガード
      home.activation.claudeMcpRegister = lib.hm.dag.entryAfter [ "seedClaudeConfig" ] ''
        CLAUDE=$HOME/.local/bin/claude
        if [ -x "$CLAUDE" ]; then
          $CLAUDE mcp remove gateway --scope user >/dev/null 2>&1 || true
          $CLAUDE mcp add --transport http gateway "${cfg.gatewayUrl}" --scope user >/dev/null
        fi
      '';
    };
}
