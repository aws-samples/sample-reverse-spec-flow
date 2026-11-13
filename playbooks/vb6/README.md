# Playbook: `vb6`

Visual Basic 6.0 のデスクトップアプリ（`.vbp` のプロジェクト・`.frm` のフォーム・`.bas` / `.cls` / `.ctl` のモジュール、ADO / DAO / RDO で DB に SQL を出す）を対象とする Playbook。
**VBA から書き出したフォーム**（Microsoft Forms の UserForm を `.frm` / `.frx` に書き出したもの）も画面として数える。
実測検証: PhotoDemon（画像編集ソフト。フォーム 232・クラス 165・ユーザーコントロール 56。DB は無い）・pcgestion20（店舗の販売管理。`.vbp` 17・`.vbg` 5・ADO）・
erp_vb6（DAO と Access。VBA の UserForm を書き出したもので `.vbp` が無い）・frei-vb6-projeto-vendas（販売の例。ADO）（2026-10-25）。

## 対象スタック

- **言語/実行基盤**: Visual Basic 6.0（VB5 も同じ形式）。Windows のデスクトップアプリ・ActiveX DLL / EXE / OCX
- **エントリポイント**: フォーム（`Begin VB.Form` / `VB.MDIForm`・VBA の UserForm）、実行ファイルのプロジェクトの起動点（`Startup=` のフォームか `Sub Main`）、
  ActiveX の公開クラス（`VB_Exposed = True` で Instancing が Private 以外）
- **モジュール**: 標準モジュール（`.bas`）・クラス（`.cls`）・ユーザーコントロール（`.ctl`）・デザイナ（`.dsr`。DataEnvironment / DataReport）・`.pag` / `.dob`
- **永続化**: ADO / DAO / RDO に渡す SQL 文字列、表名だけを渡す `Open` / `OpenRecordset`、データコントロール（Data / ADODC）の `RecordSource`。表の定義は Access の `.mdb` の中にあることが多い
- **画面**: `.frm` のヘッダ（`Begin ... End` の入れ子のコントロール）と、`コントロール名_イベント名` の手続き（イベントハンドラ）

## 適用判定（この Playbook を選ぶべきか）

```bash
find <source> \( -iname '*.vbp' -o -iname '*.frm' -o -iname '*.bas' -o -iname '*.cls' \) | head    # 1 件以上
find <source> \( -iname '*.frm' -o -iname '*.bas' -o -iname '*.cls' \) -print0 | xargs -0 -r grep -lE '^VERSION [0-9]\.00|^Attribute VB_Name' | head   # 1 件以上（拡張子の大小を区別しない）
```

- ✅ **該当**: どちらも 1 件以上（`.vbp` が無く、フォームとモジュールだけがあってもよい）
- **識別子に ASCII 以外の文字（á・ñ・日本語）を使うソース**は、`idents-nonascii` の一覧を仕様と手で照らし合わせる（`G-IDENT` が突き合わせられない。enumeration.md 落とし穴 11）
- ❌ **非該当**:
  - VB.NET（`.vbproj` と `.vb`。`Inherits System.Windows.Forms.Form`）→ **`vbnet-winforms-adonet`**
  - Access のアプリそのもの（`.mdb` / `.accdb` の中のフォーム・クエリ・マクロ）→ **未対応**（バイナリ。`SaveAsText` で書き出したテキストがあれば、その `.frm` / `.bas` をこの Playbook で数える）
  - Excel / Word の VBA（`.xlsm` 等の中）→ **未対応**（書き出したテキストだけを数える）

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-vb6-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面とコントロール・イベントハンドラ・データ連結・SQL の組み立て・外部境界） | `../specs/_appendix-vb6.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-projects`/`list-controls`/`list-handlers`/`list-procs`/`list-crud`/`list-refs`/`list-external`/`scope`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find / sort / comm / join のみで動く（追加のツールを要求しない）。
`.frm` のヘッダと VB のコード（注釈 `'` / `Rem`・文字列の `""`・行の継続 ` _`）を自前の字句解析で読む。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **プロジェクトの境界（Phase 0）。** 1 つのリポジトリに本体・部品（OCX）・試験用のプロジェクト・「Copia de ...」のような写しが並ぶことが多い（実測 pcgestion20: `.vbp` 17）。
  `list-projects` と `scope` で見て、分母から外すものを `SCAN_EXCLUDE` に書き、ADR で処分する。
- **表の定義がソースに無い。** Access の `.mdb` や SQL Server の DB の中にあり、ソースには参照しか無いことが多い（実測 4 件すべて定義 0）。`NODE-BND` の経路B を単一経路にし、
  DB から表の一覧を書き出せるなら、それを 2 経路目にする。
- **コントロールの無いイベントハンドラ。** コントロールを消しても手続きは残る（実測 pcgestion20: 42 件）。`list-handlers` の orphan を、死蔵として仕様から外すか ADR で決める。
- **VBA の UserForm。** コントロールが `.frx`（バイナリ）にしか無く、照合できない（`list-handlers` の userform）。画面の操作は手続きの名前から読む。
