# 列挙の独立ソース表（vb6 / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて実在のソース 4 件で実測検証済み（2026-10-25）:
  PhotoDemon（画像編集ソフト。.vbp 5・フォーム 232・クラス 165・ユーザーコントロール 56。Win32 API の Declare が多い。DB は無い）
  pcgestion20（店舗の販売管理。.vbp 17・.vbg 5・ADO の SQL・表名だけの Open・写しのフォーム）
  erp_vb6（DAO と Access。VBA の UserForm を書き出したもので .vbp が無い）
  frei-vb6-projeto-vendas（販売の例。ADO・表名だけの Open）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: Visual Basic 6.0 のデスクトップアプリ。`.vbp` がメンバー（`.frm` / `.bas` / `.cls` / `.ctl` / `.dsr` / `.pag` / `.dob`）を宣言し、
  フォームのヘッダにコントロールが並び、`コントロール名_イベント名` の手続きが操作を受ける。DB は ADO / DAO / RDO に SQL 文字列か表名を渡す。
- **適用判定**: `find <src> \( -iname '*.vbp' -o -iname '*.frm' -o -iname '*.bas' -o -iname '*.cls' \) | head` と、
  同じファイルに `^VERSION [0-9]\.00` か `^Attribute VB_Name` があること（README の適用判定のコマンド。拡張子の大小を区別しない）。

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **バイト列で走査する（`LC_ALL=C`）。** VB6 のソースは ANSI（Windows-1252・Shift_JIS 等）と CRLF。`gate-snippets.sh` は先頭で `LC_ALL=C` を固定し、CR と BOM を外して読む。
2. **プロジェクトの境界を先に決める（Phase 0）。** 本体・部品（OCX）・試験用のプロジェクト・写しが並ぶ。`list-projects` と `scope` を見て `SCAN_EXCLUDE` で分ける（落とし穴 8）。
3. **パスは大小を区別しないキーで突き合わせる。** `.vbp` のパスは `\` 区切り・`..\` を含み、大小が実体と違うことがある。キーは小文字・`/` 区切り（`ep-diff` / `mod-diff` の出力は小文字）。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | ディスクのコードモジュール（`.bas` / `.cls` / `.ctl` / `.dsr` / `.pag` / `.dob`） | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（`.vbp` の宣言と両方向） | モジュール数 = MOD ノード数。どの `.vbp` にも入らないもの・ファイルの無い宣言は全件説明する |
| NODE-EP（画面・入口） | ディスクのフォーム（`VB.Form` / `VB.MDIForm` / VBA の UserForm）＋ 実行ファイルのプロジェクトの起動点 ＋ ActiveX の公開クラス | `ep` / 一覧 `list-ep` / 突合 `ep-diff`（`.vbp` の `Form=` と両方向） | 入口数 = EP ノード数。写し・試験用のフォームを外すなら ADR で処分 |
| NODE-BND（DB 表） | 参照側: SQL 文字列（文をまたぐ継ぎ足しを解く）・表名だけの `Open` / `OpenRecordset`・データコントロールの `RecordSource` ／ 定義側: `CREATE TABLE`・DAO の `CreateTableDef` | `bnd` / 一覧 `list-bnd` / 定義側 `bnd-schema` / 突合 `bnd-diff` / CRUD `list-crud` | 参照表数 = BND 表ノード数。定義がソースに無いときは単一経路として理由を書く |
| （画面の子）操作 | `コントロール名_イベント名` の手続き（control / form / withevents）。コントロールの無いもの（orphan）・照合できない UserForm（userform）を分ける | `list-handlers` | 画面仕様の操作の分母（EP ノードではない） |
| （画面の子）コントロール | フォームのヘッダの `Begin 型 名前`（コントロール配列の Index・RecordSource・DataSource） | `list-controls` | 画面仕様の項目の分母 |
| （モジュールの子）手続き | `Sub` / `Function` / `Property` / `Declare` / `Event` | `list-procs` | modules 仕様の公開の手続きの分母 |
| （外部境界） | `Declare` の Win32 API・`CreateObject` / `GetObject` の COM・`Open ... For` のファイル I/O・`Shell`・`.vbp` の `Reference=` / `Object=` | `list-external` / `list-refs` | 移行の依存の分母 |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は PhotoDemon / pcgestion20 / erp_vb6 / frei-vb6-projeto-vendas の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① 利用者が操作する型: VB のフォーム（`Begin VB.Form` / `VB.MDIForm`）② VBA から書き出したフォーム: `Begin {C62A69F0-...} 名前`（Microsoft Forms の UserForm）③ プロセス起動の型: 実行ファイルのプロジェクトの `Startup=` ④ 他のプログラムから呼ばれる型: ActiveX の公開クラス（`VB_Exposed = True`。`VB_Creatable = False` の PublicNotCreatable は外から作れないので除く） | **4 系統。単一ではない。** ①だけを見ると②を落とす（実測 erp_vb6: フォーム 17 がすべて UserForm で、`VB.Form` は 0）。①②は `.vbp` の `Form=` の宣言と両方向で突き合わせる（ディスクにあるのに宣言されない写し・宣言されるのに無い参照切れ）。重複は種類・キーで取る |
| NODE-BND | ① SQL 文字列（文をまたいで変数に継ぎ足すものを含む）② 表名だけを渡す `Open` / `OpenRecordset` / `.Source` ③ データコントロール（Data / ADODC）の `RecordSource` ④ 定義: `CREATE TABLE`・DAO の `CreateTableDef` | **4 系統。単一ではない。** ①だけを見ると②を落とす（実測 frei-vb6-projeto-vendas: 表 6 のうち 1 つは表名だけの Open にしか出ない）。④は Access の `.mdb` の中にあることが多く、ソースでは 0 件になりうる（実測 4 件すべて）。①〜③と④は表名で `comm` を取る |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（PhotoDemon）では、フォームが「ディスク 232 / `.vbp` の宣言 231」、モジュールが「360 / 358」で、差はどの `.vbp` にも入らない 1 画面・2 クラスだった。
> 実測（pcgestion20）では、フォームが「128 / 120」で、差の多くは「Copia de ...」の写しと、試験用のプロジェクトだけが使うフォームだった。

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
| NODE-MOD | **ディスク**: コードモジュールのファイル（`mod-diff` 経路A） | **プロジェクト**: `.vbp` の `Module=` / `Class=` / `UserControl=` / `Designer=` / `PropertyPage=` / `UserDocument=` の宣言（解いたパス。`mod-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（どのプロジェクトにも入らない・参照切れ・絶対パスの別）>` |
| NODE-EP | **ディスク**: フォーム（`VB.Form` / `VB.MDIForm` / UserForm）のファイル（`ep-diff` 経路A） | **プロジェクト**: `.vbp` の `Form=` の宣言（解いたパス。`ep-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: パスを全件（写し・試験用・参照切れ・絶対パスの別）>` |
| NODE-BND | **DB 表・参照側**: SQL 文字列 ＋ 表名だけの Open ＋ RecordSource の表（`list-bnd`） | **定義側**: `CREATE TABLE`・`CreateTableDef` の表名（`bnd-schema`） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（定義が .mdb の中・別の DB・死蔵の別）>` |

