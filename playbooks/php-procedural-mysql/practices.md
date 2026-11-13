# ドメイン知見（`DP-php-procedural-mysql-N`）

手続き型の PHP（PHP 4〜8）の業務 Web アプリ（1 画面 1 ファイル＋ include する共通ファイル、SQL を文字列で組み立てる）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 3 件（webERP / osCommerce 2.3.4.1 / MantisBT）。

<!--
【ID 規約】`DP-php-procedural-mysql-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-php-procedural-mysql-1 | 入口は「include されないファイル」で数え、変数で組み立てる include の先とディレクトリ列挙の include を切り分ける | `.php` の数は画面の数ではない。部品・言語ファイル・決済モジュールが入口に見える |
| DP-php-procedural-mysql-2 | 表名・ファイル名を定数・置換記号・関数で書く対象は、解決表を先に作ってから表と遷移を数える | `"from " . TABLE_ORDERS` / `{bug}` / `FILENAME_LOGIN` を解かないと表もリンクも 0 件に見える |
| DP-php-procedural-mysql-3 | 画面の仕様は「1 ファイルの上から下」の処理の流れで書き、操作の分岐と要求の引数を全数で書く | 1 つのファイルが action の値・送信ボタンで複数の操作を受ける |
| DP-php-procedural-mysql-4 | CRUD は SQL 文字列と書き込みの関数の両方から取り、SQL の組み立て規則と値の埋め込み方まで書く | 書き込みの関数（`tep_db_perform`）は SQL を書かない。値の埋め込み方が移行判断を決める |
| DP-php-procedural-mysql-5 | 断面の境界（同梱ライブラリ・運用で作る設定ファイル・インストーラー）を Phase 0 で数えて決める | composer の vendor/ が .php の大半を占め、設定ファイルはリポジトリに無い |

---

## DP-php-procedural-mysql-1: 入口は「include されないファイル」で数え、変数で組み立てる include の先とディレクトリ列挙の include を切り分ける

### 目的
手続き型の PHP では、ブラウザが開くファイルと include されるファイルが同じ `.php` で、ディレクトリでも名前でも区別されないことが多い。
**変数でパスを組み立てる include の先**（決済モジュール・言語ファイル・部品のテンプレート）は名前で include されないので、素朴に数えると入口に見える。

### ルール
1. **経路A（入口のファイル）**: どこからも include されず、トップレベルの処理か HTML を持つファイル（`list-ep`）。種類（page / cli / json）を付ける。
2. **経路B（名指しされるファイル）**: リンク・フォームの送信先・`header('Location')`・ファイル名の定数を使う箇所から解いたファイル（`ep-diff`）。
3. **変数で組み立てる include の式に当たるファイル**は入口から外される（`ep-diff` の最後の節）。外してよいか（本当に部品か）を確かめる。
4. **経路A のみの入口を種類で分ける**:
   | 種類 | 典型 | 対処 |
   |---|---|---|
   | 運用から起動 | cron / CLI（`php_sapi_name`）・バッチ | 起動の仕組み（crontab 等）を断面外として書く |
   | API のルーター | REST のルーターが呼ぶクラスのファイル | ルートの定義を読み、API の入口として別に数える |
   | ディレクトリ列挙の include | `dir()` で読むメニューの部品 | 読み込む側のコードを読み、部品として扱う（ADR） |
   | インストーラー・テスト・死蔵 | `install/`・`Z_Upgrade*.php`・`tests/` | 分母から外すなら ADR で処分 |

### 実例
- osCommerce: 入口 165 → 変数で組み立てる include の先 36 を外して 129。経路B 119。経路A のみ 10 のうち 7 は管理側のメニューの部品（`includes/boxes/`）で、
  `column_left.php` がディレクトリを列挙して include する。
- MantisBT: 入口 250 / 経路B 205。経路A のみ 45 のうち `core/commands/` 12・`api/rest/` 9 は、それぞれコマンドの仕組みと REST のルーターから呼ばれる。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh ep-diff <src>        # 経路A のみ・名指しされるが入口でない・変数で組み立てる include の式で外したファイル
bash 03-audit/gate-snippets.sh list-includes <src>  # dynamic の行が「組み立てる側を読む」箇所
```

### アンチパターン
- `find -name '*.php' | wc -l` を画面数にする（共通ファイル・言語ファイル・同梱ライブラリが混ざる）。
- 名指しされない入口を「未使用」と断定する（cron・API・外から直接開く画面がある）。

---

## DP-php-procedural-mysql-2: 表名・ファイル名の解決表を先に作ってから表と遷移を数える

### 目的
手続き型の PHP は、表名とファイル名を**定数**（`TABLE_ORDERS` / `FILENAME_LOGIN`）・**置換記号**（`{bug}`）・**関数**（`db_get_table('bug')`）で書くことが多い。
SQL とリンクはそれらを連結して作るので、解決表が無いと表も遷移も数えられない。

### ルール
1. Phase 1 の最初に `list-constants` で定数の解決表を作る（名前・値・場所・別の値の再定義）。公開側と管理側で値が違う定数は両方を書く。
2. 表名は**論理名**（コードに書く名前）と**物理名**（接頭辞・設定で決まる名前）の対応を表にする。
3. `define()` の一覧（`filenames.php` 等）は台帳であって遷移ではない。遷移は定数を**使う**箇所から数える（`gate-snippets.sh` はそうしている）。

