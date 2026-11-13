# Playbook: `php-procedural-mysql`

手続き型の PHP（PHP 4〜8）で書いた業務 Web アプリ（1 画面 1 ファイル＋ include する共通ファイル、SQL を文字列で組み立てる）を対象とする Playbook。
実測検証: webERP（会計・在庫・販売の ERP）・osCommerce 2.3.4.1（ネットショップ）・MantisBT（バグ管理）（2026-10-24）。

## 対象スタック

- **言語/実行基盤**: PHP 4〜8（Apache / IIS ＋ mod_php・PHP-FPM）。フレームワークを使わないか、自前の小さな共通部品だけを使う
- **エントリポイント**: ブラウザが直接開く `.php` ファイル（画面・フォームの送信先・ダウンロード・Ajax の応答）、cron / CLI のスクリプト
- **共通部品**: `include` / `require` する共通ファイル（関数の定義・設定・テンプレートの部品・言語ファイル）
- **永続化**: MySQL 等へ SQL 文字列を直接渡す（`mysql_query` / `mysqli_query` / 自前のラッパー `DB_query()` / `tep_db_query()` / `db_query()`・ADOdb）
- **画面**: PHP の中に HTML を直接書く、または include するテンプレートの部品

## 適用判定（この Playbook を選ぶべきか）

```bash
find <source> -name '*.php' -not -path '*/vendor/*' | head                       # 1 件以上
grep -rlE '(mysql_query|mysqli_query|->query\(|_query\()' <source> --include='*.php' | head   # 1 件以上
```

- ✅ **該当**: どちらも 1 件以上で、ルート（や `admin/`）の直下に画面の `.php` が並ぶ
- ❌ **非該当**:
  - Laravel / Symfony / CakePHP / CodeIgniter 等の MVC フレームワーク（ルーティングの定義・コントローラーのクラスが入口）→ **未対応**
    （入口がファイルではなくルートの定義なので、分母の数え方が違う。`--playbook` を省略し、`enumeration.md` を自分で埋める）
  - WordPress / Drupal のプラグインだけを解析する場合 → 入口がフック（`add_action` 等）なので、この Playbook の画面の分母は当てはまらない
  - 手続き型の画面と MVC が同居するアプリは、手続き型の部分をこの Playbook で数え、MVC の部分は `enumeration.md` に別の行を足して数える

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-php-procedural-mysql-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面の処理の流れ・操作・要求の引数・CRUD・表名の解決規則） | `../specs/_appendix-php-procedural-mysql.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-includes`/`list-refs`/`list-crud`/`list-params`/`list-actions`/`list-constants`/`scope`/`sql-stores`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find / xargs のみで動く（追加のツールを要求しない）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **同梱した第三者ライブラリのソース（Phase 0）。** `scope` でディレクトリごとの件数を見て、composer の `vendor/` 等を
  `00-ingestion/gate-config.env` に `SCAN_EXCLUDE='^\./vendor/'` の形で書く（`gate-snippets.sh` が読む。環境変数で渡せばそちらが優先）。
  外したものは ADR で処分する。
- **インストーラー・アップグレードのスクリプトを画面に数えるか。** `install/` 等は運用者が 1 度だけ開く。分母から外すなら ADR で処分する。
- **変数でパスを組み立てる include で入口から外したファイル。** `ep-diff` の最後の節に出る。外してよいか（本当に include される部品か）を確かめる。
- **表の論理名と物理名。** 接頭辞・定数・置換記号（`{bug}`）で決まる物理名を仕様にどう書くかを決める。
- **要求の引数を読む独自の関数。** `list-params` は `$_GET` 等・PHP 4 の `$HTTP_*_VARS`・`gpc_get_*`・`filter_input` を拾う。独自の関数で読む対象では、
  その名前を探して手で補う。
