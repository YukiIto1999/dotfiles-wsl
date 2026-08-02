{
  pkgs,
  lib,
  self,
  hostConfig,
  sops-nix,
  ...
}:

let
  sopsKeyFile = "/var/lib/sops-nix/key.txt";
  sopsKeyDirectoryPolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix".d;
  sopsKeyFilePolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix/key.txt".z;
  sopsGenerationContract = hostConfig.environment.etc."dotfiles/sops-generation.json".source;
  sopsGenerationContractData = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (builtins.readFile sopsGenerationContract)
  );
in
{
  sops-policy =
    assert hostConfig.sops.age.keyFile == sopsKeyFile;
    assert hostConfig.sops.age.generateKey == false;
    assert sopsKeyDirectoryPolicy.type == "d";
    assert sopsKeyDirectoryPolicy.user == "root";
    assert sopsKeyDirectoryPolicy.group == "root";
    assert sopsKeyDirectoryPolicy.mode == "0700";
    assert sopsKeyFilePolicy.type == "z";
    assert sopsKeyFilePolicy.user == "root";
    assert sopsKeyFilePolicy.group == "root";
    assert sopsKeyFilePolicy.mode == "0400";
    assert sopsGenerationContractData.schemaVersion == 1;
    assert lib.hasPrefix "/nix/store/" sopsGenerationContractData.ciphertext.path;
    assert lib.hasPrefix "/nix/store/" sopsGenerationContractData.sopsManifest;
    assert
      sopsGenerationContractData.ciphertext.sha256
      == builtins.hashFile "sha256" hostConfig.sops.defaultSopsFile;
    pkgs.runCommandLocal "check-sops-policy"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.bash
          pkgs.coreutils
          pkgs.diffutils
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.sops
          pkgs.util-linux
          pkgs.yq
        ];
      }
      ''
        set -euo pipefail

        yq -r '.creation_rules[].key_groups[].age[]' ${self}/secrets/.sops.yaml \
          | sort > configured-recipients
        yq -r '[.keys.recovery] + [.keys.hosts[]] | .[]' ${self}/secrets/.sops.yaml \
          | sort > named-recipients
        yq -r '.sops.age[].recipient' ${self}/secrets/secrets.yaml \
          | sort > encrypted-recipients
        test -s configured-recipients
        test -s named-recipients
        test -s encrypted-recipients
        diff --brief configured-recipients encrypted-recipients
        diff --brief configured-recipients named-recipients
        test "$(wc -l < configured-recipients)" -eq "$(sort -u configured-recipients | wc -l)"
        test "$(wc -l < encrypted-recipients)" -eq "$(sort -u encrypted-recipients | wc -l)"

        for backend in kms gcp_kms azure_kv hc_vault pgp; do
          yq --exit-status ".sops.$backend // [] | length == 0" \
            ${self}/secrets/secrets.yaml > /dev/null
        done
        contract_ciphertext=$(jq -er '.ciphertext.path' ${sopsGenerationContract})
        contract_hash=$(jq -er '.ciphertext.sha256' ${sopsGenerationContract})
        test "$(sha256sum "$contract_ciphertext" | cut -d ' ' -f 1)" = "$contract_hash"
        contract_installer=$(jq -er '.reinstallSecrets' ${sopsGenerationContract})
        sops_manifest=$(sed -n \
          's|.*sops-install-secrets \(/nix/store/[^ ]*-manifest.json\).*|\1|p' \
          "$contract_installer")
        test -f "$sops_manifest"
        test "$sops_manifest" = "$(jq -er '.sopsManifest' ${sopsGenerationContract})"
        jq --exit-status \
          --arg ciphertext "$contract_ciphertext" \
          --arg ciphertextHash "$contract_hash" '
            (.secrets | length > 0) and
            all(.secrets[];
              .sopsFile == $ciphertext and .sopsFileHash == $ciphertextHash)
          ' "$sops_manifest" > /dev/null
        production_keyctl=${lib.getExe hostConfig.my.commands.sopsEnroll.productionKeyctl}
        for argument in \
          '--property=DynamicUser=yes' \
          '--property=PrivateNetwork=yes' \
          '--property=ProtectSystem=strict' \
          '--property=ProtectHome=yes' \
          '--property=RestrictAddressFamilies=AF_UNIX' \
          'LoadCredential=age.key:$key'; do
          grep --fixed-strings -- "$argument" "$production_keyctl" > /dev/null
        done
        production_verifier=${lib.getExe hostConfig.my.commands.sopsEnroll.productionVerifier}
        grep --fixed-strings 'identity=$CREDENTIALS_DIRECTORY/age.key' \
          "$production_verifier" > /dev/null
        grep --fixed-strings 'SOPS_AGE_KEY_FILE="$identity"' \
          "$production_verifier" > /dev/null
        bash ${self}/sops/tests/sops-enroll.sh \
          ${lib.getExe hostConfig.my.commands.sopsEnroll.testPackage} \
          ${pkgs.age}/bin/age-keygen \
          ${lib.getExe pkgs.sops} \
          ${lib.getExe hostConfig.my.commands.sopsEnroll.testKeyctl}

        touch $out
      '';

  sops-verifier-runtime =
    let
      incompatibleGeneration = pkgs.runCommandLocal "sops-vm-incompatible-generation" { } ''
        mkdir -p $out
      '';
    in
    pkgs.testers.runNixOSTest {
      name = "sops-verifier-runtime";
      nodes.machine =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          reinstallSecrets = pkgs.writeShellScript "dotfiles-sops-vm-reinstall-secrets" ''
            set -euo pipefail
            ${config.system.activationScripts.setupSecrets.text}
          '';
        in
        {
          imports = [ sops-nix.nixosModules.sops ];
          system.extraDependencies = [ incompatibleGeneration ];
          environment.systemPackages = [
            hostConfig.my.commands.sopsEnroll.productionKeyctl
            pkgs.age
            pkgs.jq
            pkgs.sops
          ];
          sops = {
            defaultSopsFile = "/var/lib/sops-nix/vm-secrets.yaml";
            validateSopsFiles = false;
            age = {
              keyFile = "/var/lib/sops-nix/key.txt";
              generateKey = false;
            };
            secrets.fixture = { };
          };
          system.activationScripts = {
            initializeSopsVmFixture = {
              deps = [ "specialfs" ];
              text = ''
                set -eu
                umask 077
                install -d -o root -g root -m 0700 /var/lib/sops-nix
                if [ ! -e /var/lib/sops-nix/key.txt ]; then
                  ${pkgs.age}/bin/age-keygen -o /var/lib/sops-nix/key.txt >/dev/null 2>&1
                  chmod 0400 /var/lib/sops-nix/key.txt
                fi
                if [ ! -e /var/lib/sops-nix/vm-secrets.yaml ]; then
                  old_recipient=$(${pkgs.age}/bin/age-keygen -y /var/lib/sops-nix/key.txt)
                  printf '%s\n' 'fixture: vm-secret' | ${lib.getExe pkgs.sops} \
                    --encrypt --input-type yaml --output-type yaml --age "$old_recipient" \
                    /dev/stdin > /var/lib/sops-nix/vm-secrets.yaml
                  chmod 0600 /var/lib/sops-nix/vm-secrets.yaml
                fi
              '';
            };
            setupSecrets.deps = lib.mkBefore [ "initializeSopsVmFixture" ];
          };
          environment.etc."dotfiles/sops-vm-manifest.json".source = config.system.build.sops-nix-manifest;
          environment.etc."dotfiles/sops-vm-reinstall".source = reinstallSecrets;
        };
      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("grep -Fx 'vm-secret' /run/secrets/fixture")
        machine.succeed(r"""
          set -euo pipefail
          umask 077
          age-keygen -o /var/lib/sops-nix/key.next >/dev/null 2>&1
          chmod 0400 /var/lib/sops-nix/key.next
          old_recipient=$(age-keygen -y /var/lib/sops-nix/key.txt)
          new_recipient=$(age-keygen -y /var/lib/sops-nix/key.next)
          test "$old_recipient" != "$new_recipient"
          printf '%s\n' 'fixture: vm-secret' | sops \
            --encrypt --input-type yaml --output-type yaml \
            --age "$old_recipient,$new_recipient" /dev/stdin \
            > /var/lib/sops-nix/vm-secrets.yaml
          chmod 0600 /var/lib/sops-nix/vm-secrets.yaml
          ciphertext=$(nix-store --add /var/lib/sops-nix/vm-secrets.yaml)
          ciphertext_hash=$(sha256sum "$ciphertext" | cut -d ' ' -f 1)
          runtime=$(mktemp -d /run/sops-vm-generation.XXXXXX)
          jq --arg ciphertext "$ciphertext" --arg ciphertextHash "$ciphertext_hash" '
            .secrets |= map(.sopsFile = $ciphertext | .sopsFileHash = $ciphertextHash)
          ' /etc/dotfiles/sops-vm-manifest.json > "$runtime/manifest.json"
          manifest=$(nix-store --add "$runtime/manifest.json")
          original_manifest=$(realpath /etc/dotfiles/sops-vm-manifest.json)
          grep -F -- "$original_manifest" /etc/dotfiles/sops-vm-reinstall > /dev/null
          sed "s|$original_manifest|$manifest|g" /etc/dotfiles/sops-vm-reinstall \
            > "$runtime/reinstall-secrets"
          grep -F -- "$manifest" "$runtime/reinstall-secrets" > /dev/null
          chmod 0555 "$runtime/reinstall-secrets"
          installer=$(nix-store --add "$runtime/reinstall-secrets")
          jq -n \
            --arg ciphertext "$ciphertext" --arg ciphertextHash "$ciphertext_hash" \
            --arg manifest "$manifest" --arg installer "$installer" '{
            schemaVersion: 1,
            ciphertext: {path: $ciphertext, sha256: $ciphertextHash},
            sopsManifest: $manifest,
            reinstallSecrets: $installer
          }' > "$runtime/contract.json"
          contract=$(nix-store --add "$runtime/contract.json")
          system=$(realpath /run/current-system)
          cp -a "$system/." "$runtime/system"
          chmod u+w "$runtime/system"
          cp -a "$system/etc/." "$runtime/etc"
          chmod u+w "$runtime/etc"
          if [ -L "$runtime/etc/dotfiles" ]; then
            mv "$runtime/etc/dotfiles" "$runtime/original-dotfiles"
            mkdir "$runtime/etc/dotfiles"
            cp -a "$runtime/original-dotfiles/." "$runtime/etc/dotfiles"
          fi
          chmod u+w "$runtime/etc/dotfiles"
          ln -s "$contract" "$runtime/etc/dotfiles/sops-generation.json"
          etc=$(nix-store --add "$runtime/etc")
          rm "$runtime/system/etc"
          ln -s "$etc" "$runtime/system/etc"
          candidate=$(nix-store --add "$runtime/system")
          shopt -s nullglob
          for link in /nix/var/nix/profiles/system-[0-9]*-link; do
            if [ "$(realpath -e "$link")" = "$system" ]; then
              ln -sfn "$candidate" "$link"
            fi
          done
          shopt -u nullglob
          ln -sfn "$candidate" /run/current-system
          test "$(sha256sum /var/lib/sops-nix/vm-secrets.yaml | cut -d ' ' -f 1)" = "$ciphertext_hash"
          rm -rf -- "$runtime"
        """)
        machine.succeed(
          "nix-env --profile /nix/var/nix/profiles/system"
          " --set \"$(realpath /run/current-system)\""
        )
        machine.succeed(
          "test \"$(realpath /run/current-system)\" = "
          "\"$(realpath /nix/var/nix/profiles/system)\""
        )
        machine.succeed(
          "nix-env --profile /nix/var/nix/profiles/system"
          " --set ${incompatibleGeneration}"
        )
        machine.succeed(r"""
          for link in /nix/var/nix/profiles/system-[0-9]*-link; do
            if [ "$(realpath -e "$link")" = "${incompatibleGeneration}" ]; then
              printf '%s\n' "$link" > /tmp/sops-incompatible-generation-link
            fi
          done
          test -s /tmp/sops-incompatible-generation-link
        """)
        machine.succeed(
          "nix-env --profile /nix/var/nix/profiles/system"
          " --set \"$(realpath /run/current-system)\""
        )
        machine.succeed(
          "test \"$(realpath /run/current-system)\" = "
          "\"$(realpath /nix/var/nix/profiles/system)\""
        )
        machine.succeed(r"""
          old_recipient=$(age-keygen -y /var/lib/sops-nix/key.txt)
          new_recipient=$(age-keygen -y /var/lib/sops-nix/key.next)
          jq -n \
            --arg previousRecipient "$old_recipient" \
            --arg nextRecipient "$new_recipient" '{
            version: 1,
            transactionId: "0123456789abcdef0123456789abcdef",
            state: "staged",
            hostId: null,
            previousRecipient: $previousRecipient,
            nextRecipient: $nextRecipient,
            oldConfigHash: null,
            oldSecretsHash: null,
            newConfigHash: null,
            newSecretsHash: null,
            historyToClose: null,
            closedGenerations: [],
            candidateSystem: null,
            startedAt: "1970-01-01T00:00:00Z"
          }' > /var/lib/sops-nix/enrollment.json
          chmod 0600 /var/lib/sops-nix/enrollment.json
        """)
        machine.succeed(
          "dotfiles-sops-keyctl verify-next 0123456789abcdef0123456789abcdef"
          " < /var/lib/sops-nix/vm-secrets.yaml"
        )
        machine.succeed(
          "dotfiles-sops-keyctl verify-previous 0123456789abcdef0123456789abcdef"
          " < /var/lib/sops-nix/vm-secrets.yaml"
        )
        machine.succeed(r"""
          new_hash=$(sha256sum /var/lib/sops-nix/vm-secrets.yaml | cut -d ' ' -f 1)
          jq -n --arg newSecretsHash "$new_hash" '{
            hostId: "vm-nixos",
            oldConfigHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            oldSecretsHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            newConfigHash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            newSecretsHash: $newSecretsHash
          }' | dotfiles-sops-keyctl prepare 0123456789abcdef0123456789abcdef
        """)
        machine.succeed(
          "dotfiles-sops-keyctl arm-swap 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "dotfiles-sops-keyctl mark-repo-swapped 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "dotfiles-sops-keyctl mark-generation-pending 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "dotfiles-sops-keyctl advance-generation 0123456789abcdef0123456789abcdef"
          " | jq -e '.ready == true'"
        )
        machine.succeed(
          "dotfiles-sops-keyctl arm-history-close 0123456789abcdef0123456789abcdef"
          " | jq -e '.incompatible | length == 1'"
        )
        machine.succeed(
          "dotfiles-sops-keyctl close-history 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "test ! -L \"$(cat /tmp/sops-incompatible-generation-link)\""
        )
        machine.succeed(
          "dotfiles-sops-keyctl promote 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "dotfiles-sops-keyctl verify-current 0123456789abcdef0123456789abcdef"
          " < /var/lib/sops-nix/vm-secrets.yaml"
        )
        machine.succeed("rm /run/secrets/fixture")
        machine.succeed(
          "dotfiles-sops-keyctl reinstall-current 0123456789abcdef0123456789abcdef"
        )
        machine.succeed("grep -Fx 'vm-secret' /run/secrets/fixture")
        machine.succeed(
          "dotfiles-sops-keyctl mark-verified 0123456789abcdef0123456789abcdef"
        )
        machine.succeed(
          "dotfiles-sops-keyctl finalize 0123456789abcdef0123456789abcdef"
        )
        machine.succeed("test ! -e /var/lib/sops-nix/key.next")
        machine.succeed("test ! -e /var/lib/sops-nix/enrollment.json")
        machine.succeed(
          "jq -e '.state == \"complete\" and .freshEnrollment == false"
          " and (.closedGenerations | length == 1)'"
          " /var/lib/sops-nix/enrollment-receipt.json"
        )
        machine.succeed(
          "dotfiles-sops-keyctl verify-installed"
          " < /var/lib/sops-nix/vm-secrets.yaml"
        )
      '';
    };

  privilege-boundary =
    let
      sudoWrapper = "${hostConfig.security.wrapperDir}/sudo";
      rawSudo = lib.getExe pkgs.sudo;
      sudoWrapperConfig = hostConfig.security.wrappers.sudo;
    in
    assert hostConfig.security.enableWrappers;
    assert hostConfig.security.sudo.enable;
    assert sudoWrapperConfig.enable;
    assert sudoWrapperConfig.program == "sudo";
    assert sudoWrapperConfig.owner == "root";
    assert sudoWrapperConfig.setuid;
    assert sudoWrapperConfig.source == rawSudo;
    pkgs.runCommandLocal "check-privilege-boundary" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      for command in \
        ${lib.escapeShellArg (lib.getExe hostConfig.my.commands.rebuild)} \
        ${lib.escapeShellArg (lib.getExe hostConfig.my.commands.doctor)} \
        ${lib.escapeShellArg (lib.getExe hostConfig.my.commands.sopsEnroll)}
      do
        if ! grep -F -- ${lib.escapeShellArg sudoWrapper} "$command" > /dev/null; then
          echo "configured sudo wrapper is absent: $command" >&2
          exit 1
        fi
        if grep -F -- ${lib.escapeShellArg rawSudo} "$command" > /dev/null; then
          echo "raw store sudo crossed the privilege boundary: $command" >&2
          exit 1
        fi
      done

      touch $out
    '';
}
