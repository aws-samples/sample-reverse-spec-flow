# 列挙の独立ソース表（java-struts-ormxml / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く（P6）。
下記のコマンドと件数はすべて Apache Roller 6.x（app モジュール）で実測検証済み（2026-08-10）。
-->

- **対象スタック**: Java / Struts 2（XML 宣言型アクション）/ JPA（`*.orm.xml` マッピングファイル方式）/ Velocity テンプレート
- **適用判定**: `grep -rlE '<struts[ >]' <src> --include='struts*.xml' | head` が 1 件以上ヒットし（ルートが `<struts>` = Struts 2）、
  かつ `grep -rl '@Path' <src> --include='*.java' | head` が **0 件**（アノテーション方式でない）。
  ルートが `<struts-config>` の Struts 1 は `java-struts1-ejb2` を使う（名前は同じ `struts*.xml` に一致する）

> **このスタックが `java-jaxrs-jpa` と決定的に違う点**: エントリポイントもエンティティも
> **Java コード内のアノテーションではなく XML 側で宣言される**。よって
> `@Path` / `@Table` を独立ソースにする手順は**計算不能**である（実測: Roller の `@Path` = 0 件、`@Table` = 0 件）。

## 独立ソース表（ノード種別ごとの分母）

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | ビルド定義のモジュール宣言 ＋ パッケージ階層 | `find <src> -name 'pom.xml' -not -path '*/target/*'` / `find <src>/src/main/java -type d -mindepth 4 \| sort` | — |
| NODE-EP（Web UI） | `struts*.xml` の `<action>` 宣言 | `find <src> -name 'struts*.xml' -not -path '*/target/*' -exec grep -c '<action ' {} +` | 全 `<action>` 件数 = EP ノード数 |
| NODE-EP（サーブレット/フィルタ） | `web.xml` の `<servlet-mapping>` / `<filter-mapping>` | `grep -c '<servlet-mapping>' <src>/src/main/webapp/WEB-INF/web.xml` / 同 `<filter-mapping>` | 各件数 = 対応 EP ノード数 |
| NODE-EP（スケジュール） | タスク登録クラス（`RollerTask` 実装等） | `grep -rlE '^public class .* extends .*Task' <src> --include='*.java'` | — |
| NODE-BND（DB: エンティティ） | `*.orm.xml` の `<entity ... class="...">` | `grep -rhoE 'class="[a-z0-9.]*\.pojos\.[A-Za-z]+"' --include='*.orm.xml' <src> \| sort -u \| wc -l` | ユニーク class 数 = BND エンティティノード数 |
| NODE-BND（DB: テーブル DDL） | DDL / スキーマ生成テンプレート | `grep -icE '^[[:space:]]*create table' <src>/**/createdb.vm`（配置は要確認） | DDL テーブル数 = エンティティ数 ＋ 管理外テーブル数 |
| NODE-BND（検索・外部） | 全文検索インデクサ・外部 Ping 送信等の実装 | `grep -rl 'IndexWriter\|IndexSearcher' <src> --include='*.java'` | — |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は Apache Roller 6.x（app モジュール）の実測に基づく。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① HTTP 要求を受ける型: Struts アクション宣言（`struts*.xml` の `<action>`）／ サーブレット・フィルタ宣言（`web.xml`）② プロセス起動の型: タスク実装（基底クラスの継承）③ テンプレート起点: Velocity マクロから直接呼ばれるアクション | **3 系統。単一ではない。** ①は XML 側の宣言が正本で **Java コード側に目印が無い**（アノテーション方式の手順は計算不能）。②は**基底クラスの継承だけで走査すると、インタフェース実装のみのタスクを落とす**——役割型（実行契約）で括り、継承と実装の両方を走査する。重複は**アクション名で `comm`** を取る |
| NODE-BND | ① 永続エンティティの型: `*.orm.xml` の `class=` 属性 ② `persistence.xml` の `<mapping-file>` 宣言 ③ DDL / スキーマ生成テンプレートにのみ存在する表 | **3 系統。単一ではない**（実測: 実体 31 に対し宣言 30 で 1 件が JPA に読まれない）。**必ず両方向の差集合を取る**（宣言のみ / 実体のみ）。①∪③ の要素和と「DDL の全表数」を **2 経路で突合**する |

