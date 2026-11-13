# 列挙の独立ソース表（vbnet-winforms-adonet / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて OSS 2 件で実測検証済み（2026-10-22）:
  Apskaita5（VB.NET の会計システム。14 プロジェクト・.vb 1,118 本・約 52 万行）
  School-Management-System（VB.NET ＋ DevExpress ＋ SQL Server。1 プロジェクト・.vb 95 本）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: VB.NET（.NET Framework 2.0〜4.x / .NET 5 以降）の Windows Forms デスクトップアプリ。
  DB アクセスは ADO.NET を直接使う（`SqlCommand` / `OleDbCommand` / `MySqlCommand` 等に SQL 文字列を渡す・ストアド呼び出し・型付き DataSet）。
- **適用判定**: 次の 2 つがどちらも 1 件以上。
  `find <src> -iname '*.vbproj' -not -path '*/obj/*' | head` ／
  `grep -rliE '<SubType>Form</SubType>|System\.Windows\.Forms|<UseWindowsForms>true' <src> --include='*.vbproj' | head`
  （C# が主体なら `csharp-winforms-adonet` を使う。混在時の扱いは README を参照）

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **バイト列で走査する（`LC_ALL=C`）。** VB.NET の業務アプリは UTF-8（BOM 有無）・ANSI コードページ・UTF-16 が混在する。
   実測: Apskaita5 は .vb 1,118 本中 BOM 付き 1,108 本・UTF-8 として不正 10 本、School は 95 本中 BOM 付き 9 本・不正 2 本。
   UTF-8 ロケールの awk / grep は不正バイトで**黙って行を落とす**（0 件ではなく「少ない件数」が出るので気づけない）。
   `gate-snippets.sh` は先頭で `LC_ALL=C` を固定している。**手で走査するときも同じにする。**
2. **大文字小文字を区別しない。** VB はキーワード・識別子・ファイル名の大小を区別しない。
   実測（School）: `frmlogin.designer.vb` が小文字。`-name '*.Designer.vb'` では落ちる。照合は小文字化してから行う。
