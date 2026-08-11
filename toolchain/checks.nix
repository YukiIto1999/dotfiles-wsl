{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
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

        ${lib.getExe toolchain.actrun} --help > actrun-help
        grep -q . actrun-help
        touch $out
      '';

}
