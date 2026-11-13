# 列挙の独立ソース表（oracle-plsql / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて OSS 3 件で実測検証済み（2026-10-25）:
  Oracle Database Sample Schemas（HR / CO / OE / SH / PM。SQL*Plus のスクリプト・REM の注釈・置換変数・同じ名前の表が別のスキーマに複数）
  utPLSQL v3（パッケージ 27 対・オブジェクト型 117。導入スクリプトは EXECUTE IMMEDIATE で表を作り、テストは文字列の中でパッケージを作る）
  Alexandria PL/SQL Utility Library（.pks / .pkb の対 56。例のスクリプトは文を ; も / も無しで並べる）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: Oracle の PL/SQL（パッケージ・単独のプロシージャ / 関数・トリガー・オブジェクト型）と、PL/SQL が読み書きする表・ビュー。
  ソースは SQL*Plus / SQLcl のスクリプトか、ユニットごとのファイル。
- **適用判定**: `grep -rliE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?((non)?editionable[[:space:]]+)?(package|procedure|function|trigger)' <src> --include='*.sql' --include='*.pk?' --include='*.pls' --include='*.prc' --include='*.fnc' --include='*.trg' | head` が 1 件以上（README と同じ）。

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **走査する拡張子を決める（`PLSQL_GLOBS`）。** 既定は `*.sql *.pks *.pkb *.pkg *.pck *.pls *.plb *.spc *.bdy *.prc *.fnc *.trg *.tps *.tpb *.typ *.vw *.tab *.ddl *.seq *.syn`。
   別の拡張子（`.plsql`・`.bdy2` 等）を使う対象は `00-ingestion/gate-config.env` に `PLSQL_GLOBS='*.sql *.plsql'` の形で書く。
2. **スキーマとアプリの境界を先に決める（Phase 0）。** `scope` でディレクトリを見て、テスト・例・別スキーマの導入スクリプトを `SCAN_EXCLUDE` で分ける（落とし穴 9・10）。
3. **バイト列で走査する（`LC_ALL=C`）。** `gate-snippets.sh` は先頭で `LC_ALL=C` を固定し、BOM を外し、UTF-16 は NUL を落として読む。
4. **名前は大小を区別しないキー（小文字）で突き合わせ、表示は出典の綴り。** 二重引用符の識別子（`"MixedCase"`）も引用符を外して同じキーにする（落とし穴 12）。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | パッケージの仕様（`CREATE PACKAGE`）＋ メソッド（MEMBER / STATIC / CONSTRUCTOR / MAP / ORDER）を持つオブジェクト型の仕様 | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（本体と両方向） | パッケージ数 ＋ メソッドを持つ型の数 = MOD ノード数 |
| NODE-EP（API・入口） | パッケージ仕様の公開サブプログラム（オーバーロードは別々）・単独の `CREATE PROCEDURE` / `FUNCTION`・`CREATE TRIGGER`・`DBMS_SCHEDULER.CREATE_JOB` / `DBMS_JOB.SUBMIT` | `ep` / 一覧 `list-ep` / 突合 `ep-diff`（仕様の宣言と本体の実装を両方向） | 入口数 = EP ノード数。テストのパッケージを外すなら ADR で処分 |
| NODE-BND（DB 表） | 参照側: PL/SQL の静的 SQL・VIEW の問い合わせ・トリガーの ON の表（同義語は先に解く）／ 定義側: `CREATE TABLE` / `VIEW` / `MATERIALIZED VIEW`（文字列の中の DDL を含む） | `bnd` / 一覧 `list-bnd` / 定義側 `bnd-schema` / 突合 `bnd-diff` / CRUD `list-crud` | 参照表数 = BND 表ノード数。定義側との差は全件説明する（データディクショナリ・導入スクリプトの DML だけの表は別の節） |
| （エッジ）呼び出し | ユニットからパッケージのサブプログラムへの修飾つきの呼び出し（`pkg.proc(`） | `list-calls` | コードグラフのエッジの分母（同じパッケージの中の呼び出しは修飾しないので出ない） |
| （入口の子）動的 SQL | `EXECUTE IMMEDIATE`・`DBMS_SQL.PARSE`・`OPEN ... FOR` 文字列 | `list-dynamic` | 「(式)」の行は組み立てる側を読んで表と操作を補う |
| （入口の子）公開の範囲 | `GRANT EXECUTE` / `SELECT` 等 | `list-grants` | 他のスキーマ・ロールに公開する API の分母 |
| （モジュールの子）読めないユニット | `wrapped` のユニット | `list-wrapped` | 本体の振る舞いを UNKNOWN に起票する数 |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は Sample Schemas / utPLSQL / Alexandria の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① 呼ばれる API: パッケージ仕様の公開サブプログラム ② 単独のユニット: `CREATE PROCEDURE` / `FUNCTION` ③ 事象で起動する入口: トリガー（DML・INSTEAD OF・DDL / DATABASE の事象）④ 時刻で起動する入口: スケジューラのジョブ | **4 系統。単一ではない。** ①だけを見るとトリガーとジョブを落とす（実測 Sample Schemas: 入口 39 のうちトリガー 7・単独のユニット 3）。①は**オーバーロードを別々に数える**——名前で数えると減る。重複は種類・キーで取る |
| NODE-BND | ① 静的 SQL の参照: PL/SQL のユニットの SELECT / INSERT / UPDATE / DELETE / MERGE ② ビューの問い合わせ ③ トリガーの ON の表 ④ 定義: `CREATE TABLE` / `VIEW` / `MATERIALIZED VIEW` ⑤ 文字列の中の DDL: 導入スクリプトの EXECUTE IMMEDIATE | **5 系統。単一ではない。** ④だけを見ると導入スクリプトが文字列で作る表を落とし（実測 utPLSQL: 21 のうち 10）、①だけを見るとアプリだけが使う表が消える（実測 Sample Schemas: 定義 48 のうち PL/SQL・ビュー・トリガーから参照されるのは 25）。①〜③と④⑤は表名で `comm` を取り、両方向の差を全件説明する |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（utPLSQL の `source/`）では、パッケージが「仕様 27 / 本体 27」、公開サブプログラムが「仕様 265 / 本体に実装あり 265」で一致した
> （本体の実装は 371 で、差の 106 は非公開・入れ子のサブプログラム）。**一致したのは、文字列の中の `CREATE PACKAGE`（テスト 187 か所）を数えず、
> 型仕様の MEMBER / CONSTRUCTOR を読んだ後**で、テストを含めた全体を素朴な grep で数えるとパッケージ仕様が 272 になる（正しくは 102）。

