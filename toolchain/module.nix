{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my;
in
{
  # 責務を持つ unit が所有しない、全 project 横断で使う実行ファイル
  options.my.toolchain = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = { };
    description = "利用者と agent が PATH 上で使う汎用ツール。project 固有の依存は devenv が持つ。";
  };

  # language server の binary。登録形式は各 CLI が持ち、PATH への配置はここが持つ
  options.my.lsp = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          package = lib.mkOption {
            type = lib.types.package;
            description = "server binary を提供する package。";
          };
          command = lib.mkOption {
            type = lib.types.str;
            description = "PATH 上で起動する実行ファイル名。";
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "server を LSP mode で起動する引数。";
          };
          extensions = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = "拡張子から language id への対応。拡張子は . から始める。";
          };
        };
      }
    );
    default = { };
    description = "AI CLI が接続する language server。対象言語は checkout の実測で決める。";
  };

  # 使用量と、解決すべき symbol と型を持つかで選ぶ。file 数が多くても HTML と CSS は採らない
  config.my.lsp = {
    csharp = {
      package = pkgs.roslyn-ls;
      command = "Microsoft.CodeAnalysis.LanguageServer";
      args = [
        "--logLevel"
        "Information"
        "--stdio"
      ];
      extensions.".cs" = "csharp";
    };

    typescript = {
      package = pkgs.typescript-go;
      command = "tsgo";
      args = [
        "--lsp"
        "--stdio"
      ];
      extensions = {
        ".ts" = "typescript";
        ".tsx" = "typescriptreact";
        ".mts" = "typescript";
        ".cts" = "typescript";
        ".js" = "javascript";
        ".jsx" = "javascriptreact";
        ".mjs" = "javascript";
        ".cjs" = "javascript";
      };
    };

    java = {
      package = pkgs.jdt-language-server;
      command = "jdtls";
      extensions.".java" = "java";
    };

    python = {
      package = pkgs.ty;
      command = "ty";
      args = [
        "server"
      ];
      extensions = {
        ".py" = "python";
        ".pyi" = "python";
      };
    };

    rust = {
      package = pkgs.rust-analyzer;
      command = "rust-analyzer";
      extensions.".rs" = "rust";
    };

    nix = {
      package = pkgs.nixd;
      command = "nixd";
      extensions.".nix" = "nix";
    };

    bash = {
      package = pkgs.bash-language-server;
      command = "bash-language-server";
      args = [ "start" ];
      extensions = {
        ".sh" = "shellscript";
        ".bash" = "shellscript";
      };
    };
  };

  config.my.toolchain = {
    # GitHub Actions のローカル実行。nix 統合を持つ
    actrun = pkgs.callPackage ./actrun/package.nix { };
    # project scope の agent context 管理。user scope の配備は clis が持つ
    apm = pkgs.callPackage ./apm/package.nix { };

    inherit (pkgs)
      # 言語 runtime
      nodejs_24
      python3
      uv
      # 探索と整形
      ripgrep
      fd
      jq
      yq
      xh
      # 構文検査と整形
      shellcheck
      shfmt
      nixfmt
      ruff
      # 構文 pattern の検索と一括書き換え、pattern は自分で書く
      ast-grep
      # 整備された rule 群による静的解析、security skill の finding source
      semgrep
      # 環境の観測と実行
      just
      devenv
      nvd
      wget
      curl
      vim
      ;
  };

  config.home-manager.users.${cfg.username} = _: {
    home.packages =
      builtins.attrValues cfg.toolchain ++ map (server: server.package) (builtins.attrValues cfg.lsp);
  };
}
