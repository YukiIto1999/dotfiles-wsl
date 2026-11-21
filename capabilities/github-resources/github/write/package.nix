{
  lib,
  writeShellApplication,
  writeText,
  coreutils,
  gnugrep,
  jq,
  gh,
  # account id から、その account の token file への対応
  accounts,
  # 本番は github.com。fixture だけが gh の開発用 host を渡す
  githubHost ? "github.com",
}:

let
  accountsFile = writeText "github-write-accounts.json" (builtins.toJSON accounts);
  vars = {
    accounts = lib.escapeShellArg "${accountsFile}";
    host = lib.escapeShellArg githubHost;
    gh = lib.escapeShellArg (lib.getExe gh);
  };
in
writeShellApplication {
  name = "dotfiles-github-write";
  runtimeInputs = [
    coreutils
    gnugrep
    jq
  ];
  text = builtins.replaceStrings (map (name: "@${name}@") (
    builtins.attrNames vars
  )) (builtins.attrValues vars) (builtins.readFile ./impl/write.sh);
  passthru = {
    githubWriteAccounts = accounts;
    githubWriteHost = githubHost;
    githubWriteGh = gh;
  };
}