> **件数の一致を集合の一致と読まない。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測でこのスタックは「実体 31 / 宣言 30」と**件数が近いのに集合がずれている**典型である
> （実体があるのに宣言されず、JPA が読み込まないファイルが 1 件あった）。
> `comm` で要素単位に突き合わせないと、**片側だけを分母にすると宣言漏れも未使用ファイルも見えない**。
> 実行可能な形は `gate-snippets.sh orm-diff` にある。

## 分母の 2 経路突合（GP-2 ルール8-4 / ルール9。実数は Phase 1 で埋める）

<!--
【なぜ 2 経路か】単一経路で数えた合算値は**検算できない**。系統ごとの件数を足しただけでは、
系統の定義そのものが漏れていても気づけない。**独立に計算できる別経路**と突き合わせて初めて検算される。
【件数一致 ≠ 集合一致】ルール9。要素単位で突き合わせる（`comm -3` / `diff`）。
差分が 0 件なら「0 件」と書く——空欄は「測っていない」と区別できない。
【定義は Playbook が提供・実数は解析対象ごと】下表の定義列はこのスタックの実測に基づく。
`gates.sh` の `G-ENUM-SOURCE` が定義・実数・差分の記入を検査する（`phase1` の完了条件）。
【列順の理由】**数値と差分を末尾に固めてある**。定義欄に `|` が入ると前から数えた列がずれるため、
検査は末尾から数えている。
【表の中にパイプを書かない】`\|` とエスケープしても表の解析では分割される（実測）。
とくに**差分欄にコマンドをそのまま貼らない**——**差分欄には結果（要素名の列挙）だけ**を書く。
-->

| ノード種別 | 経路A の定義 | 経路B の定義 | 経路A 実数 | 経路B 実数 | 要素差分（`comm -3` の出力。無ければ「0 件」） |
|-----------|------------|------------|----------|----------|--------------------------------|
| NODE-EP | 系統 ①②③ の件数の和（アクション名で重複排除してから合算） | **系統に分けず**宣言側（XML）と実装側（Java）の両方を 1 パスで走査した和集合 − 到達不能 | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 要素名を全件（理由）>` |
| NODE-BND | 系統 ①∪③ の要素和（表名で重複排除） | DDL / スキーマ生成テンプレートの全表数 | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: …（理由）>` |

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**物理表名が Java コードに無く ORM XML と DDL 側にある**ため、
「エンティティクラス名は書いたが表名は書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `table` | **物理テーブル名**（`*.orm.xml` の `<table>` / **`<join-table>`** / **`<secondary-table>`**） | `grep -rhoE '<(table\|join-table\|secondary-table) +name="[^"]+"' <src> --include='*.orm.xml' \| sed 's/.*name="\([^"]*\)".*/\1/' \| sort -u` |
| `table` （DDL 側） | スキーマ生成テンプレートにのみ存在する表名 | `grep -rhoiE 'create table +[a-z0-9_]+' <src> --include='*.vm' \| awk '{print tolower($3)}' \| sort -u` |
| `entity` | 永続エンティティのクラス名（`*.orm.xml` の `class=`） | `grep -rhoE 'class="[a-z0-9.]*\.[A-Za-z]+"' <src> --include='*.orm.xml' \| sed 's/.*\.\([A-Za-z]*\)"/\1/' \| sort -u` |
| `endpoint` | **アクション名**（`struts*.xml` の `<action name=...>`） | `grep -rhoE '<action +name="[^"]+"' <src> --include='struts*.xml' \| sed 's/.*name="\([^"]*\)".*/\1/' \| sort -u` |

> **`table` は 2 コマンドの出力を結合して 1 ファイルにする**（ORM 宣言と DDL の両系統。「目印の系統」節を参照）。
> `gate-snippets.sh idents-table` / `idents-endpoint` で実行できる。

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

