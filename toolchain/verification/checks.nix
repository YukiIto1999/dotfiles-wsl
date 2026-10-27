/**
  native検証commandの契約検査の構築
  pkgs: 検査用commandを生成する固定済みpackage集合
  lib: 実行fileの解決に使うNixpkgs library
  supervise: rootから受け取るhost非依存の子孫回収command
  戻り値: source検査と構成検査の定義
*/
{
  pkgs,
  lib,
  supervise,
  ...
}:

let
  programs = import ./package.nix { inherit pkgs supervise; };
in
{
  source = [
    {
      verification-run-within =
        pkgs.runCommandLocal "check-verification-run-within"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              python3
              util-linux
            ];
            WITHIN = lib.getExe programs.runWithin;
          }
          ''
            bash ${./fixtures/run-within.sh}
            python3 ${./fixtures/run-within-interrupt.py}
            touch $out
          '';
    }
  ];
  configuration = [
    (
      { hostConfig, ... }:
      {
        verification-entry-resolution =
          pkgs.runCommandLocal "check-verification-entry-resolution"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                git
              ];
              ENTRY = lib.getExe hostConfig.dotfiles.toolchain.verification.entry;
            }
            ''
              bash ${./fixtures/entry.sh}
              touch $out
            '';
      }
    )
  ];
}
