# Repository 所有 Skill の composition

**読み手:** 外部 repository が所有する Skill を、この host の agent へ取り込む設計・実装を担当する人。変更前に読む。

この文書は将来設計であり、まだ実装していない。設計対象は `dotfiles-wsl` における source の固定、Skill の採用、runtime command の供給、agent client への配備である。外部 repository が所有する手順、domain contract、private data の形式は設計しない。

## 決定

外部 repository が所有する Skill は owner repository から直接取得する。`dotfiles-wsl` は固定した revision から採用対象だけを明示し、既存の `agents` unit で local Skill と合成する。repository 固有 Skill を集める中央 repository と、新しい top-level unit は作らない。

| Owner | 所有するもの |
|---|---|
| Skill の owner repository | `SKILL.md`、reference、script、eval、Skill 固有 command の公開手段 |
| `flake.nix` | private data を含まない source と revision の固定、`agentSkillInputs` への登録 |
| `agents` unit | upstream layout の正規化、採用 allowlist、command binding、衝突検査、配備 artifact |
| `agents/<client>` adapter | upstream client が受理する Skill destination への binding |

Skill は domain の判断と一緒に変更されるため、owner repository に置く。中央 repository へ移すと、本文、reference、eval の変更理由と revision が owner から分かれる。`agents/shared/skills/` への複製も二つの正本を作るため行わない。donor を参考に `dotfiles-wsl` が別の Skill を所有し直す場合だけ local Skill とする。

依存方向は次の二つに分ける。owner repository から `dotfiles-wsl` への逆依存は作らない。

```text
source:  dotfiles-wsl ──> pinned owner repository
runtime: agent ──> deployed Skill ──> declared command
```

## 現行 contract と維持する境界

現在は OpenAI plugin を plain flake input として固定し（`flake.nix:16-20`）、`agents/module.nix:41-74` が security plugin と local Skill を directory 走査で全件採用している。合成結果は `dotfiles.agents.shared.skills` の `attrsOf path` であり（`agents/impl/contract.nix:444-454`）、同じ集合を全 client へ配備する（`agents/module.nix:130-141`）。

将来も `dotfiles.agents.shared.skills` と全 client 共通配備を維持する。source ごとの client 選択は、必要性が実証されていないため導入しない。変更するのは、Skill source の hard-code と全件自動採用を、source 宣言と明示 allowlist に置き換える部分である。

この責務は `agents` unit に置く。Skill は agent client へ配備する artifact であり、独立した state、consumer、lifecycle を持たない。人や service も直接使う CLI が将来生じ、agent と別に変更、配備する必要が出た場合にだけ、既存の unit 分離規則に従って別 unit を検討する。

## Source と Skill の内部 contract

`flake.nix` は取得した source だけを `specialArgs.agentSkillInputs` へ渡す。repository 固有の layout や採用 Skill は持たない。次は現行 source を新 contract へ移す時点の形であり、admission を終えていない source は加えない。

```nix
agentSkillInputs = {
  dotfiles = self.outPath;
  openai-plugins = openaiPlugins;
};
```

source 宣言は公開 Nix option にせず、`agents` unit 内の let-bound value とする。別 module から source、allowlist、derivation を注入させない。合成後の `dotfiles.agents.shared.skills` だけを、現在どおり `internal = true`、`readOnly = true` の正規化結果として公開する。

```nix
skillSources.<source-id> = {
  input = "<agentSkillInputs key>";
  root = "<input 内の Skill root への相対 path>";

  skills.<skill-name>.requiredCommands = [ "<command-name>" ];

  commands.<command-name> = {
    provider = resolvedInput: <同じ input から作る derivation>;
    executable = "<provider 内の executable basename>";
    runtimeWrapper = null; # または provider package を受け取る関数
  };
};
```

`root` は、各 Skill が `<input>/<root>/<skill-name>/SKILL.md` にある directory を指す。`skills` の key が採用 allowlist であり、source の directory を走査して暗黙に増やさない。local Skill も例外にせず、現在の集合を明記する。upstream や `agents/shared/skills/` に Skill が増えても、この宣言を変更するまで配備対象には入らない。

合成時には、採用した directory を既存の `dotfiles.agents.shared.skills` へ正規化する。`SKILL.md` の frontmatter `name` は `skill-name` と一致させる。source をまたぐ同名 Skill に優先順位、alias、override は設けず、重複を拒否する。

## Runtime command の contract

Skill が owner 固有 command を呼ぶ場合だけ、`requiredCommands` に agent が実行する安定名を記す。`git`、`rg`、`zg` など agent 共通の基礎 command はここへ重複して宣言しない。Skill は自身と同じ source entry の `commands` だけを要求できる。

composition は `input` から解決した同じ revision を `provider` 関数へ渡す。通常 flake input の package を使う場合も、その input が公開する同一 lock node の package を選ぶ。別 revision や別 owner から同名 executable を供給しない。

`runtimeWrapper = null` なら、composition が provider の `executable` を `<command-name>` として公開する。wrapper 関数を使う場合は provider package だけを引数に取り、`bin/<command-name>` を返す。wrapper の derivation graph が provider を参照することを検査する。最後に、宣言した command だけをまとめた package を Home Manager の `home.packages` へ一度だけ加え、provider に含まれる無関係な executable は PATH へ公開しない。

wrapper に埋め込めるのは store から読まれてよい非秘密値だけである。secret や非公開 path を derivation へ束縛しない。実行時に secret が必要なら、wrapper には公開してよい固定 path だけを置き、既存の SOPS 境界が store 外へ配備した file を読む。任意の environment variable、secret、host path を `skillSources` の汎用 field として追加しない。

## 拒否する構成

evaluation と build check は次を拒否する。

