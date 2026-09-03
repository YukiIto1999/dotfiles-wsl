# roster から各 client の LSP 登録形式への写像。
#
# roster は「この環境が提供する language server」を宣言し、client は「その集合をどう登録するか」
# だけを持つ。この module は形式変換に閉じ、roster に無い事実を作らない。唯一の例外は有効条件で、
# client ごとに既定が違うため、統一した条件をここで明示する。
#
# 不変条件: roster に宣言した server は、client と checkout の内容に関係なく、対応する拡張子を
# 開いた時点で有効になる。
#
# client 別の機構は次のとおりで、いずれも配備物と upstream の実装で確認した。
#
# Claude Code: plugin の `.lsp.json` に有効条件の field が無く、拡張子だけで解決する。built-in の
#              server 表を持たないので継承も起きない。roster の key をそのまま id にする。
# OMP:         宣言した名前で `defaults.json` の同名 server へ shallow merge される。宣言しない
#              field は上流の値が残るため、有効条件は必ず自分で出す。名前は実装が同一の server
#              だけ上流に合わせ、別実装には自前の名前を与えて他実装向けの設定を継承しない。
# OpenCode:    同 id の built-in へ merge されるが、`root` は built-in のものが残り、config に
#              `root` を書く手段が無い。root は workspace root と起動可否の両方を決め、marker が
#              見つからないときに諦める built-in もある。継承を避けるしかないので id を分ける。
{ lib }:

let
  # cwd 自体を marker にすると、checkout に何があるかに関係なく有効になる。
  # "." は OMP が Claude 形式の `extensionToLanguage` へ与える既定と同じ値である
  environmentRootMarkers = [ "." ];

  # 実装が同一なら上流 `defaults.json` の名前に合わせ、その server 向けの設定と runtime 配線を
  # 継承する。csharp の roslyn-ls と typescript の tsgo は上流の同名 server とは別実装なので、
  # 自前の名前で宣言して OmniSharp と tsserver 向けの設定を受け取らない
  ompNames = {
    bash = "bashls";
    csharp = "roslyn-ls";
    java = "jdtls";
    nix = "nixd";
    python = "ty";
    rust = "rust-analyzer";
    typescript = "tsgo";
  };

  # OpenCode の built-in id と衝突すると root 解決を継承する。所有者を前置して id 空間を分ける。
  # 分けないと、同名の built-in がある server だけ上流の marker 表に従い、由来が揃わない
  opencodeName = name: "dotfiles-${name}";
in
{
  inherit environmentRootMarkers ompNames opencodeName;

  claude =
    roster:
    lib.mapAttrs (
      _: server:
      {
        inherit (server) command;
        extensionToLanguage = server.extensions;
      }
      // lib.optionalAttrs (server.args != [ ]) { inherit (server) args; }
      // lib.optionalAttrs (server.initializationOptions != { }) {
        inherit (server) initializationOptions;
      }
    ) roster;

  omp =
    roster:
    lib.mapAttrs' (
      name: server:
      lib.nameValuePair ompNames.${name} (
        {
          inherit (server) command args;
          fileTypes = builtins.attrNames server.extensions;
          rootMarkers = environmentRootMarkers;
        }
        // lib.optionalAttrs (server.initializationOptions != { }) {
          initOptions = server.initializationOptions;
        }
      )
    ) roster;

  opencode =
    roster:
    lib.mapAttrs' (
      name: server:
      lib.nameValuePair (opencodeName name) (
        {
          command = [ server.command ] ++ server.args;
          extensions = builtins.attrNames server.extensions;
        }
        // lib.optionalAttrs (server.initializationOptions != { }) {
          initialization = server.initializationOptions;
        }
      )
    ) roster;
}
