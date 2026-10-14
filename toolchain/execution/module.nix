{ lib, pkgs, ... }:

let
  programs = import ./package.nix { inherit lib pkgs; };
in
{
  # Cargo の cache と出力先、Nix の no-result-link、project の devShell への入口は、process の寿命を持つ runtime ではなく toolchain が決める。
  # managed command は wrapper が policy を一度適用してから lifecycle へ渡し、client ごとの cache は増やさない。
  options.dotfiles.toolchain.execution.policy = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "`dotfiles-execution-policy [--shared-cache DIR] [--build-root DIR] -- COMMAND...`。未指定の CARGO_HOME と XDG_CACHE_HOME を共有 cache へ、build-dir と target-dir を明示も project 設定もしない checkout の CARGO_BUILD_BUILD_DIR を build root 配下へ向け、nix と nix-build の結果 link を作らない shim を PATH の先頭へ置いて COMMAND を exec する。空文字列を含む明示値と project の Cargo 設定を優先し、directory の作成と回収はしない。";
  };

  options.dotfiles.toolchain.execution.projectRun = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    internal = true;
    description = "`dotfiles-project-run [--attr NAME] -- ABSOLUTE-EXECUTABLE [ARG...]`。direnv が承認済みと答える project の .envrc の directory だけを flake として、その devShell を lock を更新せず `nix develop` で開き、絶対 path の実行ファイルを起動する。未承認、拒否、devShell の欠落と評価失敗は実行ファイルを起動せず非ゼロで終わり、host の PATH や基礎環境へ戻らない。";
  };

  config.dotfiles.toolchain.execution = {
    inherit (programs) policy projectRun;
  };

  # 利用者が Orca の command override から呼ぶため PATH に置く。
  config.dotfiles.toolchain.packages.dotfiles-project-run = programs.projectRun;
}
