# ドメイン知見（`DP-aspnet-webforms-N`）

ASP.NET Web Forms の業務 Web アプリ（`.aspx` / `.ascx` ＋ C# / VB.NET のコードビハインド）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 4 件（ERPSYS_WebForms / YAF.NET v3.2.17 / TheBeerHouse VB 版 / Property Agent）。

<!--
【ID 規約】`DP-aspnet-webforms-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-aspnet-webforms-1 | 画面の分母は「マークアップ」と「名指しされる画面」の 2 経路で取り、名指しされない画面を原因別に切り分ける | `.aspx` の数は画面の数ではない。死蔵・ダイアログ・ホストが読み込む `.ascx` が混ざる |
| DP-aspnet-webforms-2 | 遷移はマークアップ・コード・メニュー定義・クライアントスクリプトの 4 か所から集め、渡す値まで書く | 遷移先はどこか 1 か所に宣言されていない。クエリ文字列・セッションで値が渡る |
| DP-aspnet-webforms-3 | 操作はマークアップの `On〜` 属性・`Handles`・`+=`・名前による自動配線の 4 系統で数える | C# はマークアップ、VB は `Handles` で配線するのが既定で、片方だけでは操作が半分消える |
| DP-aspnet-webforms-4 | データの経路は「データソースコントロール → 型とメソッド → SQL・ストアド」の連鎖で書く | `ObjectDataSource` は画面とデータアクセス層を名前だけでつなぐ。表はその先にしか無い |
| DP-aspnet-webforms-5 | 断面の境界（ホスト・同梱ライブラリ・配備用の写し）を Phase 0 で数えて決める | DNN のモジュールはホストの上で動き、リポジトリには第三者のソースや事前コンパイルの写しが入っていることがある |

---

## DP-aspnet-webforms-1: 画面の分母は 2 経路で取り、名指しされない画面を原因別に切り分ける

### 目的
Web Forms の「画面」は `.aspx` だが、**ファイルがあることと画面として使われることは別**である。
旧版の画面を置いたままのディレクトリ・別窓で開くダイアログ・ホストが動的に読み込む `.ascx` が混ざり、
`.aspx` の数だけでは分母を決められない。

### ルール
1. **経路A（マークアップ）**: Page ディレクティブを持つ `.aspx` と、コードビハインドの基底が「〜Page」「〜ModuleBase」「〜SettingsBase」で終わる `.ascx`（`list-ep` の `page` / `control-page`）。
2. **経路B（名指しされる画面）**: 遷移・メニュー・設定・コード・クライアントスクリプトの文字列から解決した画面（`ep-diff`。マスターページ・埋め込みの参照は除く）。
3. **経路A のみの画面を 4 種に切り分ける**:
   | 差の種類 | 典型的な原因 | 対処 |
   |---|---|---|
   | 死蔵 | `obsolete/`・`test/` 等に置いたままの旧版 | 仕様化の対象外として ADR で処分（`observed-anomalies` に記録） |
   | 名前を組み立てて読み込む | `LoadControl("Pages/" + x + ".ascx")`・列挙型の名前からパスを作る | 読み込み側の規則と値の一覧から画面を補い、補ったことを書く |
   | 外から直接開く | 既定の文書（`Default.aspx`）・ログイン画面・外部システムからの直リンク | `web.config` の `defaultDocument` / `loginUrl` と運用の情報で確かめる |
   | 部品の誤分類 | 基底の名前の規則に当たった部品・当たらなかった画面 | `list-controls` で確かめ、ADR で扱いを決める |
4. **参照先のファイルが無いもの**も全件を説明する（参照切れ・断面外・ホストが提供する画面）。

### 実例
- ERPSYS: 経路A 350 / 経路B 296（メニューの XML を読んだ後。読まない版は 257）。経路A のみ 54 のうち 24 が `obsolete/` の下。
  メニューの XML は存在しない画面 2 つを 6 か所で指していた（メニューに残った参照切れ。注釈にした項目は数えない）。
- YAF: 経路A 107（`.ascx` の画面 104 ＋ `.aspx` 3）/ 経路B 4。画面は列挙型の名前からパスを組み立てて読み込むので、名指しされない。
- Property Agent: 経路A 44 / 経路B 42。画面の切り替えは `_controlToLoad = "EditProperty.ascx"` の文字列とマニフェストの `<src>` で、
  名指しされないのは `Options.ascx`・`Template.ascx` の 2 つだけ（マニフェストの `<files>` は配布ファイルの一覧なので数えない）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh ep-diff <src>        # 経路A のみ・参照先のファイルが無い・名前を組み立てて読み込む箇所
bash 03-audit/gate-snippets.sh list-controls <src>  # .ascx の扱い（埋め込み / 画面として読み込まれる）
```

### アンチパターン
- `find -iname '*.aspx' | wc -l` を画面数にする（死蔵・事前コンパイルの写しが混ざり、`.ascx` の画面を落とす）。
- 名指しされない画面を「未使用」と断定する（名前を組み立てて読み込む・外から直接開く画面がある）。

---

## DP-aspnet-webforms-2: 遷移は 4 か所から集め、渡す値まで書く

### 目的
Web Forms の遷移先は 1 か所に宣言されていない。マークアップの `NavigateUrl` / `PostBackUrl` / データバインド式、
コードの `Response.Redirect` / `Server.Transfer`、メニュー定義（XML・`Web.sitemap`）、クライアントスクリプトの `window.open` に分散する。
値はクエリ文字列・セッション・`PreviousPage` で渡り、遷移先の画面はそれを前提に動く。

