# ドメイン知見（`DP-cobol-cics-batch-N`）

IBM メインフレームの COBOL アプリ（CICS のオンライン・JCL のバッチ・DB2 / VSAM）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は OSS 3 件（AWS CardDemo / IBM Bank-of-Z / IBM CICS GenApp）。

<!--
【ID 規約】`DP-cobol-cics-batch-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-cobol-cics-batch-1 | 断面を「ソース・資源定義・JCL・DDL」の 4 点そろいで固定し、欠けを最初に数える | プログラムのソースだけでは入口もデータも数えられない。定義が別の管理下にあることが多い |
| DP-cobol-cics-batch-2 | オンラインの画面仕様は、トランザクション → 初期プログラム → マップ → 遷移先（XCTL / RETURN TRANSID）の連鎖で書く | 疑似会話型では 1 画面が複数の起動に分かれ、遷移先は変数経由で決まる |
| DP-cobol-cics-batch-3 | バッチの仕様はジョブのステップ単位で、プログラム・DD のデータセット・条件コードの扱いまで書く | 処理の順序と入出力はプログラムではなく JCL が決める |
| DP-cobol-cics-batch-4 | データ仕様は「コピー句のレコード定義」と「物理の定義（DDL・VSAM・DD）」を対にして書く | 項目の型と桁はコピー句にしか無く、キーと編成は物理の定義にしか無い |
| DP-cobol-cics-batch-5 | 動かないコード・使われない資源を「仕様」と書かない | 73 桁目以降のコード・デバッグ行・定義だけの表やトランザクションは現行の事実として記録する |

---

## DP-cobol-cics-batch-1: 断面を「ソース・資源定義・JCL・DDL」の 4 点そろいで固定し、欠けを最初に数える

### 目的
COBOL の資産は、プログラムのソースと、それを動かす定義（CICS の資源定義・JCL・DB2 の DDL・VSAM の定義）が
**別々の管理下**にあることが多い（ソースは開発、資源定義はシステムプログラマ、DDL は DBA）。
ソースだけを受け取ると、入口（トランザクション・ジョブ）もデータ（表・ファイル）も数えられず、仕様の分母が立たない。

### ルール
1. **Phase 0 で 4 点の有無を確かめる**: COBOL ソース（＋コピー句）／CICS の資源定義（CSD の抜き出し・DFHCSDUP の入力・YAML）／JCL（ジョブ・プロシージャ）／DDL（＋ DCLGEN）。
2. **欠けを数える**: `mod-diff` の「★ソースが断面に無い」、`ep-diff` の「トランザクション定義の PROGRAM のうちソースが無いもの」、
   `screen-diff` の「資源定義にあって BMS が無い」を Phase 0 のスコープ記録に書き、追加取得か対象外（ADR）かを決める。
3. **資源定義の形式を 1 つに決めつけない**（enumeration.md 落とし穴 6）。3 形式のどれで来ても `gate-snippets.sh` は読む。
4. 断面外のものは「存在しない」と書かない。「断面に無い」と書く（GP-5 の UNKNOWN）。

### 実例
- CardDemo: CSD に定義があってソースの無いプログラムが 6（管理機能 `COADM00C`、テスト用 `COTSTP1C`〜`COTSTP4C` 等）、マップセットが 15。
- Bank-of-Z: 資源定義は CICS TS の構成 YAML（`.setup/zconfig/`）、JCL は配備用の Jinja2 テンプレート（`.setup/jcl/`）にあり、ソースと別の場所に置かれていた。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh mod-diff <src>      # ★ソースが断面に無い
bash 03-audit/gate-snippets.sh ep-diff <src>       # トランザクション定義の PROGRAM のうちソースが無いもの
bash 03-audit/gate-snippets.sh screen-diff <src>   # 資源定義にあって BMS が無い
```

