# 列挙の独立ソース表（aspnet-webforms / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて OSS 4 件で実測検証済み（2026-10-23）:
  ERPSYS_WebForms（ERP。C#・Web アプリケーション・ストアドプロシージャ中心。.aspx 350 本・.ascx 117 本・.cs 1,139 本）
  YAF.NET v3.2.17（掲示板。C#・画面を .ascx で動的に読み込む・OrmLite のコードファースト。ServiceStack と Lucene.Net のソースを同梱）
  TheBeerHouse VB 版（CMS とネットショップ。VB・Web サイト プロジェクト・ObjectDataSource・ストアドプロシージャ。.aspx 50 本）
  Property Agent（物件管理。VB・DNN のモジュール・.SqlDataProvider のスクリプト 90 本）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: ASP.NET Web Forms（.NET Framework 2.0〜4.x）。画面は `.aspx` / `.ascx` ＋ C# または VB.NET のコードビハインド。
  DB アクセスは ADO.NET 直接・ストアドプロシージャ・`SqlDataSource` / `ObjectDataSource`・DNN のデータプロバイダー・コードファーストの ORM。
- **適用判定**: 次の 2 つがどちらも 1 件以上。
  `find <src> \( -iname '*.aspx' -o -iname '*.ascx' \) -not -path '*/obj/*' | head` ／
  `grep -rliE '<%@[ ]*(Page|Control)' <src> --include='*.aspx' --include='*.ascx' | head`

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **バイト列で走査する（`LC_ALL=C`）。** .NET の資産は UTF-8（BOM 有無）・ANSI コードページ・UTF-16 が混在する
   （実測 TheBeerHouse: `App_Data/CreateAllObjects.sql` が UTF-16）。`gate-snippets.sh` は先頭で `LC_ALL=C` を固定し、UTF-16 は NUL を落として読む。
2. **断面の境界を先に決める（Phase 0）。** 同梱した第三者ライブラリのソース・テストコード・事前コンパイルの写し・ホスト（DNN 等）は
   アプリではない。`scope` で数え、`00-ingestion/gate-config.env` の `SCAN_EXCLUDE` に書く（落とし穴 3・4）。
