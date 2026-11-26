{
  lib,
  writeShellApplication,
  powershellCommand,
  wslpathCommand ? "/bin/wslpath",
}:

writeShellApplication {
  name = "anode";
  text = ''
    path=$(${lib.escapeShellArg powershellCommand} -NoLogo -NoProfile -NonInteractive -Command \
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8; Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Programs\Anode\anode.exe"')
    executable=$(${lib.escapeShellArg wslpathCommand} -u "''${path//$'\r'/}")
    if [[ ! -f $executable ]]; then
      printf '%s\n' 'Anode is not installed on Windows. See "Windows の独立した操作画面（Anode）" in dotfiles-wsl/docs/tools.md.' >&2
      exit 3
    fi
    # Lease の認証値を引数へ載せず、その Windows 子プロセスの環境だけに渡す
    for name in ANODE_AGENT_ID ANODE_AGENT_NAME ANODE_LEASE_TOKEN; do
      [[ -v $name ]] || continue
      case ":''${WSLENV-}:" in
        *":$name:"* | *":$name/"*) ;;
        *) export WSLENV="''${WSLENV:+$WSLENV:}$name/w" ;;
      esac
    done
    exec "$executable" "$@"
  '';
}