### アンチパターン
- ソースのフォルダだけを解析対象にし、資源定義・JCL を「インフラの設定」として除外する。
- 参照のみのプログラム名を全部「システム提供」とみなして数えない（業務プログラムの欠けが紛れる）。

---

## DP-cobol-cics-batch-2: オンラインの画面仕様は、トランザクション → 初期プログラム → マップ → 遷移先（XCTL / RETURN TRANSID）の連鎖で書く

### 目的
CICS の疑似会話型プログラムは、1 回の画面表示ごとに `RETURN TRANSID(...)` でタスクを終え、次の入力で同じ（または別の）トランザクションとして
起動し直す。画面遷移は `XCTL PROGRAM(...)` で別プログラムへ制御を渡し、遷移先は**変数（COMMAREA の項目）経由**で決まることが多い。
画面単位・プログラム単位でまとめると、どの入力でどこへ遷移するかが消える。

### ルール
1. 画面仕様の単位は「トランザクション ID ＋ 初期プログラム ＋ マップ（マップセット）」の組。`list-ep` / `ep-diff` / `screen-diff` の名前で引用する。
2. **遷移は `list-calls` の XCTL / LINK を分母にし、変数経由の遷移先は MOVE の候補ごとに書く**（enumeration.md 落とし穴 9）。
   表（OCCURS）の要素経由で解決できないものは、メニューの表の VALUE を読んで補い、補ったことを書く。
3. 画面項目は BMS の `DFHMDF`（位置・長さ・属性・初期値）とシンボリックマップ（コピー句）の対で書く。
4. 入力の検査（`EIBAID` の PF キー分岐・項目の検査）は画面ごとに全分岐を書く。

### 実例
CardDemo: 画面遷移の `XCTL` の大半は `MOVE 'COxxxxxC' TO CDEMO-TO-PROGRAM` → `XCTL PROGRAM(CDEMO-TO-PROGRAM)` の形。
`gate-snippets.sh` は MOVE を 1 段だけ辿り、辿った後の未解決の名前は 3（表の要素経由 2・コピー句の中の DB2 エラー処理のプログラム名 1）。
メニューから選ぶ遷移は `CDEMO-MENU-OPT-PGMNAME(WS-OPTION)` で表の要素経由になり、静的には決まらない。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-calls <src> | grep -E 'via |未解決'   # 変数経由の遷移
bash 03-audit/gate-snippets.sh screen-diff <src>
```

### アンチパターン
- 1 プログラム = 1 画面と仮定する（1 プログラムが複数マップを送る・複数プログラムが同じマップを送る）。
- 「メニューから各機能へ遷移する」とだけ書き、選択肢ごとの遷移先を書かない。

---

## DP-cobol-cics-batch-3: バッチの仕様はジョブのステップ単位で、プログラム・DD のデータセット・条件コードの扱いまで書く

### 目的
バッチの処理順序・入出力・異常時の扱いは、プログラムではなく **JCL** が決める（ステップの順序、`DD` で割り当てるデータセット、
`COND` / `IF` による条件実行、ソート・IDCAMS 等のユーティリティのステップ）。プログラム単位で書くと、
ユーティリティだけのステップ・データの受け渡し・再実行の条件が消える。

### ルール
1. 単位は「ジョブ → ステップ」。各ステップに `EXEC PGM=`（業務プログラムかユーティリティか）・`DD` のデータセット（`list-dd`）・実行条件を書く。
2. ステップ間で受け渡すデータセット（前のステップの出力 DD が次のステップの入力 DD）を明示する。
3. カタログ式プロシージャ（`EXEC <PROC>`）は展開した中身で書く（プロシージャのソースが断面に無ければ UNKNOWN）。
4. ジョブの起動条件（スケジューラ）は JCL に無い。断面外として明示する。

### 実例
CardDemo: JCL 55 本のうち、業務プログラムを動かすステップのほかに IDCAMS（VSAM の定義・REPRO）・IEBGENER・SORT・DFHCSDUP のステップが多数ある。
`list-calls` の JCL の行（`EXEC PGM=` のステップ）は 150、`list-dd` のデータセットの行は 344（連結 DD を含む）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-calls <src> | awk -F '\t' '$3 == "JCL"' | wc -l   # EXEC PGM= のステップ数（プロシージャを呼ぶステップは含まない）
bash 03-audit/gate-snippets.sh list-dd <src>   # ステップごとのデータセット（同名のジョブは場所の path:line で区別する）
bash 03-audit/gate-snippets.sh list-calls <src> | awk -F '\t' '$3 == "JCL"'   # ステップの一覧（業務プログラムかユーティリティか）
```