3. **パスは解析対象からの相対（`./` 始まり）で出る。** そのまま `path:line` の引用に使える。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | 実在する `.csproj` / `.vbproj` ＋ プロジェクトファイルの無い Web サイト（`web.config` のある最上位のディレクトリ） | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（`.sln` / `.slnx` の宣言と両方向） | 実在数 = MOD ノード数。宣言との差は全件を説明する |
| NODE-EP（画面） | Page ディレクティブを持つ `.aspx` ＋ コードビハインドの基底が「〜Page」「〜ModuleBase」「〜SettingsBase」で終わる `.ascx` | `list-ep` の `page` / `control-page` 行 / 突合 `ep-diff`（名指しされる画面と両方向） | 画面数 = EP 画面ノード数 ＋ 死蔵・部品の誤分類（ADR で処分） |
| NODE-EP（ハンドラ・サービス・開始） | `.ashx`・`.asmx` / `.svc`・`Global.asax`・`web.config` の `<httpHandlers>` / `<handlers>` の登録 | `list-ep` の `handler` / `service` / `startup` / `confighandler` 行 | 件数 = 対応 EP ノード数（`confighandler` の組み込み `*.axd` 等は ADR で処分） |
| NODE-BND（DB: 参照側） | コードの SQL 文字列リテラル ＋ マークアップの `SqlDataSource` の SQL ＋ `*.sql` / `*.SqlDataProvider` / `SQL_STORE_GLOBS` ＋ コードファーストの ORM の型を使う箇所 | `bnd` / 一覧 `list-bnd` | 参照表数 = BND 表ノード数 ＋ 対象外（ビュー・一時表・別 DB を ADR で処分） |
| NODE-BND（DB: 定義側） | DDL（`CREATE TABLE`）・型付き DataSet（`.xsd`）・`.dbml`・`.edmx`・`[Table]` / `[Alias]` 属性・`CreateTable<T>` / `DbSet<T>` | `bnd-schema` / 突合 `bnd-diff` | 定義表数 = 参照表数 ＋ 未参照（死蔵）− 定義の無い参照（全件説明） |
| NODE-BND（DB: ストアド） | 呼び出し側（`CommandType.StoredProcedure`・DB ヘルパー経由・DNN の `ObjectQualifier` 連結・`SqlDataSource` の `CommandType`・`EXEC`）と定義側（`CREATE PROC`） | `list-sproc` / 識別子 `idents-proc` | 呼び出し側の名前集合と定義側の名前集合を両方向で突合 |
| （画面の子）データソース | マークアップの `SqlDataSource` / `ObjectDataSource` / `EntityDataSource` / `LinqDataSource` / `AccessDataSource` | `list-datasources` | 画面とデータをつなぐ分母（`ObjectDataSource` は型とメソッドの先まで辿る） |
| （画面の子）イベント配線 | マークアップの `On〜` 属性・VB の `Handles`・`+=` / `AddHandler`・名前による自動配線（`Page_Load` 等） | `list-handlers` | 画面仕様の操作の分母（EP ノードではない） |
| （エッジ）遷移・埋め込み | マークアップの属性・データバインド式・コードの文字列・メニュー定義（XML・`Web.sitemap`）・`web.config`・クライアントスクリプト | `list-refs`（`embed` / `master` は埋め込み、それ以外は遷移） | 画面遷移の分母（`dynamic` の行は規則と値を手で補う） |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は ERPSYS / YAF / TheBeerHouse / Property Agent の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① 利用者が開く画面: `.aspx`（Page ディレクティブ）と、**ホストが画面として読み込む `.ascx`** ② 画面以外の要求の入口: `.ashx`・`.asmx` / `.svc`・`web.config` の handlers に登録したクラス ③ アプリの開始: `Global.asax` | **3 系統。単一ではない。** ①は**`.aspx` だけを数えると `.ascx` の画面を全部落とす**（実測 YAF: `.aspx` 3 本に対し `.ascx` の画面 104 本。Property Agent: `.aspx` 1 本に対し 43 本）。`gate-snippets.sh` はコードビハインドの基底の名前（「〜Page」「〜ModuleBase」「〜SettingsBase」）で判定し、`list-controls` で確かめさせる。②は**ファイルの無い仮想のハンドラ**がある（`web.config` にクラスで登録）。重複はマークアップのパスで取る |
| NODE-BND | ① コードの SQL 文字列リテラル ② マークアップの `SqlDataSource` の SQL ③ SQL ファイル（`.sql`・DNN の `.SqlDataProvider`）④ コードファーストの ORM（`CreateTable<T>` / `DbSet<T>` とその型の使用）⑤ スキーマ定義（DDL・`.xsd`・`.edmx`）⑥ ストアドプロシージャ | **6 系統。単一ではない。** ①だけを見ると**ストアドの中でしか触らない表**と**ORM の表**を全部落とす（実測 ERPSYS: 表を参照する SQL はコードに無く、ストアドの呼び出し 606 か所だけ。YAF: 表は OrmLite の型で、SQL は移行用のスクリプトにしか無い）。①〜④と⑤は表名で `comm` を取り、両方向の差を全件説明する |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（ERPSYS）では画面が「経路A 350 / 経路B 296」で、経路B を**メニュー定義の XML を読まずに**取った版は 257 だった。
> XML を読んで 296 になり、経路A のみの 54 のうち 24 が `obsolete/` の下に残った（落とし穴 8）。

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
| NODE-MOD | 実在する `.csproj` / `.vbproj` ＋ プロジェクトファイルの無い Web サイトの全数（`mod`） | 全 `.sln` の `Project(...)` 行・`.slnx` の `<Project Path=>` が指すプロジェクトと Web サイト（`mod-diff`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（ソリューション未登録・参照切れ・IIS 上の Web サイトの別）>` |
| NODE-EP | **画面・マークアップ側**: Page ディレクティブを持つ `.aspx` ＋ 画面として読み込まれる `.ascx`（`ep-diff` 経路A） | **名指しされる画面**: 遷移（属性・データバインド式）・コードの文字列・メニュー定義・`web.config`・クライアントスクリプトから解決した画面（`ep-diff` 経路B。埋め込み・マスターは除く） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（死蔵・名前を組み立てて読み込む・外から直接開く・部品の誤分類の別）>` |
| NODE-BND | **DB 表・参照側**: SQL リテラル ＋ `SqlDataSource` ＋ SQL ファイル ＋ ORM の型の使用が参照する表名（`list-bnd`） | **定義側**: DDL・`.xsd`・`.dbml`・`.edmx`・`[Table]` / `[Alias]` 属性・`CreateTable<T>` / `DbSet<T>` の表名（`bnd-schema`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（ビュー・一時表・別 DB・接頭辞の違い・死蔵の別）>` |

- **`NODE-EP` の 2 経路は画面について取る。** ハンドラ・サービス・開始は件数が小さく（実測: 0〜6 件）、実行記録の行で全件を列挙して突合する。
- **経路B（名指しされる画面）は経路A より少ないのが普通**（名前を組み立てて読み込む・外から直接開く画面がある）。
  **経路A のみの画面を分母から外さない。** 1 件ずつ原因を書き、対象外にするものは ADR で処分する（実測: ERPSYS 54・YAF 103・
  TheBeerHouse 2・Property Agent 2）。
- **定義側（スキーマ）がソースに無い場合**（ストアドプロシージャだけ・バイナリの `.mdf`・別リポジトリ）は、`NODE-BND` の経路B の
  定義欄を「単一経路（スキーマがソースに無い）」に書き換え、差分欄に理由を書く（`G-ENUM-SOURCE` が理由の記入を検査する）。
  実測 ERPSYS がこれに当たる（定義側 0 件・ストアドの定義も 0 件）。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**表名が SQL 文字列・ストアドの中にしか無く、画面とデータの対応がマークアップの文字列（型名・メソッド名）でつながる**ため、
「画面の処理は書いたが、どの表・手続きを使うかは書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `table` | **物理テーブル名**（参照側 ∪ 定義側。表ごとに最も多く現れた綴り） | `bash 03-audit/gate-snippets.sh idents-table <src>` |
| `screen` | **画面のファイル名**（`ManageArticles.aspx` のように拡張子つき。綴りどおり） | `bash 03-audit/gate-snippets.sh idents-screen <src>` |
| `proc` | **ストアドプロシージャ名**（呼び出し側 ∪ 定義側） | `bash 03-audit/gate-snippets.sh idents-proc <src>` |

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。

1. **文字コードの混在（`LC_ALL=C`）。** 前提 1 を参照。UTF-16 の `.sql` は素の grep で 1 件も拾えない（実測 TheBeerHouse: 表の定義 26 件がすべて UTF-16 のファイルにある）。
2. **C# と VB.NET の両方を読む。** Web Forms のコードビハインドはどちらの言語でもよく、1 つのアプリで混在もする。
   `gate-snippets.sh` は `.cs` と `.vb` の両方を字句解析（コメント・文字列・`#if false`）してから数える。