## 分母の 2 経路突合（GP-2 ルール8-4 / ルール9。実数は Phase 1 で埋める）

<!--
【なぜ 2 経路か】単一経路で数えた合算値は**検算できない**。系統ごとの件数を足しただけでは、
系統の定義そのものが漏れていても気づけない。**独立に計算できる別経路**と突き合わせて初めて検算される。
【件数一致 ≠ 集合一致】ルール9。要素単位で突き合わせる（`comm -3` / `diff`）。`*-diff` サブコマンドが要素を出す。
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
| NODE-MOD | **仕様**: パッケージ仕様 ＋ メソッドを持つ型仕様（`mod-diff` 経路A） | **本体**: パッケージ本体 ＋ 型本体（`mod-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 名前を全件（宣言だけの仕様・抽象型・本体の無い仕様・仕様の無い本体の別）>` |
| NODE-EP | **仕様の宣言**: 公開サブプログラム（パッケージ.名前#オーバーロードの番号。`ep-diff` 経路A） | **本体の実装**: IS / AS を持つサブプログラムの定義（同じ形。`ep-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 経路A のみを全件（本体が無い・ラップ・外部ルーチン）。経路B のみは非公開の数だけ書いてよい>` |
| NODE-BND | **DB 表・参照側**: PL/SQL の静的 SQL・ビュー・トリガーの表（`bnd-diff` 経路A） | **定義側**: `CREATE TABLE` / `VIEW` / `MATERIALIZED VIEW`（文字列の中の DDL を含む。`bnd-schema`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（別スキーマ・同義語の先・アプリだけが使う・死蔵の別）>` |

- **NODE-EP の経路B は経路A より多いのが普通**（非公開・入れ子のサブプログラム）。**経路A のみ**（仕様にあるのに本体に実装が無い）は 1 件ずつ原因を書く。
  経路B のみは非公開の API なので、件数とパッケージごとの内訳を書けばよい（要素を全件並べなくてよいが、`ep-diff` の出力を `01-code-graph/` に保存する）。
- **NODE-BND の経路B のみ**（定義されるのに PL/SQL から参照されない）は、アプリ側が直接使う表のことが多い。アプリ側の Playbook の表の一覧と突き合わせて説明する。
- **定義側（DDL）がソースに無い場合**（DB にだけある）は、`NODE-BND` の経路B の定義欄を「単一経路（DDL がソースに無い）」に書き換え、差分欄に理由を書く
  （`G-ENUM-SOURCE` が理由の記入を検査する）。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**業務の処理がパッケージのサブプログラムにあり、表の操作がその中の SQL にある**ため、
「パッケージは書いたが、どのサブプログラムがどの表を更新するかは書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `package` | **パッケージ名**（仕様の綴り） | `bash 03-audit/gate-snippets.sh idents-package <src>` |
| `subprogram` | **パッケージ.サブプログラム**（公開 API。仕様の綴り） | `bash 03-audit/gate-snippets.sh idents-subprogram <src>` |
| `table` | **物理テーブル名**（参照側 ∪ 定義側。表ごとに最初に見た綴り） | `bash 03-audit/gate-snippets.sh idents-table <src>` |
| `trigger` | **トリガー名** | `bash 03-audit/gate-snippets.sh idents-trigger <src>` |

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。

1. **注釈・文字列・SQL*Plus のコマンド。** `REM` / `PROMPT` / `SET` / `@` / `DEFINE` の行、`--` と `/* */` の注釈、`'...'`（`''` で引用符）と
   `q'[...]'` の引用演算子（`[]` `{}` `()` `<>` か任意の 1 文字で囲む）を区別して読む。素朴な grep は注釈の「Create the PRODUCTS table」を数える
   （実測 Sample Schemas）。**`GRANT CREATE TABLE, CREATE VIEW, CREATE TRIGGER` の権限の一覧も `CREATE TABLE` に見える**（素朴な数え: 表 41・トリガー 10 /
   正しくは 38・7）。
2. **文の終わり。** PL/SQL のユニット（`CREATE PACKAGE` / `PROCEDURE` / `FUNCTION` / `TRIGGER` / `TYPE`・`DECLARE` / `BEGIN` の無名ブロック）は「/」だけの行で終わり、
   それ以外の SQL は文の外の「;」で終わる。ユニットの中の「;」で切ると、パッケージが文ごとにばらばらになる。
3. **終端の無い文。** 例のスクリプトは文を「;」も「/」も無しで並べる。SQL*Plus の既定（`SQLBLANKLINES OFF`）では**空行が SQL の文を終える**。
   無名ブロックの `END;` の後に「/」が無いまま行の 1 桁目から次の文が始まるときも区切る（実測 Alexandria の demos: 表 1・ビュー 1 が前の文に吸い込まれて数えられなかった）。
4. **ユニットの見出し。** `CREATE OR REPLACE NONEDITIONABLE PACKAGE BODY ut_runner IS`（実測 utPLSQL）・`AUTHID CURRENT_USER`・スキーマつきの名前・
   二重引用符の名前・置換変数（`&&owner..name`）を読む。仕様（`package`）と本体（`package body`）、型（`type`）と型本体（`type body`）を分ける。
5. **文字列の中の DDL。** 導入スクリプトは、何度流しても通るように無名ブロックの `EXECUTE IMMEDIATE q'[create table ...]'` で表を作る（実測 utPLSQL: 定義 21 のうち 10）。
   `gate-snippets.sh` は文字列の中の `CREATE TABLE` / `VIEW` / `SEQUENCE` を定義に数え、`list-objects` の付記に `dynamic:anonymous` / `dynamic:<ユニットの種類>` を付ける。
   **文字列の中の `CREATE PACKAGE` は数えない**——テストが実行時に作る部品である（実測 utPLSQL の `test/`: 文字列の中の `CREATE ... PACKAGE` が 187 か所。テストを含めた全体で、素朴な grep ではパッケージ仕様が 272 / 正しくは 102）。
6. **FROM の取り違え。** `EXTRACT(DAY FROM a_interval)`・`TRIM(LEADING x FROM a_item)` の FROM の後は列、`FROM TABLE(f(...))`・`JSON_TABLE(...)` は関数、
   `WITH t1 (a, b) AS (...)` の名前（列の並びを持つ再帰の WITH を含む）は表ではない。`PROCEDURE delete (p_conn ...)` は DELETE 文ではない
   （実測: utPLSQL の `a_end_time` / `a_interval` / `a_item` / `t1`、Alexandria の `p_conn` が表に化けた）。
7. **INTO とコレクションの操作。** `SELECT ... INTO 変数` の INTO は表ではない。`l_tab.DELETE`・`FOR UPDATE` は DML ではない。
8. **データディクショナリ・システムの表。** `ALL_` / `USER_` / `DBA_` / `V$` / `NLS_` / `ROLE_` / `XDB$` / `APEX_` の表・ビュー、`DUAL`・`DICTIONARY` 等は定義の無い参照になる。
   `bnd-diff` の最後の節に system として出し、経路A に入れない（実測 Alexandria: `nls_database_parameters`・APEX のビュー 5 つ）。
9. **同じ名前の表が別のスキーマに複数ある。** 実測 Sample Schemas: `customers` は CO / OE / SH の 3 スキーマに別々にあり、`products` / `order_items` も定義が 3 つ。**同じスキーマの別の版のスクリプト**（OE の `coe_v3.sql` と `oe_cre.sql`）も同じ表を 2 度作る。
   キーは名前だけなので 1 つに束ねる（`bnd-diff` の最後の節に定義の位置を全部出す）。スキーマを分けて数えるなら、スキーマごとに `SCAN_EXCLUDE` で分けて走査する。
10. **テスト・例のパッケージ。** utPLSQL の `test/` を含めると入口が 266 → 2,387 になる（テストのパッケージの手続き）。`examples/` の `tst_pkg_huge` は仕様だけで本体が無い
    （`ep-diff` の経路A のみ 654）。分母から外すものは `SCAN_EXCLUDE` に書き、ADR で処分する。
11. **本体が要らない仕様と抽象型。** 定数・型・例外だけのパッケージ仕様（実測 Sample Schemas の `coe_namespaces`）と、NOT INSTANTIABLE のメソッドだけの型
    （実測 utPLSQL の `ut_event_listener`）は本体を持たない。`mod-diff` が「宣言だけ」「抽象型なら正しい」と分けて出す。
12. **オーバーロードと種類。** 公開サブプログラムは名前でなく宣言の数で数える（`ut.run` 等）。`ep-diff` の突き合わせのキーは `パッケージ.名前(procedure|function)#番号` で、
    **種類を入れないと、仕様の function を本体の非公開の procedure と組にして欠落を隠す**（反証レビューで実証。実測 Alexandria の `amazon_aws_s3_pkg.get_object_list` は
    仕様の function 1 つと本体の function 1 つ・非公開の procedure 1 つで、種類を入れた後は経路B のみに procedure の 1 つが出る）。番号は種類ごとの宣言の順。
