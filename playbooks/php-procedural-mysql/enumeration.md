# 列挙の独立ソース表（php-procedural-mysql / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて OSS 3 件で実測検証済み（2026-10-24）:
  webERP（会計・在庫・販売の ERP。1 画面 1 ファイル・DB_query に SQL 文字列・.sql 305 本。composer の vendor/ を同梱）
  osCommerce 2.3.4.1（ネットショップ。tep_db_query・表名とファイル名を define() の定数で書く・公開側と管理側の 2 系統）
  MantisBT（バグ管理。画面のファイル＋ core/*_api.php・{表} の置換記号・ADOdb のスキーマ配列・gpc_get_* で引数を読む）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: 手続き型の PHP（PHP 4〜8）の Web アプリ。ブラウザが直接開く `.php` ファイルが画面で、`include` / `require` で共通ファイルを読み、
  SQL は文字列で組み立てて DB の関数（`mysql_query` / `mysqli_query` / 自前のラッパー / ADOdb）に渡す。
- **適用判定**: 次の 2 つがどちらも 1 件以上。
  `find <src> -name '*.php' -not -path '*/vendor/*' | head` ／
  `grep -rlE '(mysql_query|mysqli_query|->query\(|_query\()' <src> --include='*.php' | head`

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **バイト列で走査する（`LC_ALL=C`）。** PHP の資産は UTF-8（BOM 有無）と ISO-8859-1 / Shift_JIS 等が混在し、`.sql` のダンプは UTF-16 のことがある。
   `gate-snippets.sh` は先頭で `LC_ALL=C` を固定し、BOM を外し、UTF-16 は NUL を落として読む。
2. **断面の境界を先に決める（Phase 0）。** 同梱した composer のライブラリ（`vendor/`）・テストコード・インストーラーはアプリの分母ではない。
   `scope` で数え、`00-ingestion/gate-config.env` の `SCAN_EXCLUDE` に書く（落とし穴 2）。
3. **パスは解析対象からの相対（`./` 始まり）で出る。** そのまま `path:line` の引用に使える。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | 関数・クラスを宣言するファイル（共通ファイル・ライブラリ） | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（include されるファイルと両方向） | 宣言ファイル数 = MOD ノード数。include との差は全件を説明する |
| NODE-EP（画面・入口） | include されず、トップレベルの処理か HTML を持つ `.php` ファイル（種類: page / cli / json） | `list-ep` / 突合 `ep-diff`（名指しされるファイルと両方向） | 入口数 = EP ノード数 ＋ インストーラー・テスト・死蔵（ADR で処分） |
| NODE-BND（DB: 参照側） | コードの SQL 文字列（定数・`{表}`・表名の関数を解いた後）＋ SQL ファイル ＋ SQL を書かない書き込みの関数（`tep_db_perform`）が参照する表名 | `bnd` / 一覧 `list-bnd` / CRUD `list-crud` | 参照表数 = BND 表ノード数 ＋ 一時表・対象外（ADR で処分） |
| NODE-BND（DB: 定義側） | `.sql` と PHP の文字列の `CREATE TABLE`・ADOdb のスキーマ配列（`CreateTableSQL`） | `bnd-schema` / 突合 `bnd-diff` | 定義表数 = 参照表数 ＋ 未参照（死蔵）− 定義の無い参照（全件説明） |
| （画面の子）要求の引数 | `$_GET` / `$_POST` / `$_REQUEST` / `$_COOKIE` / `$_FILES`・PHP 4 の `$HTTP_*_VARS`・`gpc_get_*` / `filter_input`（`$_SESSION` / `$_SERVER` も出す。セッションと環境は要求の引数とは分けて書く） | `list-params` | 画面仕様の入力の分母 |
| （画面の子）操作 | 操作を選ぶ `switch` の `case`・`$action == '...'` の比較・送信ボタンの `isset($_POST['Name'])` | `list-actions` | 画面仕様の操作の分母（EP ノードではない） |
| （エッジ）include | `include` / `require`（`_once` を含む）・`require_api` 等の関数 | `list-includes` | コードグラフのエッジの分母（`dynamic` は組み立てる側を読んで補う） |
| （エッジ）遷移 | HTML のリンク・フォームの送信先・`header('Location: ...')`・ファイル名の定数を使う箇所 | `list-refs` | 画面遷移の分母 |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は webERP / osCommerce / MantisBT の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① ブラウザが開く画面: HTML を出す `.php` ② フォームの送信先・Ajax の応答・ダウンロード: 画面を出さずに処理して返す `.php`（json）③ 運用から起動するスクリプト: cron / CLI（`$argv`・`php_sapi_name`）④ 外部から呼ばれる API: REST のルーター・SOAP / XML-RPC の入口 | **4 系統。単一ではない。** 入口は「どこからも include されないファイル」で取るが、**変数でパスを組み立てる include の先は入口に見える**（実測 osCommerce: 165 件のうち 36 件が決済モジュール・言語ファイル・部品のテンプレート。落とし穴 5）。④は**ルーターがクラスを呼ぶ形**だと 1 ファイルの入口に API 全体が入る（実測 MantisBT の `api/rest/`）。重複はファイルのパスで取る |
| NODE-BND | ① コードの SQL 文字列 ② 表名を定数・置換記号・関数で書く SQL ③ SQL を書かない書き込みの関数 ④ SQL ファイル（インストール・アップグレード）⑤ スキーマ定義（`CREATE TABLE`・ADOdb のスキーマ配列） | **5 系統。単一ではない。** ①だけを見ると、**表名を定数で書く対象では表が 0 件に見え**（実測 osCommerce: `"select ... from " . TABLE_ORDERS`）、**書き込みの関数の表を落とす**（実測 osCommerce: `tep_db_perform` 140 か所。insert / update の半分）。①〜④と⑤は表名で `comm` を取り、両方向の差を全件説明する |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（osCommerce）では表が「参照側 53 / 定義側 54」で一致した（定義のみ 1 = `counter_history`）。**一致したのは定数を解き、文言の定数と
> 言語ファイルを SQL から外した後**で、最初の版は参照側に英単語（`the` / `your` / `this` 等）が 12 件混ざっていた（落とし穴 12）。

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
| NODE-MOD | 関数・クラスを宣言するファイルの全数（`mod`） | include されるファイル（パスを解けたもの ＋ 変数で組み立てる include の式に当たるもの。`mod-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（オートロード・入口が関数を持つ・死蔵／宣言の無い設定・テンプレート・言語ファイルの別）>` |
| NODE-EP | **入口のファイル**: include されず、トップレベルの処理か HTML を持つ `.php`（`ep-diff` 経路A） | **名指しされるファイル**: HTML のリンク・フォームの送信先・`header('Location')`・ファイル名の定数を使う箇所から解いたファイル（`ep-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（外から直接開く・cron・API のルーター・名前を組み立てて開く・死蔵の別）>` |
| NODE-BND | **DB 表・参照側**: コードの SQL ＋ SQL ファイル ＋ 書き込みの関数が参照する表名（`list-bnd`） | **定義側**: `CREATE TABLE`・ADOdb のスキーマ配列の表名（`bnd-schema`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（一時表・接頭辞の違い・別 DB・死蔵の別）>` |

- **経路B（名指しされるファイル）は経路A より少ないのが普通**（cron・API・外から直接開く画面・名前を組み立てて開く画面がある）。
  **経路A のみの入口を分母から外さない。** 1 件ずつ原因を書き、対象外にするもの（インストーラー・テスト）は ADR で処分する
  （実測: osCommerce 10・MantisBT 45・webERP 65）。
- **定義側（スキーマ）がソースに無い場合**（DB のダンプだけ・別リポジトリ）は、`NODE-BND` の経路B の定義欄を
  「単一経路（スキーマがソースに無い）」に書き換え、差分欄に理由を書く（`G-ENUM-SOURCE` が理由の記入を検査する）。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**表名が SQL の文字列と定数の中にしか無く、業務の処理が共通ファイルの関数にある**ため、
「画面の処理は書いたが、どの表・どの関数を使うかは書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `table` | **物理テーブル名**（参照側 ∪ 定義側。論理名で書く対象は論理名。表ごとに最も多く現れた綴り） | `bash 03-audit/gate-snippets.sh idents-table <src>` |
| `page` | **入口のファイル名**（`AccountGroups.php` のように拡張子つき。綴りどおり） | `bash 03-audit/gate-snippets.sh idents-page <src>` |
| `function` | **関数名**（トップレベルの `function`。共通ファイルの業務の処理を特定するのに必須） | `bash 03-audit/gate-snippets.sh idents-function <src>` |

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。

1. **文字コードと BOM（`LC_ALL=C`）。** 前提 1 を参照。`<?php` の前の BOM は字句解析の前に外す（外さないと 1 行目が HTML に見える）。
2. **同梱したライブラリのソース。** 実測 webERP: `.php` 5,303 本のうち 4,534 本が composer の `vendor/`。外さないと入口 2,037（外すと 540）、
   宣言ファイル 3,211（外すと 155）になる。`scope` で見つけ、`SCAN_EXCLUDE='^\./vendor/'` の形で外す。
3. **HTML と PHP の混在・注釈・文字列。** `gate-snippets.sh` はファイルを HTML の部分と PHP の文に分けて読む。`//` と `#` の注釈は行末までだが
   **`?>` で PHP の外へ出る**（PHP の規則）。文字列の中の `?>` / `//` / `#` は注釈でも PHP の終わりでもない。ヒアドキュメント（`<<<EOD`）・
   ナウドキュメントも読む。`#` で始まる注釈は MantisBT の全ファイルの見出しにある。
4. **入口の判定。** 入口 = どこからも include されず、トップレベルの処理（関数・クラスの宣言・`define()`・include・入口の守り
   `defined('X') or die` 以外の文）か HTML を持つファイル。宣言だけのファイル・設定だけのファイルは入口にしない。
5. **変数でパスを組み立てる include。** `include(DIR_WS_MODULES . 'payment/' . $module)` / `require(DIR_WS_LANGUAGES . $language . '/x.php')` の先の
   ファイルは名前で include されないので入口に見える（実測 osCommerce: 入口 165 のうち 36。決済モジュール・言語ファイル・部品のテンプレート）。
   `gate-snippets.sh` は解けなかった部分を「任意の文字列」にした式（`includes/modules/payment/*`）に当たるファイルを include されるものとして入口から外し、
   `ep-diff` の最後の節に一覧を出す。**ディレクトリを列挙して include する形**（`dir()` で `includes/boxes/` を読む。実測 osCommerce の管理側 7 件）は式が無いので外せない。
6. **表名とファイル名を定数で書く。** osCommerce は `define('TABLE_ORDERS', 'orders')` / `define('FILENAME_ACCOUNT', 'account.php')` で名前を決め、
   SQL とリンクは定数を連結して書く。定数を解かないと表もリンクも 0 件に見える。`gate-snippets.sh` は `define()` と `const` を集め、
   定数の連結（`DIR_WS_INCLUDES . 'boxes/'`）も解く（`list-constants`。実測 osCommerce: 3,067 件）。**`define()` の一覧そのものは遷移に数えない**
   （ファイル名の一覧は配布ファイルの台帳で、遷移ではない）。**文言の定数**（`TEXT_X = 'Select one from the list'`）は SQL に混ぜない。
   公開側と管理側で同じ名前の定数を別の値で定義することがあり、最初の定義を使って別の値を `other` として出す（実測 osCommerce: 197 件）。
7. **表名の置換記号・関数・接頭辞。** MantisBT は SQL に `{bug}` と書き、実行時に接頭辞つきの物理名に置き換える。`db_get_table( 'bug' )` も同じ。
   `gate-snippets.sh` は `{名前}` と「名前が table で終わる関数に表の名前を渡す呼び出し」を表として読む（物理名は設定の接頭辞で決まる）。
   **接頭辞の定数を連結する形**（`"FROM " . DB_PREFIX . "users"`）は、定数の値を詰めて `pre_users` と読む（空の接頭辞なら `users`）。
   **接頭辞が変数**（`$prefix . "users"`）の SQL は表を拾えない——`list-bnd` に出ないので、接頭辞の変数を grep で探して手で補う。
8. **include のパスの解決。** PHP は相対パスを入口のディレクトリ（include_path の `.`）と呼び出し元のディレクトリから探す。`gate-snippets.sh` は
   呼び出し元のディレクトリから上へ順に探し、無ければファイル名（一意なら）・末尾のディレクトリ名の一致で決める。`require_api('gpc_api.php')`
   のような include の関数も読む（実測 MantisBT: 1,993 件をファイル名で解決）。
9. **スキーマが SQL ファイルに無い。** MantisBT は表を PHP の配列（`array( 'CreateTableSQL', array( db_get_table( 'bug' ), ...`）で定義し、
   ADOdb の DataDict が実行時に DDL を作る（実測: 33 表）。webERP は `.sql` 305 本のほかに、アップグレードの PHP の文字列に `CREATE TABLE` がある。
10. **SQL を書かない書き込み。** `tep_db_perform(TABLE_X, $data, 'update')` のように表名と列の配列を渡して SQL を作る関数がある
    （実測 osCommerce: 140 か所。拾わないと CRUD の insert が 176、拾うと 348）。名前が `perform` / `_insert` / `_update` / `_delete` / `_replace` で
    終わる関数と ADOdb の `AutoExecute` の第 1 引数が、スキーマにある表の名前に解けるものを拾う。
11. **要求の引数の読み方。** PHP 4 の長い名前（`$HTTP_GET_VARS` / `$HTTP_POST_VARS`。実測 osCommerce 2.3）と、引数を読む関数
    （`gpc_get_int('bug_id')`。実測 MantisBT: 600 か所以上が関数経由で、`$_GET` は直接書かない）。独自の関数で読む対象は名前を探して手で補う。
12. **英文・文言を SQL と誤認しない。** SQL の句の語で始まる文字列を含む文だけを SQL とみなすが、それだけでは次の文言の語が表に化ける
    （最初の版で webERP の参照側に 48 件・osCommerce に 12 件・MantisBT に 3 件）:
    翻訳の関数の引数（`DB_query($SQL, _('... could not be deleted from the database'))` の `the`）、`echo` / ログ / 例外の文言（`'Update BLOB in '`）、
    `define()` の文言、先頭だけ大文字の語で始まる文言（`Update BLOB in`）、翻訳の関数の後ろに連結した文言、`ON DUPLICATE KEY UPDATE 列`、
    関数の引数の `FROM`（`EXTRACT(YEAR_MONTH FROM 列)`）。`gate-snippets.sh` はこれらを外してから表を拾う（後: webERP 12（うち一時表 7。落とし穴 14）・osCommerce 0・MantisBT 0）。
    **外しすぎの側にも注意する**: 先頭だけ大文字の SQL（`Select * from t`）は SQL の記号（`* = ( )`）を含むので残すが、記号の無い短い SQL（`, ` だけのものも含む）
    （`Delete from t`）は文言として落ちる。参照側に無い表がスキーマにあれば（`bnd-diff` の経路B のみ）、その表の名前で grep して確かめる。
13. **SQL の中の文字列値と注釈。** MySQL のダンプは `INSERT ... VALUES ('It\'s from the list')` のように `\'` で引用符を書き、`''` も使う。
    素朴に `'...'` を消すと文言の語が表に化ける（実測 webERP のヘルプの文言）。SQL ファイルの `--` / `#` / 複数行の `/* */` は外す
    （同じ行で閉じる文字列の中は外さない）。DDL の `ON UPDATE CURRENT_TIMESTAMP` の update は表の更新ではない。
14. **一時表。** `CREATE TEMPORARY TABLE` で作る作業用の表は定義側の表にしない（実測 webERP: 7 つ）。`bnd-diff` が「一時表」の節に出す。
15. **FROM の後の関数の呼び出し。** `' FROM ' . implode(', ', $from)`（実測 MantisBT）/ `' INNER JOIN ' . DB_escape_string($t)`（実測 webERP）の
    関数名を表にしない（表は静的に決まらない）。`INSERT INTO 表 (列, ...)` の括弧は列の一覧なので、この判定は FROM / JOIN の後だけ。
16. **運用で作る設定ファイル。** `config_inc.php` / `config.php` はインストール時に作られ、リポジトリに無い（実測: MantisBT への参照 17 件・
    webERP への参照 37 件が「ファイルが無い」に出る）。断面外として ADR で処分する。
17. **名指しされない入口。** cron / CLI（実測 MantisBT 6・webERP 3）、REST API のルーターが呼ぶクラスのファイル（実測 MantisBT の `api/rest/` 9）、
    コマンドのクラス（`core/commands/` 12）、インストーラー・アップグレード（webERP の `Z_Upgrade*.php`）は、リンクから名指しされない。
    `ep-diff` の「経路A のみ」に出るので、1 件ずつ種類を書く。
18. **基点のパスの変数を前に連結したリンク。** `$RootPath . '/X.php'`（実測 webERP: 画面のリンクのほとんど）は、変数を基点とみなして `/X.php` で解く。
    基点がどの階層かは静的に決まらないので、複数の階層に同名のファイルがあれば `ambiguous` に出す。変数の後ろに `/` で始まらない文字列を
    連結する形（`$base . 'admin/x.php'`・`$this->base . 'x.php'`・`$cfg['root'] . 'x.php'`）は変数の値が名前の一部になるので `dynamic` に出す
    （実測 osCommerce: `install_4.php` の `$dir_fs_document_root . 'admin/includes/configure.php'`）。
19. **操作の switch の書き方。** 積み重ねた `case 'a': case 'b':`、`case` の中の入れ子の `switch`、`switch (式): ... endswitch;`（テンプレートの
    `<?php case 'x': ?>` を含む）を読む。式に action / mode / step / cmd / do / op / task を含む switch だけを操作とする
    （実測: osCommerce の case 185・webERP 20。入れ子の switch の後の外側の case を落とすと osCommerce で 5 つ減る）。ほかの名前で操作を分ける対象は grep で探して足す。

### 作成時の検証記録（このファイルのコマンドを OSS で走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（宣言 / include される） | 入口（経路A / 経路B） | 表（参照 / 定義） | CRUD の行 | 引数 / 操作 | 備考 |
|---|---|---|---|---|---|---|
| webERP（`vendor/` を除外） | 155 / 210 | 540 / 475（A のみ 65。`reportwriter/admin` 13・`Z_Upgrade*` 9 等） | 230 / 242（A のみ 5・一時表 7・B のみ 24＝CRM・HR 等の未使用の表） | 4,301 | 27,401 / 2,610 | 除外しない場合: 入口 2,037・宣言 3,211。変数で組み立てる include の先 99（`sql/updates/{}.php` 73 等）を入口から除外 |
| osCommerce 2.3.4.1 | 303 / 155 | 129 / 119（A のみ 10。管理側のディレクトリ列挙の include 7） | 53 / 54（B のみ 1＝`counter_history`） | 1,335 | 1,903 / 474 | 定数 3,067。変数で組み立てる include の先 36 を入口から除外 |
| MantisBT | 313 / 123 | 250 / 205（A のみ 45。`core/commands` 12・`api/rest` 9 等） | 32 / 33（B のみ 1＝`user_print_pref`） | 254 | 748 / 46 | 引数の 600 以上が `gpc_get_*` 経由。表の定義は ADOdb のスキーマ配列 |

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# 同梱した composer のライブラリ・キャッシュを除く（この Playbook の列挙と同じ除外にそろえる）
SOURCE_EXCLUDE='(^|/)(vendor|cache|tmp)/'
```

**入れないとどうなるか**: `vendor/` には同名の `index.php` / `config.php` が大量にあり、basename の引用が「候補複数」で解決できなくなる。
`SCAN_EXCLUDE` に入れたディレクトリも `SOURCE_EXCLUDE` にそろえる。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 540 画面を 40 の業務単位にまとめる）、
**独立ソース側には 540 を書き、ノード登録数に 40 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。オートロード・死蔵・同梱ライブラリの除外を明示>` | `<YYYY-MM-DD>` |
| NODE-EP（画面・入口） | `<N>` | `<M>` | `<同上。cron・API・インストーラー・テスト・死蔵を明示>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。一時表・接頭辞・別 DB・未使用の表を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
