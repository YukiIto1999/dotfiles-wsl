# 採用した upstream Skill の ID から、固定した flake input の中の directory への対応。
# upstream の追加による採用集合の暗黙変更を防ぐため directory の自動列挙は不採用
{ inputs }:

let
  from = source: directories: builtins.mapAttrs (_: directory: "${source}/${directory}") directories;
in
from inputs.orca {
  orca-cli = "skills/orca-cli";
  orca-computer-use = "skills/orca-computer-use";
  orca-emulator = "skills/orca-emulator";
  orca-emulator-android = "skills/orca-emulator-android";
  orca-linear = "skills/orca-linear";
  orca-per-workspace-env = "skills/orca-per-workspace-env";
  orchestration = "skills/orchestration";
}
// from inputs.mattSkills {
  diagnosing-bugs = "skills/engineering/diagnosing-bugs";
  domain-modeling = "skills/engineering/domain-modeling";
  grilling = "skills/productivity/grilling";
  code-review = "skills/engineering/code-review";
  setup-matt-pocock-skills = "skills/engineering/setup-matt-pocock-skills";
  codebase-design = "skills/engineering/codebase-design";
  improve-codebase-architecture = "skills/engineering/improve-codebase-architecture";
  grill-with-docs = "skills/engineering/grill-with-docs";
  to-spec = "skills/engineering/to-spec";
  to-tickets = "skills/engineering/to-tickets";
  prototype = "skills/engineering/prototype";
  retro = "skills/engineering/retro";
  writing-for-agents = "skills/productivity/writing-for-agents";
}
// from inputs.pstackSkills {
  benchmark-checklist = "pstack/skills/benchmark-checklist";
  correct = "pstack/skills/correct";
  maintain-verification-skill = "pstack/skills/maintain-verification-skill";
  # TLA+ の検査結果は statechart で読む手順のため、相対参照先の statechart を同じ固定 source から配備する
  create-formal-verification-skill = "pstack/skills/create-formal-verification-skill";
  maintain-formal-verification-skill = "pstack/skills/maintain-formal-verification-skill";
  statechart = "pstack/skills/statechart";
}
// from inputs.chromeDevtoolsMcp {
  a11y-debugging = "skills/a11y-debugging";
  debug-optimize-lcp = "skills/debug-optimize-lcp";
}
// from inputs.dotnetSkills {
  msbuild = "plugins/dotnet/skills/msbuild";
  run-tests = "plugins/dotnet-test/skills/run-tests";
  platform-detection = "plugins/dotnet-test/skills/platform-detection";
  filter-syntax = "plugins/dotnet-test/skills/filter-syntax";
  microbenchmarking = "plugins/dotnet-diag/skills/microbenchmarking";
  nuget-trusted-publishing = "plugins/dotnet-advanced/skills/nuget-trusted-publishing";
}
// from inputs.explainerSkills {
  explainer = "skills/explainer";
  explainer-book = "skills/explainer-book";
  first-reader = "skills/first-reader";
}