### アンチパターン
- 業務プログラムの仕様だけを書き、ユーティリティのステップ（ソート・データ変換）を落とす。

---

## DP-cobol-cics-batch-4: データ仕様は「コピー句のレコード定義」と「物理の定義（DDL・VSAM・DD）」を対にして書く

### 目的
COBOL では、項目の型・桁・再定義（REDEFINES）・繰り返し（OCCURS）は**コピー句**にしかなく、
キー・編成・レコード長・データセット名は**物理の定義**（DDL・IDCAMS の `DEFINE CLUSTER`・JCL の `DD`・CICS の `DEFINE FILE`）にしかない。
片方だけではファイル・表を再実装できない。

### ルール
1. ファイル・表ごとに「論理名（CICS のファイル名・DD 名）」「物理名（データセット・表）」「レコード定義のコピー句」「キー」を 1 行にする。
2. DB2 の表は DDL と DCLGEN の両方を見る（DCLGEN だけ・DDL だけの表がある）。
3. 名前は大文字で書く（`idents-table` の綴り。G-IDENT は大小を区別する）。

### 実例
CardDemo: CICS のファイル名（`ACCTDAT` 等）はコードに直接書かれず、すべて `VALUE` 経由。VSAM の定義は IDCAMS の JCL（15 クラスター）にある。
GenApp: DDL の表名は小文字（`customer`）でコードは大文字（`CUSTOMER`）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh list-dd <src>
```

### アンチパターン
- コピー句のレコード定義だけを data 仕様にし、キーと編成を書かない。

---

## DP-cobol-cics-batch-5: 動かないコード・使われない資源を「仕様」と書かない

### 目的
長く保守された資産には、**書いてあるが動かない・使われない**ものが残る。読んだとおりに仕様へ書くと、再構築で不要な機能を作る。

### ルール
1. `overflow` が出す 73 桁目以降のコードは「コンパイラは読まない」と `observed-anomalies` に記録する（仕様には書かない）。
2. デバッグ行（7 桁目 `D`）は「デバッグ時のみ」と明記するか、仕様から外す。
3. 定義だけで参照されない表・トランザクション・マップ（`bnd-diff` / `ep-diff` / `screen-diff` の「定義のみ」）は、
   死蔵か外部から使われるかを確かめるまで「現行の事実」として記録し、仕様化するかを ADR で決める（SB-13）。

### 実例
- Bank-of-Z: IMS のロードプログラム 5 本で、`UNSTRING ... DELIMITED BY` の区切り文字の一部が 73 桁目以降にあった。
- GenApp: 表 `CLAIM` は DDL にあるが、どのプログラムも参照しない（コピー句の注釈に名前があるだけ）。
- Bank-of-Z: BMS の `BNK1B2M.bms` のマップセット名が別ファイルと重複（`BNK1TFM`）、コードは存在しないマップ名 `BNK1CCM` を送る。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh overflow <src>
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh screen-diff <src>
```

### アンチパターン
- 73 桁目以降のコードを「区切り文字の一覧」として仕様に書く。
- 定義だけの表を data 仕様に普通の表として並べる（死蔵かどうかが読み手に分からない）。

<!-- ENTRIES END -->
