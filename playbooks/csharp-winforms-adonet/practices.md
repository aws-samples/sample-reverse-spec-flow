# ドメイン知見（`DP-csharp-winforms-adonet-N`）

C# の Windows Forms デスクトップアプリ（ADO.NET 直接・SQL 文字列・ストアド・型付き DataSet）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 2 件（OpenDental 24.3 の部分取得 / Estate）、VB.NET の同型スタック（Apskaita5 / School）で観測したものはその旨を書く。

<!--
【ID 規約】`DP-csharp-winforms-adonet-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-csharp-winforms-adonet-1 | 画面の分母はコード（継承閉包）とプロジェクト（`SubType=Form`）の 2 経路で取り、差を原因別に切り分ける | 自作・外部の基底フォームを経由し、ディスクにあってもビルドされないファイルがある |
| DP-csharp-winforms-adonet-2 | 起動点は実行ファイルのプロジェクトから辿り、`Main` の分岐まで書く | `Main` は起動フォームを選ぶ分岐・前処理を持つことがあり、`Main` の数は起動点の数ではない |
| DP-csharp-winforms-adonet-3 | 画面仕様は Designer（項目）とコードビハインド（操作）の両方から書き、操作は（画面, イベント元, ハンドラ）の対で全数を書く | 項目と配線の正本は `*.Designer.cs` の `InitializeComponent` にある |
| DP-csharp-winforms-adonet-4 | SQL と表定義の置き場所を先に特定してから表を数える | コード・`.sql`・ストアド・型付き DataSet・自作 ORM の表基底クラスに分かれる |
| DP-csharp-winforms-adonet-5 | 連結・補間で組み立てる SQL は、組み立て規則と値の埋め込み方まで書く | 条件句の分岐が業務ルールで、値の埋め込み方（パラメータ / エスケープ関数 / 素の連結）が移行判断を決める |

---

## DP-csharp-winforms-adonet-1: 画面の分母は 2 経路で取り、差を原因別に切り分ける

### 目的
WinForms の「画面」は `Form` を継承したクラスだが、**継承は自作・外部の基底フォームを何段も経由し、ファイルはビルド対象外のことがある**。
コード側の継承だけ、またはファイルの有無だけで数えると、どちらも黙って誤った件数になる。

### ルール
1. **経路A（コード）**: 型宣言（`class X : Base`。宣言が複数行に分かれる形を含む）から `Form` への継承閉包を取る。
   **根には外部部品の基底フォームを加える**（ソースに宣言が無く、宣言の綴りが `Form` で終わり、`I` ＋大文字で始まらない基底。`gate-snippets.sh ep-diff` が根の一覧を出すので人が確認する）。
2. **経路B（プロジェクト）**: `.csproj` の `<Compile>` に付いた `<SubType>Form</SubType>`。Designer 側に付いたものは非 Designer ファイルに寄せる。
3. **差を 3 種に切り分ける**:
   | 差の種類 | 経路A | 経路B | 典型的な原因 | 対処 |
   |---|---|---|---|---|
   | ビルド対象外 | あり | なし | 旧形式プロジェクトの `<Compile>` に無いファイル | 仕様化の対象外として ADR で処分（`observed-anomalies` に記録） |
   | 外部基底の取りこぼし | なし | あり | 基底がソース外（別リポジトリ・部分取得の外）で綴りが `Form` で終わらない | 基底の所在を特定して根に加えるか、断面外として ADR に残す |
   | 抽象基底・SDK 形式 | あり | なし | 画面の共通基底クラス／SDK 形式は `SubType` を書かないことがある | 基底は画面ノードにせず modules 側で扱う（ADR） |
4. **画面の単位はクラス**（`X.cs` と `X.Designer.cs`、partial の分割ファイルは 1 画面。引用は最初の非 Designer ファイル）。

### 実例
- OpenDental: 経路A 964 / 経路B 944（クラス単位。ファイル単位では 967 / 947 で、partial の分割ファイルを二重に数えていた）。経路A のみ 21 件はすべて旧形式の `.csproj` に無いファイル（同じ機能群のファイルがまとめて外されていた＝死蔵）。
  経路B のみ 1 件は、基底クラスが部分取得の外（別ディレクトリのプロジェクト）にあった。画面の大半（942）は自作の基底フォーム `FormODBase` 経由。
- Estate: 経路A 61 / 経路B 54。差 7 件はすべてビルド対象外。うち中国語名の画面 2 件は ASCII の名前で切ると経路A から消えた（enumeration.md 落とし穴 2）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh ep-diff <src>   # 根に加えた外部基底・経路A のみ（原因つき）・経路B のみ
```