- **`.vbp` がソースに無い場合**（フォームとモジュールだけを持つ・VBA から書き出した）は、`NODE-MOD` / `NODE-EP` の経路B の定義欄を「単一経路（.vbp がソースに無い）」に書き換え、
  差分欄に理由を書く（`G-ENUM-SOURCE` が理由の記入を検査する。実測 erp_vb6）。
- **表の定義がソースに無い場合**（Access の `.mdb`・SQL Server の DB の中）は、`NODE-BND` の経路B の定義欄を「単一経路（定義が .mdb の中）」等に書き換え、差分欄に理由を書く。
  DB から表の一覧を書き出せるなら、その一覧を 2 経路目にする（ADR に書く）。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**画面の処理がフォームのイベントハンドラにあり、表が文字列の中にある**ため、
「画面は書いたが、どの表を更新するかは書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `form` | **フォームの名前**（`Attribute VB_Name`。大小違いは最も多い綴り） | `bash 03-audit/gate-snippets.sh idents-form <src>` |
| `module` | **モジュールの名前**（`.bas` / `.cls` / `.ctl` の `VB_Name`） | `bash 03-audit/gate-snippets.sh idents-module <src>` |
| `table` | **物理テーブル名**（参照側 ∪ 定義側。表ごとに最も多い綴り） | `bash 03-audit/gate-snippets.sh idents-table <src>` |

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。

