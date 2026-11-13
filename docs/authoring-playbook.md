# 新規 Playbook の作成手順（GP-105）

Playbook = **特定の技術スタックに固有の知識**を汎用フローから分離した層。
`playbooks/<domain>/` を追加するだけで新しいスタックに対応でき、
`method`（GP/SB）・手順書・`gates.sh` 本体は変更しない。

## なぜ Playbook 層があるか（作る前に読む）

SB-2 ルール8 の「列挙完全性を独立ソースで突合する」＝本フレームワーク最強の網羅性機構は、
**何が独立ソースかがスタック依存**である。汎用手順書に特定スタックの目印を書くと、
その目印を持たない対象では分母突合が計算不能になる。

**これは仮説ではなく観測された失敗である**（2026-08-10 実測）:

| 対象 | `@Path` を含む `.java` | `@Table` を含む `.java` | `struts*.xml` | `*.orm.xml` |
|---|---|---|---|---|
| Fineract 1.15.0 | 172 | 258 | 0 | 0 |
| **Apache Roller** | **0** | **0** | 3 | 93 |

Roller では手順書が指定する等式が計算不能で、roller-spec は独自に代替源を発明していた
（記録も再利用もされない形で）。**同じ Java でも分母の数え方は同じではない。**

## 作成手順

### 1. 既存 Playbook で足りないことを確認する

```bash
./init.sh --list-playbooks
```

既存の `README.md` の「適用判定」を実際の解析対象で走らせ、どれも該当しないことを確認する。
**該当するなら新規作成しない**（既存 Playbook に知見を追記する方が価値が高い）。

### 2. 雛形をコピーする

```bash
cp -R playbooks/_template playbooks/<new-domain>
```

`<new-domain>` は英数字とハイフン。**`DP-<new-domain>-N` の ID に入る**ので短く安定した名前にする
（後から変えると ID が変わる。GP-9 の永続 ID 原則）。

### 3. `enumeration.md` を実データで埋める（最重要・最初にやる）

**これが Playbook の中核**で、他のファイルは無くても動くがこれは必須。

1. **実際の解析対象で走査コマンドを実行する。** 「たぶんこれで数えられる」で書かない。
2. **2 通り以上の数え方で検算する。** 桁が違ったらデータではなくコマンドを疑う（GP-6 ルール12）。
   実例: `grep -c '<entity'` = 186 / `'<entity[[:space:]]'` = 93 / `class=` ユニーク = 31（正）。**6 倍の開き。**
3. **「走査の落とし穴」節に実測した数え間違いを全部書く。** これが次の利用者を救う。
4. **突合の等式は両辺を書く**（`独立ソース件数 = EP ノード数` のように）。

### 4. `gate-snippets.sh` を実装して実測で検証する

```bash
bash playbooks/<new-domain>/gate-snippets.sh ep  /path/to/real-source
bash playbooks/<new-domain>/gate-snippets.sh bnd /path/to/real-source
```

- **数値 1 行のみ**を出力する（`gates.sh` がそのまま読む）。
- 数えられない場合は `unknown` を返す（`0` を返すと「0 件」と誤解される）。
- **実測していないコマンドを配布しない**（桁違いの誤りが分母に混入する。GP-105 アンチパターン）。

### 5. `practices.md` にドメイン知見を書く（`DP-<domain>-N`）

- ID は `DP-<domain>-N`。**ドメイン名を含めて構成上一意にする**（GP-105 ルール5）。
- サマリ表と本文の `## DP-<domain>-N:` を一致させる（`selftest.sh` が検査する）。
- **汎用 GP/SB に書かれている内容を再掲しない**（二重記述を作らない）。
  汎用化できると判断したら `dev/backport-procedure.md` の手順でフレームワークへ還元する。

### 6. `spec-appendix.md` と `README.md` を書く

- `spec-appendix.md`: 29148 章立て（GP-8）に**追加が必要な節だけ**を書く。章立て本体は書かない。
- `README.md`: **適用判定を実行可能なコマンドで書く**（「〜のような」ではなく `grep` で判定できる形）。
  非該当時にどの Playbook を使うべきかを名指しする。

### 7. 検証する

```bash
./selftest.sh
```

