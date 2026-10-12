{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPypi,
  unzip,
  patchelf,
  addBinToPathHook,
  gitMinimal,
  writableTmpDirAsHomeHook,
  python3Packages,
}:

let
  version = "1.180.0";

  # 追加 flake input と submodule を要する upstream の Nix build のため source build は不採用
  semgrep-core = stdenv.mkDerivation {
    pname = "semgrep-core";
    inherit version;
    strictDeps = true;

    src =
      let
        wheelTag = "cp310.cp311.cp312.cp313.cp314.py310.py311.py312.py313.py314";
      in
      fetchPypi {
        pname = "semgrep";
        inherit version;
        format = "wheel";
        dist = wheelTag;
        python = wheelTag;
        platform = "manylinux_2_34_x86_64";
        hash = "sha256-FtsuJwargUqXXu7CXev61Jq7qEa3xRPYjgQURxUvhEc=";
      };

    nativeBuildInputs = [
      unzip
      patchelf
    ];

    # .whl を認識しない unzip の setup hook のため既定の unpackPhase は不可
    unpackPhase = ''
      runHook preUnpack
      unzip -qq "$src" 'semgrep-${version}.data/purelib/semgrep/bin/*'
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      bin=semgrep-${version}.data/purelib/semgrep/bin
      install -Dm755 -t "$out/bin" "$bin/semgrep-core"
      cp -r "$bin/libs" "$out/bin/libs"
      runHook postInstall
    '';

    # patchelf の複数回書き換えで巨大 binary が壊れる報告があるため autoPatchelfHook は不採用
    dontPatchELF = true;
    dontStrip = true;
    postFixup = ''
      patchelf \
        --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" \
        --set-rpath "$out/bin/libs:${lib.makeLibraryPath [ stdenv.cc.libc ]}" \
        "$out/bin/semgrep-core"
    '';

    meta = {
      description = "Lightweight static analysis for many languages - core binary";
      homepage = "https://semgrep.dev/";
      license = lib.licenses.lgpl21Plus;
      mainProgram = "semgrep-core";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
python3Packages.buildPythonApplication (finalAttrs: {
  pname = "semgrep";
  inherit version;
  pyproject = true;

  src = fetchFromGitHub {
    owner = "semgrep";
    repo = "semgrep";
    rev = "a35fe8306115b3e55274969098cc46f8451d6b4d";
    hash = "sha256-IaXW9gExaYqu/SBF/7Xu1Djx2GniVb50ZEv/35lwUNw=";
  };
  sourceRoot = "${finalAttrs.src.name}/cli";

  build-system = with python3Packages; [
    setuptools
    wheel
  ];

  # 他 package と共有する python 依存の版を変えないため依存の個別 override は不採用
  pythonRelaxDeps = [
    "boltons"
    "click"
    "exceptiongroup"
    "jsonschema"
    "mcp"
    "opentelemetry-api"
    "opentelemetry-exporter-otlp-proto-http"
    "opentelemetry-instrumentation-requests"
    "opentelemetry-instrumentation-threading"
    "opentelemetry-sdk"
    "pyjwt"
    "wcmatch"
  ];

  dependencies =
    (with python3Packages; [
      attrs
      boltons
      click
      click-option-group
      colorama
      exceptiongroup
      glom
      jsonschema
      mcp
      opentelemetry-api
      opentelemetry-exporter-otlp-proto-http
      opentelemetry-instrumentation-requests
      opentelemetry-instrumentation-threading
      opentelemetry-sdk
      packaging
      peewee
      pyjwt
      requests
      rich
      ruamel-yaml
      ruamel-yaml-clib
      semantic-version
      tomli
      typing-extensions
      urllib3
      wcmatch
    ])
    ++ python3Packages.pyjwt.optional-dependencies.crypto;

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ semgrep-core ])
    "--set-default"
    "SEMGREP_SEND_METRICS"
    "off"
    "--set-default"
    "SEMGREP_ENABLE_VERSION_CHECK"
    "0"
  ];

  nativeCheckInputs = [
    addBinToPathHook
    gitMinimal
    semgrep-core
    writableTmpDirAsHomeHook
  ]
  ++ (with python3Packages; [
    flaky
    pytest-asyncio
    pytest-freezegun
    pytest-mock
    pytest-snapshot
    pytest-timeout
    pytestCheckHook
    requests-mock
    types-freezegun
  ]);

  disabledTestPaths = [
    "tests/default/e2e"
    "tests/default/e2e-other"
    "tests/default/e2e-pysemgrep"
    "tests/default/mcp"
  ];

  disabledTests = [
    # .git を要する test のため sandbox 内の実行は不可
    "clean_project_url"
    # 上流が報告する flaky plugin の起動不可のため実行は不可
    "test_debug_performance"
    # network の無い sandbox のため実行は不可
    "test_install_command_download_error_records_download_reason"
    "test_install_command_metrics_off"
    "test_install_command_sends_failure_metrics"
    "test_install_command_sends_metrics_when_logged_in"
    "test_parse_exclude_rules_auto"
    "test_run_install_success_records_outcome"
    "test_run_install_version_check_failure_records_error"
    "test_send"
    "TestConfigLoaderForProducts"
  ];

  passthru = { inherit semgrep-core; };

  meta = {
    description = "Lightweight static analysis for many languages";
    homepage = "https://semgrep.dev/";
    changelog = "https://github.com/semgrep/semgrep/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.lgpl21Plus;
    mainProgram = "semgrep";
    platforms = [ "x86_64-linux" ];
  };
})
