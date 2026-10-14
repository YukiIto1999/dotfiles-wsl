{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  # Orca の agent ID は、Orca の TUI agent 定義と同じ起動 command 名である。
  managedClients = lib.filterAttrs (_: client: client.runtime ? managed) cfg.agents.clients;
  overrides = lib.mapAttrs' (
    _: client:
    lib.nameValuePair client.binary "dotfiles-project-run --attr default -- ${cfg.agents.lifecycle.wrapperDirectory}/${client.binary}"
  ) managedClients;
  settings = pkgs.writeText "orca-agent-command-overrides.json" (
    builtins.toJSON { agentCmdOverrides = overrides; }
  );
  orcaConfig = pkgs.writeShellApplication {
    name = "dotfiles-orca-config";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      case "''${1-}" in
        "")
          jq -r '.agentCmdOverrides | to_entries[] | "\(.key)\t\(.value)"' ${settings}
          ;;
        --json)
          [ "$#" -eq 1 ] || exit 2
          jq . ${settings}
          ;;
        --help)
          printf '%s\n' 'Usage: dotfiles-orca-config [--json]' \
            'Print, for each selected managed client, the Orca agent ID and the command override that starts it in the trusted project devShell.' \
            '--json prints the same values as the Orca settings fragment agentCmdOverrides.' \
            'It changes no Windows file and no Orca setting. Apply a value by hand in Orca: Settings > Agents > the agent > command override.'
          ;;
        *)
          printf '%s\n' 'Usage: dotfiles-orca-config [--json]' >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  # Orca の設定は Windows 側の利用者所有 file で、この repository は書かない。適用の入口は Orca の設定画面であり、ここは貼り付ける値だけを出す。
  dotfiles.platform.cli.commands.orcaConfig = orcaConfig;
}
