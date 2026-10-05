{
  rustPlatform,
  fetchFromGitHub,
  cmake,
  perl,
}:

rustPlatform.buildRustPackage rec {
  pname = "agentgateway";
  version = "1.6.0";

  src = fetchFromGitHub {
    owner = "agentgateway";
    repo = "agentgateway";
    tag = "v${version}";
    hash = "sha256-rxRDONkTVFbav+cVO+aYtIzjcFu9JfnD/DTwumXgEYA=";
  };

  cargoHash = "sha256-PCE/wyslj4UPHocBKNp24QaqeKIGXRig9KZovBqdcHo=";

  patches = [
    ./agentgateway/mcp-session-recovery.patch
    ./agentgateway/mcp-downstream-lifecycle.patch
    ./agentgateway/mcp-loopback-bind.patch
  ];

  nativeBuildInputs = [
    cmake
    perl
  ];

  cargoBuildFlags = [
    "-p"
    "agentgateway-app"
  ];

  env = {
    RUSTFLAGS = "--cfg tokio_unstable";
    AGENTGATEWAY_BUILD_buildVersion = version;
    AGENTGATEWAY_BUILD_buildGitRevision = "v${version}";
  };

  doCheck = true;

  cargoTestFlags = [
    "-p"
    "agentgateway"
    "--lib"
  ];
  checkFlags = [ "downstream_lifecycle_" ];

  meta.mainProgram = "agentgateway";
}
