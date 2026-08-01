{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
  declared = builtins.attrValues hostConfig.my.toolchain;
  # この repo が宣言する package だけを見る。NixOS と Home Manager の既定は所有の外
  owned = lib.unique (
    declared ++ builtins.attrValues hostConfig.my.commands ++ homeConfig.home.packages
  );
  lspServers = builtins.attrValues hostConfig.my.lsp;
  toolchain = hostConfig.my.toolchain;
in
{
  # 上流 release の binary は同梱 library を欠くと build は通って実行時に落ちる
  toolchain-binary-runs =
    pkgs.runCommandLocal "check-toolchain-binary-runs" { nativeBuildInputs = [ pkgs.coreutils ]; }
      ''
        set -euo pipefail


        ${lib.getExe toolchain.actrun} --help > actrun-help
        grep -q . actrun-help
        touch $out
      '';

  # 宣言した command が package に無いと、CLI 側は起動時まで気付かない
  lsp-command-present =
    assert lib.all (server: lib.elem server.package homeConfig.home.packages) lspServers;
    assert lib.all (
      server: lib.all (extension: lib.hasPrefix "." extension) (builtins.attrNames server.extensions)
    ) lspServers;
    pkgs.runCommandLocal "check-lsp-command-present" { nativeBuildInputs = [ pkgs.coreutils ]; } (
      lib.concatMapStrings (server: ''
        test -x ${server.package}/bin/${server.command}
      '') lspServers
      + "touch $out"
    );

  # 同じ実行ファイル名を二人が持つと、どちらが効くかは PATH の順序で決まる
  toolchain-single-owner =
    assert lib.all (package: lib.elem package homeConfig.home.packages) declared;
    pkgs.runCommandLocal "check-toolchain-single-owner"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
        roots = owned;
      }
      ''
        set -euo pipefail

        for root in $roots; do
          [ -d "$root/bin" ] || continue
          for entry in "$root"/bin/*; do
            printf '%s\t%s\n' "$(basename "$entry")" "$root"
          done
        done | sort -u > owners

        cut -f1 owners | uniq -d > duplicates
        if [ -s duplicates ]; then
          echo "executable name is owned by more than one declared package:" >&2
          grep -F -f duplicates owners >&2
          exit 1
        fi
        touch $out
      '';
}
