# ドメイン知見（`DP-vb6-N`）

Visual Basic 6.0 のデスクトップアプリ（フォーム・標準モジュール・クラス・ユーザーコントロール、ADO / DAO / RDO）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は実在のソース 4 件（PhotoDemon / pcgestion20 / erp_vb6 / frei-vb6-projeto-vendas）。

<!--
【ID 規約】`DP-vb6-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-vb6-1 | 画面とモジュールは「ディスク」と「.vbp の宣言」の両方で数え、写し・試験用・参照切れを分ける | 1 つのリポジトリに本体・部品・試験用・写しが並ぶ |
| DP-vb6-2 | 画面の操作はイベントハンドラの名前とコントロールの対で数え、コントロールの無いハンドラを死蔵として扱う | VB6 は Handles を持たない。消したコントロールのハンドラが残る |
| DP-vb6-3 | 表は SQL の継ぎ足しを解き、表名だけの Open とデータ連結を足して数える。定義は .mdb の中にあると決めてかかる | SQL は何文にも分けて組み立て、表名は文字列の中にしか無い |
| DP-vb6-4 | 外部の依存（Win32 API・COM・OCX・ファイル・レジストリ）を全数で書く | 移行で置き換えが要るのは、業務の処理より依存のほうが多い |

---

## DP-vb6-1: 画面とモジュールは「ディスク」と「.vbp の宣言」の両方で数え、写し・試験用・参照切れを分ける

### 目的
VB6 のリポジトリは、本体のプロジェクト・部品（OCX）のプロジェクト・部品の試験用のプロジェクト・「Copia de ...」のような写しが同じフォルダに並ぶことが多い。
ディスクのファイルだけで数えると写しを数え、`.vbp` だけで数えるとどのプロジェクトにも入らないファイル（死蔵）と参照切れを見落とす。

### ルール
1. **経路A（ディスクのファイル）と経路B（`.vbp` の宣言）を突き合わせる**（`ep-diff` / `mod-diff`）。パスは大小を区別しないキーにする。
2. **経路A のみ**を種類で分ける: 写し（`Copia de ...`・`Copy of ...`）・試験用のプロジェクトだけが使うもの・どこにも入らない死蔵・`.vbp` がソースに無い。
3. **経路B のみ**は参照切れ（ファイルが無い）・開発機の絶対パス・`SCAN_EXCLUDE` で外したもの。
4. **複数の `.vbp` が同じファイルを宣言する**ものは共有の部品として 1 つに書き、使うプロジェクトを列挙する。
5. 分母から外すプロジェクト（試験用・部品の見本）は `SCAN_EXCLUDE` に書き、ADR で処分する。

### 実例
- pcgestion20: フォームがディスク 128 / 宣言 120、`.vbp` 17・`.vbg` 5。同じ名前のフォーム（`Form1` 5 つ等）が 6 種。
- PhotoDemon: フォーム 232 / 231、モジュール 360 / 358。差はどのプロジェクトにも入らない 1 画面・2 クラス。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-projects <src>
bash 03-audit/gate-snippets.sh ep-diff <src>
bash 03-audit/gate-snippets.sh mod-diff <src>
```

### アンチパターン
- `find -name '*.frm' | wc -l` を画面数にする（写しと試験用のフォームを数える）。
- `.vbp` が無いリポジトリで「画面は無い」と書く（VBA から書き出したフォームはディスクにだけある）。

---

## DP-vb6-2: 画面の操作はイベントハンドラの名前とコントロールの対で数え、コントロールの無いハンドラを死蔵として扱う

### 目的
VB6 のイベントハンドラは `コントロール名_イベント名` の名前だけでコントロールに結び付き、宣言の Handles を持たない。コントロールを消しても手続きは残り、
名前に「_」を含むだけの手続きはハンドラではない。**名前の形だけで数えると、死蔵のハンドラとただの手続きが操作に混ざる**。

