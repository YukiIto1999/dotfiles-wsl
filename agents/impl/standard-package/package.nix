{
  pkgs,
  lib,
  # flake.lock の original が宣言する GitHub の owner、repo、ref。ref が null なら既定 branch の HEAD
  origin,
  # Skill ID から host が審査した SKILL.md 所在 directory への対応
  reviewed,
  # host が固定した版の package 検査器
  checker,
  # host の nix-daemon と同じ版の Nix
  nixPackage,
  # 版ごとの GC root と最後の検証結果を置く host state（HOME からの相対 path）
  stateRelative,
  # build 時にだけ選べる archive の取得元。未公開の source での実地確認だけが変える
  archivePrefix ? "https://github.com/${origin.owner}/${origin.repo}/archive/",
  # 問い合わせへ渡す唯一の環境。host が信頼する CA bundle
  caBundle ? "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt",
  # 外部作用の境界。検査は同じ resolver へ代替の command を渡す
  gitCommand ? lib.getExe pkgs.git,
  nixBuildCommand ? "${nixPackage}/bin/nix-build",
  lookupSeconds ? 20,
  buildSeconds ? 900,
  # 先行する作業の問い合わせと検査が終わるまでは待つ
  lockSeconds ? lookupSeconds + buildSeconds + 10,
}:

let
  reviewedManifest = pkgs.writeText "standard-package-reviewed.json" (builtins.toJSON reviewed);

  validator = pkgs.writeShellApplication {
    name = "dotfiles-standard-package-validate";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      fd
      findutils
      gawk
      jq
      nodejs
    ];
    text =
      builtins.replaceStrings
        [ "@reviewedManifest@" "@checker@" ]
        [
          (lib.escapeShellArg "${reviewedManifest}")
          (lib.escapeShellArg checker)
        ]
        (builtins.readFile ./validate.sh);
  };
  substitutions = {
    "@admittedIds@" = lib.escapeShellArgs (builtins.attrNames reviewed);
    "@remoteUrl@" = lib.escapeShellArg "https://github.com/${origin.owner}/${origin.repo}.git";
    "@remoteRef@" = lib.escapeShellArg (if origin.ref == null then "HEAD" else origin.ref);
    "@caBundle@" = lib.escapeShellArg (toString caBundle);
    "@archivePrefix@" = lib.escapeShellArg archivePrefix;
    "@stateRelative@" = lib.escapeShellArg stateRelative;
    "@validator@" = lib.escapeShellArg "${validator}";
    "@validationExpression@" = lib.escapeShellArg "${./validation.nix}";
    "@gitCommand@" = lib.escapeShellArg (toString gitCommand);
    "@nixBuildCommand@" = lib.escapeShellArg (toString nixBuildCommand);
    "@lookupSeconds@" = toString lookupSeconds;
    "@buildSeconds@" = toString buildSeconds;
    "@lockSeconds@" = toString lockSeconds;
  };
in
assert lib.assertMsg (reviewed != { }) "the standard package needs at least one admitted Skill";
assert lib.assertMsg (lib.all (lib.hasPrefix "${builtins.storeDir}/") (
  [ checker ] ++ builtins.attrValues reviewed
)) "the host-reviewed standard sources and checker must be store paths";
pkgs.writeShellApplication {
  name = "dotfiles-standard-package";
  runtimeInputs = with pkgs; [
    coreutils
    jq
    util-linux
  ];
  text =
    builtins.replaceStrings (builtins.attrNames substitutions) (builtins.attrValues substitutions)
      (builtins.readFile ./resolver.sh);
}
