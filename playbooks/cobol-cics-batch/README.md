# Playbook: `cobol-cics-batch`

IBM メインフレームの COBOL アプリ（CICS のオンライン・JCL のバッチ・DB2 / VSAM）を対象とする Playbook。
実測検証: AWS CardDemo・IBM Bank-of-Z・IBM CICS GenApp（2026-10-23）。

## 対象スタック

- **言語**: COBOL（固定形式・自由形式）。コピー句（`COPY`・`EXEC SQL INCLUDE`）を含む
- **エントリポイント**: CICS のトランザクション（資源定義: CSD の抜き出し・DFHCSDUP の入力・CICS TS の構成 YAML）・JCL のジョブ
- **画面**: BMS（`DFHMSD` / `DFHMDI` / `DFHMDF`）
- **データ**: DB2（`EXEC SQL`・DDL・DCLGEN）・VSAM（`EXEC CICS ... FILE`・IDCAMS）・順編成（JCL の `DD`）
- **併用されうるもの**: IMS（`CBLTDLI`・PSB / DBD）・MQ（`MQPUT` 等）——有無は `list-calls` で確かめ、走査は手で補う

## 適用判定（この Playbook を選ぶべきか）

```bash
find <source> -type f \( -iname '*.cbl' -o -iname '*.cob' -o -iname '*.cobol' \) | head                 # 1 件以上
grep -rliE 'PROGRAM-ID' <source> --include='*.cbl' --include='*.cob' --include='*.cobol' | head          # 1 件以上
```

- ✅ **該当**: どちらも 1 件以上
- ⚠️ **拡張子が無い**（メインフレームの区分データセットから落としたメンバー）: COBOL・コピー句・JCL・BMS に拡張子を付けた写しを解析対象にする
  （`gate-snippets.sh` は拡張子で種類を見分ける。対象は変更しない——SB-5）
- ⚠️ **PL/I・アセンブラが混在する**: その部分はこの Playbook の走査の対象外（件数に入らない）。`enumeration.md` の実行記録に「対象外 N 本（ADR）」と書く
- ❌ **非該当**:
  - オンラインが IMS（MPP）だけで CICS が無い → 未対応（入口の数え方が違う。`--playbook` を省略して `enumeration.md` を自分で埋める）
  - 分散系の COBOL（Micro Focus / GnuCOBOL の画面・ファイル）→ 未対応（同上）

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴 19 件（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-cobol-cics-batch-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面遷移・ジョブフロー・レコード定義と物理の定義・CRUD マトリクス等） | `../specs/_appendix-cobol-cics-batch.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-calls`/`list-dd`/`overflow`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find のみで動く（追加のツールを要求しない）。
1 サブコマンドあたりの所要時間の実測: COBOL 40〜50 本・JCL 15〜55 本で 2〜50 秒（Windows の Git Bash）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **断面の 4 点（ソース・資源定義・JCL・DDL）がそろっているか（Phase 0）。** 欠けは `mod-diff` / `ep-diff` / `screen-diff` が出す。
  追加取得か対象外（ADR）かを決める（DP-cobol-cics-batch-1）。
- **定義だけのトランザクション・表・マップの扱い。** 開始トランザクション（端末から入力）・製品提供・テスト用・死蔵に分け、対象外は ADR で処分する。
- **システム・製品提供のプログラムの扱い。** `mod-diff` は接頭辞で「システム・製品提供の疑い」と付記するだけ。業務プログラムが紛れていないか人が確かめる。
- **73 桁目以降にはみ出たコード・デバッグ行。** `overflow` の出力を `observed-anomalies` に記録し、仕様に書かない（DP-cobol-cics-batch-5）。
- **IMS・MQ を併用する場合。** この Playbook の `gate-snippets.sh` は IMS の DB・MQ のキューを数えない。`enumeration.md` の目印の系統 ③④ を手で数える。