13. **ACCESSIBLE BY の並び。** `ACCESSIBLE BY (PACKAGE x, PROCEDURE y, FUNCTION z)` は呼んでよい相手の一覧で、宣言ではない（12c 以降）。括弧が閉じるまで飛ばす。
14. **MERGE の USING・INSERT ALL / FIRST の INTO・LOCK TABLE。** `MERGE INTO t USING s` の `s`、`INSERT ALL INTO t1 ... INTO t2 ... SELECT ... FROM src` の `t1` / `t2` は、
    キーワードの直後の名前を取るだけでは落ちる。MERGE の文の中の USING（`(` で始まらないもの）と、INSERT ALL / FIRST の中の INTO を別に読む。
    トリガーの見出しの `DELETE OR UPDATE ON t` の「OR」を表にしない。
15. **SQL*Plus の継続行と SQLBLANKLINES。** `SET LINESIZE 200 -` / `EXECUTE dbms_stats.gather_table_stats( -` のように行末の「-」で続く SQL*Plus のコマンドは、続きの行も飛ばす
    （実在: Sample Schemas の `oe_analz.sql` / `pm_analz.sql`）。`SET SQLBLANKLINES ON` の後は空行で文を切らない（落とし穴 3 の例外）。**SQL*Plus 以外の実行器**
    （Flyway・Liquibase・SQL Developer）向けのスクリプトは空行の扱いが違うので、空行で切ると文の中の参照を落としうる。
