# 仕様章立ての追補（vbnet-winforms-adonet）

ISO/IEC/IEEE 29148 準拠の章立て（GP-8）に対する、このスタック固有の追補。
汎用テンプレート（`specs/*/_template.md`）の節では表現しきれない要素だけを扱う。

- **対象スタック**: VB.NET / Windows Forms / ADO.NET 直接（SQL 文字列・ストアド・型付き DataSet）

## 追加すべき節（カテゴリ別）

| カテゴリ | 追加する節 | 理由（このスタックで必要になるもの） | 密度の判定基準 |
|---------|----------|--------------------------------|--------------|
| behavior | 画面項目定義 | 項目の型・初期値・Enabled / Visible / ReadOnly・タブ順・入力桁数は `*.Designer.vb` にしか無い（DP-vbnet-winforms-adonet-3） | 画面 1 つにつき Designer の `Friend WithEvents` 全数 |
| behavior | 画面イベント一覧（操作仕様） | 操作は `Handles` 句と `AddHandler` に分散し、1 ハンドラが複数イベントを受ける | 画面 1 つにつき `list-handlers` の対の全数 |
| behavior | 画面遷移 | 遷移は `.Show()` / `.ShowDialog()` / `New <画面>` の呼び出しで、宣言的な遷移定義が無い | 遷移元ハンドラ・遷移先画面・モーダルか否か・戻り値（`DialogResult`）の扱い |
| behavior | 起動シーケンス | `Application.myapp` の `MainForm` と `ApplicationEvents.vb`（Startup / UnhandledException）に分かれる（DP-vbnet-winforms-adonet-2） | 起動点 1 つにつき起動前処理・起動フォーム・終了時処理 |
| data | 画面 × 表の CRUD マトリクス | 表の読み書きは画面のハンドラ内の SQL 文字列にあり、data 仕様だけでは「誰が書くか」が追えない | 画面 1 つにつき参照・更新する全表と操作（C/R/U/D） |
| data | 動的 SQL の組み立て規則 | `&` 連結の条件句が業務ルール（DP-vbnet-winforms-adonet-5） | 組み立てる SQL 1 つにつき基本形・条件句ごとの付加条件・並び順 |
| data | ストアドプロシージャ | 処理本体が DB 側にある。呼び出し側と定義側を両方向に突合する | 手続き 1 つにつき引数・結果セット・更新する表・呼び出し元 |
| api | 外部連携（ファイル・COM・Win32 API・帳票・Office） | `CreateObject` / `Declare` / 帳票ファイル（`.rdlc` 等）は型システムの外にある | 連携 1 つにつき相手・入出力形式・呼び出し元・失敗時の扱い |
| modules | 設定（`app.config` / `My.Settings`） | 接続文字列・動作フラグが設定にあり、コードからは値が分からない | 設定キー 1 つにつき既定値・読む箇所・意味 |

## 記述方式の指定

同じ対象を複数の書き方で書くと横断突合ができなくなるため、方式を固定する。

- **画面 ID（`SCR-NN`）はフォームのクラス名と 1 対 1 に対応させ、本文にクラス名を必ず書く**
  （`idents-screen` の出力と `G-IDENT` で突合する）。
- **画面の引用は非 Designer ファイルの `path:line`、項目の引用は Designer ファイルの `path:line`** で書く。
- **操作は「イベント元.イベント → ハンドラ」の形で 1 行ずつ書く**（`btnSave.Click → btnSave_Click`）。
  まとめて「保存ボタン等」と書かない。
- **表は物理名で書き、綴りは `idents-table` の出力に合わせる**（`G-IDENT` は大小を区別して突合する。SQL 中の綴りは揺れる）。
- **画面遷移は mermaid `stateDiagram` で書き、ノード ID を画面 ID と一致させる**（統合画面遷移図のノード数 = 画面数の突合。GP-14 ルール6）。

## このスタックで静的読解が効かない箇所（SB-6 の具体化）

- **動的に作るコントロール**: `Controls.Add(New ...)` で実行時に作る項目は Designer に無い。生成ループと命名規則を書く。
- **リフレクション・名前文字列での画面起動**: `Activator.CreateInstance` / `Type.GetType("...")` / メニュー定義からの起動は呼び出し関係が静的に追えない。
  起動元の定義（メニュー表・設定）を特定し、到達可能な画面を列挙する。
- **データバインド**: `DataSource` / `DataBindings.Add` / `DataMember` による表示は、列の対応が実行時に決まる。バインド元の SQL と列名を書く。
- **外部部品の既定動作**: DevExpress 等のグリッド・入力部品は、プロパティ既定値で検証・書式が変わる。Designer に書かれていない既定値は部品の版に依存する。
- **遅延バインディング（`Option Strict Off`）**: `Object` 型経由の呼び出しは呼び先が静的に決まらない。`Option Strict` の設定をプロジェクトごとに記録する。
- **接続先の切り替え**: 接続文字列が設定・INI・レジストリから来る場合、どの DB に繋ぐかはコードから決まらない。