1. **文字コードと CR。** ANSI（Windows-1252・Shift_JIS）と CRLF。`LC_ALL=C` で読み、CR を外す（前提 1）。
2. **フォームのヘッダとコード。** `.frm` / `.ctl` はヘッダ（`VERSION 5.00`・`Object = ...`・`Begin VB.Form 名前` の入れ子・`BeginProperty` のフォント等）の後に `Attribute VB_Name` があり、
   その後がコード。`BeginProperty` / `EndProperty` は入れ子の深さに数えない。`.cls` は `VERSION 1.0 CLASS` / `BEGIN ... END` のブロック（`MultiUse` 等）を持つ。
3. **VBA から書き出したフォームとデザイナ。** `Begin {C62A69F0-16DC-11CE-9E98-00AA00574A4F} 名前` は Microsoft Forms の UserForm で、コントロールは `.frx`（バイナリ）にしか無い
   （実測 erp_vb6: 17 画面がすべてこの形で、`VB.Form` だけを探すと画面 0 になる）。`.dsr` の DataEnvironment / DataReport も `Begin {GUID} 名前`。
4. **注釈・文字列・行の継続。** 注釈は `'` と `Rem`（文の始まりか `:` の後）。文字列は `"..."` で `""` が引用符。行末の ` _` で次の行に続く（SQL を何行にも分けて書く）。
5. **イベントハンドラは名前で結び付く。** VB6 は Handles を持たず、`Sub cmdOK_Click()` の名前だけでコントロールと結び付く。コントロール配列は `Index As Integer` の引数で分かれる。
   **コントロールを消しても手続きは残る**（実測 pcgestion20: 標準のイベント名なのに対応するコントロールの無いもの 42）。
   名前に「_」を含むだけの手続き（`Calc_Total` のような名前）はハンドラではない——後ろが標準のイベント名のものだけを orphan にする（最初の版で 146 件が化けた）。
6. **SQL は変数に継ぎ足して組み立てる。** `sql = "SELECT ..."` / `sql = sql & " FROM t"` / `sql = sql & " WHERE ..."`。文ごとに読むと FROM の断片が残り、表を取り違える。
   `gate-snippets.sh` は同じ変数への継ぎ足しを 1 つの SQL にしてから読む。**画面の文言を SQL と読まない**: メニューの「Delete layer」「Select all」「From file」が表に化けた
   （実測 PhotoDemon: DB が無いのに表 10）。DELETE は FROM か WHERE を伴い、WHERE の無い「Delete from history?」のように ? ! . で終わらないものだけを SQL とみなす。`+` での継ぎ足し・単一行の `If ... Then sql = sql & ...`・`Case 1: sql = sql & ...` も読む。SQL を組み立てる専用のクラスは継ぎ足しの規則で読めない
   （実測 pcgestion20: SQL を組み立てるクラスの中の `LEFT JOIN` の語が表に化けた）。
7. **表名だけを渡す。** `rs.Open "CLIENTES", cn`・`db.OpenRecordset("Clientes")`・データコントロールの `RecordSource = "Clientes"` は SQL でなく表名
   （実測 frei-vb6-projeto-vendas: 表 6 のうち 1 つはこの形にしか出ない）。`XMLHTTP` の `.Open "GET", url` は HTTP の方法で表ではない（実測 PhotoDemon）。接続の `cn.Open "MyDsn"`（ODBC の DSN）・`Err.Source = "modY"`・
   `adCmdStoredProc` と組む `cmd.CommandText = "sp_x"`（ストアドの名前）も表ではない。受け手の名前（`cn` / `conn` / `*Connection`）で接続を見分けるので、別の名前の接続変数は表に化けうる。
