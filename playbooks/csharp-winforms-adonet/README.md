# Playbook: `csharp-winforms-adonet`

C# の Windows Forms デスクトップアプリ（ADO.NET 直接・SQL 文字列・ストアド・型付き DataSet）を対象とする Playbook。
実測検証: OpenDental 24.3（歯科医院向け業務システムの部分取得）・Estate（WinForms ＋ SQL Server ＋ ストアドの小規模業務アプリ）（2026-10-22）。

## 対象スタック

- **言語/実行基盤**: C# / .NET Framework 2.0〜4.x（.NET 5 以降の Windows Forms も可）
- **エントリポイント**: `Form` 派生クラス（画面）・実行ファイルのプロジェクト（起動点）・Windows サービス / Remoting / ASMX / WCF / Web API
- **永続化**: ADO.NET 直接（`SqlCommand` / `OleDbCommand` / `MySqlCommand` 等）・ストアドプロシージャ・型付き DataSet・自作の軽量 ORM
- **画面**: Visual Studio のフォームデザイナ（`*.Designer.cs`）。自作・外部部品（DevExpress 等）の基底フォームを含む

## 適用判定（この Playbook を選ぶべきか）

```bash
find <source> -iname '*.csproj' -not -path '*/obj/*' | head                     # 1 件以上
grep -rliE '<SubType>Form</SubType>|System\.Windows\.Forms|<UseWindowsForms>true' \
  <source> --include='*.csproj' | head                                           # 1 件以上
```

- ✅ **該当**: どちらも 1 件以上
- ❌ **非該当**:
  - `.vbproj` が主体 → **`vbnet-winforms-adonet` を使う**
  - 画面が `.aspx` / `.ascx`（Web Forms）→ **`aspnet-webforms` を使う**
  - 画面が `.xaml`（WPF）・Razor（ASP.NET MVC / Blazor）→ **未対応**
    （`--playbook` を省略し、`enumeration.md` を自分で埋める。分母の数え方が違う）
  - 永続化が Entity Framework 主体（`DbContext` / `DbSet<T>`）→ 画面側はこの Playbook で数えられるが、
    表の分母は `DbSet<T>` とマイグレーションから取る必要がある（`bnd` は SQL 文字列しか見ない）
- **C# と VB.NET の混在**: プロジェクト数の多い側の Playbook を指定し、もう一方の `gate-snippets.sh` を
  `playbooks/<他方>/gate-snippets.sh` から直接実行して両方の件数を `enumeration.md` に記録する
  （各スクリプトは自分の言語のファイルだけを数える）。

> **同じ .NET でも C# と VB.NET で Playbook を分ける理由**: 字句（コメント `//` / `'`、文字列の `\"` / `""`、逐語的文字列）・
> 継承の書き方（`: Base` / `Inherits` が別の行・別の Partial ファイル）・イベント配線（`+=` / `Handles` 句）・
> 起動点（`static void Main` / `Application.myapp`）がすべて違い、**同じ目印では数えられない**。

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴 16 件（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-csharp-winforms-adonet-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面項目・イベント・CRUD マトリクス・動的 SQL・自作 ORM 等） | `../specs/_appendix-csharp-winforms-adonet.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-handlers`/`list-sproc`/`sql-stores`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find のみで動く（追加のツールを要求しない）。
解析対象が大きいと 1 回の実行に時間がかかる（実測: .cs 4,378 本・約 145 万行で 1 サブコマンドあたり 25〜35 秒。Windows の Git Bash）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **外部 SQL 置き場の有無（Phase 0）。** `sql-stores` で SQL を含むコード以外のファイルを探し、
  見つけた拡張子を `00-ingestion/gate-config.env` に `SQL_STORE_GLOBS='*.sqld'` の形で書く（`gate-snippets.sh` が読む。環境変数で渡せばそちらが優先）。書かないと表が過少になり、Phase 4 の再実行でも同じ値が使われない。
- **ビルド対象外のファイルの扱い。** `ep-diff` が「ビルド対象外」と出した画面は、ディスクにあってもビルドされない。
  仕様化しないなら ADR で対象外と確定し、`observed-anomalies` に記録する（暗黙に除外しない）。
- **閉包の根に加えた外部基底の妥当性。** `ep-diff` の冒頭に出る基底名が本当にフォームの基底かを確認する。
- **表の定義側の正本。** DDL・`.xsd` が無く自作の ORM（表を表す基底クラス）が正本なら、派生型を数えて経路B にする。
  バイナリの `.mdf` しか無いなら経路B を `単一経路` にする。
- **呼ばれないストアドの扱い。** `list-sproc` で定義側にだけ出る手続きは、死蔵か動的呼び出しかを確かめてから処分する。
- **画面の共通基底クラスを画面ノードにするか。** 抽象基底フォームは継承閉包に入るが利用者が開く画面ではない。modules 側で扱うなら ADR に残す。
