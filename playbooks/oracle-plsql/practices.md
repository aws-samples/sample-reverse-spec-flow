# ドメイン知見（`DP-oracle-plsql-N`）

Oracle の PL/SQL（パッケージ・プロシージャ・関数・トリガー・オブジェクト型）で業務ロジックを DB の側に置く構成に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 3 件（Oracle Database Sample Schemas / utPLSQL v3 / Alexandria PL/SQL Utility Library）。

<!--
【ID 規約】`DP-oracle-plsql-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-oracle-plsql-1 | 入口はパッケージ仕様の公開サブプログラムで数え、トリガーとジョブを別の系統として足す | 本体のサブプログラムの多くは非公開。仕様が API の契約 |
| DP-oracle-plsql-2 | 文の切り方を SQL*Plus の規則で決めてから数える | 「/」・「;」・空行・注釈・q'[...]' を取り違えると、パッケージも表も数え違える |
| DP-oracle-plsql-3 | 表は「PL/SQL が触る表」と「定義された表」を分けて数え、差をアプリ側の表と突き合わせる | 定義のうち PL/SQL が触るのは一部。残りはアプリが直接使う |
| DP-oracle-plsql-4 | トランザクションの制御・例外・自律型トランザクションを、サブプログラムごとに仕様に書く | COMMIT の位置と例外の扱いが業務の不変条件を決める |
| DP-oracle-plsql-5 | 動的 SQL・ラップ・DB にだけある定義を、読めないものとして明示的に数える | 文字列の SQL と wrapped の本体は静的に読めない |

---

## DP-oracle-plsql-1: 入口はパッケージ仕様の公開サブプログラムで数え、トリガーとジョブを別の系統として足す

### 目的
PL/SQL のパッケージは、仕様（`CREATE PACKAGE`）が外から呼べる API を宣言し、本体（`CREATE PACKAGE BODY`）が実装と非公開のサブプログラムを持つ。
アプリ・他のスキーマ・ジョブから呼ばれるのは仕様に宣言されたものだけなので、**仕様が API の契約**である。

### ルール
1. **経路A（仕様の宣言）と経路B（本体の実装）を突き合わせる**（`ep-diff`）。オーバーロードは宣言の数で数える。
2. **経路A のみ**（仕様にあるのに実装が無い）は 1 件ずつ原因を書く: 本体が無い・ラップされた本体・`LANGUAGE JAVA` / `C` の外部ルーチン・作成に失敗する本体。
3. **経路B のみ**は非公開・入れ子のサブプログラム。modules の仕様で「内部の処理」として書き、API の一覧には入れない。
4. **トリガー**（DML / INSTEAD OF / DDL / DATABASE の事象）と**ジョブ**（DBMS_SCHEDULER / DBMS_JOB）は、呼び出しでなく事象・時刻で起動する入口として別に数える。
5. **GRANT EXECUTE の先**（`list-grants`）を API の公開の範囲として書く（どのロール・スキーマが呼べるか）。

### 実例
- utPLSQL の `source/`: 公開サブプログラム 265 = 本体の実装と一致。本体の定義は 371 で、差の 106 は非公開・入れ子。
- Sample Schemas: 入口 39 = 公開 29 ＋ 単独の PROCEDURE 2・FUNCTION 1 ＋ トリガー 7。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh ep-diff <src>
bash 03-audit/gate-snippets.sh list-grants <src>
```

### アンチパターン
- 本体のサブプログラムを全部 API として仕様に書く（非公開の処理を外部契約と誤読させる）。
- 名前でサブプログラムを数え、オーバーロードを 1 つに潰す。

---

## DP-oracle-plsql-2: 文の切り方を SQL*Plus の規則で決めてから数える

### 目的
PL/SQL のソースは SQL*Plus / SQLcl で流すスクリプトで、文の終わりが種類で違う。PL/SQL のユニットは「/」だけの行で終わり、SQL は「;」で終わり、
終端の無い SQL は空行で終わる。注釈・文字列（`''`・`q'[...]'`）・SQL*Plus のコマンド行（`REM` / `PROMPT` / `SET` / `@`）を取り違えると、
**パッケージが文ごとにばらばらになったり、注釈の「Create the PRODUCTS table」を表に数えたりする**。

### ルール
1. **`gate-snippets.sh` の字句解析の結果（`list-objects`）を分母の正本にする。** grep の結果を分母に使わない。
2. **素朴な grep と突き合わせて差を説明する**（権限の一覧の `CREATE TABLE`・注釈・文字列の中の DDL が差になる。enumeration.md 落とし穴 1・5）。
3. **拡張子を確かめる。** `.pks` / `.pkb` 以外の拡張子（`.plsql` 等）を使う対象は `PLSQL_GLOBS` に足す。

