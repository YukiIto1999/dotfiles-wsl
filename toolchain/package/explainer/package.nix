{
  lib,
  buildNpmPackage,
  nodejs_24,
  makeWrapper,
  coreutils,
  runtimeShell,
  fetchzip,
  runCommand,
  playwright-driver,
  explainerSource,
}:

let
  chromiumHeadless = playwright-driver.components.chromium-headless-shell.overrideAttrs (_: {
    name = "explainer-chromium-headless-shell-149.0.7827.55";
    src = fetchzip {
      url = "https://cdn.playwright.dev/builds/cft/149.0.7827.55/linux64/chrome-headless-shell-linux64.zip";
      hash = "sha256-gggPgsytsnEkRfuilixnMW5c9flq2mglNdYcAWbcQOs=";
      stripRoot = true;
    };
  });
  browsers = runCommand "explainer-playwright-browsers-1228" { } ''
    mkdir -p "$out/chromium_headless_shell-1228"
    ln -s ${chromiumHeadless} "$out/chromium_headless_shell-1228/chrome-headless-shell-linux64"
  '';
in
buildNpmPackage {
  pname = "explainer-runtime";
  version = "578defb";
  src = explainerSource;
  nodejs = nodejs_24;
  npmDepsHash = "sha256-wdfOF2PzlrhSgSvYokGKhG/QYNfp14TuXZpruSeNaX8=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  postPatch = ''
    cp ${./package.json} package.json
    cp ${./package-lock.json} package-lock.json
  '';

  installPhase = ''
        runHook preInstall
        mkdir -p "$out/share/explainer" "$out/bin"
        cp -R . "$out/share/explainer/"
        for spec in \
          'build-html:explainer/scripts/build-html.mjs' \
          'verify-doc:explainer/scripts/verify-doc.mjs' \
          'verify-book:explainer-book/scripts/verify-book.mjs' \
          'figure-check:explainer/scripts/figure-check.mjs'; do
          name="''${spec%%:*}"
          script="''${spec#*:}"
          cat > "$out/bin/explainer-$name" <<EOF
    #!${runtimeShell}
    case "\''${1-}" in /*) ;; *) echo "explainer requires an absolute document or figure path" >&2; exit 2;; esac
    work=\$(${coreutils}/bin/mktemp -d "\''${TMPDIR:-/tmp}/explainer-runtime.XXXXXX")
    ${coreutils}/bin/ln -s "$out/share/explainer/package.json" "\$work/package.json"
    ${coreutils}/bin/ln -s "$out/share/explainer/node_modules" "\$work/node_modules"
    cd "\$work" || exit 2
    export NODE_PATH="$out/share/explainer/node_modules"
    export PLAYWRIGHT_BROWSERS_PATH=${browsers}
    ${nodejs_24}/bin/node "$out/share/explainer/skills/$script" "\$@"
    EOF
          chmod +x "$out/bin/explainer-$name"
        done
        makeWrapper ${nodejs_24}/bin/node "$out/bin/explainer-vlmkit" \
          --add-flags "$out/share/explainer/node_modules/@mizchi/vlmkit/dist/vlmkit.mjs" \
          --set NODE_PATH "$out/share/explainer/node_modules" \
          --set PLAYWRIGHT_BROWSERS_PATH ${browsers}
        runHook postInstall
  '';

  meta = {
    description = "Pinned upstream explainer scripts with compatible immutable dependencies";
    homepage = "https://github.com/mizchi/explainer";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "explainer-verify-doc";
  };
}
