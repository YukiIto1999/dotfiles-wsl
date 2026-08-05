{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  sopsFile = "${self}/secrets/secrets.yaml";
  templates = hostConfig.sops.templates;
  inHome = template: lib.hasPrefix hostConfig.dotfiles.host.homeDir template.path;
  wrongTemplatesFor =
    candidateTemplates:
    builtins.filter (
      template:
      inHome template && (template.mode != "0600" || template.owner != hostConfig.dotfiles.host.username)
    ) (builtins.attrValues candidateTemplates);
  templatePolicyIsValid =
    candidateTemplates: candidateTemplates != { } && wrongTemplatesFor candidateTemplates == [ ];
  normalTemplateEvaluation = builtins.tryEval (
    assert templatePolicyIsValid templates;
    true
  );
  emptyTemplateEvaluation = builtins.tryEval (
    assert templatePolicyIsValid { };
    true
  );
in
{
  # 鍵は root だけが読み、recipient は宣言と暗号文の両方で一致する
  sops-policy =
    assert hostConfig.sops.age.keyFile == "/var/lib/sops-nix/key.txt";
    assert !hostConfig.sops.age.generateKey;
    assert hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix/key.txt".z.mode == "0400";
    pkgs.runCommandLocal "check-sops-policy" { nativeBuildInputs = with pkgs; [ yq-go ]; } ''
      set -euo pipefail

      # 宣言した recipient と、暗号文が実際に持つ recipient が一致すること
      # anchor は explode しないと alias 名のまま出る
      yq -r 'explode(.) | .creation_rules[0].key_groups[0].age[]' ${self}/secrets/.sops.yaml \
        | sort > declared
      yq -r '.sops.age[].recipient' ${sopsFile} | sort > actual
      diff -u declared actual

      # host 鍵と recovery 鍵の二つ。片方だけだと復旧手段が無い
      test "$(wc -l < declared)" -eq 2

      # 平文が残っていないこと。! 付きの command は set -e の対象外なので
      # 否定を条件式で書く
      if grep -qE '^[a-z_]+: [^E]' ${sopsFile}; then
        echo "secrets.yaml holds a plaintext value" >&2
        exit 1
      fi
      touch $out
    '';

  # secret file は user 所有で 0600。各 unit が mode を決めない
  sops-secret-file-mode =
    let
      wrong = wrongTemplatesFor templates;
    in
    assert normalTemplateEvaluation.success;
    assert !emptyTemplateEvaluation.success;
    assert templates != { };
    assert lib.assertMsg (wrong == [ ]) (
      "sops template does not use the shared user secret file policy: "
      + lib.concatStringsSep " " (map (t: t.path) wrong)
    );
    pkgs.runCommandLocal "check-sops-secret-file-mode" { } "touch $out";
}
