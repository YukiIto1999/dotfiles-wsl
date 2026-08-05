{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
  declared = builtins.attrValues hostConfig.dotfiles.toolchain.packages;
  lspServers = builtins.attrValues hostConfig.dotfiles.toolchain.lsp;
  expectedLspNames = [
    "bash"
    "csharp"
    "java"
    "nix"
    "python"
    "rust"
    "typescript"
  ];
  lspRosterIsValid =
    servers:
    servers != { } && lib.sort builtins.lessThan (builtins.attrNames servers) == expectedLspNames;
  normalLspEvaluation = builtins.tryEval (
    assert lspRosterIsValid hostConfig.dotfiles.toolchain.lsp;
    true
  );
  emptyLspEvaluation = builtins.tryEval (
    assert lspRosterIsValid { };
    true
  );
  toolchain = hostConfig.dotfiles.toolchain.packages;

  # この repo の unit が宣言する package。衝突はこれが片側に居るときだけ見る
  owned = lib.unique (
    declared
    ++ map (server: server.package) lspServers
    ++ builtins.attrValues hostConfig.dotfiles.commands
  );

  # PATH 上に載る全て。NixOS と Home Manager の既定同士の衝突は上流が profile の
  # 優先順位で解いており、この repo が直す対象ではない
  onPath = lib.unique (owned ++ homeConfig.home.packages ++ hostConfig.environment.systemPackages);
in
{
  # 宣言した command が package に無いと、CLI 側は起動時まで気付かない
  lsp-command-present =
    assert normalLspEvaluation.success;
    assert !emptyLspEvaluation.success;
    assert lspServers != [ ];
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

  # 上流 release の binary は同梱 library を欠くと build は通って実行時に落ちる
  toolchain-binary-runs =
    pkgs.runCommandLocal "check-toolchain-binary-runs" { nativeBuildInputs = [ pkgs.coreutils ]; }
      ''
        set -euo pipefail

        version=$(${lib.getExe toolchain.apm} --version)
        case $version in
          "Agent Package Manager (APM) CLI version ${toolchain.apm.version}"*) ;;
          *)
            echo "unexpected apm version banner: $version" >&2
            exit 1
            ;;
        esac

        ${lib.getExe toolchain.actrun} --help > actrun-help
        grep -q . actrun-help
        touch $out
      '';

  # 同じ実行ファイル名を二人が持つと、どちらが効くかは PATH の順序で決まる
  toolchain-single-owner =
    assert lib.all (package: lib.elem package homeConfig.home.packages) declared;
    pkgs.runCommandLocal "check-toolchain-single-owner"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
        roots = onPath;
        ownedRoots = owned;
      }
      ''
        set -euo pipefail

        for root in $roots; do
          [ -d "$root/bin" ] || continue
          for entry in "$root"/bin/*; do
            printf '%s\t%s\n' "$(basename "$entry")" "$root"
          done
        done | sort -u > owners

        for root in $ownedRoots; do
          [ -d "$root/bin" ] || continue
          for entry in "$root"/bin/*; do
            basename "$entry"
          done
        done | sort -u > owned-names

        cut -f1 owners | uniq -d | sort -u > duplicates
        comm -12 duplicates owned-names > conflicts
        if [ -s conflicts ]; then
          echo "an executable this repository declares is also provided by another package:" >&2
          grep -F -f conflicts owners >&2
          exit 1
        fi
        touch $out
      '';
}
