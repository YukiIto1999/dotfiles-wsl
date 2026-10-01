{
  lib,
  pkgs,
  hostConfig,
  hostOptions,
  ...
}:

let
  inherit (hostConfig.dotfiles.workstation) username;
  # 実 account を使わない。印のない fixture-a は primary と同じく gh の helper へ落ちる
  fixtureOwners = {
    fixture-a = [ ];
    fixture-b = [ "fixture-org" ];
    fixture-c = [
      "fixture-lab"
      "fixture-team"
    ];
  };
  # git は helper を問い合わせた directory で起動する。build directory の相対 path で足りる
  fixtureTokenFile = account: "fixture-tokens/${account}";
  evaluation = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      ./module.nix
      (
        { lib, ... }:
        {
          options = {
            dotfiles.workstation = lib.mkOption {
              type = lib.types.raw;
            };
            dotfiles.identity.github.owners = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
            };
            sops.secrets = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
            };
            # host と同じ Home Manager で描画し、gh の helper と同じ file に並べる
            home-manager.users = lib.mkOption {
              inherit (hostOptions.home-manager.users) type;
            };
          };
          config = {
            dotfiles.workstation = { inherit username; };
            dotfiles.identity.github.owners = fixtureOwners;
            sops.secrets = lib.mapAttrs' (
              account: _: lib.nameValuePair "accounts/${account}/token" { path = fixtureTokenFile account; }
            ) fixtureOwners;
            home-manager.users.${username} = {
              home.stateVersion = hostConfig.home-manager.users.${username}.home.stateVersion;
              programs.gh.enable = true;
            };
          };
        }
      )
    ];
  };
  gitConfig = evaluation.config.home-manager.users.${username}.xdg.configFile."git/config".source;
  hookPrefix = ".config/git/hooks/";
  homeFiles = hostConfig.home-manager.users.${username}.home.file;
  hookFiles = lib.filterAttrs (name: _: lib.hasPrefix hookPrefix name) homeFiles;
  deployedHooks = lib.mapAttrs' (
    name: file: lib.nameValuePair (lib.removePrefix hookPrefix name) file.source
  ) hookFiles;
  hooksDirectory = pkgs.linkFarm "git-hooks" deployedHooks;
in
{
  # 生成した Git 設定を実際の git に読ませ、URL ごとに選ばれる helper と token を見る
  git-credential-routing =
    pkgs.runCommandLocal "check-git-credential-routing"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          git
          gnugrep
        ];
        accounts = builtins.attrNames fixtureOwners;
      }
      ''
        set -euo pipefail
        export HOME=$PWD GH_CONFIG_DIR=$PWD/gh GH_NO_UPDATE_NOTIFIER=1
        export GIT_CONFIG_GLOBAL=${gitConfig} GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

        mkdir fixture-tokens
        for account in $accounts; do
          printf 'token-%s' "$account" > "fixture-tokens/$account"
        done

        fill() {
          rm -f trace
          printf 'url=%s\n\n' "$1" \
            | GIT_TRACE="$PWD/trace" git credential fill > filled 2> fill.stderr || true
        }

        expect_account() {
          local url=$1 account=$2
          fill "$url"
          if ! grep -qx "password=token-$account" filled \
            || ! grep -qx 'username=x-access-token' filled; then
            echo "$url did not receive the token of $account" >&2
            cat fill.stderr >&2
            exit 1
          fi
          if grep -qF 'gh auth git-credential' trace; then
            echo "$url still asked gh for a credential" >&2
            exit 1
          fi
        }

        expect_gh() {
          local url=$1
          fill "$url"
          if ! grep -qF 'gh auth git-credential get' trace \
            || grep -qF 'git-credential-token-file' trace \
            || grep -q '^password=' filled; then
            echo "$url did not fall back to the gh helper alone" >&2
            exit 1
          fi
        }

        expect_account https://github.com/fixture-org/repo.git fixture-b
        expect_account https://github.com/fixture-team/repo.git fixture-c
        expect_account https://github.com/fixture-lab/repo fixture-c
        expect_gh https://github.com/fixture-primary/repo.git
        # path の一致は segment 単位。名前が前方一致するだけの owner を取り込まない
        expect_gh https://github.com/fixture-org-other/repo.git
        touch $out
      '';

  # 配備した hook 一式を実際の git に起こさせ、dotfiles の検査と repository の hook の連鎖を見る
  git-hook-dispatch =
    assert lib.all (name: deployedHooks ? ${name}) [
      "commit-msg"
      "post-checkout"
      "post-merge"
      "pre-commit"
      "pre-push"
      "prepare-commit-msg"
    ];
    pkgs.runCommandLocal "check-git-hook-dispatch"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          git
          gnugrep
        ];
        HOOKS = hooksDirectory;
      }
      ''
        bash ${./fixtures/hooks.sh}
        touch $out
      '';
}
