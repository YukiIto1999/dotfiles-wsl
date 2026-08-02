{ lib }:

# 部分一致も存在確認も追記で破れる。argparse も env も後勝ちなので、
# 出現回数を数え、--flag value と --flag=value の両形を見る
rec {
  tokensOf = exec: builtins.filter (token: token != "") (lib.splitString " " exec);

  # ExecStart が script のとき、unit の文字列では argv が見えない。
  # exec 行まで降りて docker や wrapper が実際に受け取る列を取る
  argvOfScript =
    exec:
    let
      script = lib.removeSuffix " " exec;
      afterExec = lib.last (lib.splitString "\nexec " (builtins.readFile script));
    in
    builtins.filter (token: token != "" && token != "\\") (
      lib.splitString " " (lib.replaceStrings [ "\n" "'" ] [ " " "" ] afterExec)
    );

  valuesOf =
    tokens: flag:
    lib.concatLists (
      lib.imap0 (
        index: token:
        lib.optional (token == flag && index + 1 < builtins.length tokens) (
          builtins.elemAt tokens (index + 1)
        )
        ++ lib.optional (lib.hasPrefix "${flag}=" token) (lib.removePrefix "${flag}=" token)
      ) tokens
    );

  onlyValue =
    tokens: flag: expected:
    valuesOf tokens flag == [ expected ];
}
