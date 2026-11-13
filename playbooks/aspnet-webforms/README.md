# Playbook: `aspnet-webforms`

ASP.NET Web Forms（`.aspx` / `.ascx` ＋ C# または VB.NET のコードビハインド）の業務 Web アプリを対象とする Playbook。
実測検証: ERPSYS_WebForms（C#・Web アプリケーション・ストアドプロシージャ中心）・YAF.NET v3.2.17（C#・画面を `.ascx` で動的に読み込む・
OrmLite のコードファースト）・TheBeerHouse VB 版（VB・Web サイト・ObjectDataSource）・Property Agent（VB・DNN のモジュール）（2026-10-23）。

## 対象スタック

- **言語/実行基盤**: C# / VB.NET、.NET Framework 2.0〜4.x の ASP.NET Web Forms（IIS 上の Web アプリケーション・Web サイト）
- **エントリポイント**: `.aspx`（ページ）・ホストが画面として読み込む `.ascx`（DNN のモジュール・YAF のページ等）・
  `.ashx`（ハンドラ）・`.asmx` / `.svc`（サービス）・`Global.asax`（アプリの開始）・`web.config` のハンドラ登録
- **画面**: マークアップ（サーバーコントロール・マスターページ・ユーザーコントロール）＋ コードビハインド（`CodeBehind=` / `CodeFile=`）
- **永続化**: ADO.NET 直接・ストアドプロシージャ・`SqlDataSource` / `ObjectDataSource`・型付き DataSet・
  DNN のデータプロバイダー（`.SqlDataProvider`）・コードファーストの ORM（`CreateTable<T>` / `DbSet<T>`）

## 適用判定（この Playbook を選ぶべきか）

```bash
find <source> \( -iname '*.aspx' -o -iname '*.ascx' \) -not -path '*/obj/*' | head      # 1 件以上
grep -rliE '<%@[ ]*(Page|Control)' <source> --include='*.aspx' --include='*.ascx' | head  # 1 件以上
```

- ✅ **該当**: どちらも 1 件以上（C# と VB.NET のどちらでも、混在していてもよい。この Playbook は両方の字句を読む）
- ❌ **非該当**:
  - 画面が Windows Forms（`.Designer.cs` / `.Designer.vb`）→ **`csharp-winforms-adonet` / `vbnet-winforms-adonet`**
  - ASP.NET MVC（`Controller` ＋ `.cshtml` / `.vbhtml`）・Razor Pages・Blazor → **未対応**（入口がコントローラーのアクションで、数え方が違う）
  - Web Forms と MVC が同居するアプリは、`.aspx` の画面だけをこの Playbook で数え、MVC の部分は `enumeration.md` に別の行を足して数える

> **Web Forms を C# と VB.NET で分けない理由**: 分母（画面・コントロール・データソース・遷移・`web.config`）は言語に依存しない
> マークアップの側にある。言語で違うのはコードビハインドの字句（コメント・文字列・継承・イベント配線）だけで、
> `gate-snippets.sh` は `.cs` と `.vb` の両方を字句解析してから数える（Windows Forms では画面の定義そのものが言語で書かれるので分けている）。

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴 16 件（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-aspnet-webforms-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面のライフサイクル・ViewState・ポストバック・データソース・遷移） | `../specs/_appendix-aspnet-webforms.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-refs`/`list-controls`/`list-handlers`/`list-datasources`/`list-sproc`/`inline-code`/`scope`/`sql-stores`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find / xargs のみで動く（追加のツールを要求しない）。
1 サブコマンドあたりの所要時間の実測: `.aspx` / `.ascx` 50〜470 本・`.cs` / `.vb` 120〜1,400 本で 5〜115 秒（Windows の Git Bash。4 対象を同時に走らせた値。
`bnd-diff` / `idents-table` は内部で 2 回走査し、`list-refs` / `list-controls` / `ep-diff` は参照を全部解決するので長い）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **同梱した第三者ライブラリのソース（Phase 0）。** `scope` でディレクトリごとの件数を見て、ORM・検索エンジン等のソースを丸ごと
  入れたディレクトリを `00-ingestion/gate-config.env` に `SCAN_EXCLUDE='^\./src/(ServiceStack|Lucene\.Net)/'` の形で書く
  （`gate-snippets.sh` が読む。環境変数で渡せばそちらが優先）。外したものは ADR で処分する。
- **外部 SQL 置き場の有無（Phase 0）。** `sql-stores` で SQL を含むコード以外のファイルを探し、見つけた拡張子を
  `SQL_STORE_GLOBS='*.sqld'` の形で書く（`.sql` と DNN の `.SqlDataProvider` は既定で読む）。
- **画面として読み込まれる `.ascx` の判定。** `gate-snippets.sh` はコードビハインドの基底が「〜Page」「〜ModuleBase」「〜SettingsBase」で終わる
  `.ascx` を画面に数える（`list-ep` の `control-page`）。`list-controls` で、画面でない部品が入っていないか・画面が部品に入っていないかを確かめる。
- **ホスト（DNN 等）が提供する画面・コントロール。** モジュールの断面にはホストの `~/controls/*.ascx` や `Default.aspx` が無い。
  `ep-diff` の「参照先のファイルが無い」に出るので、断面外として ADR で処分する。
- **表の定義側の正本。** DDL がソースに無い（ストアドプロシージャだけ・バイナリの `.mdf`・別リポジトリ）なら経路B を `単一経路` にする。
  ストアドプロシージャしか見えない対象では、手続き（`idents-proc`）をデータ境界の分母として扱うかを決める。
- **事前コンパイルの写し・配備用のディレクトリ。** `PrecompiledApp.config` のあるディレクトリは自動で除く。それ以外の配備用の写し
  （手で置いた `Deploy/` 等）は `SCAN_EXCLUDE` に入れる。