3. **同梱した第三者ライブラリのソース。** 実測 YAF: `.cs` 3,438 本のうち 2,056 本が ServiceStack（ORM）と Lucene.Net（検索エンジン）の
   ソース。数えるとプロジェクトが 25（外すと 15）、参照される表が 104（外すと 77）になり、PostgreSQL のシステム表（`pg_class` 等）まで表に化けた。
   `scope` で見つけ、`SCAN_EXCLUDE='^\./yafsrc/(Lucene\.Net|ServiceStack)/'` の形で外す。**テストコード**（`tests/`）にも表名に化ける文字列が
   ある（実測 YAF: `a` / `me` / `Win32_Process`）——外すかどうかを ADR で決める。
4. **事前コンパイルした配備用の写し。** `PrecompiledApp.config` のあるディレクトリは `aspnet_compiler` の出力で、「更新可能」の形では
   `.aspx` が残る（コードは `bin/` の DLL）。実測 TheBeerHouse: `TBH_Deploy/` の下に `.aspx` 50 本の写しがあり、数えると画面が 2 倍・
   Web サイトが 4 つになった。`gate-snippets.sh` は自動で外す（「更新不可」の形の中身の無い印のファイルも画面に数えない）。
5. **プロジェクトの作り方が 2 通りある。** Web アプリケーション（`.csproj` / `.vbproj`・`CodeBehind=`）と Web サイト（プロジェクトファイルが無く、
   `.sln` の `Project(...)` 行がディレクトリを指す・`CodeFile=`・`App_Code/`）。実測: ERPSYS は前者、TheBeerHouse は後者（`TBH_Web/`）。
   `list-mod` は Web サイトを `website` として数える（`web.config` のある最上位のディレクトリ。下の `Admin/web.config` は別のサイトにしない）。