3. **パスは解析対象からの相対（`./` 始まり）で出る。** そのまま `path:line` の引用に使える。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | 実在する `.vbproj`（ビルド単位） | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（`.sln` の宣言と両方向） | 実在数 = MOD ノード数。`.sln` 宣言との差は全件を説明する |
| NODE-EP（画面） | `Form` 派生クラスを宣言する非 Designer ファイル（継承閉包） | `list-ep` の `screen` 行 / 突合 `ep-diff`（`.vbproj` の `SubType=Form` と両方向） | 画面数 = EP 画面ノード数 ＋ ビルド対象外（ADR で処分） |
| NODE-EP（起動点） | `OutputType` が `WinExe` / `Exe` のプロジェクト | `list-ep` の `startup` 行（`StartupObject` と `Application.myapp` の `MainForm` を併記） | 実行ファイル数 = 起動点ノード数 |
| NODE-EP（サービス入口） | `ServiceBase` / `MarshalByRefObject` / `WebService` 派生、`<WebMethod>` / `<ServiceContract>` / `<OperationContract>` を持つファイル | `list-ep` の `service` 行 | サービス入口数 = 対応 EP ノード数 |
| NODE-BND（DB: 参照側） | コード中の SQL 文字列リテラル ＋ `*.sql` ＋ 外部 SQL 置き場（`SQL_STORE_GLOBS`）が参照する表名 | `bnd` / 一覧 `list-bnd` | 参照表数 = BND 表ノード数 ＋ 対象外（ビュー・一時表・別 DB を ADR で処分） |
| NODE-BND（DB: 定義側） | DDL（`*.sql` / コード中の `CREATE TABLE`）・型付き DataSet（`.xsd` の `DbObjectName`）・LINQ to SQL（`.dbml`）・EF（`.edmx` / `<Table>` 属性） | `bnd-schema` / 突合 `bnd-diff` | 定義表数 = 参照表数 ＋ 未参照（死蔵）− 定義の無い参照（全件説明） |
| NODE-BND（DB: ストアド） | 呼び出し側（`CommandType.StoredProcedure`・DB ヘルパー経由・`EXEC`）と定義側（`CREATE PROC`） | `list-sproc` | 呼び出し側の名前集合と定義側の名前集合を両方向で突合 |
| NODE-BND（その他） | ファイル・COM（`CreateObject`）・Win32 API（`Declare` / `<DllImport>`）・帳票（`.rdlc` / Crystal）・Office 連携・レジストリ・ネットワーク | `grep -rliE 'CreateObject\|Declare (Function\|Sub)\|DllImport\|Microsoft\.Office\|ReportViewer\|CrystalDecisions\|Registry\.\|WebClient\|HttpWebRequest\|TcpClient\|IO\.File' <src> --include='*.vb'` | 種別ごとに全ファイルを列挙して境界ノードに対応づける |
| （画面の子）イベント配線 | `Handles` 句・`AddHandler` の（画面, イベント元, ハンドラ）の対 | `list-handlers`（4 列目が `screen` の行） | 画面仕様の操作の分母（密度の突合に使う。EP ノードではない） |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は Apskaita5 / School の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① 利用者が操作する型: `Form` 派生（**外部部品の基底フォーム経由を含む**。DevExpress の `XtraForm` 等）② プロセス起動の型: 実行ファイルのプロジェクト（起動対象は `StartupObject` または `Application.myapp` の `MainForm`）③ 外部から呼ばれる型: Windows サービス・Remoting・ASMX・WCF | **3 系統。単一ではない。** ①は**継承の根を `Form` に限ると外部基底の画面を全部落とす**（実測 School: 30 画面すべてが `XtraForm` 継承で、`Form` からの閉包は 0 件）。`gate-snippets.sh` は「ソースに宣言が無く綴りが `Form` で終わる基底」を根に加え、`ep-diff` の冒頭に列挙する（人が妥当性を確認する）。②は**`Sub Main` の有無で数えると落とす**（落とし穴 7）。重複はファイル単位で取る（同じファイルが①と③の両方になる例は 0 件だったが毎回確認する） |
| NODE-BND | ① コード中の SQL 文字列リテラルが参照する表 ② `*.sql` と外部 SQL 置き場が参照する表 ③ スキーマ定義（DDL・型付き DataSet・ORM 定義）にある表 ④ ストアドプロシージャ | **4 系統。単一ではない。** ①だけでは**名前付き SQL を外部ファイルに置く設計で表の大半を落とす**（実測 Apskaita5: ①で見える表は 3、`.sqld` を加えると 76。落とし穴 11）。①②と③は表名で `comm` を取り、両方向の差を全件説明する |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（School）では画面が「経路A 30 / 経路B 30」で一致したが、**一致したのは外部基底を根に入れた後**である。
> 根を `Form` に限った版では経路A が 0 件で、件数の差がそのまま定義の漏れを示した。

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
| NODE-MOD | 実在する `.vbproj` の全数（`mod`） | 全 `.sln` の `Project(...)` 宣言のうち `.vbproj` を指すもの（`mod-diff`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（.sln 未登録・参照切れの別）>` |
| NODE-EP | **画面・コード側**: 型宣言と `Inherits` から `Form`（＋外部基底）への継承閉包を取り、非 Designer ファイルで数える（`ep-diff` 経路A） | **プロジェクト側**: `.vbproj` の `<Compile>` に付いた `<SubType>Form</SubType>`（Designer 側は寄せる。`ep-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（ビルド対象外・外部基底・解析漏れの別）>` |
| NODE-BND | **DB 表・参照側**: SQL リテラル ＋ `*.sql` ＋ `SQL_STORE_GLOBS` が参照する表名（`list-bnd`） | **定義側**: DDL・`.xsd`・`.dbml`・`.edmx`・`<Table>` 属性の表名（`bnd-schema`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（ビュー・一時表・別 DB・死蔵の別）>` |

- **`NODE-EP` の 2 経路は画面について取る。** 起動点・サービス入口は件数が小さく（実測: 0〜3 件）、実行記録の行で全件を列挙して突合する。
- **定義側（スキーマ）がソースに無い場合**（`.mdf` 等のバイナリのみ・別リポジトリ・独自形式）は、`NODE-BND` の経路B の定義欄を
  「単一経路（スキーマがソースに無い）」に書き換え、差分欄に理由を書く（`G-ENUM-SOURCE` が理由の記入を検査する）。
  独自形式を手で数えられるならその件数を経路B にする（例: 独自 XML の表 67。コマンドは本文に書く）。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**表名が SQL 文字列の中にしか無い**ため、「画面の処理は書いたが、どの表を読み書きするかは書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `table` | **物理テーブル名**（参照側 ∪ 定義側。表ごとに最も多く現れた綴り。data 仕様から DDL を書くのに必須） | `bash 03-audit/gate-snippets.sh idents-table <src>` |
