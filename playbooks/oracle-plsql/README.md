# Playbook: `oracle-plsql`

Oracle の PL/SQL（パッケージ・プロシージャ・関数・トリガー・オブジェクト型）と、それが読み書きする表を、ソースのスクリプトから数える Playbook。
業務ロジックが DB の側にある構成（アプリはストアドを呼ぶだけ）を対象にする。アプリ側の Playbook が「SQL・ストアドの呼び出し」までを数え、
この Playbook がその先（PL/SQL の中身と表）を数える分担になる。両方を使うときは `--playbook` を 2 回並べる（下の「併用の手順」）。
実測検証: Oracle Database Sample Schemas（HR / CO / OE / SH / PM）・utPLSQL v3（テストを含む）・Alexandria PL/SQL Utility Library（2026-10-25）。

## 対象スタック

- **言語/実行基盤**: Oracle Database の PL/SQL（8i〜23ai）。ソースは SQL*Plus / SQLcl で流すスクリプト（`.sql`）か、ユニットごとのファイル（`.pks` / `.pkb` / `.prc` / `.fnc` / `.trg` / `.tps` / `.tpb` 等）
- **エントリポイント**: パッケージ仕様の公開サブプログラム（アプリ・他のスキーマから呼ばれる API）、単独の PROCEDURE / FUNCTION、トリガー、
  DBMS_SCHEDULER / DBMS_JOB のジョブ
- **モジュール**: パッケージ（仕様と本体）、メソッドを持つオブジェクト型（型仕様と型本体）
- **永続化**: 表・ビュー・マテリアライズド・ビュー（`CREATE` 文。導入スクリプトが EXECUTE IMMEDIATE で作るものを含む）と、PL/SQL の静的 SQL・動的 SQL
- **対象外**: Oracle Forms / Reports（`.fmb` / `.rdf` はバイナリ）、APEX のアプリの書き出し（`f*.sql`）の画面定義、Java ストアドの中身

## 適用判定（この Playbook を選ぶべきか）

```bash
grep -rliE 'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?((non)?editionable[[:space:]]+)?(package|procedure|function|trigger)' <source> \
  --include='*.sql' --include='*.pk?' --include='*.pls' --include='*.prc' --include='*.fnc' --include='*.trg' | head   # 1 件以上
```

- ✅ **該当**: PL/SQL のユニットを作るスクリプトが 1 件以上ある。アプリのソースと同じリポジトリにあってもよい（アプリ側は別の Playbook で数える）
- ❌ **非該当**:
  - SQL Server の T-SQL（`CREATE PROC` / `GO`）・PostgreSQL の PL/pgSQL（`$$` で囲む）・DB2 の SQL PL → **未対応**（文の区切りと字句が違う）
  - DDL だけで PL/SQL が無い（表の定義だけ）→ この Playbook の入口とモジュールは 0 件になる。表だけを数えるならアプリ側の Playbook の DDL の行で足りる

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-oracle-plsql-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（公開 API・トランザクション制御・例外・トリガー・ジョブ・CRUD・動的 SQL） | `../specs/_appendix-oracle-plsql.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-objects`/`list-crud`/`list-calls`/`list-dynamic`/`list-jobs`/`list-grants`/`list-wrapped`/`scope`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find / xargs / sort / comm / join のみで動く（追加のツールを要求しない）。
SQL と PL/SQL は自前の字句解析で読む（注釈・`'...'` の `''`・`q'[...]'` の引用演算子・二重引用符の識別子・SQL*Plus のコマンド行・`/` の終端・空行の終端）。

## 併用の手順（アプリ側の Playbook と一緒に使う）

1. `init.sh` にアプリ側の Playbook を先に、この Playbook を後に渡す（GP-105 ルール11）:
   `init.sh <src> <spec-name> rebuild --playbook csharp-winforms-adonet --playbook oracle-plsql`
2. この Playbook は `01-code-graph/enumeration-oracle-plsql.md`・`03-audit/gate-snippets-oracle-plsql.sh`・
   `docs/knowledge/practices-oracle-plsql.md` に置かれる。走査は `bash 03-audit/gate-snippets-oracle-plsql.sh <サブコマンド> <PL/SQL の置き場>`。
3. 2 つの `enumeration*.md` を**それぞれ**埋める（`G-ENUM-SOURCE` がどちらも検査する。1 つに合体させない）。
4. **表はアプリ側の NODE-BND に寄せる。** アプリの SQL と PL/SQL が同じ表を読み書きするので、表のノードは 1 回だけ登録し、
   この Playbook の実行記録の NODE-BND の差分欄に「主の NODE-BND に統合（ADR-N）」と書く。
   パッケージ・トリガー・ジョブ（NODE-EP）と PL/SQL の手続き（NODE-MOD）は、アプリ側に無いので別のノードとして登録する。
   この Playbook の実行記録の NODE-BND のノード登録数には、アプリ側に無い表（PL/SQL だけが使う表）の数を書く（全部寄せたなら 0）。
5. 除外が違うとき（アプリは `vendor/`、PL/SQL は `test/` 等）は、`SCAN_EXCLUDE` を環境変数で上書きして走らせる
   （`gate-config.env` の値は 2 つの走査器で共有される）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **スキーマの境界（Phase 0）。** 1 つのリポジトリに複数のスキーマの導入スクリプトがあると、同じ名前の表（`customers` 等）が別々に定義される。
  キーは名前だけなので 1 つに束ねられる（`bnd-diff` の最後の節に出る）。スキーマごとに `SCAN_EXCLUDE` で分けて走査するか、束ねたまま ADR に書く。
- **テスト・例・導入スクリプト。** テストのパッケージ（utPLSQL の `--%suite` 等）は API ではない。`scope` でディレクトリを見て、外すなら `SCAN_EXCLUDE` に書き、ADR で処分する。
- **動的 SQL と動的 DDL。** 文字列の中の SQL は静的に読めない。`list-dynamic` の「(式)」の行は、組み立てる側を読んで表・操作を補う。
- **ラップされたユニット。** `wrapped` のユニットは中身を読めない（`list-wrapped`）。仕様の宣言だけを分母にし、本体の振る舞いは UNKNOWN に起票する。
- **DB にだけある定義。** ソースのスクリプトと DB の実体はずれることがある（手で足した表・本番だけの索引）。ずれを測るなら、
  DB のデータディクショナリ（`USER_OBJECTS` 等）の書き出しを別の経路として突き合わせる（この Playbook は読まない）。
