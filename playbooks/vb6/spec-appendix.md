# 仕様章立ての追補（vb6）

ISO/IEC/IEEE 29148 準拠の章立て（GP-8）に対する、このスタック固有の追補。
汎用テンプレート（`specs/*/_template.md`）の節では表現しきれない要素だけを扱う。

- **対象スタック**: Visual Basic 6.0 のデスクトップアプリ（フォーム・標準モジュール・クラス・ユーザーコントロール、ADO / DAO / RDO）

## 追加すべき節（カテゴリ別）

| カテゴリ | 追加する節 | 理由（このスタックで必要になるもの） | 密度の判定基準 |
|---------|----------|--------------------------------|--------------|
| behavior | 画面の操作（イベントハンドラ） | 操作は `コントロール名_イベント名` の手続きで、宣言の Handles を持たない。コントロール配列は Index で分かれる（`list-handlers`） | 画面 1 つにつき操作の全数（control / form / withevents）と、操作ごとの処理と遷移 |
| behavior | 画面遷移 | 遷移は `frmX.Show`（`vbModal` の有無）・`Unload Me`・MDI の子フォームで書かれ、宣言的な遷移の定義が無い | 遷移元・遷移先・モーダルかどうか・渡す値（フォームの公開変数・プロパティ） |
| behavior | 起動と終了 | `Startup=` のフォームか `Sub Main`、`End` 文・`QueryUnload` で終わり方が決まる（`list-projects`） | 実行ファイル 1 つにつき起動点・初期化・終了の処理 |
| behavior | 入力の検証 | `Validate` / `LostFocus` / `KeyPress` のイベント・`CausesValidation` で検証し、宣言的な規則が無い | 画面 1 つにつき項目ごとの検証の位置と規則 |
| data | 画面・モジュール × 表 × 操作（CRUD） | SQL を文字列の継ぎ足しで組み立て、表名だけを `Open` に渡し、データコントロールの `RecordSource` で表を結び付ける（`list-crud`） | ファイル 1 つにつき参照・更新する全表と操作 |
| data | SQL の組み立て規則 | 条件句の継ぎ足し（`sql = sql & " AND ..."`）が業務の規則で、値の埋め込み（`'" & txt & "'`）が移行の判断を決める | 組み立てる SQL 1 つにつき基本形・条件句ごとの付加条件・値の埋め込み方 |
| data | データ連結 | Data / ADODC / DataEnvironment のコントロールと、`DataSource` / `DataField` で結んだ入力欄が、コードを書かずに DB を更新する | 連結 1 つにつき表・列・更新の可否 |
| modules | 標準モジュールとクラス | 業務の処理が標準モジュールの Public な手続きとグローバル変数にある（`list-procs`） | モジュール 1 つにつき公開の手続き・グローバル変数・使う表 |
| nfr | 外部境界 | Win32 API（`Declare`）・COM（`CreateObject`）・ファイル I/O（`Open ... For`）・`Shell`・OCX の部品が、移行で置き換えの必要な依存になる（`list-external` / `list-refs`） | 依存 1 つにつき用途・呼び出し元・置き換えの候補 |

## 記述方式の指定

同じ対象を複数の書き方で書くと横断突合ができなくなるため、方式を固定する。

- **画面 ID（`SCR-NN`）はフォームと 1 対 1 に対応させ、本文にフォームの名前（`VB_Name`）を必ず書く**（`idents-form` の出力と `G-IDENT` で突合する）。
  同じ名前のフォームが複数のプロジェクトにあるときはファイルのパスで区別する。
- **操作は「コントロール.イベント → 処理」の形で書く**（`cmdGuardar.Click → 入力を検証して INSERT`）。コントロール配列は `cmdOp(0).Click` のように添字を添える。
- **表は綴りを `idents-table` の出力に合わせる**。モジュールは `idents-module` の綴りで書く。
- **引用は `path:line` で書く**（`frmOrders.frm:120`）。

## このスタックで静的読解が効かない箇所（SB-6 の具体化）

- **遅延バインディング**: `Dim o As Object` / `CreateObject("...")` の呼び出しは、実行時まで型が決まらない。ProgID の出どころ（設定・レジストリ）を書く。
- **動的なフォーム**: `Forms(i)`・`Controls.Add`・`Load frmX(i)`（フォームの配列）・`CallByName` は、静的に画面・手続きが決まらない。
- **SQL の組み立て**: 変数・関数を通して組み立てる SQL は、継ぎ足しを辿っても表が決まらないことがある（SQL を組み立てる専用のクラス等）。
- **データ連結**: `DataSource` / `DataField` で結んだ入力欄は、コードを書かずに DB を更新する。`list-controls` の RecordSource / DataSource を読む。
- **設定とレジストリ**: `GetSetting` / `SaveSetting`・INI ファイル（`GetPrivateProfileString`）・`App.Path` の下のファイルで動作が切り替わる。
- **エラーの処理**: `On Error Resume Next` の範囲では失敗が黙って先に進む。範囲と、その後の `Err.Number` の確認の有無を書く。
