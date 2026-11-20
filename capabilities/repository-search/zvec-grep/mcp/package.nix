{
  lib,
  fetchurl,
  runCommandLocal,
  writeShellApplication,
  zvecGrep,
  port,
}:

let
  # loopback 限定の front では初回 download ができないため model artifact の事前配備が必須
  modelRepo = "minishlab/potion-code-16M-v2";
  modelRevision = "e9d2a44ca6a05ac6685f3b23709ea57eb7352d5b";
  modelBase = "https://huggingface.co/${modelRepo}/resolve/${modelRevision}";
  modelFile = fetchurl {
    url = "${modelBase}/model.safetensors";
    hash = "sha256-dc96bCFxsjCtGbHn2OCxruhtpaAq+OfKzt2ZIdInYjw=";
  };
  tokenizerFile = fetchurl {
    url = "${modelBase}/tokenizer.json";
    hash = "sha256-EHu9y61L/x0pm3pMOi+xfFKJBoi33Q5Mneq3nTxPPUU=";
  };
  # 読取専用 cache では zg による tokenizer_config.json の生成ができないため事前配備が必須
  modelCache = runCommandLocal "zvec-grep-model-cache-${modelRevision}" { } ''
    model_dir="$out/model2vec/${lib.replaceStrings [ "/" ] [ "--" ] modelRepo}/${modelRevision}"
    mkdir -p "$model_dir/tokenizer"
    cp ${modelFile} "$model_dir/model.safetensors"
    cp ${tokenizerFile} "$model_dir/tokenizer/tokenizer.json"
    printf '%s\n' '{"tokenizer_class":"PreTrainedTokenizer"}' > "$model_dir/tokenizer/tokenizer_config.json"
  '';
in
writeShellApplication {
  name = "zvec-grep-mcp";
  text = ''
    export ZVEC_GREP_MODEL_CACHE=${modelCache}
    exec ${lib.getExe zvecGrep} --server run --listen 127.0.0.1:${toString port} --mcp-toolset agent
  '';
  passthru = { inherit modelCache; };
}