### 実例
- osCommerce: 定数 3,067 件。表は `includes/database_tables.php` の `TABLE_*`、ファイル名は `includes/filenames.php` の `FILENAME_*`。
  定数を解いた後の表は参照側 53 / 定義側 54 で、差は未使用の `counter_history` だけ。
- MantisBT: SQL は `{bug}` と書き、`db_get_table( 'bug' )` も使う。物理名は設定の接頭辞・接尾辞（既定 `mantis_` ＋ `_table`）で決まる。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-constants <src> | grep -E '^(TABLE|FILENAME|DIR)_'
bash 03-audit/gate-snippets.sh bnd-diff <src>
```

### アンチパターン
- 表を `grep -i 'from [a-z_]*'` で数える（定数で書く対象では 0 件、文言の英単語が混ざる）。

---

## DP-php-procedural-mysql-3: 画面の仕様は「1 ファイルの上から下」の流れで書き、操作の分岐と要求の引数を全数で書く

### 目的
画面のファイルは「共通ファイルの include → 引数の読み取り → 操作の分岐 → SQL → HTML の出力」を上から順に書く。
1 つのファイルが `action` 等の値・送信ボタンの名前で**複数の操作**を受け、引数は型の宣言が無いまま `$_GET` / `$_POST` / 読み取りの関数から来る。

### ルール
1. 画面 1 つにつき、`list-actions` の値（case・比較・送信ボタン）を操作の分母にし、操作ごとに処理と遷移先を書く。
2. 画面 1 つにつき、`list-params` の名前を入力の分母にし、出どころ（GET / POST / セッション）・型・検証・既定値を書く。
3. PHP 4 の長い名前（`$HTTP_POST_VARS`）・読み取りの関数（`gpc_get_int`）は同じ引数として数える。

### 実例
- osCommerce: 引数 1,903 行（GET 1,009・POST 826）、操作 474 行（case 185・比較 96・送信ボタン 193）。PHP 4 の `$HTTP_GET_VARS` で書かれている。
- MantisBT: 引数 748 行のうち 644 行が `gpc_get_*` 経由。
- webERP: 操作の大半（2,590 行）が送信ボタンの `isset($_POST['Name'])` で分かれる。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-actions <src> | cut -f2 | sort | uniq -c
bash 03-audit/gate-snippets.sh list-params <src> | cut -f2 | sort | uniq -c
```

### アンチパターン
- 画面の仕様に HTML の項目だけを書き、ファイルの中の分岐（同じファイルが受ける別の操作）を落とす。

---

## DP-php-procedural-mysql-4: CRUD は SQL 文字列と書き込みの関数の両方から取り、組み立て規則と値の埋め込み方まで書く

### 目的
表の読み書きは画面のファイルと共通ファイルの関数に散らばり、**書き込みの関数**（表名と列の配列を渡して SQL を作る）は SQL を書かない。
SQL は条件句を文字列で連結して作り、値の埋め込み方（エスケープ関数・プリペアド・素の連結）が移行（SQL インジェクションの対処を含む）の判断を決める。

### ルール
1. `list-crud`（ファイル × 表 × 操作）を data 仕様の CRUD の分母にする。`?` の行（SQL の続きの文字列だけの文）は前の文を読んで操作を補う。
2. 組み立てる SQL 1 つにつき、基本形・条件句ごとの付加条件・並び順・値の埋め込み方を書く。
3. 一時表（`CREATE TEMPORARY TABLE`）は業務の表と分けて、作る処理と使う処理を書く。

### 実例
- osCommerce: CRUD 1,335 行。`tep_db_perform` の 140 か所を入れると insert が 176 → 348。値は `tep_db_input()` でエスケープする。
- webERP: CRUD 4,301 行。作業用の一時表 7 つ（`tempbom` 等）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-crud <src> | awk -F '\t' '$3 != "select"'
```

### アンチパターン
- SQL 文字列だけから CRUD を作り、書き込みの関数の insert / update を落とす。

---

## DP-php-procedural-mysql-5: 断面の境界を Phase 0 で数えて決める

### 目的
リポジトリには、アプリ以外のもの（composer の `vendor/`・テスト・インストーラー）が入り、逆に**動くのに必要なもの**（インストール時に作る設定ファイル）が無い。
境界を決めないまま数えると、分母が桁で狂い、参照切れが大量に出る。

### ルール
1. `scope` でディレクトリごとの件数を見て、同梱ライブラリは `SCAN_EXCLUDE` に入れ、ADR で処分する。
2. 運用で作る設定ファイル（`config_inc.php` / `config.php`）は断面外として ADR に書き、設定のキーと既定値を仕様にする（既定値のファイルがあればそれを読む）。
3. インストーラー・アップグレードのスクリプトを分母に入れるかを決める。

### 実例
- webERP: `.php` 5,303 本のうち 4,534 本が `vendor/`。外さないと入口 2,037・宣言ファイル 3,211、外すと 540・155。
  `config.php` への参照 37 件が「ファイルが無い」に出る（インストール時に作る）。
- MantisBT: `config_inc.php` への参照 17 件が同じく「ファイルが無い」。既定値は `config_defaults_inc.php` にある。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh scope <src>
```

### アンチパターン
- リポジトリ全体をそのまま数え、同梱ライブラリの関数・SQL を業務の分母に入れる。

<!-- ENTRIES END -->