### ルール
1. 遷移は「遷移元（画面・操作）→ 遷移先 ＋ 渡す値（クエリ文字列のキー・セッションのキー）」の形で 1 行ずつ書く。
2. メニューが権限ごとに分かれている（役割ごとの XML 等）なら、どの役割にどの画面が見えるかを表にする。
3. `list-refs` の `nav` / `code` / `script` の行を分母にし、`dynamic` の行（名前を組み立てる遷移）は規則と値を書く。

### 実例
- ERPSYS: 画面の一覧は役割ごとのメニュー定義 XML 12 本にあり、コードは役割と部署で XML のファイル名を選ぶだけ（`UCMenu.ascx.cs`）。
- TheBeerHouse: 一覧から詳細への遷移はデータバインド式（`NavigateUrl='<%# "~/ShowArticle.aspx?ID=" & Eval("ID") %>'`）。
  `web.config` の `<urlMappings>` が仮想の URL（`~/articles/beer.aspx`）を実在の画面へ対応づける。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-refs <src> | awk -F '\t' '$1 != "embed" && $1 != "master"'   # 遷移の全数
```

### アンチパターン
- マークアップの `NavigateUrl` だけを数える（コード・メニュー・スクリプトの遷移を落とす）。
- 遷移先だけを書き、渡す値を書かない（遷移先の画面の前提が仕様から消える）。

---

## DP-aspnet-webforms-3: 操作は 4 系統で数える

### 目的
Web Forms のイベント配線は、**マークアップの `On〜` 属性**（`<asp:Button OnClick="Save_Click">`）・**VB の `Handles` 句**・
**コードの `+=` / `AddHandler`**・**名前による自動配線**（`AutoEventWireup="true"` の画面の `Page_Load` 等）に分かれる。
言語とプロジェクトの作り方で主に使う系統が違う。

### ルール
1. 画面 1 つにつき `list-handlers` の行（画面, イベント元, ハンドラ）の全数を操作仕様の分母にする。
2. `auto` の行（`Page_Load` / `Page_Init` 等）は初回表示とポストバック（`IsPostBack`）で処理が分かれる。両方を書く。
3. クライアント側の `OnClientClick` / `onclick` は操作仕様の別の行として書く（サーバーの操作に数えない）。

### 実例
- ERPSYS（C#）: 1,740 行のうち markup 1,188・auto 503・code 49。
- TheBeerHouse（VB）: 182 行のうち handles 176・markup 5・code 1。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-handlers <src> | cut -f4 | sort | uniq -c
```

### アンチパターン
- C# の `+=` だけ（WinForms の数え方）で数える（Web Forms の C# はマークアップの属性で配線するのが既定）。

---

## DP-aspnet-webforms-4: データの経路は「データソース → 型とメソッド → SQL・ストアド」の連鎖で書く

### 目的
`SqlDataSource` は SQL をマークアップに直接持ち、`ObjectDataSource` は**型名とメソッド名の文字列だけ**で
データアクセス層を呼ぶ。表は呼ばれたメソッドの先（SQL・ストアドプロシージャ）にしか無い。

### ルール
1. データソース 1 つにつき「画面・コントロール ID・種類・SQL またはメソッド・パラメータの出どころ」を書く（`list-datasources`）。
2. `ObjectDataSource` は `TypeName` / `SelectMethod` 等をデータアクセス層のメソッドへ辿り、その先のストアド・SQL・表まで書く。
3. ストアドプロシージャしか見えない対象では、手続き（`idents-proc`）を表の代わりのデータ境界として扱うかを Phase 1 で決める（ADR）。

### 実例
- TheBeerHouse: データソース 129 行（`ObjectDataSource` の型 42 か所）→ VB のデータアクセス層 → ストアドプロシージャ 155（定義）。
- ERPSYS: 表を参照する SQL はコードに無く（コメントアウトされた古い SQL だけ）、データアクセスはストアドプロシージャの呼び出し 606 か所だけ。
  DDL もソースに無い。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-datasources <src>
bash 03-audit/gate-snippets.sh list-sproc <src>
```

### アンチパターン
- `ObjectDataSource` を「データソースあり」とだけ書き、型とメソッドの先を追わない（どの表を読み書きするかが仕様から消える）。

---

## DP-aspnet-webforms-5: 断面の境界を Phase 0 で数えて決める

### 目的
Web Forms のリポジトリには、**アプリ以外のもの**が入っていることが多い。
同梱した第三者ライブラリのソース・事前コンパイルした配備用の写し・テストコード、そしてモジュール型（DNN 等）では
**アプリが動くホストそのものが断面に無い**。境界を決めないまま数えると、分母が桁で狂う。

### ルール
1. `scope` でディレクトリごとの件数を見て、第三者のソースは `SCAN_EXCLUDE` に入れ、ADR で処分する。テストコードの扱いも決める。
2. 事前コンパイルの写し（`PrecompiledApp.config` のあるディレクトリ）は `gate-snippets.sh` が自動で外す。外したことを記録する。
3. ホストが提供する画面・コントロール（DNN の `~/controls/*.ascx`・`Default.aspx`）は断面外として ADR に書き、モジュールが依存する点だけを仕様にする。

### 実例
- YAF: `.cs` 3,438 本のうち 2,056 本が同梱した ServiceStack と Lucene.Net。外すとプロジェクト 25 → 15、参照される表 104 → 77。
- TheBeerHouse: 配備用の写し `TBH_Deploy/` に `.aspx` 50 本の写し（`PrecompiledApp.config` あり）。外さないと画面が 2 倍になる。
- Property Agent: ホストの `~/controls/LabelControl.ascx` 等 5 種への埋め込み参照 57 件が「参照先のファイルが無い」に出る。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh scope <src>
```

### アンチパターン
- リポジトリ全体をそのまま数え、同梱ライブラリの型・SQL を業務の分母に入れる。

<!-- ENTRIES END -->
