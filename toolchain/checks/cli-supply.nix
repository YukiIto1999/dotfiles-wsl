{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:
      let
        toolchain = hostConfig.dotfiles.toolchain.packages;
        fixtures = ../fixtures/cli-supply;
      in
      {
        toolchain-cli-supply-runs =
          pkgs.runCommandLocal "check-toolchain-cli-supply-runs"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.jq
              ];
            }
            ''
              set -euo pipefail
              export HOME=$PWD/home XDG_CACHE_HOME=$PWD/cache
              mkdir -p "$HOME"

              run() {
                local expected=$1 name=$2 status=0
                shift 2
                "$@" > "$name.out" 2> "$name.err" || status=$?
                if [ "$status" -ne "$expected" ]; then
                  echo "$name exited $status instead of $expected: $*" >&2
                  cat "$name.err" >&2
                  exit 1
                fi
              }

              expect_only_bin() {
                local package=$1 name=$2
                if [ "$(ls "$package/bin")" != "$name" ]; then
                  echo "$package must expose only bin/$name:" >&2
                  ls "$package/bin" >&2
                  exit 1
                fi
              }

              betterleaks=${lib.getExe' toolchain.betterleaks "betterleaks"}
              token="ghp_$(printf 'dotfiles betterleaks fixture' | sha256sum | cut -c1-36)"
              mkdir leak clean
              printf 'token = "%s"\n' "$token" > leak/config.txt
              printf 'no secret\n' > clean/readme.txt
              run 3 leak "$betterleaks" dir --no-banner --no-color --redact --validation=false \
                --exit-code 3 --report-format json --report-path leak.json leak
              jq -e 'length == 1 and .[0].RuleID == "github-pat" and .[0].Secret == "REDACTED" and .[0].Match == "REDACTED"' \
                leak.json > /dev/null
              if grep -Fq -- "$token" leak.json leak.out leak.err; then
                echo "betterleaks wrote the unredacted fixture secret" >&2
                exit 1
              fi
              run 0 clean "$betterleaks" dir --no-banner --no-color --redact --validation=false \
                --exit-code 3 --report-format json --report-path clean.json clean
              jq -e 'length == 0' clean.json > /dev/null

              zizmor=${lib.getExe' toolchain.zizmor "zizmor"}
              run 14 injection "$zizmor" --offline --no-config --no-progress --color never --format json \
                ${fixtures}/template-injection.yml
              jq -e '[.[].ident] == ["template-injection"]' injection.out > /dev/null
              run 0 quiet "$zizmor" --offline --no-config --no-progress --color never --format json \
                ${fixtures}/quiet.yml
              jq -e 'length == 0' quiet.out > /dev/null

              expect_only_bin ${toolchain.nix-locate} nix-locate
              run 0 locate ${lib.getExe' toolchain.nix-locate "nix-locate"} --minimal --whole-name --at-root /bin/gdb
              grep -Fxq gdb.out locate.out
              expect_only_bin ${toolchain.gdb} gdb

              touch "$out"
            '';
      }
    )
  ];
}