### 実例
- Sample Schemas: 素朴な grep で表 41・トリガー 10、字句解析で 38・7（差はすべて `GRANT CREATE TABLE, CREATE VIEW, CREATE TRIGGER` の権限の一覧）。
- Alexandria の demos: 文を「;」も「/」も無しで並べるので、空行で切らないと表 1・ビュー 1 が前の文に吸い込まれた。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-objects <src> | cut -f1 | sort | uniq -c
```

### アンチパターン
- `grep -c 'create table'` を表の数にする。
- 「;」で PL/SQL のユニットを切る（パッケージ本体の中の文ごとに別のオブジェクトに見える）。

---

## DP-oracle-plsql-3: 表は「PL/SQL が触る表」と「定義された表」を分けて数え、差をアプリ側の表と突き合わせる

### 目的
DB にロジックを置く構成でも、表のすべてを PL/SQL が触るわけではない。アプリが直接 SQL を出す表・レポートだけが読む表・死蔵の表が混ざる。
**経路A（PL/SQL・ビュー・トリガーが参照する表）と経路B（定義）の差**が、アプリ側の分母との境界になる。

### ルール
1. **`bnd-diff` の経路B のみを、アプリ側の Playbook の表の一覧と突き合わせる。** アプリが使う表・どちらも使わない表（死蔵の疑い。SB-13）に分ける。
2. **経路A のみ**（参照されるのに定義が無い）は、別のスキーマ・同義語の先・DB にだけある定義・誤検出に分ける。
3. **データディクショナリ・システムの表**は経路A に入れない（`bnd-diff` の最後の節）。権限や環境に依存する処理として nfr に書く。
4. **導入スクリプトの DML だけで使う表**（初期データ）は経路A に入れず、data の「初期データ」に書く。

### 実例
- Sample Schemas: 定義 48 のうち PL/SQL・ビュー・トリガーから参照されるのは 25。残りのビュー・表はアプリ（例のアプリ）が使う。
- utPLSQL の `source/`: 参照 17 / 定義 21。経路B のみの 4 表（`dbmspcc_*`・`plsql_profiler_runs`）は Oracle のツールの表で、PL/SQL の静的 SQL には出ない（動的 SQL として見えたのは `dbmspcc_units` だけ）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh list-crud <src>
```

### アンチパターン
- 定義された表を全部「PL/SQL が使う」と書く。
- 同じ名前の別スキーマの表（`customers` が 3 つ）を 1 つの表として仕様にする。

---

## DP-oracle-plsql-4: トランザクションの制御・例外・自律型トランザクションを、サブプログラムごとに仕様に書く

### 目的
PL/SQL では、COMMIT / ROLLBACK をどのサブプログラムが出すか、例外をどこで捕まえて何を返すか、`PRAGMA AUTONOMOUS_TRANSACTION` で
呼び出し元と別のトランザクションにするかが、**失敗時に何が残るか**を決める。アプリ側からは見えないので、PL/SQL の仕様に書かないと消える。

### ルール
1. **公開サブプログラムごとに**: COMMIT / ROLLBACK の有無（呼び出し元に任せるか）、SAVEPOINT、自律型トランザクションかどうか、
   捕まえる例外と再送出（`RAISE` / `RAISE_APPLICATION_ERROR` のエラー番号）、`WHEN OTHERS` で握りつぶすかを書く。
2. **トリガー**: どの事象・行単位か文単位か・INSTEAD OF の対象のビュー、トリガーの中の COMMIT（自律型）を書く。
3. **エラー番号の一覧**（`-20000`〜`-20999`）を、アプリ側の画面のエラー表示と突き合わせられる形で書く。

### チェック方法
```bash
grep -rniE 'commit|rollback|savepoint|autonomous_transaction|raise_application_error|when[[:space:]]+others' <src> --include='*.pkb' --include='*.sql'
```

### アンチパターン
- 「更新する」とだけ書き、COMMIT するのが自分か呼び出し元かを書かない。
- `WHEN OTHERS THEN NULL` を仕様に書かない（失敗が黙って成功に見える）。

---

## DP-oracle-plsql-5: 動的 SQL・ラップ・DB にだけある定義を、読めないものとして明示的に数える

### 目的
`EXECUTE IMMEDIATE` / `DBMS_SQL` / `OPEN ... FOR 文字列` の SQL は、文字列を組み立てる側を読まないと表も操作も決まらない。
`wrapped` のユニットは本体を読めない。ソースに無く DB にだけある定義もある。**読めないものを数えずに黙ると、分母が静かに縮む。**

### ルール
1. **`list-dynamic` の全件**について、リテラルなら先頭の語、式なら組み立てる側の位置を書き、表と操作を補う（補えなければ UNKNOWN）。
2. **文字列の中の DDL**: 導入スクリプトが作る表は定義に数える（`list-objects` の付記 `dynamic:anonymous`）。実行時に作る表・パッケージ（テストの部品）は分母に入れない。
3. **`list-wrapped` の全件**を UNKNOWN に起票し、仕様の宣言だけを分母に使う。
4. **DB にだけある定義**を疑うときは、DB のデータディクショナリの書き出しを別の経路として突き合わせる（ソースのスクリプトだけでは分からない）。

### 実例
- utPLSQL: 動的 SQL 765 か所（テストを含む）。「(式)」が 506、残りはリテラル（`grant execute on`・`alter session set`・`drop package` 等）。
- utPLSQL の `source/`: 文字列の中の DDL で作る表 10（`ut_coverage_runs`・`ut_dbms_output_cache` 等）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-dynamic <src>
bash 03-audit/gate-snippets.sh list-wrapped <src>
```

### アンチパターン
- 動的 SQL の表を「無い」ものとして CRUD から黙って落とす。
- ラップされた本体の振る舞いを、名前から推測して書く（SB-4）。

---

<!-- ENTRIES END -->
