# SonarQube による静的解析証拠

**読み手:** SonarQubeの配備と権限を保守するowner、および保存解析をreviewへ渡すcaller。
設定またはscanの前に読む。

`code-quality` は SonarQube Community Build と PostgreSQL、公式 SonarQube MCP Server、承認された project に対する upstream scanner の入口を配備する。
source 解析と保存済み結果の取得を分け、既存の review や project の build・lint・test を SonarQube の稼働に依存させない。
現在の source への適用判断と caller-side の証拠 bundle は [code-quality Skill](../../skills/code-quality/skill/SKILL.md) が所有する。

## 採用する実装

server と DB は削除前と同一 digest を使い、可変 tag の追従による upgrade を行わない。
Docker Registry の index annotation はそれぞれ `26.7.0.124771-community` と `17.10-alpine3.24` を示す。
固定値の正本は [server/module.nix](../../capabilities/code-quality/sonarqube/server/module.nix) と [database/module.nix](../../capabilities/code-quality/sonarqube/database/module.nix) にある。
一次取得先は [Sonar manifest](https://registry-1.docker.io/v2/library/sonarqube/manifests/sha256:160bd2f6a3485bd09b655ef22dd63c02bd1fa7ba82aa5d9973fd010b8bcca0b3) と [PostgreSQL manifest](https://registry-1.docker.io/v2/library/postgres/manifests/sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193) であり、public registry の pull-scope token による metadata の取得が必要である。

MCP は第三者 npm package を戻さず、SonarSource の [standalone JAR](https://binaries.sonarsource.com/Distribution/sonarqube-mcp-server/sonarqube-mcp-server-1.19.0.2785.jar) を immutable fetch する。
採用版は `1.19.0.2785`、取得した bytes の SHA-256 は `a6cccd5f83c0ecba38d90919bfad75425de76ba80fbb7f742cfa82035af3d0f2` である。
設定の根拠は [同版の README](https://github.com/SonarSource/sonarqube-mcp-server/blob/39ae394eac8bf66ab7c6265fbc8efea14d8fbca1/README.md) と [公式環境変数](https://docs.sonarsource.com/sonarqube-mcp-server/reference/environment-variables) にある。
Java 21 以降で起動し、既存の stdio front が loopback の `8778` へ bridge する。
MCP の upstream license は [SONAR Source-Available License v1.0](https://www.sonarsource.com/license/ssal/) であり、この配備は内部 software development の利用を対象とする。
独自の Sonar query、tool schema、HTTP client は実装しない。

通常の CLI 解析は既存 nixpkgs input の `sonar-scanner-cli` を使い、全体の nixpkgs を更新しない。
復旧時 input の package は `7.3.0.5189` を [SonarSource source と Maven dependency hash](https://github.com/NixOS/nixpkgs/blob/456e8a9468b9d46bd8c9524425026c00745bc4d2/pkgs/by-name/so/sonar-scanner-cli/package.nix) で固定している。
receiptの`scanner_package_version`はnixpkgsのpackage版であり、native processが自己申告する版とは区別する。
scanner の upstream license は [LGPL version 3](https://github.com/SonarSource/sonar-scanner-cli/blob/588b1712d2ec0cef5c6b80b8404e03320e34d49b/LICENSE.txt) であり、nixpkgs metadata は LGPL-3.0-only としている。
運用条件は [公式 SonarScanner CLI](https://docs.sonarsource.com/sonarqube-server/analyzing-source-code/scanners/sonarscanner) を参照する。
Maven、Gradle、.NET project は各 upstream build-specific scanner と project-owned 設定を使い、この CLI wrapper で置き換えない。

## 採用の継続条件

upstreamの対応version、license、公式MCPの取得契約、credential注入、解析入力の対応条件が変わった場合は、Capability ownerが採用条件を再評価する。
常駐資源は宣言上限だけで可否を決めず、実際の解析負荷と同時利用下のRAM・CPUを測り、この環境の運用条件との適合を判断する。
目的に必要な証拠を取得できない状態、保守不能な配布やlicenseの条件、運用資源との不適合が続く場合は、ownerが代替と撤退を判断する。
SHAの相違、一時的な障害、Skillへの接続不足を撤退条件へ読み替えず、配備や呼出し側の不備を先に修正する。
撤退する場合は、ownerがDB、解析履歴、credential、Skillとcallerの導線の扱いを決め、明示的な判断なしにvolumeを削除しない。

## Runtime と credential

server は `127.0.0.1:9000`、DB は共通 backend network 内だけに配置する。
DB には host port を公開せず、`sonarqube-db` の network alias と `sonarqube` database/user を使う。
各 image の取得は共通 `dotfiles-sync-images` が所有し、service の起動時は pull しない。
server の Elasticsearch bootstrap checks は無効化しない。
[Linux の公式前提](https://docs.sonarsource.com/sonarqube-community-build/server-installation/pre-installation/linux) に従い、host の `vm.max_map_count >= 524288`、`fs.file-max >= 131072` と seccomp を満たす必要がある。
server の container ulimit は `nofile=131072`、`nproc=8192` であり、memory/CPU/PID の上限、read-only root、限定 volume/tmpfs、capability 制限は module にある。
MCP と provisioning は loopback 通信、限定された書き込み先と systemd sandbox を使う。
core dump と credential を含み得る heap dump は無効にするが、Elasticsearch の mandatory `ErrorFile` を追加 JVM option で上書きしない。
採用版の [EsJvmOptions](https://github.com/SonarSource/sonarqube/blob/94766f42c013a6b115ca9b17669da178e7d24cb9/server/sonar-main/src/main/java/org/sonar/application/command/EsJvmOptions.java) と [JvmOptions](https://github.com/SonarSource/sonarqube/blob/94766f42c013a6b115ca9b17669da178e7d24cb9/server/sonar-main/src/main/java/org/sonar/application/command/JvmOptions.java) が所有する必須設定と、許容される追加設定を区別する。
MCP の local analysis/IDE/Vortex toolset は有効にせず、保存済み証拠の取得を読み取り専用にする。

暗号化済み SOPS store には次の三つの string key が必要である。
値は永続平文 file、argv、log、Git、Nix store に残さず、owner が生成・暗号化する。

| SOPS key | 値と使用条件 | Runtime reader |
|---|---|---|
| `sonarqube/admin_password` | default と異なる単一行 password。末尾改行を含めない | root。provisioning service へ `LoadCredential` で渡す |
| `sonarqube/db_password` | 32 文字以上の `[A-Za-z0-9_-]` password。properties escape を不要にするための入力制約 | root の runtime template と、container の読み手 |
| `sonarqube/token` | 専用 evidence user が発行した User token | host user の MCP process |

evidence user は対象 project の Browse と必要な See Source Code のみを持ち、Administer/Execute Analysis を常設で与えない。
defaultの`sonar-users` groupは全userが継承するため、userへの直接付与だけで読み取り専用とは判断しない。
新instanceのownerは同groupのglobal Execute Analysis/Create Projectsと、default templateのissue/hotspot変更権限を外し、project側でも継承権限が残らないことを確認する。
既存instanceへ設定を移す場合は、他のuser/projectへの影響を確認せず共有権限を削除しない。
MCP は User token が必要であり、project/global analysis token を流用しない。
scanner は別の project analysis token を、source tree 外の private runtime file として caller が渡す。
project ごとの SOPS key の命名と権限は project owner が管理し、この Capability は全 project の global analysis token を作らない。
secret の差替えだけで server の admin/DB password は変更されないため、rotation は API/DB と store の整合を owner が取る。

DB の `.env` は接続 user/database と `POSTGRES_PASSWORD_FILE` path だけを渡し、password を Docker の Env/config に展開しない。
DB は upstream の `POSTGRES_PASSWORD_FILE` で root `0400` の runtime template を読む。
Sonar は upstream uid `1000` / gid `0` が読める root:root `0440` の `sonarqube.properties` template を、native `/opt/sonarqube/conf/sonar.properties` へ読み取り専用 mount する。
template は `/run` のみで生成し、宣言された container だけを読み手にする。
Sonar の upstream entrypoint と native properties loader をそのまま使い、独自 entrypoint や `_FILE` 対応を作らない。
native file のサポートと優先順位は [公式設定方法](https://docs.sonarsource.com/sonarqube-community-build/server-installation/system-properties/configuration-methods) と [採用 version の loader](https://github.com/SonarSource/sonarqube/blob/94766f42c013a6b115ca9b17669da178e7d24cb9/server/sonar-main/src/main/java/org/sonar/application/config/AppSettingsLoaderImpl.java) に基づく。
token は MCP/scanner の private process environment にだけ渡し、Docker Env には渡さない。
root、Docker group、credential reader は引き続き runtime secret の信頼境界に含まれる。

初回は token key がまだ存在しないため、最終 SOPS 宣言を不完全な状態で activation しない。
owner が同じ digest、file 注入契約、最終 volume を使う専用 bootstrap container/network/私有 port で DB と server を初期化し、`/api/system/status` の `UP` を確認する。
同じ `dotfiles-sonarqube-provision` に bootstrap URL と admin password file の path を環境変数で渡し、初回 password の変更を済ませる。
専用 evidence user と real User token を作成し、API response から token を直接 SOPS へ暗号化してから bootstrap を停止し、私有 network を回収する。
通常配備は完成した三 key と同じ volume を使う。
bootstrap と通常 container が同じ DB/data volume を同時に書き込むことを許可しない。

## 承認された project の解析

呼出し条件は、owner が作成した project key、送信を承認された source root、project-owned `sonar-project.properties`、必要な build/coverage、Execute Analysis を持つ別 token file である。
CLI wrapper は未知 project の作成、quality profile/gate の変更、権限付与を行わない。
source/test の対象 path は承認した source root 内に限り、credential を source、scanner 設定、coverage artifact に混ぜない。

```bash
dotfiles-sonarqube-scan --cwd <absolute-project-root> --project-key <approved-key> --token-file <private-runtime-file>
```

実 upstream scanner の診断は stderr、receipt path と scanner exit は stdout の JSON に返る。
wrapper は token を process environment にだけ渡し、debug/verbose を無効にし、診断に raw token が含まれた場合は伏せる。
scan receipt と `report-task.txt` は user の private state directory に置き、credential は書かない。
receipt の `scanner_return_code` は native process の return code、`scanner_exit_code` は wrapper を含む CLI の終了値である。
native process だけが signal で終了した場合は、その signal を `128 + signal` へ変換する。
wrapper の TERM/INT 中断では native process group を TERM、必要なら KILL で停止して回収した後、`wrapper_cancel_signal` と native return code を receipt に保存し、CLI は `128 + wrapper_cancel_signal` で終了する。
中断後の TERM/INT は回収と receipt の保存を再中断しない。
native終了後の入力観測やreceipt保存中の初回中断も、receiptとstdoutの公開前に終了値へ反映する。
最終receiptの保存とstdoutの返却を確定点とし、その区間では中断状態を固定して、CLIの実終了値とstdout、receiptの終了値を一致させる。
中断による終了値がnative由来の終了値と同じ場合も、`wrapper_cancel_signal`を保存する。
wrapper内の失敗処理と初回中断が競合した場合は、中断signalをCLIの終了値へ反映し、native return codeは別に保存する。
入力 file の観測に失敗した場合は fingerprint と観測間の同一性を不明とし、失敗種別を記録するが、開始済み scan の native exit と CE task を失わない。
CLI の `--wait` は upstream の Compute Engine/gate 待機を有効にし、失敗を同じ非zeroで伝える。
scan の upload と解析処理の完了は別であり、待機しない場合は同じ CE task が `SUCCESS` になるまで保存済み結果を今回の解析とは呼ばない。

## 新 instance の受入

この手順は配備 owner が実行する受入契約である。
共有 project や他 session の container を対象にせず、新しい所有 fixture を使う。

1. 完成した三 key で配備し、doctor の native `get_system_status` protocol probe と server `UP` を確認する。
2. 一意の fixture project key を作り、evidence user へその project の Browse/See Source Code、別 scanner principal へ Execute Analysis を付与する。
   その project の analysis token を source tree 外の private runtime file に直接渡す。
3. 新しいfixture rootを`<fixture-root>`とし、`<fixture-root>/src/example.py`と`<fixture-root>/sonar-project.properties`へ次の内容を置く。
   Python の S3776 が有効な fixture project の profile を選び、他 project の profile/gate を変更しない。

```python
def select(value):
    if value > 0:
        if value > 1:
            if value > 2:
                if value > 3:
                    if value > 4:
                        if value > 5:
                            if value > 6:
                                if value > 7:
                                    return value
    return 0
```

```properties
sonar.sources=src
sonar.sourceEncoding=UTF-8
sonar.python.version=3.13
```

4. 対象 root/key/token path を指定して `dotfiles-sonarqube-scan ... --wait` を実行する。
   gate が成功した場合は exit 0、失敗した場合は非zeroを期待し、どちらでも receipt の scanner exit を実 exit と照合する。
   初回のdefault gateが条件なしで`OK`を返した場合は品質拒否の証拠にせず、所有fixture専用のgateへ明示条件を追加して、CEの成功とgateの失敗、CLIの非zeroを別々に確認する。
5. receipt の CE task を SonarQube Background Tasks で開き、`SUCCESS`、analysis ID、日時、run ID、入力 revision を記録する。
   native MCP の `search_sonar_issues_in_projects` に fixture を明示して S3776 の対象 file を取得し、`get_project_quality_gate_status` の analysis ID 指定で同じ解析の gate を取得する。
   issues は最新の可変集合なので、他の scan がないことと取得時刻を記録する。
   同じ解析を指す根拠が得られなければ issues と gate は endpoint ごとの観測とし、snapshot の対応を不明にする。
6. fixture の別 commit/history rewrite または未commit編集後に scan せず同じ結果を取得し、古 SHA の結果が取得可能なまま、現在への適用は別判断になることを確認する。
   nested 条件が残る場合は現在の対象条件を確認した候補、関数を単純化した場合は現在には非適用とし、過去 gate を現在の合格にしない。
7. fixture token を revoke し、fixture project とその所有 source/receipt/runtime credential file を回収する。
   evidence user の fixture 権限だけを外し、通常 service、他 project、最終 named volume を回収対象にしない。

受入証拠には、scanner 実 exit、CE 完了、issues/gate、入力 fingerprint、config/profile/analyzer version、analysis/task ID、解析日時、取得時刻、現在への適用理由、回収対象を残す。
native API/receipt で得られなかった metadata は不明と記録し、未確認の coverage や current verified に変えない。
API/DB/secret の失敗を成功 fallback にせず、静的 review は不足証拠を記録して継続する。

## 過去の DB

runtime の復旧は過去の解析履歴の復元とは別である。
旧 volume/image の削除記録があり、現在は旧 named volume と確認可能な dump がないため、この復旧は新 instance として始める。
将来 real backup が見つかった場合も、同じ volume への上書きや今回の検証済みとの扱いはせず、owner が別途 DB version と復元範囲を確認する。