`selftest.sh` が Playbook ごとに検査する項目:
- 必須 5 ファイル（`README.md` / `enumeration.md` / `practices.md` / `spec-appendix.md` / `gate-snippets.sh`）の存在
- `enumeration.md` に「独立ソース表」「目印の系統」「**分母の 2 経路突合**」「実行記録」の節があること
  （**「分母の 2 経路突合」は「実行記録」より前に置く**。実行記録の抽出は節の終わりまでを読むので、
  後ろに置くと新表の行が実行記録の行として検査されてしまう）
- `gate-snippets.sh` の bash 構文
- `DP-<domain>-N` がドメイン名を含むこと・サマリ表と本文の一致

### 8. 実対象で end-to-end 確認する

```bash
./init.sh /path/to/real-source <spec-name> rebuild --playbook <new-domain>
cd <real-source>-spec && bash spec-extraction/03-audit/gates.sh phase1
```

`G-ENUM-SOURCE` が「未記入」で FAIL することを確認する（配置された `enumeration.md` の
実行記録は空なので FAIL が正しい）。**続けて、実対象で数えた値を「分母の 2 経路突合」と「実行記録」に書き込み、
`G-ENUM-SOURCE` が PASS に転じることを確認する**——未記入で FAIL するだけでは、
**記入しても PASS に転じない書式の欠陥**を検出できない（実測: 2 経路突合の行キーに `NODE-EP（画面）` と補足を付けた・
経路B の定義欄に注記として「単一経路」と書いた、の 2 件がここで初めて出た。`selftest.sh` が両方を検査する）。

- **2 経路突合の行キーは「目印の系統」の行キーと完全一致させる**（補足は定義欄に書く）。
- **配布する経路B の定義欄に「単一経路」の語を書かない**（ゲートが免除の宣言と読む。使い方は表の下に注記する）。
- **識別子（`idents-*`）は出典の綴りで出す**（`G-IDENT` は大小を区別して `specs/` 本文と突合する）。

## 作らない判断（重要）

- **実対象が来る前に投機的に作らない。** 実測で検証していない Playbook は害になる
  （誤ったコマンドが分母に混入する）。既存 2 つも実プロジェクトの実測から起こしている。
- **既存 Playbook の亜種で足りるなら作らない。** 「走査の落とし穴」を追記する方がよい。
- **1 プロジェクトだけの都合なら作らない。** それは `LL-N`（プロジェクト固有教訓）に属する。

## 他の Playbook と併用される前提で書く

`init.sh --playbook <主> --playbook <従>` で 2 つ以上を併用できる（GP-105 ルール11）。従として置かれると、
ファイルは `enumeration-<名前>.md` / `gate-snippets-<名前>.sh` / `practices-<名前>.md` / `playbook-<名前>.md` に改名される。

- **`gate-snippets.sh` は自分のファイル名を決め打ちしない。** 設定は `$(dirname "$0")/../00-ingestion/gate-config.env` から読む
  （改名されても同じ場所を指す）。
- **自分の置き場は決まった綴りで書く**: `03-audit/gate-snippets.sh`・`` `gate-snippets.sh` ``・`01-code-graph/enumeration.md`・
  `identifiers/<種別>`。従として置かれるとき、`init.sh` がこの綴りだけを `-<名前>` つきに書き換える
  （`enumeration.md` / `practices.md` / `spec-appendix.md` / `README.md`）。別の綴り（`./gate-snippets.sh` 等）は書き換わらず、
  従の文書のコマンドが**主の走査器を呼ぶ**。
- **設定のキーは主と共有される。** `SCAN_EXCLUDE` 等を `gate-config.env` から読むなら、環境変数を先に見る
  （既存の走査器はそうしている）。併用時は従の走査を環境変数で上書きして走らせる。
- **README の「適用判定」に、併用される相手を書く**（例: アプリ側の Playbook ＋ `oracle-plsql`）。
  両方が同じノード種別（DB の表など）を数えるときは、どちらにノードを寄せるかも書く。

## Playbook 未指定でも動く（縮退）

`--playbook` を省略すると `_template/enumeration.md` の雛形が配置される。
Phase 1 Step 1-2 の**最初の作業**として自分で埋める。
**`G-ENUM-SOURCE` が未記入を FAIL にする**ので、空のまま列挙に進むことはできない
（「独立ソースが分からない」を「突合しない」に落とさないための構造）。

埋めた `enumeration.md` が他プロジェクトでも使えると判断したら、
Playbook として切り出して還元する（本手順の 2 以降）。