8. **プロジェクトの境界と写し。** 本体と部品と試験用のプロジェクトがフォルダを分けずに並び、`Copia de frmX.frm` のような写しが残る（実測 pcgestion20: `.vbp` 17・同じ名前のフォーム `Form1` が 5 つ）。
   `.vbp` は `..\` で別のフォルダのモジュールを共有し、複数の `.vbp` が同じファイルを宣言する（`ep-diff` / `mod-diff` の「複数の .vbp」の節）。
9. **`.vbp` の絶対パス。** 開発機の絶対パス（`D:\Program Files\...` の形）で宣言されたメンバーはリポジトリに無い（実測 pcgestion20: 1 件）。経路B のみに「(絶対パス)」と出る。
10. **表の定義がソースに無い。** Access の `.mdb` の中・SQL Server の DB の中にあり、ソースには参照しか無い（実測 4 件すべて定義 0）。経路B を単一経路にして理由を書く。
11. **ASCII 以外の名前。** 識別子に cp1252 の文字（`cbAñadir`）・Shift_JIS の文字を使える。識別子の文字クラスは 0x80〜0xFF のバイトを含めて読む（最初の版では
    `cbAñadirPago_Click` が `cbA` に化けて消えた。実測 pcgestion20）。**Shift_JIS の 2 バイト目が記号（`\` `^` `[` `]` `{` `}` `@` 等）の文字を含む名前は、名前の途中で切れる。**
    `.vbp`（cp1252）とディスク（UTF-8 に変わったファイル名）で名前のバイトが違うので、パスのキーは ASCII 以外のバイトを `?` に畳んで突き合わせる。
    **ASCII 以外を含む識別子は `idents-*` に出さず、`idents-nonascii` に出す**——ソースのバイト列のままでは UTF-8 で書く仕様本文と `G-IDENT` が突き合わせられず、
    永久に「未記載」になるため。仕様には読める綴りで書き、`idents-nonascii` の一覧と手で照らし合わせる（実測 erp_vb6: 画面 1・モジュール 1）。
12. **条件付きコンパイル。** `#If VBA7 Then ... #Else ... #End If` は両方の枝を読み、`Declare` や手続きを 2 度数える（実測 PhotoDemon: `#If` の枝の中に手続きと Declare がある）。

### 作成時の検証記録（このファイルのコマンドを実在のソースで走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（ディスク / .vbp の宣言） | 入口 `ep`（画面: ディスク / 宣言） | 表（参照 / 定義） | 操作（ハンドラ） | 備考 |
|---|---|---|---|---|---|
| PhotoDemon | 360 / 358（A のみ 2） | 237（画面 232 / 231・起動点 5） | 0 / 0（DB を使わない） | control 2,385・form 995・withevents 617 | Win32 API の Declare 1,497。文言の SQL の誤認を外した後に表 0 |
| pcgestion20 | 59 / 53 | 140（画面 128 / 120・起動点 12） | 75 / 0 | control 1,419・form 501・withevents 90・orphan 42 | `.vbp` 17・`.vbg` 5・参照 56（ADO 2.7・MSCOMCTL.OCX 等）・同じ名前のフォーム 6 種 |
| erp_vb6 | 12 / 0（`.vbp` が無い） | 17（UserForm 17 / 0） | 2 / 0 | form 19・userform 145・withevents 1 | VBA の UserForm を書き出したもの。DAO と Access |
| frei-vb6-projeto-vendas | 1 / 1 | 7（画面 6 / 5・起動点 1） | 6 / 0 | control 34・form 5 | 表名だけの Open にしか出ない表 1 |

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# 写し・試験用のプロジェクトを分母から外した場合は、その同じパスを外す（この Playbook の SCAN_EXCLUDE にそろえる）
SOURCE_EXCLUDE='(^|/)(Copia de |Copy of |Backup/|test/)'
```

**入れないとどうなるか**: `Form1.frm`・`Module1.bas` のような既定の名前が複数のプロジェクトにあり、basename の引用が「候補複数」で解決できなくなる。
`SCAN_EXCLUDE` に入れたディレクトリも `SOURCE_EXCLUDE` にそろえる。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 128 のフォームを 20 の業務単位にまとめる）、
**独立ソース側には 128 を書き、ノード登録数に 20 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。どのプロジェクトにも入らないモジュール・写しを明示>` | `<YYYY-MM-DD>` |
| NODE-EP（画面・入口） | `<N>` | `<M>` | `<同上。写し・試験用のフォーム・起動点・公開クラスを明示>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。定義が .mdb の中・別の DB・SQL を組み立てるクラスの誤検出を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
