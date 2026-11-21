{
  lib,
  pkgs,
  mkCommand,
}:

# 選んだ MCP 経路を 1 回の client 起動にだけ足す command の builder。
# client と profile の設定は書き換えず、各 client が文書化した起動単位の機構だけを使う。
# 本番は agents/module.nix が host の値を渡し、fixture は検証用の実行ファイルを渡す
{
  name ? "dotfiles-tool-session",
  # client ID から、PATH に置かれた公開 command の絶対 path への対応
  clientExecutables,
  # 通常の接続に加えて選べる Streamable HTTP endpoint
  optionalUrls,
  # 共有 HTTP 経路に載せない stdio server。利用者の端末から明示した起動にだけ渡す
  privateServers,
}:
let
  json = pkgs.formats.json { };
  yaml = pkgs.formats.yaml { };

  isName = value: builtins.match "[a-z0-9]+(-[a-z0-9]+)*" value != null;
  # 経路は同じ host の gateway だけで、OMP の Agent Plugins も loopback 以外の http を黙って捨てる
  isEndpoint = lib.hasPrefix "http://127.0.0.1:";
  isAbsolute = value: builtins.match "/[^[:space:]]+" value != null;

  routeNames = builtins.attrNames optionalUrls;
  privateNames = builtins.attrNames privateServers;
  capabilityNames = routeNames ++ privateNames;
  # 全 client が通常の接続をこの名前で登録しており、同名の追加は通常の接続を上書きする
  reservedNames = [ "gateway" ];

  # OMP 19 の Agent Plugins 1.0.0 は root の plugin.json と mcp.json だけを読み、stdio の command に
  # 絶対 path も plugin root の外へ解決する symlink も受け付けない。起動役は plugin の中の実 file にする
  pluginManifestSchema = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json";
  pluginMcpSchema = "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json";
  ompPlugin =
    capability: server: executable:
    let
      manifest = json.generate "plugin.json" {
        "$schema" = pluginManifestSchema;
        name = capability;
        description = "dotfiles-tool-session が起動単位で足す MCP 経路";
      };
      mcp = json.generate "mcp.json" {
        "$schema" = pluginMcpSchema;
        mcpServers.mcp = server;
      };
      launcher = pkgs.writeShellScript "omp-session-${capability}" ''
        exec ${lib.escapeShellArg executable}
      '';
    in
    pkgs.runCommandLocal "omp-session-plugin-${capability}" { } (
      ''
        mkdir "$out"
        cp ${manifest} "$out/plugin.json"
        cp ${mcp} "$out/mcp.json"
      ''
      + lib.optionalString (executable != null) ''
        mkdir "$out/bin"
        cp ${launcher} "$out/bin/${capability}"
        chmod 0555 "$out/bin/${capability}"
      ''
    );
  # 子 agent は親の MCP 接続を借りて承認なしで動くため、書込み用の起動では生成そのものを拒否する。
  # MCP を eval の名前空間へ移すと tool 単位の承認を通らないため、既定の false に固定する
  ompPrivateOverlay = yaml.generate "omp-tool-session-private.yml" {
    tools.approval.task = "deny";
    mcp.evalNamespaces = false;
  };

  # route と private は client へ渡す引数と、設定を受け取る環境変数へ入れる断片を返す
  adapters = {
    omp = {
      route = capability: url: {
        args = [
          "--plugin-dir"
          "${ompPlugin capability {
            type = "streamable-http";
            inherit url;
          } null}"
        ];
      };
      private = capability: executable: {
        args = [
          "--plugin-dir"
          "${ompPlugin capability {
            type = "stdio";
            command = "./bin/${capability}";
          } executable}"
        ];
      };
      # MCP tool は write 段で、always-ask では呼出しごとに確認する。実行時の flag は --config の overlay より強い
      privateArgs = [
        "--approval-mode"
        "always-ask"
        "--config"
        "${ompPrivateOverlay}"
      ];
    };
    codex = {
      route = capability: url: {
        args = [
          "-c"
          "mcp_servers.${capability}.url=${builtins.toJSON url}"
        ];
      };
      private = capability: executable: {
        args = [
          "-c"
          "mcp_servers.${capability}.command=${builtins.toJSON executable}"
          "-c"
          "mcp_servers.${capability}.default_tools_approval_mode=\"prompt\""
        ];
      };
      # approval_policy = "never" のままでは確認の必要な MCP 呼出しが常に失敗する。
      # 子 agent に書込み経路を継がせないため、multi agent の両世代を止める
      privateArgs = [
        "-a"
        "on-request"
        "-c"
        "approvals_reviewer=\"user\""
        "-c"
        "agents.enabled=false"
        "--disable"
        "multi_agent_v2"
      ];
    };
    opencode = {
      configEnvironment = "OPENCODE_CONFIG_CONTENT";
      route = capability: url: {
        config.mcp.${capability} = {
          type = "remote";
          inherit url;
          enabled = true;
        };
      };
      # 書込み経路は渡さない。agent ごとの permission は全体の規則の後に足され、task や MCP tool の
      # ask を後勝ちで allow へ戻せる。利用者は TUI でその agent へ切り替えられる
      privateUnsupported = "OpenCode appends per-agent permission rules after the global ones, so an agent could re-allow task or the writer's tools without a prompt";
    };
  };
  unsupportedReasons = {
    claude = "/etc/claude-code/managed-mcp.json takes exclusive control of MCP servers; Claude Code ignores --mcp-config and plugin servers while it exists";
    antigravity = "agy documents no session-scoped MCP entry; its settings carry no MCP keys and plugins load only from global or workspace customization roots";
  };

  normalize =
    entry:
    {
      args = [ ];
      config = { };
    }
    // entry;
  clientSpec =
    client: executable:
    if adapters ? ${client} then
      let
        adapter = adapters.${client};
        takesPrivate = adapter ? private;
      in
      {
        inherit executable;
        configEnvironment = adapter.configEnvironment or null;
        launch =
          lib.mapAttrs (capability: url: normalize (adapter.route capability url)) optionalUrls
          // lib.optionalAttrs takesPrivate (
            lib.mapAttrs (
              capability: server: normalize (adapter.private capability server.executable)
            ) privateServers
          );
        private =
          if takesPrivate then
            { args = adapter.privateArgs; }
          else
            { unsupported = adapter.privateUnsupported; };
      }
    else
      {
        unsupported =
          unsupportedReasons.${client} or "no session-scoped MCP adapter is defined for this client";
      };

  spec = json.generate "dotfiles-tool-session.json" {
    capabilities =
      lib.mapAttrs (_: _: { kind = "route"; }) optionalUrls
      // lib.mapAttrs (_: _: { kind = "private"; }) privateServers;
    clients = lib.mapAttrs clientSpec clientExecutables;
  };

  invalidNames = builtins.filter (
    value: !isName value || builtins.elem value reservedNames
  ) capabilityNames;
  sharedNames = lib.intersectLists routeNames privateNames;
  invalidEndpoints = builtins.filter (capability: !isEndpoint optionalUrls.${capability}) routeNames;
  invalidExecutables = builtins.filter (
    capability: !isAbsolute privateServers.${capability}.executable
  ) privateNames;
  invalidClients = builtins.filter (client: !isAbsolute clientExecutables.${client}) (
    builtins.attrNames clientExecutables
  );
in
assert lib.assertMsg (invalidNames == [ ])
  "${name}: capability names must be lowercase hyphen-separated IDs other than ${lib.concatStringsSep ", " reservedNames}: ${lib.concatStringsSep ", " invalidNames}";
assert lib.assertMsg (sharedNames == [ ])
  "${name}: a capability cannot be both an optional route and a private server: ${lib.concatStringsSep ", " sharedNames}";
assert lib.assertMsg (invalidEndpoints == [ ])
  "${name}: optional routes must be http://127.0.0.1: endpoints: ${lib.concatStringsSep ", " invalidEndpoints}";
assert lib.assertMsg (invalidExecutables == [ ])
  "${name}: private server executables must be absolute paths: ${lib.concatStringsSep ", " invalidExecutables}";
assert lib.assertMsg (
  invalidClients == [ ]
) "${name}: client executables must be absolute paths: ${lib.concatStringsSep ", " invalidClients}";
mkCommand {
  inherit name;
  src = ./tool-session.sh;
  vars.spec = lib.escapeShellArg "${spec}";
  runtimeInputs = [ pkgs.jq ];
}
