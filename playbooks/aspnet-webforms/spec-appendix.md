# 仕様章立ての追補（aspnet-webforms）

ISO/IEC/IEEE 29148 準拠の章立て（GP-8）に対する、このスタック固有の追補。
汎用テンプレート（`specs/*/_template.md`）の節では表現しきれない要素だけを扱う。

- **対象スタック**: ASP.NET Web Forms（`.aspx` / `.ascx` ＋ C# / VB.NET のコードビハインド）

## 追加すべき節（カテゴリ別）

| カテゴリ | 追加する節 | 理由（このスタックで必要になるもの） | 密度の判定基準 |
|---------|----------|--------------------------------|--------------|
| behavior | 画面項目定義 | 項目の型・初期値・検証（`RequiredFieldValidator` 等）・Visible / Enabled はマークアップのサーバーコントロールの属性にあり、コードは一部しか持たない | 画面 1 つにつきサーバーコントロールの全数（ID 付き） |
| behavior | 画面イベント一覧（操作仕様） | 配線はマークアップの `On〜` 属性・VB の `Handles`・C# の `+=`・名前による自動配線（`Page_Load`）に分散する（DP-aspnet-webforms-3） | 画面 1 つにつき `list-handlers` の行の全数 |
| behavior | ページのライフサイクルと ViewState | 初回表示とポストバック（`IsPostBack`）で処理が分かれ、値は ViewState・Session・クエリ文字列で次の要求へ渡る | 画面 1 つにつき初回表示・各ポストバックの処理・保持する状態とその置き場所 |
| behavior | 画面遷移 | 遷移は `Response.Redirect` / `Server.Transfer` / `NavigateUrl` / `PostBackUrl` / メニュー定義（XML・サイトマップ）に分散し、クエリ文字列で値を渡す（DP-aspnet-webforms-2） | 遷移元・遷移先・渡す値（クエリ文字列のキー）・条件 |
| behavior | 共通部品（マスターページ・ユーザーコントロール） | 認証表示・メニュー・共通の検証がマスターページと埋め込みのコントロールにある | 部品 1 つにつき使う画面の一覧・公開プロパティ・イベント |
| data | 画面 × データソース × 表の対応 | `SqlDataSource` の SQL・`ObjectDataSource` の型とメソッドが画面とデータを直接つなぐ（DP-aspnet-webforms-4） | データソース 1 つにつき種類・SQL またはメソッド・パラメータの出どころ（コントロール・クエリ文字列・セッション） |
| data | ストアドプロシージャ | 処理本体が DB 側にあり、DB ヘルパー・DNN の `ObjectQualifier` 連結・`SqlDataSource` から呼ばれる | 手続き 1 つにつき引数・結果セット・更新する表・呼び出し元 |
| api | ハンドラ・サービス（`.ashx` / `.asmx` / `.svc` / `web.config` の handlers） | 画面以外の入口で、要求・応答の形式が型の外にある | 入口 1 つにつき URL・HTTP メソッド・入力・出力・認証 |
| modules | `web.config` の設定 | 認証・認可（`<authorization>` / `<location>`）・接続文字列・アプリ設定・URL の対応づけ・ハンドラ・モジュールが設定にある | 設定 1 つにつき値・効く範囲（`<location path>`）・読む箇所 |
| modules | 認証・認可 | フォーム認証・ロール（`<location>` の `<allow roles>` / `PrincipalPermission` / コード中の `IsInRole`）が設定とコードに分かれる | 画面 1 つにつきアクセスできるロール・未認証時の遷移先 |

## 記述方式の指定

同じ対象を複数の書き方で書くと横断突合ができなくなるため、方式を固定する。

- **画面 ID（`SCR-NN`）はマークアップのファイル名と 1 対 1 に対応させ、本文にファイル名（拡張子つき）を必ず書く**
  （`ManageArticles.aspx`。`idents-screen` の出力と `G-IDENT` で突合する。同じファイル名が別ディレクトリにあるときはパスで区別する）。
- **引用は `path:line` で書く**（マークアップの項目はマークアップの行、処理はコードビハインドの行）。
- **操作は「コントロール ID.イベント → ハンドラ」の形で 1 行ずつ書く**（`btnSave.Click → btnSave_Click`）。自動配線は `Page.Load → Page_Load` と書く。
- **表は物理名で書き、綴りは `idents-table` の出力に合わせる**。ストアドプロシージャは `idents-proc` の綴りで書く（`G-IDENT` は大小を区別して突合する）。
- **画面遷移は mermaid `stateDiagram` で書き、ノード ID を画面 ID と一致させる**（統合画面遷移図のノード数 = 画面数の突合。GP-14 ルール6）。

## このスタックで静的読解が効かない箇所（SB-6 の具体化）

- **名前を組み立てて読み込む画面**: `LoadControl("Pages/" + name + ".ascx")`・列挙型の名前からパスを作る形（実測 YAF）・
  DNN の `ControlKey` から決まる画面は、読み込み側の規則と取りうる値を列挙する（`ep-diff` の「名前を組み立てて読み込む箇所」）。
- **ホストが提供する画面・コントロール**: DNN 等のモジュールは、ホストの `Default.aspx`・`~/controls/*.ascx` の上で動く。
  ホスト側の動作（タブ・権限・モジュールの設定）は断面外として扱い、モジュールが依存する点だけを書く。
- **動的に作るコントロール**: `Controls.Add(LoadControl(...))` / `new TextBox()` で実行時に作る項目はマークアップに無い。生成規則を書く。
- **データバインド式**: `<%# Eval("X") %>` の列・書式は実行時のデータ源で決まる。バインド元のデータソースと列名を書く。
- **マークアップの中のサーバーコード**: `<% ... %>` / `<script runat="server">` の中は、コードの走査（`.cs` / `.vb` の字句解析）が読まない。
  `inline-code` で場所を出し、中身を手で読む。
- **URL の書き換え・ルーティング**: `web.config` の `<urlMappings>`・URL 書き換えの規則・`MapPageRoute` の URL は実在のファイルではない。
  外部に見える URL と実際の画面の対応表を書く。
- **接続先・テーブル名の接頭辞**: DNN の `{objectQualifier}`・ORM の表名の接頭辞（実測 YAF: `yaf_`）は設定で決まり、コードからは物理名が決まらない。
