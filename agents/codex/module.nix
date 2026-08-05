{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.my;

  codexModel = "gpt-5.6-sol";
  dotfilesHomeRelative = lib.removePrefix "${cfg.homeDir}/" cfg.dotfilesDir;
  dotfilesPathComponents = lib.splitString "/" dotfilesHomeRelative;
  dotfilesDirIsBelowHome =
    lib.hasPrefix "${cfg.homeDir}/" cfg.dotfilesDir
    && lib.all (
      component: component != "" && component != "." && component != ".."
    ) dotfilesPathComponents;
  codexProjectHomePath = "${dotfilesHomeRelative}/.codex/config.toml";
  codexProjectConfig = (pkgs.formats.toml { }).generate "codex-project-config.toml" {
    sandbox_workspace_write.writable_roots = [ "${cfg.dotfilesDir}/.git" ];
  };
  codexGatewayConfig = (pkgs.formats.toml { }).generate "codex-gateway.toml" {
    mcp_servers.gateway.url = config.dotfiles.mcp.gateway.url;
  };
  codexSystemBase = pkgs.replaceVars ./assets/config-system.toml { inherit codexModel; };
  codexSystemConfig = pkgs.runCommandLocal "codex-system-config.toml" { } ''
    cat ${codexSystemBase} ${codexGatewayConfig} > "$out"
  '';
  codexUserSeed = pkgs.replaceVars ./assets/config.toml { inherit codexModel; };

  splitFrontmatter =
    src:
    let
      parts = lib.splitString "\n---\n" (builtins.readFile src);
    in
    {
      frontmatter = lib.removePrefix "---\n" (builtins.head parts);
      body = lib.concatStringsSep "\n---\n" (builtins.tail parts);
    };

  buildAgent =
    name: srcPath:
    let
      fm = splitFrontmatter srcPath;
    in
    pkgs.runCommand "${name}.toml"
      {
        nativeBuildInputs = [
          pkgs.remarshal
          pkgs.yq
        ];
        inherit (fm) frontmatter body;
      }
      ''
        # frontmatter から codex agent schema への変換
        yq -y '
          ((.tools // []) | any(. == "Edit" or . == "Write") | not) as $readOnly
          | del(.tools)
          | if has("effort") then .model_reasoning_effort = .effort | del(.effort) else . end
          | if $readOnly then .sandbox_mode = "read-only" else . end
        ' <<<"$frontmatter" | remarshal -if yaml -of toml > "$out"
        {
          printf 'model = "${codexModel}"\n'
          printf 'developer_instructions = """\n'
          printf '%s\n' "$body"
          printf '"""\n'
        } >> "$out"
      '';
in
{
  my.agents.clients.codex = {
    binary = "codex";
    rulesDestination = ".codex/AGENTS.md";
    skillsDestination = ".codex/skills";
    definitionMode = "rendered";
    definitionsDestination = ".codex/agents";
    definitionFormat = "toml";
    definitions = lib.mapAttrs buildAgent cfg.agents.shared.definitions;
    gatewayConfig = {
      source = codexGatewayConfig;
      format = "toml";
      managedFile = "system";
    };
    managedFiles = {
      system = {
        source = codexSystemConfig;
        format = "toml";
        deployment = "system";
        destination = "codex/config.toml";
      };
      project = {
        source = codexProjectConfig;
        format = "toml";
        deployment = "home";
        destination = codexProjectHomePath;
      };
      user = {
        source = codexUserSeed;
        format = "toml";
        deployment = "seed";
        destination = ".codex/config.toml";
      };
    };
    capabilityManagedFiles.agentmemory = "system";
    lspMode = "unsupported";
    telemetryMode = "unsupported";
    agentmemoryMode = "hooks";
    install = {
      kind = "github-release";
      repo = "openai/codex";
      assetByArch = {
        x86_64 = "codex-x86_64-unknown-linux-musl.tar.gz";
        aarch64 = "codex-aarch64-unknown-linux-musl.tar.gz";
      };
    };
  };

  # codex の workspace-write sandbox が PATH 上に要求する bubblewrap
  environment.systemPackages = [ pkgs.bubblewrap ];

  assertions = [
    {
      assertion = dotfilesDirIsBelowHome;
      message = "my.dotfilesDir must be a normalized path below my.homeDir for Codex project config deployment";
    }
  ];
}
