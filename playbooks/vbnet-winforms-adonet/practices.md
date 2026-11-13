# ドメイン知見（`DP-vbnet-winforms-adonet-N`）

VB.NET の Windows Forms デスクトップアプリ（ADO.NET 直接・SQL 文字列・ストアド・型付き DataSet）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 2 件（Apskaita5 / School-Management-System）、C# の同型スタック（OpenDental / Estate）で観測したものはその旨を書く。

<!--
【ID 規約】`DP-vbnet-winforms-adonet-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-vbnet-winforms-adonet-1 | 画面の分母はコード（継承閉包）とプロジェクト（`SubType=Form`）の 2 経路で取り、差を原因別に切り分ける | 根を `Form` に限ると外部基底の画面が全部落ち、ファイルの有無で数えると死蔵が混ざる |
| DP-vbnet-winforms-adonet-2 | 起動点は `OutputType` と `Application.myapp` で特定する | `Sub Main` はアプリケーションフレームワークでは書かれない |
| DP-vbnet-winforms-adonet-3 | 画面仕様は Designer（項目）とコードビハインド（操作）の両方から書き、操作は（画面, イベント元, ハンドラ）の対で全数を書く | 項目の定義は Designer.vb にしか無く、1 つのハンドラが複数のイベントを受ける |
| DP-vbnet-winforms-adonet-4 | SQL の置き場所を先に特定してから表を数える | コード・`.sql`・外部 SQL 置き場・ストアド・型付き DataSet に分かれる |
| DP-vbnet-winforms-adonet-5 | 文字列連結で組み立てる SQL は、組み立て規則（条件句の有無と順序）まで書く | 連結の分岐が業務ルールそのもので、SQL 文字列の 1 行だけでは再実装できない |

---

## DP-vbnet-winforms-adonet-1: 画面の分母は 2 経路で取り、差を原因別に切り分ける

### 目的
WinForms の「画面」は `Form` を継承したクラスだが、**継承は外部部品を経由することがあり、ファイルはビルド対象外のことがある**。
コード側の継承だけ、またはファイルの有無だけで数えると、どちらも黙って誤った件数になる。

### ルール
1. **経路A（コード）**: 型宣言と `Inherits` から `Form` への継承閉包を取る。**根には外部部品の基底フォームを加える**
   （ソースに宣言が無く、宣言の綴りが `Form` で終わり、`I` ＋大文字で始まらない基底。`gate-snippets.sh ep-diff` が根の一覧を出すので人が確認する）。
2. **経路B（プロジェクト）**: `.vbproj` の `<Compile>` に付いた `<SubType>Form</SubType>`。Designer 側に付いたものは非 Designer ファイルに寄せる。
3. **差を 3 種に切り分ける**:
   | 差の種類 | 経路A | 経路B | 典型的な原因 | 対処 |
   |---|---|---|---|---|
   | ビルド対象外 | あり | なし | 旧形式プロジェクトの `<Compile>` に無いファイル | 仕様化の対象外として ADR で処分（`observed-anomalies` に記録） |
   | 外部基底の取りこぼし | なし | あり | 基底がソース外で綴りが `Form` で終わらない | 根に加えて再計算する |
   | 抽象基底・SDK 形式 | あり | なし | 画面の共通基底クラス／SDK 形式は `SubType` を書かないことがある | 基底は画面ノードにせず modules 側で扱う（ADR） |
4. **画面の単位はクラス**（`X.vb` と `X.Designer.vb`、Partial の分割ファイルは 1 画面。引用は最初の非 Designer ファイル）。

### 実例
- School: 30 画面すべてが DevExpress の `XtraForm` 継承。根を `Form` に限ると経路A は **0 件**、外部基底を根に加えると **30 = 30**。
- Apskaita5: 経路A 156 / 経路B 157 で、差 1 件は `MainForm.Designer.vb` に付いた `SubType=Form`。寄せると **156 = 156**。
- C# の OpenDental（同じ機構）: 経路A 964 / 経路B 944（クラス単位）。差のうち 21 件は旧形式の `.csproj` に無いファイル（ビルドされない死蔵）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh ep-diff <src>   # 根に加えた外部基底・経路A のみ（原因つき）・経路B のみ
```

