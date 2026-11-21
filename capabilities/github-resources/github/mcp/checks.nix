{
  configuration = [
    (
      {
        lib,
        pkgs,
        hostConfig,
        ...
      }:
      let
        fixtureAccounts = [
          "fixture-a"
          "fixture-b"
        ];
        mkFixtureTarget = account: lib.nameValuePair "github-${account}" { provider = "github"; };
        fixtureTargets = builtins.listToAttrs (map mkFixtureTarget fixtureAccounts);

        assertionsPass =
          accounts: candidateTargets:
          let
            evaluation = lib.evalModules {
              specialArgs = { inherit pkgs; };
              modules = [
                ./module.nix
                (
                  { lib, ... }:
                  {
                    options = {
                      dotfiles.identity.github.accounts = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                      };
                      dotfiles.capabilities.resolved = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                      };
                      dotfiles.platform.mcp.targets = lib.mkOption {
                        type = lib.types.attrsOf lib.types.raw;
                        default = { };
                      };
                      dotfiles.platform.mcp.privateServers = lib.mkOption {
                        type = lib.types.attrsOf lib.types.raw;
                        default = { };
                      };
                      assertions = lib.mkOption {
                        type = lib.types.listOf lib.types.raw;
                        default = [ ];
                      };
                      sops.secrets = lib.mkOption {
                        type = lib.types.attrsOf lib.types.raw;
                        default = { };
                      };
                    };

                    config = {
                      dotfiles.identity.github.accounts = accounts;
                      dotfiles.capabilities.resolved = [ "github-resources" ];
                      dotfiles.platform.mcp.targets = lib.mkForce candidateTargets;
                    };
                  }
                )
              ];
            };
            result = builtins.tryEval (
              builtins.deepSeq evaluation.config.assertions (
                lib.all (entry: entry.assertion) evaluation.config.assertions
              )
            );
          in
          result.success && result.value;

        missingTarget = builtins.removeAttrs fixtureTargets [ "github-fixture-b" ];
        extraTarget = fixtureTargets // {
          github-extra.provider = "github";
        };
        renamedTarget = builtins.removeAttrs fixtureTargets [ "github-fixture-b" ] // {
          github-renamed = fixtureTargets.github-fixture-b;
        };

        accounts = hostConfig.dotfiles.identity.github.accounts;
        githubTargetNames = builtins.attrNames (
          lib.filterAttrs (_: target: target.provider == "github") hostConfig.dotfiles.platform.mcp.targets
        );
        expectedTargetNames = lib.sort builtins.lessThan (map (account: "github-${account}") accounts);
        writers = hostConfig.dotfiles.platform.mcp.privateServers;
        writerNames = lib.sort builtins.lessThan (map (account: "github-write-${account}") accounts);
        # 配備する起動 script をそのまま使い、server が公開する tool の集合で境界を確かめる
        toolSurface = builtins.toJSON {
          servers =
            map (account: {
              name = "github-${account}";
              script = hostConfig.dotfiles.platform.mcp.targets."github-${account}".executable;
              readOnly = true;
            }) accounts
            ++ map (account: {
              name = "github-write-${account}";
              script = writers."github-write-${account}".executable;
              readOnly = false;
            }) accounts;
          # dotfiles-github-write が起動中のセッションで担う書込
          commandOwned = [
            "add_issue_comment"
            "create_branch"
            "update_issue_comment"
          ];
          # 直前確認を要する merge、削除、commit と history の操作、命令が持たない field の更新、
          # その pre-read と identity の確認
          retained = [
            "add_comment_to_pending_review"
            "add_reply_to_pull_request_comment"
            "create_pull_request"
            "create_or_update_file"
            "delete_file"
            "get_file_contents"
            "get_me"
            "issue_read"
            "issue_write"
            "list_branches"
            "merge_pull_request"
            "pull_request_read"
            "pull_request_review_write"
            "push_files"
            "sub_issue_write"
            "update_pull_request"
            "update_pull_request_branch"
          ];
        };
      in
      {
        github-account-target-contract =
          assert githubTargetNames == expectedTargetNames;
          assert assertionsPass fixtureAccounts fixtureTargets;
          assert !(assertionsPass fixtureAccounts missingTarget);
          assert !(assertionsPass fixtureAccounts extraTarget);
          assert !(assertionsPass fixtureAccounts renamedTarget);
          assert builtins.attrNames writers == writerNames;
          pkgs.runCommandLocal "check-github-account-target-contract" { } "touch $out";

        github-account-tool-surface =
          pkgs.runCommandLocal "check-github-account-tool-surface" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              python3 ${./fixtures/tool-surface.py} ${lib.escapeShellArg toolSurface}
              touch "$out"
            '';
      }
    )
  ];
}
