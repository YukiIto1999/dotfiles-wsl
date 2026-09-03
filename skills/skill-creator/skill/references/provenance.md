# Provenance

外部sourceを使ったSkillは、repository文書で次を追跡する。

- repositoryまたは公式source
- version、commit、取得時点のいずれか
- license
- 採用したprocedure、failure mode、trade-off
- 採らなかったsource固有のtaxonomy、runtime、harness
- local philosophyとrepository制約に合わせた変更

このSkillは次のdonorから方法を抽出した。本文やscriptはコピーしていない。

| Donor | Revision / date | License | 採用した内容 | 採らなかった内容 |
|---|---|---|---|---|
| Codex system `skill-creator` | Codex CLI `0.147.0`、2026-08-14 | 配布物内に個別表示なし。本文は非転載 | conciseな本文、descriptionでのrouting、必要なresourceだけを追加すること | Skill作成を既定にする入口、mechanism gateの欠如、local版と同じnameによるrouting競合。`skills.config`で無効化した |
| [Anthropic skill-creator](https://github.com/anthropics/claude-plugins-official/tree/ae21a9367949f92df4e31231d7efe43eaa08207c/plugins/skill-creator) | `ae21a9367949f92df4e31231d7efe43eaa08207c` | Apache-2.0 | realistic test、baselineとの対照、iteration、description routing、leanな本文、ablationに相当する削減 | Claude専用subagent prompt、viewer、grader、description optimizer、directory workflow |
| [OpenAI Academy: Using skills](https://openai.com/academy/skills/) | 2026-04-10 | [Terms of Use](https://openai.com/policies/terms-of-use/)。本文は非転載 | 反復task、inputとoutputとguardrail、組合せ可能な小さいbuilding block、toolを含むworkflow | ChatGPTのinstall、workspace、共有手順 |
| [dotnet skills](https://github.com/dotnet/skills/tree/7953ba85365219dc7df5d73634e1f9d0bfabf0b9) | `7953ba85365219dc7df5d73634e1f9d0bfabf0b9` | MIT | natural stimulus、baseline対Skill、dormancy guard、outcome中心のrubric、eval自体のfault分離、retire判断 | Vally schema、.NET固有fixture、sign testの固定閾値、repository専用CI |
| [Ponytail](https://github.com/DietrichGebert/ponytail/tree/2ed6c52c9d7e5e56942508591085fd45dea277d3) | `2ed6c52c9d7e5e56942508591085fd45dea277d3` | MIT | 新規所有物の前に不要、既存mechanism、標準機能、導入済みdependencyを比較するlens、安全性を削減対象にしないこと | 全coding taskへの常時注入、mode、line数とtoken削減をSkill admissionの目的にすること |

donorの作者名や分類をruntime構造にしない。sourceの主張は、別の具体例と反例で有効性を確認してから採用する。
