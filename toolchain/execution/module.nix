{
  config,
  lib,
  pkgs,
  ...
}:

let
  programs = import ./package.nix { inherit lib pkgs; };
  workloadRun = programs.mkWorkloadRun {
    supervise = lib.getExe config.dotfiles.platform.supervise.package;
    policy = config.dotfiles.workstation.workload.deepAdmissionPolicy;
  };
  # budget が未設定の間は入口を作らない。budget の無い policy は全ての走行を断るため、PATH にある command が常に断る状態を作らない
  cappedPolicy = config.dotfiles.workstation.workload.cappedAdmissionPolicy;
  cappedRun = lib.mapNullable (
    policy:
    programs.mkCappedRun {
      supervise = lib.getExe config.dotfiles.platform.supervise.package;
      inherit policy;
    }
  ) cappedPolicy;
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

  options.dotfiles.toolchain.execution.cappedRun = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    readOnly = true;
    internal = true;
    description = "`dotfiles-capped-run --cpu-percent P --wait-seconds W --run-seconds R [--memory-gib G] -- COMMAND...`。新しい前景の重い走行を、走行ごとの scope の CPUQuota を P%（CPU 一つ分が 100）に掛けて起動する。P、W、R は必須で、P は正の整数、W と R は有限で正の秒数。W は CPU と memory の予約を待つ秒数で、過ぎれば command を起動せず 75 で返す。R は入場から数える走行の秒数で、過ぎれば取り消して 124 で返す。P が host の budget を超える要求は待たずに 70 で返す。動いている走行は取り消さず、他の走行の scope へ止めの要求も出さず、自分も受入や deep に取り消されない。入れ子は、外側が capped の scope で P がその上限と等しい時だけ外側で走り、外側が capped でないか P が違う時は要求した上限を満たせないため 70 で返す。`dotfiles.workstation.workload.capped.cpuBudgetPercent` が null の間は null で、command は PATH に置かれない。";
  };

  config.dotfiles.toolchain.execution = {
    inherit (programs) policy projectRun;
    inherit cappedRun;
  };

  # 利用者が Orca の command override から呼ぶため PATH に置く。
  config.dotfiles.toolchain.packages.dotfiles-project-run = programs.projectRun;
  config.dotfiles.toolchain.packages.dotfiles-workload-run = workloadRun;
  config.dotfiles.toolchain.packages.dotfiles-capped-run = lib.mkIf (cappedRun != null) cappedRun;
}