6. **HTML の注釈の中のサーバーコントロールは生きている。** ASP.NET が読まないのは `<%-- --%>` だけで、`<!-- -->` の中の `runat="server"` の
   タグは実行される。`gate-snippets.sh` は `<%-- --%>` だけを捨てる（注釈の中のデータソース・配線は数える）。ただし `<!-- -->` の中の
   **リンク・式・サーバーコントロールの `NavigateUrl`** は描画先が注釈の中でブラウザが表示しないので、遷移に数えない。`<script>` / `<style>` の中身はタグとして読まない（`if (a<b)` の `<b` をタグの始まりと読むと、閉じない引用符で以降の
   ファイル全体が 1 つのタグに呑まれる。反証レビューで実証）——中の `<% %>` は読み、遷移先はクライアントスクリプトの走査で拾う。
   自分で閉じた `<script src="a.js" />` は中身を持たないので読み飛ばさない。HTML の注釈の中の `<script>` は `</script` か注釈の終わりの早い方まで
   読み飛ばす。クライアントスクリプトの走査（遷移先を拾う）も、スクリプトの外の HTML の注釈を外し、`<script ... />` ではスクリプトを始めない。
7. **画面として読み込まれる `.ascx`。** ホスト（DNN）やアプリ（YAF）が `.ascx` を画面として動的に読み込む。`.aspx` だけを数えると
   画面の大半が消える（落とし穴は NODE-EP の系統①）。コードビハインドの基底の名前（YAF の `ForumPage`・DNN の `PortalModuleBase` と
   設定画面の `ModuleSettingsBase`）で判定する（実測 Property Agent: 設定画面 3 つを入れて 43）。
   部品（`UserControl` 派生）と画面の境は基底の名前の規則に頼るので、`list-controls` で埋め込みの参照数と照らす。
8. **遷移先は 4 か所に分かれる。** マークアップの属性（`NavigateUrl` / `PostBackUrl` / `href`）、**データバインド式**
   （`NavigateUrl='<%# "~/ShowArticle.aspx?ID=" & Eval("ID") %>'`）、コードの文字列（`Response.Redirect` / `LoadControl`）、
   **メニュー定義**（実測 ERPSYS: 役割ごとの XML 12 本を `RadMenu.LoadContentFile` で読む）と**クライアントスクリプト**（実測 ERPSYS:
   `Controls/DialogBox/` の画面は JavaScript の URL でしか名指しされない）。メニューの XML を読まない経路B は ERPSYS で 257、
   読むと 296。**遷移ではないものを読まない**: 変換ウィザードのログ（`UpgradeWizardLog.xml`。全ファイルの名前を並べる。実測 ERPSYS: 1 本で 1,541 件）、
   **XML の注釈の中の項目**（実測 ERPSYS: 注釈にしたメニュー項目が、画面 5 つを「名指しされる」側に入れ、存在しない画面 4 つを参照切れに見せていた）、
   **DNN のマニフェストの `<files>`**（配布ファイルの一覧。入口は DNN 3〜4 形式の `<src>` と、DNN 5 以降の `<controlSrc>`（拡張子 `.dnn5` 等も読む）。
   `<files>` を読むと Property Agent の全画面が「名指しされる」に化けた）、
   `<location path=>`（設定の範囲）。クライアントスクリプトは `.js` とマークアップの `<script>` を読むが、`scripts/`・`lib/`・`vendor/` 等の
   ディレクトリと `*.min.js`（ライブラリ）は読まない——アプリのスクリプトをそこに置く対象では、名指しされない画面が増えるので確かめる。
