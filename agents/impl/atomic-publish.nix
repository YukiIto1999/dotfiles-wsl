{ pkgs }:

pkgs.runCommandCC "dotfiles-agent-atomic-publish" { } ''
  mkdir -p "$out/bin"
  $CC -std=c11 -O2 -Wall -Wextra -Werror \
    ${./atomic-publish.c} \
    -o "$out/bin/dotfiles-agent-atomic-publish"
''