| `screen` | **画面のクラス名**（宣言どおりの綴り。behavior / modules 仕様で画面を特定するのに必須） | `bash 03-audit/gate-snippets.sh idents-screen <src>` |

> 外部 SQL 置き場がある対象では `00-ingestion/gate-config.env` に `SQL_STORE_GLOBS` を書く（書かないと `table` が過少になる）。

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。
実測値は特記の無いかぎり VB.NET の Apskaita5 / School。C# の OSS でだけ観測したものは「C# で実測」と書く（機構は VB.NET でも同じ）。

1. **文字コードの混在（`LC_ALL=C`）。** 前提 1 を参照。UTF-8 ロケールでは不正バイトの行が黙って落ちる。
2. **識別子は非 ASCII を許す。** 日本語・中国語のクラス名・コントロール名は普通にある。
   `[A-Za-z_][A-Za-z0-9_]*` で名前を切ると黙って落ちる（C# で実測: 中国語名の画面 2 件が消えた）。
   名前は「区切り文字以外の連続」で切る。
3. **大文字小文字の混在。** 前提 2 を参照（`frmlogin.designer.vb`）。キーワード（`Inherits` / `inherits`）も同じ。
4. **コメントと文字列を区別する。** `'` 以降はコメントだが、文字列 `"...'..."` の中の `'` はコメントではない。
   素の grep はコメントアウトされた旧ハンドラ・旧 SQL を数え、SQL の文字列値 `'abc'` で行の後半を切り落とす。
   `REM` は行頭だけでなく `:` の後（`x = 1 : REM ...`）でもコメント。`#If False Then` 〜 `#End If` の中も数えない。
   1 行に複数の文がある形（`Public Class F1 : Inherits Form`）と、行頭の属性（`<Serializable()> Public Class F2`）も読む。
   `gate-snippets.sh` は字句解析してから数える（いずれも反証レビューで「素の書き方では落ちる」ことを合成入力で実証した）。
5. **外部部品の基底フォーム。** 継承の根を `Form` に限ると、`XtraForm`（DevExpress）・`RadForm`（Telerik）等を継承した画面が全部落ちる。
   実測（School）: 30 画面すべてが `XtraForm` 継承で、`Form` からの閉包は 0 件。
   `gate-snippets.sh` は「ソースに宣言が無く、**宣言の綴りが `Form` で終わる**基底」を根に加え、`I` ＋大文字で始まるインタフェース名は除く
   （小文字の `form` で判定すると `ICryptoTransform` / `Transform` を実装・継承したクラスが画面になる。反証レビューで実証）。
   **加えた根は `ep-diff` が列挙するので人が確認する。**
6. **ファイルがあることとビルドされることは別。** 旧形式（`ToolsVersion`）の `.vbproj` は `<Compile Include>` の列挙がビルド対象の全数で、
   列挙に無いファイルはディスクにあってもビルドされない。SDK 形式（`<Project Sdk=`）は逆に既定で全ファイルを含み、`Remove` で外す。
   C# で実測: 旧形式のプロジェクトに無い `Form` 派生クラスが 21 件（OpenDental）・7 件（Estate）あり、`ep-diff` が「ビルド対象外」と判定した。
   **画面の単位はクラス**（`X.vb` と `X.Designer.vb`、partial の分割ファイルは 1 画面）。`SubType=Form` は Designer 側・分割ファイル側にも
   付くので、経路B もファイルが宣言するクラスに寄せて数える（実測 Apskaita5: `MainForm.Designer.vb` に SubType=Form。
   C# の OpenDental: ファイル単位 967 に対しクラス単位 964——`FormOpenDental` が 3 ファイルに分かれていた）。
7. **起動点は `Sub Main` では数えられない。** VB のアプリケーションフレームワークは起動フォームを
   `My Project/Application.myapp` の `<MainForm>` で宣言し、ソースに `Sub Main` が無い。
   実測（Apskaita5）: 実行ファイル 3 件のうち `Sub Main` を持つのは Windows サービスの 1 件だけ。
   逆に `Application.myapp` は**ライブラリにも置かれる**（同 12 件・`MainForm` は空）ので、myapp の数も起動点の数ではない。
   **`OutputType`（`WinExe` / `Exe`）で数え、起動対象は `StartupObject` と `MainForm` で特定する。**
   アプリケーションイベント（`ApplicationEvents.vb` の `Startup` / `UnhandledException`）は `list-handlers` のイベント元の列に `startup` として出る。