### アンチパターン
- `find -iname '*.Designer.cs' | wc -l` を画面数にする（ユーザーコントロール・コンポーネントも Designer を持つ。ビルド対象外も混ざる）。
- `: Form` だけを grep する（自作・外部の基底フォーム経由の画面を落とし、宣言が複数行に分かれる形も落とす）。

---

## DP-csharp-winforms-adonet-2: 起動点は実行ファイルのプロジェクトから辿り、`Main` の分岐まで書く

### 目的
起動点は `OutputType` が `WinExe` / `Exe` のプロジェクトで、起動対象はその中の `static void Main`（多くは `Program.cs`）である。
`Main` は**コマンドライン引数・設定・多重起動の判定で起動フォームを選び分ける**ことがあり、起動前処理（例外ハンドラの登録・ログイン）もここにある。

### ルール
1. 起動点は **`OutputType` が `WinExe` / `Exe` のプロジェクト**で数える（`list-ep` の `startup` 行）。
2. **`Main` の本体を起動シーケンスとして仕様化する**（`Application.Run(new X())` の X・引数による分岐・`Application.ThreadException` / `AppDomain.UnhandledException` の登録）。
3. リポジトリ全体の `static void Main` の数を起動点の数にしない（ツール・テスト・試作の `Main` が混ざる）。
4. `.sln` に載らない実行ファイルのプロジェクト（試作・ツール）は `mod-diff` で見つかる。仕様化するかを ADR で決める。

### 実例
Estate: 実行ファイル 2 件のうち 1 件はどの `.sln` にも載らない試作（動画再生のサンプル）だった。OpenDental（部分取得）の実行ファイルは 1 件で、
`Main`（`Main Modules/ProgramEntry.cs`）は**実行形態（ブラウザ配信版か否か）で未処理例外の扱いと前処理を分岐**してから起動フォームを開く。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-ep <src> | grep '^startup'
bash 03-audit/gate-snippets.sh mod-diff <src>
```

### アンチパターン
- `grep -rc 'static void Main'` で起動点を数える。
- 起動フォームの `Load` だけを読み、`Main` の分岐・前処理を落とす。

---

## DP-csharp-winforms-adonet-3: 画面仕様は Designer（項目）とコードビハインド（操作）の両方から書く

### 目的
WinForms の画面項目（コントロールの種類・名前・初期値・Enabled / Visible / ReadOnly・タブ順・入力桁数）と、
**イベント配線の大半**は `*.Designer.cs` の `InitializeComponent` にある。処理本体はコードビハインドにある。
片方だけでは画面を再構築できない（SB-8）。

### ルール
1. **項目**: Designer のフィールド宣言（`private System.Windows.Forms.Button btnSave;` 等）を全数の分母とし、`InitializeComponent` 内のプロパティ設定を項目定義として書く。
2. **操作**: `list-handlers` の 4 列目が `screen` の行の（画面, イベント元, ハンドラ）の対を分母とする。Designer の `this.x.Click += new System.EventHandler(this.y);` と、
   コードビハインドのラムダ（`grid.CellClick += (s, e) => ...`）の両方を含む。
3. **画面を跨いで `sort -u` しない**（同名ハンドラが潰れる。enumeration.md 落とし穴 8）。
4. 1 つのハンドラが複数のイベントに配線されることがある（`+=` が複数行）。対ごとに書く。

### 実例
- OpenDental: 画面の配線の対 7,436（962 ファイル。全ファイルでは 8,961）。ハンドラ名だけで全体を `sort -u` すると 4,439（4 割減）。
- Estate: 配線の対 193、ハンドラ名だけの `sort -u` は 105。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-handlers <src> | awk -F '\t' '{ n[$1]++ } END { for (k in n) print n[k] "\t" k }' | sort -rn | head
grep -cE '^[[:space:]]*(private|internal|public|protected)[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+[^ ;(]+;' <画面>.Designer.cs   # 画面ごとの項目数の目安
```

### アンチパターン
- 画面のスクリーンショット（または想像）で項目を書く。Designer の値が正本である。
- 「ボタンを押すと保存する」のようにハンドラ単位でまとめ、どのイベントがどのハンドラに来るかを書かない。

---