9. **パスの解決。** `~/` はアプリの根（`web.config`・`Global.asax`・DNN のマニフェストのある最上位のディレクトリ）から、相対パスは書いたファイルから
   解決する。ユーザーコントロールの中の相対パスは**使う側の画面から**の相対で書かれることがある（実測 ERPSYS: `UCHeader.ascx` の `../main/home.aspx`）。
   パスで一致しなければファイル名で引き、同じファイル名が複数あれば末尾のディレクトリ名が最も長く一致する候補に決める
   （実測 ERPSYS: `ItemSearch.aspx` が 4 か所にある）。**仮想の URL**（`web.config` の `<urlMappings>` の `url=`、実測 TheBeerHouse 6 件）・
   **URL 書き換えの規則**（`~/$1Default.aspx`・`error\.aspx`、実測 YAF 25 件）は実在のファイルではないので、それぞれ別に出す。
10. **ホストが提供する画面・コントロール。** DNN のモジュールの断面には、ホストの `~/controls/LabelControl.ascx` 等も `Default.aspx` も無い
    （実測 Property Agent: 5 種への埋め込みの参照 57 件、`Default.aspx` への文字列 8 件）。`ep-diff` の「参照先のファイルが無い」に出るので
    断面外として ADR で処分する。マニフェスト（`.dnn`）の `<src>` はモジュールの入口の画面を示す。
11. **イベント配線は 4 系統。** マークアップの `On〜` 属性・VB の `Handles`・`+=` / `AddHandler`・名前による自動配線。
    実測: ERPSYS（C#）は markup 1,188・auto 503・code 49、TheBeerHouse（VB）は handles 176・markup 5・code 1。
    `OnClientClick` と、runat の無い HTML タグの `onclick` はブラウザで動くので数えない。`+=` でメソッド名を渡す形は、同じ画面のファイル群で
    メソッドとして宣言された名前に限る（`lblMsg.Text += msg;` は文字列の連結。実測 ERPSYS で 1 件混入していた）。**限界**: 判定はファイル単位で、
    partial クラスの別のファイル・基底のページで宣言したハンドラを渡す `+=` は落ちる（`new EventHandler(...)` の形・マークアップの配線は拾える）。
12. **英文メッセージを SQL と誤認しない。** SQL 句の語で**始まる**リテラルだけを SQL と見なし、先頭語が「先頭だけ大文字」なら英文として除く
    （C# / VB の WinForms の Playbook と同じ判定）。マークアップの `SqlDataSource` の `SelectCommand` 等にも同じ判定を掛ける。
13. **ストアドプロシージャの名前の書き方。** DB ヘルパーの第 1 引数（実測 ERPSYS: `Dbhelper.ExecuteDataTable("PRD_...", p, CommandType.StoredProcedure)`）、
    `New SqlCommand("tbh_Articles_GetArticles", cn)`（実測 TheBeerHouse）、**DNN の `DatabaseOwner & ObjectQualifier & "名前"` の連結**
    （実測 Property Agent: `CommandType` を書かない `SqlHelper` に渡るので、`CommandType` を手掛かりにすると 0 件）、`SqlDataSource` の
    `SelectCommandType="StoredProcedure"`。定義側の `.SqlDataProvider` は `{databaseOwner}{objectQualifier}` の置換記号を外して読む。
    SQL ファイルの `--` と複数行の `/* */` は注釈として外すが、同じ行で閉じる文字列の中（`LIKE '/*%'`）は外さない（行をまたぐ文字列は追わない）。
    **SSMS の生成スクリプトは手続きの本体を `sp_executesql` の文字列に入れ、中の文字列を引用符 2 個で囲む**——外さないと文言の語が表に化ける
    （実測 TheBeerHouse: `RAISERROR` の文言の `of`）。
14. **コードファーストの ORM。** 表はクラスから作られ、DDL がソースに無い（実測 YAF: OrmLite の `CreateTable<User>()` が移行処理に 58 種）。
    `bnd-schema` は `CreateTable<T>` / `DbSet<T>` の型を表として数え、`list-bnd` はその型をジェネリック引数で使う箇所（`GetRepository<User>()`）を
    参照として数える。**物理名には設定の接頭辞が付く**（実測 YAF: 移行用の SQL スクリプトは `yaf_Forum` のように接頭辞つきで、型の名前は `Forum`）
    ——接頭辞の違いで経路A のみに出る表は差分欄で対応づける。
