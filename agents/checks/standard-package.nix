{
  pkgs,
  lib,
  pluginSources,
  ...
}:

let
  baseline = pluginSources.architecture-standard;
  admittedIds = [
    "standard-apply"
    "standard-audit"
    "standard-conformance"
    "standard-feedback"
    "standard-update"
    "property-testing"
  ];
  stateRelative = ".local/state/dotfiles-wsl";

  # 外部作用だけを置き換える。呼ばれた名前で振る舞いを選ぶ
  boundary = pkgs.writeShellApplication {
    name = "standard-package-boundary";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../fixtures/standard-package/boundary.sh;
  };
  boundaries = pkgs.runCommandLocal "standard-package-boundaries" { } ''
    mkdir -p $out/bin
    for name in git nix-build; do
      ln -s ${lib.getExe boundary} $out/bin/$name
    done
  '';

  resolver = import ../impl/standard-package/package.nix {
    inherit pkgs lib;
    origin = {
      owner = "standard-owner";
      repo = "standard";
      ref = null;
    };
    reviewed = lib.genAttrs admittedIds (id: "${baseline}/skills/${id}");
    checker = "${baseline}/skills/standard-update/scripts/skill-package-check.sh";
    nixPackage = pkgs.nix;
    gitCommand = "${boundaries}/bin/git";
    nixBuildCommand = "${boundaries}/bin/nix-build";
    inherit stateRelative;
    lockSeconds = 3;
  };

  # host が固定した版を元に、ABI を宣言した公開候補とその改変を作る
  candidate =
    name: edit:
    pkgs.runCommandLocal "standard-package-candidate-${name}" { nativeBuildInputs = [ pkgs.jq ]; } ''
      cp -R --no-preserve=mode ${baseline} $out
      cd $out
      jq '.skillPackageAbi = 1' package.json >package.json.new
      mv package.json.new package.json
      ${edit}
    '';
  rejectedCandidates = lib.mapAttrsToList candidate {
    abi-missing = "jq 'del(.skillPackageAbi)' package.json >package.json.new && mv package.json.new package.json";
    abi-two = "jq '.skillPackageAbi = 2' package.json >package.json.new && mv package.json.new package.json";
    abi-string = ''jq '.skillPackageAbi = "1"' package.json >package.json.new && mv package.json.new package.json'';
    manifest-stream = ''printf '{"skillPackageAbi":1}\n' >>package.json'';
    frontmatter = "sed -i '3s/^description: /description: changed /' skills/standard-audit/SKILL.md";
    missing-skill = "rm -r skills/property-testing";
    escaping-symlink = "ln -s /etc/passwd skills/standard-apply/references/escape.md";
    checker-rejection = "printf 'if then\\n' >skills/standard-update/scripts/broken.sh";
  };

  scenarios = pkgs.writeShellApplication {
    name = "standard-package-scenarios";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      util-linux
    ];
    text =
      builtins.replaceStrings
        [
          "@resolver@"
          "@stateRelative@"
          "@candidateA@"
          "@candidateB@"
          "@candidateC@"
          "@rejectedCandidates@"
        ]
        [
          (lib.escapeShellArg (lib.getExe resolver))
          (lib.escapeShellArg stateRelative)
          (lib.escapeShellArg "${candidate "a" ""}")
          (lib.escapeShellArg "${candidate "b" "printf '\\nB\\n' >>skills/standard-apply/references/recovery.md"}")
          (lib.escapeShellArg "${candidate "c" "printf '\\nC\\n' >>skills/standard-update/references/process.md"}")
          (lib.escapeShellArgs (map toString rejectedCandidates))
        ]
        (builtins.readFile ../fixtures/standard-package/scenarios.sh);
  };
in
{
  source = [
    {
      standard-package-resolver = pkgs.runCommandLocal "check-standard-package-resolver" { } ''
        ${lib.getExe scenarios}
        touch $out
      '';
    }
  ];
}