8. **イベント配線は画面ごとに数える。** 画面を跨いで `sort -u` すると、`Form_Load` のような同名ハンドラが潰れる。
   `list-handlers` は全ファイルの配線を出し、4 列目で画面（`screen`）とそれ以外（ユーザーコントロール・業務クラス等の `other`）を分ける。
   **画面仕様の操作の分母は `screen` の行だけ**（実測 Apskaita5: 全 797 のうち画面の配線は 631）。
   実測（画面の配線）: (画面, イベント元, ハンドラ) の対は School 299・Apskaita5 631。**ハンドラ名だけで全体を `sort -u` すると 180・388**（4 割減）。
   1 つのハンドラが `Handles a.Click, b.Click` で複数のイベントを受けるので、対はイベントごとに出す。
   行継続（` _`）で Handles 句が次の行に来る形も読む。
9. **英文メッセージを SQL と誤認しない。** 「`from` / `select` を含む文字列」を SQL と見なすと、
   `"Select the item from the list"` の `list` が表名に化ける。SQL 句の語で**始まる**リテラルだけを SQL と見なし、
   先頭語が「先頭だけ大文字」（`Select` / `From`）なら英文として除く。小文字で始まる英文（`"select an item from the list"`）は
   英文に特有の語（the / your / please / you）を含むことで除く（`an` は `FROM t4 an` のような別名ごとリテラルを消すので入れない。除外語を含まない英文——例: `select an item from list`——は通るので、参照側にしか無い表は差分欄で処分する）。**SQL の文字列値 `'...'` は先に消す**（`'From your friends'` の `your`）。
   C# で実測（OpenDental）: 「語を含む」判定 930 表 → この判定で 544 表。除いた側はほぼ英単語だった。
   **先頭語の判定はコード中のリテラルにだけ掛ける**（`.sql` の行は `FROM` 句が継続行に来るので掛けない。`--` コメントは除く）。
10. **UTF-16 の `.sql` / `.xml`。** SSMS の「スクリプト生成」は既定で UTF-16 LE を出し、VS が保存した XML も UTF-16 のことがある。
    素の grep は 1 件も拾わない。実測（School）: `.sql` の `CREATE TABLE` 13 件が 0 件に見えた。Apskaita5 のスキーマ定義 XML も UTF-16。
    `gate-snippets.sh` は BOM を見て NUL を落としてから読む（**非 ASCII の表名は崩れる**ので一覧で目視する）。
    **ソース本体（`.vb`）が UTF-16 の場合は字句解析が読めない（未対応）**。前提 1 の文字コード確認のときに
    先頭 2 バイトが `ff fe` / `fe ff` のファイル（`head -c 2 <file> | od -An -tx1` で確かめる）を探し、見つけたら UTF-8 に変換した写しを解析対象にする。
11. **SQL がコードに無いことがある（外部 SQL 置き場）。** 名前付き SQL を XML や独自拡張子のファイルに置き、コードは名前で引く設計がある。
    実測（Apskaita5）: コード中のリテラルから見える表は 3、`.sqld`（独自拡張子の XML）を加えると 76。
    **`sql-stores` で SQL を含むコード以外のファイルを拡張子別に探し**、見つけた拡張子を `00-ingestion/gate-config.env` に `SQL_STORE_GLOBS='*.sqld'` の形で書く（`gate-snippets.sh` が読む。Phase 4 の再実行でも同じ値が使われる）。
    `.resx`（リソース文字列）・`.config`・`.xml` も候補になる。
12. **`.sln` の宣言と実在のプロジェクトはずれる。** `.sln` にはソリューションフォルダ・セットアップ（`.vdproj`）・Web サイトも載り、
    参照切れ（ファイルが無い）も残る。実測（Apskaita5）: `.sln` 5 本の宣言 15 件に対し実在 14 件、`AccAdminPanel.vbproj` が参照切れ。
    `mod-diff` は拡張子で絞り、両方向の差を出す。**変換ウィザードの `Backup/`・試作フォルダの重複プロジェクト**も「.sln 未登録」に出る。