### アンチパターン
- `find -iname '*.Designer.vb' | wc -l` を画面数にする（ユーザーコントロール・コンポーネントも Designer を持つ。ビルド対象外も混ざる）。
- `Inherits System.Windows.Forms.Form` だけを grep する（外部基底・自作基底フォーム経由の画面を落とす）。

---

## DP-vbnet-winforms-adonet-2: 起動点は `OutputType` と `Application.myapp` で特定する

### 目的
VB のアプリケーションフレームワーク（`My.MyApplication`）を使うプロジェクトは、起動フォームを
`My Project/Application.myapp` の `<MainForm>` で宣言し、**ソースに `Sub Main` を書かない**。
起動直後の処理（ログイン・設定読込・未処理例外の扱い）は `ApplicationEvents.vb` のイベントにある。

### ルール
1. 起動点は **`OutputType` が `WinExe` / `Exe` のプロジェクト**で数える。
2. 起動対象は `StartupObject` と `Application.myapp` の `<MainForm>` の両方を見る（`list-ep` の `startup` 行に併記される）。
3. **`ApplicationEvents.vb` の `Startup` / `Shutdown` / `UnhandledException` を起動シーケンスとして仕様化する**（`list-handlers` のイベント元の列に `startup` 等で出る。`Me.` は外して出す）。
4. `Application.myapp` は**ライブラリにも置かれる**ので、myapp の数を起動点の数にしない。

### 実例
Apskaita5: 実行ファイル 3 件（会計本体・移行ツール・Remoting サーバ）。`Sub Main` があるのは Windows サービスの 1 件だけで、
他の 2 件は `MainForm=MDIParent1` / `MainForm=MainForm`。`Application.myapp` 自体は 14 プロジェクト中 14 件にあり、
うち 12 件はライブラリ（`MainForm` が空）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-ep <src> | grep '^startup'
bash 03-audit/gate-snippets.sh list-handlers <src> | awk -F "\t" '$2 ~ /^(startup|shutdown|unhandledexception)$/'
```

### アンチパターン
- `grep -c 'Sub Main'` で起動点を数える。
- 起動フォームの `Load` だけを読み、`ApplicationEvents.vb` の前処理を落とす。

---

## DP-vbnet-winforms-adonet-3: 画面仕様は Designer（項目）とコードビハインド（操作）の両方から書く

### 目的
WinForms の画面項目（コントロールの種類・名前・初期値・Enabled / Visible / ReadOnly・タブ順・入力桁数）は
**`*.Designer.vb` の `InitializeComponent` にしか無い**。操作（ボタン押下・値変更・画面ロード）は
コードビハインドの `Handles` 句と `AddHandler` にある。片方だけでは画面を再構築できない（SB-8）。

### ルール
1. **項目**: Designer の `Friend WithEvents <名前> As <型>` を全数の分母とし、`InitializeComponent` 内のプロパティ設定を項目定義として書く。
2. **操作**: `list-handlers` の 4 列目が `screen` の行の（画面, イベント元, ハンドラ）の対を分母とする。**1 つのハンドラが `Handles a.Click, b.Click` で複数のイベントを受ける**ので対ごとに書く。
3. **画面を跨いで `sort -u` しない**（同名ハンドラが潰れる。enumeration.md 落とし穴 8）。
4. `AddHandler` で実行時に配線されるイベント（動的に作るコントロール・グリッドのセル）も操作に含める。

### 実例
- School: Designer の `Friend WithEvents` は 1,667 個。画面の配線の対は 299、ハンドラ名だけで全体を `sort -u` すると 180（4 割減）。
- Apskaita5: 画面の配線の対 631（全ファイルでは 797。差はユーザーコントロール等）、ハンドラ名だけの `sort -u` は 388。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-handlers <src> | awk -F '\t' '{ n[$1]++ } END { for (k in n) print n[k] "\t" k }' | sort -rn | head
grep -ic 'friend withevents' <画面>.Designer.vb   # 画面ごとの項目数
```