- `input` が `agentSkillInputs` にない
- `root` が空または絶対 path である、もしくは path segment に空文字列、`.`、`..` を含む
- `source-id`、`skill-name`、`command-name` が安全な basename でない
- 採用 Skill の directory または直下の `SKILL.md` がない
- frontmatter `name` と `skill-name` が一致しない
- source をまたいで `skill-name` または `command-name` が重複する
- `requiredCommands` が同じ source entry の `commands` にない
- どの採用 Skill からも参照されない command provider が残る
- command 名が agent client 自身の executable と衝突する
- provider が宣言した executable が build 結果にない、または実行できない
- provider の derivation input が宣言した source pin と結び付かない
- runtime wrapper の derivation graph が provider package を含まない

## Admission

repository が Skill を所有しているだけでは配備しない。次をすべて満たした source と Skill だけを `agentSkillInputs` と `skillSources` に加える。

1. source 全体に private record、evidence、credential がなく、Nix store へ取り込めることを人が確認する。
2. 上流 Skill の直接採用が `docs/architecture/skills.md:9-13,122` の signature procedure 規則を満たす。repository 所有 Skill では、owner の同一 revision にある本文や tool から手順を分離すると方法の価値を失い、local Skill への再構成が規範や routing の複製になる場合だけを signature procedure と扱う。
3. license と利用条件を確認する。
4. Skill と owner 固有 command が同じ pin から供給される。
5. owner eval に加え、実際に全 client へ配る Skill 集合で trigger、near-miss、欠ける sibling Skill、immutable source、runtime command を検査する。
6. Skill が Git object や repository metadata を必要とする場合、固定 source artifact がその操作を実行できる。

Nix の type や closure check は、source が private data を含まないことを意味から証明できない。`agentSkillInputs` への登録は review が必要な trust decision である。private path を source にすれば path 文字列も store から観測できるため、非公開であるべき path は runtime の store 外設定で扱う。

## Source ごとの扱い

### local Skill

`agents/shared/skills/` の現在の集合を明示 allowlist に移す。自動検出を local だけの例外として残さない。移行前後で `dotfiles.agents.shared.skills` の key と source が同一であることを検査する。

### OpenAI security plugin

現在配備している六つの Skill を明示する。移行時に増減させず、以後の upstream 追加も lock 更新だけでは採用しない。

### architecture-standard

現行の `standard-apply` は、標準本文と process mapping から分離すると価値を失う signature procedure なので global 配備候補になるが、まだ `agentSkillInputs` に登録しない。同 Skill は対象 project の ADR に記録した標準 commit を特定し、`git -C <standard-root> show <commit>:...` で commit object の本文を読む（`architecture-standard/.claude/skills/standard-apply/SKILL.md:11-16,29-33`）。通常の `flake = false` source tree には、この操作に必要な Git object が含まれない。

owner が private data を含まない固定可能な配布 artifact を用意し、記録済み commit を解決できるようにするか、同等の不変条件を保つ immutable snapshot contract へ upstream Skill を変更するまで admission を保留する。単に repository tree を pin して `standard-apply` directory を配る案は採らない。

admission 後も global に選ぶ候補は `standard-apply` だけである。`standard-audit` と `standard-update` は architecture-standard 自体の監査・変更を担うため、その repository の local Skill として残す。`standard-apply` の owner eval は sibling Skill が存在する前提の near-miss を含むため（`architecture-standard/.claude/skills/standard-apply/evals/trigger-evals.json:12-18`）、global な実配備集合だけでも routing を再検査する。

確認した範囲では architecture-standard root に `LICENSE` または `COPYING` がない。配布 artifact の contract とともに利用条件も admission 前に確定する。

### vibe-knowledge

現時点では何も登録しない。private record を含む `vibe-knowledge` repository 自体を input にせず、owner 側に private data を含まない Skill 配布 source と、必要なら同じ pin から作る command package ができた後で admission を行う。この文書は、その配布境界、CLI、read/write protocol を決めない。

## 検証と導入

`nix flake check` には、contract の拒否条件に加えて次を登録する。

- 最終 Skill 集合が全 source の明示 allowlist の和と一致し、未採用 Skill を含まない
- 全 client の source と destination が現在の `dotfiles.agents.shared.skills` と一致する
- 配備 source が Nix store path である
- runtime package が宣言した command だけを公開し、`home.packages` に入る
- provider の derivation input が source entry と同じ lock node または source path を参照する
- wrapper の derivation graph が provider を参照し、既知の secret 値と非公開 path を含まない
- 外部 source の revision が `flake.lock` に固定され、採用 path がその input 配下にある
- owner eval と、全配備 Skill 集合に対する composition 固有 eval が成功する

private sentinel fixture は二つの限界を固定する。登録した synthetic input に sentinel があれば、Skill の subdirectory だけを選んでも source tree が store から観測できることを確認する。登録していない runtime fixture の sentinel は closure に入らないことを確認する。これは accidental dependency の回帰検査であり、登録 source の privacy 証明には使わない。

既存の deployment check は全 client の source、destination、artifact を照合している（`agents/checks/deployment.nix:215-276`）。Nix store source の検査も維持する（`agents/checks/deployment.nix:838-846`）。`dotfiles-doctor` は配備後の managed artifact drift を観測するだけとし、Skill の意味や command protocol の検査は owner repository の eval と composition 固有 check に残す。

導入は、local Skill と security plugin を新 contract へ写して配備集合が不変であることを確認するところまでを最初の変更にする。新しい owner source は個別に admission を終えてから追加する。`architecture-standard` と `vibe-knowledge` は現時点で加えない。revision 更新では `flake.lock`、source 固有 check、composition 固有 eval を同じ変更にし、upstream の追加や rename を暗黙に取り込まない。