13. **システムカタログ・FK の動作句は表ではない。** SSMS の生成スクリプトは `sys.objects` / `sys.foreign_keys` を参照し、
    `ON DELETE CASCADE` の `CASCADE` は `delete` の後に来る。実測（School）: 除外前は 16 表、除外後 13 表（定義側と一致）。
14. **ストアドは DB ヘルパー越しに呼ばれる。** `DBHelper.Exec("proc", ...)` のように手続き名を引数で渡し、
    `CommandType.StoredProcedure` を設定するファイルには名前のリテラルが無い。C# で実測（Estate）: ヘルパーを辿らないと呼び出し 0 件、辿ると 31 箇所（一意 27）。
    `list-sproc` は「`StoredProcedure` を使うファイルが宣言する、先頭引数が `String` の Sub / Function」をヘルパーとみなして呼び出し側を辿る
    （VB.NET 版は合成フィクスチャで検証。実データの検証は未了——差が出たら `list-sproc` の出力と手の走査を突き合わせる）。
15. **表名の綴りは大小が揺れる。仕様は `idents-table` の綴りで書く。** SQL は表名の大小を区別しないので、同じ表が複数の綴りで書かれる
    （実測 Apskaita5: 外部 SQL 置き場を含めると 2 通り以上の綴りで現れる表が 34。C# の OpenDental では 18）。`gates.sh` の `G-IDENT` は**大小を区別して**
    `specs/` 本文と突合するため、`idents-table` は表ごとに最も多く現れた綴りを 1 つ出す。突合の分母（`list-bnd` / `bnd-diff`）は小文字に揃えて数える。
    画面名（`idents-screen`）は宣言どおりの綴りで出る（VB は大小を区別しないが、宣言の綴りが正本）。
16. **表名の切り出し: 別名・カンマ結合・角括弧・一時表。** `DELETE a FROM t a` の `a` は別名（表は `FROM` の後）。
    `FROM t1 a, t2 b` は 2 つ目以降の表も拾う（C# で実測 Estate: `FROM [dbo].[x],[dbo].[ZUIXINXIAOXI]` の 2 つ目を取りこぼしていた。11 → 12 表）。
    `[Order Details]` / `[Order]` のように角括弧で囲んだ名前は、空白を含んでも予約語でもそのまま表名にする。
    `CREATE TABLE #work` の一時表は定義側の表にしない。いずれも反証レビューで合成入力により実証した。

### 作成時の検証記録（このファイルのコマンドを OSS で走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（実在 / .sln 宣言） | 画面（経路A / 経路B。クラス単位） | 起動点 / サービス | 表（参照側 / 定義側） | 画面の配線の対（全体） | 備考 |
|---|---|---|---|---|---|---|
| School | 1 / 1 | 30 / 30（根に `xtraform`） | 1 / 0 | 13 / 13（差 0） | 299（300） | 定義側は UTF-16 の `.sql` |
| Apskaita5 | 14 / 15（参照切れ 1） | 156 / 156 | 3 / 1 | 3 / 4（`SQL_STORE_GLOBS='*.sqld'` で参照側 76） | 631（797） | スキーマは独自形式の XML（67 表）で `bnd-schema` の対象外 |

> Apskaita5 のように**スキーマが独自形式**の対象では、`bnd-schema` は定義側を拾えない。
> その形式を `sql-stores` 等で特定し、件数を手で数えて差分欄に「独自形式 N 表（コマンド: …）」と書く。

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# ビルド出力・NuGet パッケージ・VS のキャッシュを除く（この Playbook の列挙と同じ除外にそろえる）
SOURCE_EXCLUDE='(^|/)(bin|obj|packages|[.]vs)/'
```

**入れないとどうなるか**: `bin/` `obj/` には `*.Designer.vb` の生成コピーや `.resources` が入り、
basename の引用が「候補複数」で解決できなくなる。索引は 10% を超えると原因と対処を本文に書く。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 156 画面を 20 の業務単位にまとめる）、
**独立ソース側には 156 を書き、ノード登録数に 20 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。.sln 未登録・参照切れ・Backup を明示>` | `<YYYY-MM-DD>` |
| NODE-EP（画面） | `<N>` | `<M>` | `<同上。ビルド対象外・外部基底・抽象基底フォームを明示>` | `<YYYY-MM-DD>` |
| NODE-EP（起動点・サービス） | `<N>` | `<M>` | `<同上>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。ビュー・一時表・別 DB・外部 SQL 置き場の有無を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
