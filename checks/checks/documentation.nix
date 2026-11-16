{
  pkgs,
  lib,
  self,
  ...
}:
let
  root = /. + builtins.unsafeDiscardStringContext (toString self);
  # docs/README.md など読み手の明示を求めない文書の変更で再実行しない
  readerDocKinds = [
    "operations"
    "reference"
    "architecture"
  ];
  readerDocSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions (
      map (kind: lib.fileset.fileFilter (file: file.hasExt "md") (root + "/docs/${kind}")) readerDocKinds
    );
  };
in
{
  source = [
    {
      docs-reader = pkgs.runCommandLocal "check-docs-reader" { } ''
        set -euo pipefail
        missing=""
        for kind in ${lib.escapeShellArgs readerDocKinds}; do
          for doc in ${readerDocSource}/docs/$kind/*.md; do
            grep -q '^\*\*読み手:\*\*' "$doc" || missing="$missing $doc"
          done
        done
        if [ -n "$missing" ]; then
          echo "docs missing a reader statement:$missing" >&2
          exit 1
        fi
        touch $out
      '';

      # 文書の相互参照。移動と参照切れを build で落とす
      docs-links = pkgs.testers.lycheeLinkCheck {
        # 文書は宣言 file を参照するため、site は checkout 全体にする
        site = self;
        extraConfig.offline = true;
      };

      # link 先が解決しても、表示名が移動前の path を名乗っていれば読み手は迷う。
      # link destination だけでなく、表示した path の実在も検査する。他の repository が所有する
      # path は所有者の repository を指す link で示し、この検査の対象にしない。
      docs-path-labels =
        pkgs.runCommandLocal "check-docs-path-labels"
          {
            nativeBuildInputs = with pkgs; [
              coreutils
              gnugrep
              gnused
            ];
          }
          ''
            set -euo pipefail

            missing=""
            while IFS= read -r doc; do
              # 大文字を含む token は NAME のような雛形なので対象にしない
              while IFS= read -r label; do
                [ -e "${self}/$label" ] || missing="$missing ''${doc#${self}/}:$label"
              done < <(
                grep -ohE '`[a-z0-9_.-]+/[a-z0-9_./-]+\.(nix|sh|md|yaml|yml|json|py|ts)`' "$doc" \
                  | tr -d '`' | sort -u || true
              )
            done < <(find ${self}/README.md ${self}/CONTRIBUTING.md ${self}/docs -name '*.md')

            if [ -n "$missing" ]; then
              echo "documentation names a path that does not exist:$missing" >&2
              exit 1
            fi
            touch $out
          '';

    }
  ];
}