### アンチパターン
- 画面のスクリーンショット（または想像）で項目を書く。Designer の値が正本である。
- 「ボタンを押すと保存する」のようにハンドラ単位でまとめ、どのイベントがどのハンドラに来るかを書かない。

---

## DP-vbnet-winforms-adonet-4: SQL の置き場所を先に特定してから表を数える

### 目的
ADO.NET 直接の業務アプリでは、SQL が**コード中の文字列・`.sql` スクリプト・外部 SQL 置き場（XML / 独自拡張子 / `.resx`）・
ストアドプロシージャ・型付き DataSet（`.xsd`）**に分かれる。コード中のリテラルだけを走査すると、
外部置き場やストアドに寄せた設計では表の大半が見えない。

### ルール
1. **Phase 0 で `sql-stores` を実行し、SQL を含むコード以外のファイルを拡張子別に確認する。** 見つけた拡張子を `00-ingestion/gate-config.env` に `SQL_STORE_GLOBS='*.sqld'` の形で書く（`gate-snippets.sh` が読むので Phase 4 の再実行でも同じ値になる）。
2. ストアドは `list-sproc` で**呼び出し側と定義側を両方向に突合する**（呼ばれない定義＝死蔵の候補／定義の無い呼び出し＝別 DB か断面外）。
3. **定義側（スキーマ）が独自形式**の場合は `bnd-schema` が拾えない。形式を特定して手で数え、差分欄に「独自形式 N 表（コマンド）」と書く。
4. スキーマがソースに無い（`.mdf` 等のバイナリのみ・別リポジトリ）場合は、`enumeration.md` の経路B に `単一経路` と理由を書く。

### 実例
- Apskaita5: コード中のリテラルから見える表は **3**、`.sqld`（名前付き SQL を収めた独自拡張子の XML。MySQL 用・SQLite 用が 2 か所に計 4 本）を加えると **76**。
  スキーマは独自形式の XML（67 表）で、`bnd-schema` の対象外だった。
- School: スキーマは UTF-16 の `.sql` に 13 表。参照側 13 と一致（UTF-16 を読まないと定義側が 0 件に見える）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh sql-stores <src> | head -20
bash 03-audit/gate-snippets.sh bnd-diff <src>   # gate-config.env の SQL_STORE_GLOBS を読む
bash 03-audit/gate-snippets.sh list-sproc <src>
```

### アンチパターン
- `bnd` の値を見て「表は 3 つだけ」と仕様に書く（外部置き場を探していない）。
- SQL がコードに無いことを理由に data 仕様を薄くする。

---

## DP-vbnet-winforms-adonet-5: 文字列連結で組み立てる SQL は、組み立て規則まで書く

### 目的
`"SELECT ... WHERE 1=1"` に検索条件を `&` で足していく形では、**どの入力が空のときにどの条件句が付くか**が業務ルールそのものである。
SQL 文字列の 1 行を引用しても再実装できない。また入力値をそのまま連結している箇所は、現行の事実として記録すべき脆弱性である。

### ルール
1. 連結で組み立てる SQL は「基本形 ＋ 条件句ごとの付加条件（どの入力が・どの値のとき）＋ 並び順」の形で書く。
2. 入力値を引用符で囲んで連結している箇所（`"'" & txtX.Text & "'"`）は `observed-anomalies.md` に記録する（SB-13。仕様として「正しい」とは書かない）。
3. パラメータ化（`Parameters.Add`）されているか否かを画面ごとに書く（再構築時の移行判断に要る）。

### 実例
School: SQL 文字列を `&` で連結する行が 157、そのうち画面の入力（`.Text`）を引用符で囲んで直接連結する行が 59。
`Parameters.Add` の使用は 0 件。

### チェック方法
```bash
grep -rniE '"[^"]*(select|insert|update|delete|where)[^"]*"[^"]*&' <src> --include='*.vb' | wc -l
grep -rnic 'Parameters[.]Add' <src> --include='*.vb' | awk -F: '{ s += $NF } END { print s }'
```

### アンチパターン
- 連結後の「ある 1 通り」の SQL だけを書く（条件の組み合わせが消える）。
- 連結している事実を書かずに「検索条件で絞り込む」とだけ書く。

<!-- ENTRIES END -->