15. **コードビハインドの無い画面・マークアップの中のサーバーコード。** `<% ... %>` / `<script runat="server">` の中はコードの字句解析が読まない。
    `inline-code` で場所を出す（実測: ERPSYS 1 画面に 3 か所——クライアントスクリプトの中の `<%-- --%>`（18 ファイルにある、注釈にした旧コード）は数えない、TheBeerHouse は `Global.asax` の
    `<script runat="server">`、YAF 1 か所、Property Agent 0）。`ep-diff` は `CodeBehind=` / `CodeFile=` の指すファイルが無い画面も出す。
16. **表名の綴りは大小が揺れる。仕様は `idents-table` の綴りで書く。** `G-IDENT` は大小を区別して突合するので、表ごとに最も多く現れた綴りを出す。
    画面は `idents-screen`（ファイル名の綴りどおり）、手続きは `idents-proc` で出る。

### 作成時の検証記録（このファイルのコマンドを OSS で走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（実在 / 宣言） | 画面（経路A / 経路B） | ハンドラ・サービス・開始 | 表（参照側 / 定義側） | ストアド（呼び出し箇所 / 定義） | 配線 | 備考 |
|---|---|---|---|---|---|---|---|
| ERPSYS | 1 / 1 | 350 / 296（A のみ 54。うち `obsolete/` の下 24） | 4 / 1 / 1（＋ config 5） | 2 / 0 | 606 / 0 | 1,740 | 表を参照する SQL はコードに無い（コメントアウトだけ）。DDL・ストアドの定義もソースに無い。メニューが存在しない画面 2 つを指す（参照 6 か所） |
| YAF（同梱ライブラリを除外） | 15 / 20（実在のみ 5＝ソリューションに載らない DB 別のプロジェクト等・宣言のみ 10＝除外した同梱ライブラリ） | 107 / 4（A のみ 103＝名前を組み立てて読み込む） | 0 / 0 / 1 | 77 / 59（A のみ 19・B のみ 1） | 2 / 0 | 629 | 除外しない場合: MOD 25、表 104 / 64。`.ascx` の画面 104 |
| TheBeerHouse | 2 / 2 | 50 / 48（A のみ 2＝同梱のエディタ部品） | 0 / 0 / 1 | 25 / 26（B のみ 1＝`sysdiagrams`） | 98 / 155 | 182 | 配備用の写し `TBH_Deploy/` を自動で除外。データソース 129 行 |
| Property Agent | 2 / 0（`.sln` 無し） | 44 / 42（A のみ 2＝マニフェストの `<src>` に無い `Options.ascx`・`Template.ascx`） | 3 / 1 / 0 | 20 / 18（A のみ 3・B のみ 1） | 79 / 242 | 270 | ホストのコントロールへの参照 57 件が断面外。`.ascx` の画面 43（設定画面 3 を含む） |

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# ビルド出力・NuGet パッケージ・VS のキャッシュ・事前コンパイルの写しを除く（この Playbook の列挙と同じ除外にそろえる）
SOURCE_EXCLUDE='(^|/)(bin|obj|packages|[.]vs)/'
```

**入れないとどうなるか**: `obj/` には `*.designer.cs` の生成コピーが、配備用の写しには同名の `.aspx` が入り、
basename の引用が「候補複数」で解決できなくなる。`SCAN_EXCLUDE` に入れたディレクトリも `SOURCE_EXCLUDE` にそろえる。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 350 画面を 30 の業務単位にまとめる）、
**独立ソース側には 350 を書き、ノード登録数に 30 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。ソリューション未登録・Web サイト・断面外を明示>` | `<YYYY-MM-DD>` |
| NODE-EP（画面） | `<N>` | `<M>` | `<同上。死蔵・部品の誤分類・ホストが提供する画面を明示>` | `<YYYY-MM-DD>` |
| NODE-EP（ハンドラ・サービス・開始） | `<N>` | `<M>` | `<同上。組み込みのハンドラ（*.axd）の扱いを明示>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。ビュー・一時表・別 DB・接頭辞・ストアドだけの対象・同梱ライブラリの除外を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