1. **`<entity` は `<entity-mappings` にも一致する。**
   `grep -c '<entity'` は Roller で **186** を返すが、これはルート要素 `<entity-mappings>` を含む過大計上。
   `<entity` の直後に空白を要求する（`'<entity[[:space:]]'` → 93）か、
   **`class=` 属性でユニーク化する（→ 31）**。属性は複数行に分かれるため、
   `<entity ...>` を 1 行として扱う grep は成立しない（SB-2（宣言位置まで固定する） の「宣言位置まで固定する」の実例）。

2. **`*.orm.xml` の実体数と `persistence.xml` の宣言数は一致しない。**
   実測（Roller）: ファイル実体 **31**、`<mapping-file>` 宣言 **30**。
   差分 1 件は `org/apache/roller/planet/pojos/RuntimeConfigProperty.orm.xml` で、
   **実体があるのに宣言されていない**（＝ JPA が読み込まない）。
   **ただしこれは「宣言漏れ」ではなく「死蔵ファイル」だった**（2026-09-23 に再実測して是正）
   ——マップ先クラスが宣言されたパッケージに存在しない（下の ⚠️ を参照）。
   **必ず両方向の差集合を取る**（宣言のみ / 実体のみ）。片側だけを分母にすると
   「宣言漏れ」も「未使用ファイル」も見えない。
   **⚠️ 突合は basename でなくクラスパスルート相対のフルパスで行う（2026-09-23 追記）。**
   同名ファイルが複数のモジュールに存在する構成では、**basename 比較は件数が合ったまま
   同一性を壊す**——実測では差分 1 件を「片方のモジュールのファイル」と誤読しうる状態で、
   **実際は別モジュールのファイルであり、しかもマップ先クラスが存在しない死蔵ファイル**だった。
   **差分には必ずフルパスを添える**（件数だけを報告しない）。
   **⚠️ 差分が出たら「マップ先クラスが実在するか」まで確認する（同上）。**
   宣言も実体もあるのに**マップ先のクラスが無い**ことがあり、その場合は
   「宣言漏れ」ではなく**死蔵ファイル**である（対処が逆になる）。
   ```bash
   # ★この手順の正本は `gate-snippets.sh orm-diff`。手で実行するときも同じルート一覧を使う
   #   （値を 2 箇所に持つと必ず乖離する。実測で `target/classes` の有無が食い違った）。
   bash 03-audit/gate-snippets.sh orm-diff <src>
   # --- 手で追うときの最小形 ---
   P=$(find <src> -name persistence.xml -not -path '*/target/*' | head -1)
   # クラスパスルートからの相対パスで比較する（basename に落とすと同一性が壊れる）
   grep -oE '<mapping-file>[^<]+' "$P" | sed 's#<mapping-file>##' \
     | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sort > /tmp/declared.txt
   find <src> -name '*.orm.xml' -not -path '*/target/*' \
     | sed -E 's#^.*/(src/main/resources|src/main/java|src/test/resources)/##' | sort > /tmp/actual.txt
   # ★削り残し（= ルート一覧がこのレイアウトに未対応）を先に検出する。
   #   放置すると全件が差分として出るだけでなく、死蔵判定が無マッチで黙って 0 件になる
   grep -c '^/' /tmp/actual.txt   # 0 でなければ突合不能。ルート一覧を足してから続ける
   comm -23 /tmp/declared.txt /tmp/actual.txt   # 宣言のみ（ファイル欠落）
   comm -13 /tmp/declared.txt /tmp/actual.txt   # 実体のみ（宣言漏れ or 死蔵）
   # 実体のみに出たファイルは、マップ先クラスの実在を確認する（死蔵かどうかの切り分け）
   comm -13 /tmp/declared.txt /tmp/actual.txt | while IFS= read -r f; do
     src_f=$(find <src> -path "*/$f" -not -path '*/target/*' | head -1)
     [ -n "$src_f" ] || { printf '%s -> ★実ファイルを再発見できない\n' "$f"; continue; }
     # ★クラスは全件見る（1 ファイルに複数 entity があると head -1 では 2 件目以降を見落とす）
     grep -oE 'class="[^"]+"' "$src_f" | sed 's/class="//; s/"//' | sort -u | while IFS= read -r cls; do
       # ★クラス名だけで探さない。パッケージを含むパスで探す（同名の別パッケージを拾う）
       rel="$(printf '%s' "$cls" | tr '.' '/').java"
       if [ -z "$(find <src> -path "*/$rel" -not -path '*/target/*' | head -1)" ]; then
         printf '%s -> %s ★マップ先クラス不在＝死蔵の疑い（宣言を足すのではなくファイルを消す判断）\n' "$f" "$cls"
       else
         printf '%s -> %s 宣言漏れ（クラスは実在。persistence.xml に宣言を足す判断）\n' "$f" "$cls"
       fi
     done
   done
   ```