16. **DDL の揺れ。** `CREATE EDITIONING VIEW` はエディションを使う構成の表の窓口で、ビューとして数える。`CREATE MATERIALIZED VIEW LOG ON t` はビューではない。
17. **業務の表の名前が SYS_ / ROLE_ で始まる。** `sys_param`・`role_master` のような業務の表は、同じ名前の定義がソースにあればデータディクショナリと見なさない。
18. **ジョブの名前が式。** `DBMS_SCHEDULER.CREATE_JOB(job_name => l_name, ...)` のように名前を変数で渡すと静的に決まらない（実測 utPLSQL のテスト 2 件）。`list-jobs` に「(名前が式)」と出る。


落とし穴 13〜17 は反証レビュー（2026-10-25）が合成の入力で示した形で、15 の継続行以外は実測した 3 件に無かった。`gate-snippets.sh` は対応済みで、selftest のフィクスチャが確かめる。
**直していない形**: 空白を含む二重引用符の名前（`"My Table"` は最初の語で切れる）・`JOIN ... USING (列), 表` のカンマの後の表・`ALTER TYPE ... ADD MEMBER` で足したメソッド。

### 作成時の検証記録（このファイルのコマンドを OSS で走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（仕様 / 本体） | 入口 `ep`（公開 API の仕様 / 本体の実装） | 表（参照 / 定義） | 動的 SQL / 呼び出し | 備考 |
|---|---|---|---|---|---|
| Sample Schemas（全スキーマ） | 9 / 7（A のみ 2＝宣言だけの `coe_namespaces`・抽象型の `category_typ`） | 39（公開 29 / 実装 30。単独のユニット 3・トリガー 7） | 25 / 48（同じ名前の定義が複数あるもの 11 種: 別スキーマの表 6・同じスキーマの別の版のスクリプトや作り直し 5） | 10 / 3 | 素朴な grep: 表 41・トリガー 10（権限の一覧を含む）。経路B のみの多くは例のアプリが使うビュー |
| utPLSQL `source/` | 113 / 112（A のみ 1＝抽象型の `ut_event_listener`） | 266（公開 265 / 実装 371。差は非公開・入れ子） | 17 / 21（文字列の中の DDL で作る表 10） | 76 / 340 | パッケージ 27 対・型 117 |
| utPLSQL 全体（`test/`・`examples/` を含む） | 190 / 186 | 2,387（公開 2,381 / 実装 1,924。A のみ 656 のうち 654 は仕様だけの `tst_pkg_huge`） | 25 / 33 | 765 / 441 | 文字列の中の `CREATE ... PACKAGE` 187 か所を数えない。ジョブ 2（名前が式） |
| Alexandria | 57 / 57 | 562（公開 562 / 実装 881） | 2 / 7（A は APEX・NLS のビューを除いた後） | 12 / 277 | demos は文を終端無しで並べる（空行で区切る） |

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# テスト・例を分母から外した場合は、その同じディレクトリを外す（この Playbook の SCAN_EXCLUDE にそろえる）
SOURCE_EXCLUDE='(^|/)(test|tests|examples)/'
```

**入れないとどうなるか**: 導入用と削除用のスクリプト（`install.sql` / `uninstall.sql`）・版ごとの写しに同名のファイルがあり、basename の引用が「候補複数」で解決できなくなる。
`SCAN_EXCLUDE` に入れたディレクトリも `SOURCE_EXCLUDE` にそろえる。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 265 の公開サブプログラムを 27 のパッケージにまとめる）、
**独立ソース側には 265 を書き、ノード登録数に 27 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。宣言だけの仕様・抽象型を明示>` | `<YYYY-MM-DD>` |
| NODE-EP（API・入口） | `<N>` | `<M>` | `<同上。トリガー・ジョブ・単独のユニット・テストの除外を明示>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。データディクショナリ・別スキーマ・アプリだけが使う表を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