### ルール
1. **`list-handlers` の control / form / withevents** を画面の操作の分母にする（コントロール配列は Index ごとに分けて書く）。
2. **orphan**（後ろが標準のイベント名なのにコントロールが無い）は死蔵のハンドラとして、仕様から外すか ADR で決める。
3. **userform**（VBA の UserForm）はコントロールが `.frx` にしか無く照合できない。手続きの名前から操作を読み、照合できないことを UNKNOWN に書く。
4. **データ連結**（`DataSource` / `DataField`）はコードの無い操作になる。`list-controls` の RecordSource / DataSource を画面の仕様に書く。

### 実例
- pcgestion20: コントロールと結び付くもの 1,419・フォーム自身 501・WithEvents 90・orphan 42。名前に「_」を含むだけの手続きはこのどれにも入らない。
- erp_vb6: UserForm 17 画面のハンドラ 145 はすべて照合できない。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-handlers <src>
bash 03-audit/gate-snippets.sh list-controls <src>
```

### アンチパターン
- `Private Sub .*_` の数を操作の数にする（ただの手続きと死蔵のハンドラが混ざる）。
- orphan のハンドラを「その画面の操作」として仕様に書く（押せるボタンは無い）。

---

## DP-vb6-3: 表は SQL の継ぎ足しを解き、表名だけの Open とデータ連結を足して数える。定義は .mdb の中にあると決めてかかる

### 目的
VB6 の SQL は `sql = sql & "..."` で何文にも分けて組み立てる。表名だけを `rs.Open "CLIENTES"` に渡す形と、データコントロールの `RecordSource` もある。
表の定義は Access の `.mdb` や SQL Server の DB の中にあり、ソースには参照しか無いことが多い。

### ルール
1. **`list-bnd` の参照側**（SQL・表名だけの Open・RecordSource）を分母にする。由来（code / code:表名 / control）を CRUD の仕様に添える。
2. **定義側が 0 件のとき**は経路B を単一経路にして理由を書く。DB から表の一覧を書き出せるなら、それを 2 経路目にする（ADR）。
3. **SQL を組み立てる専用のクラス**（汎用の SQL ビルダー）は継ぎ足しの規則で読めない。呼び出し側から表を補う。
4. **値の埋め込み方**（`'" & txt & "'` の連結・パラメーター）を data の「SQL の組み立て規則」に書く（移行の判断と SQL インジェクションの評価に要る）。

### 実例
- pcgestion20: 参照 75 / 定義 0。SQL 文字列と表名だけの Open の両方に出る表が多い。
- frei-vb6-projeto-vendas: 表 6 のうち 1 つは表名だけの Open にしか出ない。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh list-crud <src>
```

### アンチパターン
- 文ごとに SQL を読み、`" FROM t"` の断片だけを表にする（継ぎ足しの前の SELECT と組にならない）。
- 画面の文言（`"Delete layer"`）を SQL として表に数える。

---

## DP-vb6-4: 外部の依存（Win32 API・COM・OCX・ファイル・レジストリ）を全数で書く

### 目的
VB6 のアプリは、Win32 API（`Declare`）・COM（`CreateObject`）・OCX の部品（`.vbp` の `Object=`）・タイプライブラリ（`Reference=`）・ファイル I/O・`Shell`・レジストリと INI に深く依存する。
移行（.NET・Web）で置き換えが要るのはこの依存で、業務の処理より件数が多いことがある。

### ルール
1. **`list-external` と `list-refs` の全件**を nfr の「外部境界」に書く。用途と呼び出し元を添える。
2. **OCX の部品**（MSCOMCTL・MSFLXGRD・RICHTX32 等）は画面の部品として、置き換えの候補を書く。
3. **遅延バインディング**（`CreateObject("...")`）の ProgID の出どころ（設定・レジストリ）を書く。

### 実例
- PhotoDemon: `Declare` の Win32 API 1,497。
- pcgestion20: 参照 56（OLE Automation 15・ADO 2.7 が 5・MSCOMCTL.OCX 4 等）、`Shell` 6、ファイル I/O 25。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-external <src>
bash 03-audit/gate-snippets.sh list-refs <src>
```

### アンチパターン
- 依存を「Win32 API を使う」とだけ書き、関数の全数と呼び出し元を書かない。

---

<!-- ENTRIES END -->