## DP-csharp-winforms-adonet-4: SQL と表定義の置き場所を先に特定してから表を数える

### 目的
ADO.NET 直接の業務アプリでは、SQL が**コード中の文字列（逐語的文字列 `@"..."` の複数行を含む）・`.sql` スクリプト・
外部 SQL 置き場・ストアドプロシージャ・型付き DataSet（`.xsd`）**に分かれ、表の定義側は DDL・`.mdf`（バイナリ）・
**自作の ORM（表を表す基底クラス）**に分かれる。置き場所を確認せずに数えると、参照側・定義側のどちらも黙って過少になる。

### ルール
1. **Phase 0 で `sql-stores` を実行し、SQL を含むコード以外のファイルを拡張子別に確認する。** 見つけた拡張子を `00-ingestion/gate-config.env` に `SQL_STORE_GLOBS='*.sqld'` の形で書く（`gate-snippets.sh` が読むので Phase 4 の再実行でも同じ値になる）。
2. ストアドは `list-sproc` で**呼び出し側と定義側を両方向に突合する**（呼ばれない定義＝死蔵の候補／定義の無い呼び出し＝別 DB か断面外）。
3. **自作の ORM がある場合**、表を表す基底クラス（例: 「全ての表クラスが継承する基底」）を特定し、派生型の全数を定義側の系統にする。
   **クラス名と物理表名の対応は属性・規約で決まる**ので、対応規則を data 仕様に書く。
4. スキーマがソースに無い（`.mdf` のみ・別リポジトリ）場合は、`enumeration.md` の経路B に `単一経路` と理由を書く。

### 実例
- Estate: コード中のリテラルから見える表は 8、ストアド定義（`.sql`）を加えると 12。スキーマはバイナリの `.mdf` のみ。
  ストアドは DB ヘルパー越しに呼ばれ、呼び出し 31 箇所（一意 27）に対し定義 51（24 は呼び出し側に現れない）。
- OpenDental: 表の定義側の正本は自作の基底クラスの派生型（421 型）。うち 3 型は属性で別の物理名を指定していた（`Def` → `definition` 等）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh sql-stores <src> | head -20
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh list-sproc <src>
```

### アンチパターン
- `bnd-schema` が 0 件なのを見て「スキーマ定義は無い」と書く（独自形式・自作 ORM・バイナリを確認していない）。
- 呼ばれないストアドを黙って仕様から落とす（死蔵か動的呼び出しかを確かめていない）。

---

## DP-csharp-winforms-adonet-5: 連結・補間で組み立てる SQL は、組み立て規則と値の埋め込み方まで書く

### 目的
`"SELECT ... WHERE 1=1"` に検索条件を `+` / `$"..."` で足していく形では、**どの入力のときにどの条件句が付くか**が業務ルールそのものである。
また**値の埋め込み方**（パラメータ・自作のエスケープ関数・素の連結）は、再構築時の移行判断と脆弱性の記録に直結する。

### ルール
1. 連結で組み立てる SQL は「基本形 ＋ 条件句ごとの付加条件（どの入力が・どの値のとき）＋ 並び順」の形で書く。
2. **値の埋め込み方を画面・データアクセス層ごとに書く**: `Parameters.Add` / `SqlParameter`、自作のエスケープ関数、素の連結のどれか。
3. 入力値を素で連結している箇所は `observed-anomalies.md` に記録する（SB-13。仕様として「正しい」とは書かない）。

### 実例
- OpenDental: SQL 文字列を `+` で連結する行が 10,472。値は自作のエスケープ関数（`POut.*`。25,460 呼び出し）で埋め込み、`Parameters.Add` は 87。
- Estate: 連結は 0 で、`SqlParameter` / `Parameters.Add` が 106（ストアドの引数）。
- VB.NET の School（同型スタック）: 入力（`.Text`）を引用符で囲んで素で連結する行が 59、パラメータは 0。

### チェック方法
```bash
grep -rnE '"[^"]*(SELECT|WHERE|INSERT|UPDATE|DELETE)[^"]*" *[+]' <src> --include='*.cs' | wc -l
grep -rhoE 'Parameters[.]Add|new SqlParameter' <src> --include='*.cs' | wc -l
```

### アンチパターン
- 連結後の「ある 1 通り」の SQL だけを書く（条件の組み合わせが消える）。
- 値の埋め込み方を書かずに「検索条件で絞り込む」とだけ書く。

<!-- ENTRIES END -->