3. **Struts 2 のアクションは継承・パッケージ継承で増える。**
   `struts.xml` の `<package extends="...">` により、宣言されていない URL が有効になることがある。
   `<action>` 件数だけでなく `<package>` の継承関係も確認する。

4. **`target/` 配下に生成物のコピーが存在する。** 必ず `-not -path '*/target/*'` で除外する
   （除外しないと件数が倍になる）。

5. **UI は Velocity テンプレート側にも分岐がある。** アクションクラスだけを読むと画面の条件表示を落とす
   （`*.vm` を画面仕様の抽出源に含める）。
6. **ORM 側のテーブル集合は `<table>` だけではない。**
   `<join-table>`（多対多の結合表）と `<secondary-table>`（1 エンティティを複数表に分割）も
   **JPA 管理下の物理表**である。`<table name=...>` だけで数えると、
   **結合表を「ORM 管理外の孤児表」と誤って書く**（実測: Roller の `rag_group_subscription`）。
   実測値: `<table>` のみ **30** 件 → 3 種の和集合 **31** 件。
   ※ DDL 側（`create table`）と和集合を取る抽出では結果的に拾えてしまうため、
     **ORM 管理下かどうかを判定する場面でだけ差が出る**（件数の一致を根拠にしない。SB-2）。
   **走査コマンド（2026-09-23 追記。規約はあったが実行できる形が無かった）:**
   ```bash
   # ★`xargs -0` には必ず `-r`（対象 0 件のとき grep が標準入力を読んで止まる。実測済み）
   find <src> -name '*.orm.xml' -not -path '*/target/*' -print0 \
     | xargs -0 -r grep -hoE '<(table|join-table|secondary-table)[^>]* +name="[^"]+"' \
     | grep -oE 'name="[^"]+"' | sed 's/name="//;s/"//' | sort -u
   ```


### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# `target/` に生成物のコピーが存在する（上記「走査の落とし穴」4 と同じ理由）
SOURCE_EXCLUDE='(^|/)target/'
```

**入れないとどうなるか**: 同名のビルド生成物が分母に入り、`web.xml` のような basename 引用が
「候補複数」で解決できなくなる。実測（Apache Roller）: 除外なしで引用の **23%（1,748/7,624）が解決不能**、
`target/` を除外して **0.9%（67 件）**。索引は 10% を超えると原因と対処を本文に書く。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 69 ディレクトリを 16 単位にまとめる）、
**独立ソース側には 69 を書き、ノード登録数に 16 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**
（実測: 実運用で 69→16 の集約が「16 = 16」と記録され、`G-DENOM` は PASS し続けた）。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-EP（action） | `<N>` | `<M>` | `<差分がある場合は全件の理由>` | `<YYYY-MM-DD>` |
| NODE-EP（servlet/filter） | `<N>` | `<M>` | `<同上>` | `<YYYY-MM-DD>` |
| NODE-BND（entity） | `<N>` | `<M>` | `<同上>` | `<YYYY-MM-DD>` |
| NODE-BND（DDL table） | `<N>` | `<M>` | `<同上。エンティティ管理外テーブルを明示する>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
