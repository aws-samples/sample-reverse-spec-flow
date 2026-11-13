# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性質

`reverse-spec-flow` は**フレームワーク本体**であり、ビルド・テスト・実行対象のアプリケーションではない。
既存ソースコードを解析して仕様書を生成する（コード→仕様のリバースエンジニアリング）ための
AI 駆動ワークフローを、`init.sh` + テンプレート群 + プレイブックとして提供する。言語非依存。

- 依存パッケージ・ビルドシステム・テストランナーは**存在しない**（bash + Markdown のみ）。
- このディレクトリ自体は git 管理外（親ディレクトリは版管理外）。`init.sh` が**別の**新規リポジトリを作る。
- **プラットフォーム基盤（グラフ DB・ベクター DB・エンベディング）は持たない・要求しない。**「コードグラフ」は
  物理 DB でなく AI が書く Markdown の構造マップ、コード探索はホスト AI ツールに委譲する。基盤が要るのは
  「消費時の検索/chat（将来ポータル）」と「無人自動生成（自動化版）」の 2 局面のみで、いずれもスコープ外。
  この境界を変える提案が来たら、ツール非依存・依存ゼロの核心価値と衝突しないか必ず確認する（詳細は `pipeline.md` スコープ境界節）。

## 唯一の主要コマンド

```bash
./init.sh <解析対象ソースのパス> <spec-name> [purpose] [--playbook <name|path>] [--host <name|path>]
# 例: ./init.sh /path/to/legacy-order-system order-system rebuild --playbook java-jaxrs-jpa
# ./init.sh --list-playbooks で利用可能な Playbook を、--list-hosts で利用可能なホストを確認できる
```

`init.sh` は解析対象の隣に `<source>-spec/` という**独立した新規 git リポジトリ**を作り、
テンプレートを配置して初期コミットし、`spec/<spec-name>` ブランチに切り替える。
解析対象ソースは**コピーも変更もしない**（参照専用）。

## 決定的に重要な役割分担（セッション境界）

**このリポジトリで行うのは init.sh の実行（STEP 1）まで。** 実際の仕様書生成作業（Phase 0〜4）は
生成された `<source>-spec/`（ルート。`spec-extraction/` で開かない）を開いて**別セッション**で行う。ここで解析作業を始めてはいけない。

生成される構造:
```
<source>/                    解析対象（参照専用・変更しない・コピーしない）
<source>-spec/               ★init.sh が作る独立 git リポジトリ (branch: spec/<spec-name>)
  ├── specs/                 成果物: overview / modules / api / data / behavior
  └── spec-extraction/       作業アセット (AGENTS.md, pipeline-procedure.md, 00-ingestion 〜 03-audit, worklog, docs/)
```
成果物（specs/）と作業記録（spec-extraction/）は同じリポジトリ・同じブランチに同居し、まとめてコミットする。

## 生成パイプライン（コアワークフロー）

作業手順は、コード→仕様の自動生成基盤で実証された生成パイプラインの設計思想を写像した
**5 段パイプライン**として構造化されている。各 Phase は中間生成物を経て段階的に仕様を構築する（`pipeline.md` / `GP-N`）:

| Phase | 名称 | パイプライン段 | 拠点 | 主な生成物 |
|-------|------|------------------|------|-----------|
| 0 | 取り込み・スコープ確定 | Source Ingestion | `00-ingestion/` | 断面固定・スコープ/除外・固有文脈 |
| 1 | コードグラフ構築 | Code Graph Generation | `01-code-graph/` | 構造マップ（ノード/エッジ）＝カバレッジ基準 ＋ 分析作業計画書（work-plan、GP-17）＋（多数ドメイン時）レイヤ化ロードマップ（roadmap、GP-18） |
| 2 | 分析 | Code Analysis | `02-analysis/` | カテゴリ別分析物（ARCH/REQ/API/DATA/BEHAVIOR/SEC） |
| 3 | 仕様生成 | Documentation Generation | `../specs/` | 29148 準拠章立ての仕様（`[[分析物ID]]` 引用＋検証付き） |
| 4 | 監査 | Audit | `03-audit/` | 網羅性・引用実在の突合結果 |

## ファイル間の設計上の関係（編集時に整合を保つ）

このフレームワークを編集するとき、以下の 6 箇所は密結合しており、片方だけ変えると壊れる:

1. **`init.sh`** — 配置するファイルとディレクトリ構造を定義。`templates/*.template` と `playbook.md`,
   `pipeline.md`, `AGENTS.md.template` をコピーする。テンプレートを追加・改名したら `init.sh` の `cp` 行と
   `mkdir` 行（フェーズディレクトリ名）も更新する。
2. **`AGENTS.md.template`** — 生成先リポジトリの AI 行動規範。`<SOURCE_PATH>`（解析対象の実パス）と
   `<SPEC_NAME>`（知見の採番名前空間 `GP-<spec-name>-N`）は `init.sh` が `sed` で置換する
   （これらのプレースホルダー名を変えるなら `init.sh` の sed も直す）。それ以外の `<...>` は初回セッションで人が埋める。
3. **`pipeline.md`** — 生成プロセスの規約。`GP-N` 形式。フェーズ構成・中間生成物・引用記法の Single Source of Truth。
   行動規範（AGENTS.md）・手順書（pipeline-procedure）は各段に対応する `GP-N` を参照している。
4. **`playbook.md`** — 仕様品質の不変条件。`SB-N` 形式。各 `GP-N` から相互参照される。SB/GP を追加・改番したら
   AGENTS.md・pipeline-procedure・templates の参照も揃える。
5. **`templates/`** — 生成先の作業アセットの雛形（pipeline-procedure・session-context・code-graph・traceability・rebuild-readiness・observed-anomalies・work-plan・roadmap・lessons-learned・decisions・**investigation**（着手時の受け皿。GP-28）・**subtask-plan**・**gates.sh**）。
   フェーズ名・ディレクトリ名は init.sh の構造と一致させる。`code-graph.md.template`（GP-2・ノード＋エッジ 2 レジストリ）・`work-plan.md.template`（GP-17）・`roadmap.md.template`（GP-18・多数ドメイン時）は `01-code-graph/` に、`observed-anomalies.md.template`（SB-13）・`gates.sh`（GP-6 ルール7 の実行可能ゲート。Phase 1/3/4 の完了条件＝`gates.sh phase<N>` exit 0。検証結果の正本は `gate-results.md`）は `03-audit/` に配置。
   **`templates/procedures/`** は手順書の付録（状況限定部分。GP-102）で、**適用条件が `gate-config.env` の値で機械判定できるものだけ**を置く
   （`rebuild-layer.md` = `REBUILD_LAYER` / `DENSITY_GATES`）。条件が偽なら `init.sh` が**配置しない**。
   「大規模時」「高影響な宣言時」等の AI 判断で決まる部分は付録化せず手順書本体に残す（規律を自己判断の先に置かない）。
   **検証官の隔離を強制する配布物は harness 層にある**（`hosts/claude-code/agents/spec-verifier.md`・`hosts/claude-code/hooks/verifier-guard.sh`
   → `.claude/`、`hosts/kiro-cli/kiro-verify.sh` → `03-audit/`。各 `placement.sh` が置く）。skill・手順書は役割だけを書き、
   実体は各 harness の `entry.md` §5（生成先ではルートの `HOST.md`）が正本。`entry.md` §5 の `subagent_type: spec-verifier` と定義の `name`、
   hook・`kiro-verify.sh` が読む `gate-config.env` の `SOURCE_PATH` が密結合（名前・キーを変えるなら両方と selftest を直す）。
6. **`playbooks/<domain>/`** — ドメイン固有知識の交換可能な層（GP-105）。**固定ファイル名が契約**:
   `README.md`・`enumeration.md`（**必須**。列挙の独立ソース＝分母の定義）・`practices.md`（`DP-<domain>-N`）・
   `spec-appendix.md`・`gate-snippets.sh`。`init.sh --playbook <name|path>` が配置し、`gate-config.env` の
   `PLAYBOOK` に記録する。`--playbook` は繰り返せて（併用。GP-105 ルール11）、2 つ目以降は
   `enumeration-<名前>.md` / `gate-snippets-<名前>.sh` / `practices-<名前>.md` / `playbook-<名前>.md` に置き、
   全部の名前を `PLAYBOOKS` に記録する（`G-ENUM-SOURCE` が `enumeration*.md` をすべて検査する）。**手順書・GP/SB に特定スタックの目印（アノテーション名・設定ファイル名）を書かない**
   （別スタックで分母突合が計算不能になる。実測: roller は `@Path`/`@Table` が 0 件）。
   新規作成手順は `docs/authoring-playbook.md`。未指定時は `_template` の雛形が置かれ、
   `gates.sh` の `G-ENUM-SOURCE` が未記入を FAIL にする（「分からない」を「やらない」に落とさない）。

### 採番は番号帯で分離する（`./next-id.sh` を必ず使う）

**新しい GP/SB/FB は `./next-id.sh` で採番する。****フレームワーク本体は 100 番以降**を使い、
稼働中のプロジェクトが自然に使う 1〜99 と**構造的に分離する**。

これは **3 回続けて衝突したため**の方式変更である:
Phase G は GP-23 を記憶で判断して衝突、Phase H は SB-32 を 1 時間前の実測値で採って衝突、Phase J は SB-34 を実測直後に採ったのに衝突した。<!-- refcheck:ignore -->
根本原因は**単一の連番空間を本体と
稼働中プロジェクトが同時に消費している**ことで、「測ってから採る」方式は測定と採番の間に
隙間がある限り必ず破れる（プロジェクトは並行して作業を続けており、隙間はゼロにできない）。
Phase F の名前空間分離（`GP-<spec-name>-N`）も、**それ以前に生成されたプロジェクト**は
宣言のないコピーを持つため無印を採り続ける（遡って直せない）。

`./next-id.sh --check` が他リポジトリとの意味の衝突を検査し、`selftest.sh` からも毎回呼ばれる。
未コミットの追記も占有として数える（git 状態を見ない）。**1〜99 の既存エントリは維持する**
（GP-9 の欠番保持。改番は衝突が実際に起きたものだけ）。

**フレームワーク自体を変更したら `./selftest.sh` を必ず実行する**（上記 6 箇所の密結合のスモークテスト。
init.sh のフィクスチャ実行・期待ファイル検査・gates.sh の偽陰性/偽陽性検査・テンプレ整合を検証し、exit 0 で通過）。

**さらに `dev/developing-the-framework.md` を読む**（本体改造時に実際に踏んだ落とし穴 66 件＋未着手事項）。
特に**完了の 4 条件**——(1) selftest が通り**検査項目を追加している**、(2) GP/SB 追記は手順書の Step 反映と対で決める、
(3) **コミット前に別コンテキストのサブエージェントで反証レビュー**、
(4) **配布物に出所・業務ドメインの語・固有識別子が入っていないかを判定した**（`dev/backport-procedure.md` 手順 2b）——は毎回守る
（Phase F〜N の全フェーズで、自己申告の「完了」時点に blocking 級の欠陥が残っていた）。

## 文書の階層（ランタイム契約と参照文書）

生成先リポジトリで**実行時に従う唯一の文書は `pipeline-procedure.md`（手順書）**である（＋AGENTS.md の行動制約
＋`gates.sh`）。`pipeline.md`（GP-N）と `playbook.md`（SB-N）は「なぜそのルールがあるか」（実運用フィードバック・根拠・
ゲートの詳細設計）を保持する**参照文書**で、手順書・AGENTS.md から ID でオンデマンド参照される。
**手順書に反映されていない運用ルールは実行時には存在しないのと同じ**——GP/SB に知見を追記するときは
「pipeline-procedure.md.template のどの Step に反映するか」を必ず対で決める（両ファイルの追記・改廃ルールに明記済み）。

### 二系統の知見体系（GP-N と SB-N）＋ 実運用フィードバック（FB-N）

**`playbook.md` の「実運用フィードバック（FB-N）」表**が、GP/SB の根拠となる実運用の失敗を一元定義する。
GP/SB 本文は `FB-N` でそれを参照する（従来は参照だけが存在し定義台帳が無かった）。
同一メタ原理——「必須ゲートでない散文ルールは自己申告で素通りする」——が繰り返し観測されており、
該当エントリの一覧は実運用フィードバック表の直後の注記が正本（個々のエントリ本文の「N 度目」は執筆時点の観測数で通し番号ではない）。
新ルールを作るときは「これは実行物になっているか」「**量まで指定しているか**」を必ず問う
（FB-6 = 対策自身が量を問わなかったため最小限の実施で形骸化した失敗）。


- **`pipeline.md`（GP-1〜GP-28・GP-100〜107）** — 「どう生成するか」= 生成プロセスの構造。段階パイプライン（GP-1）・コードグラフ
  （GP-2）・カテゴリ分析（GP-3）・トレーサビリティ（GP-4）・UNKNOWN（GP-5）・監査の実行ゲート化（GP-6）・
  スコープ設定（GP-7）・29148 準拠（GP-8）・機械可読/配布単位（GP-9）・縦串反復（GP-10）・middle-out（GP-11）・
  参考情報（GP-12）・rebuild 分離（GP-13）・可読性/統合ビュー（GP-14）・並列実行（GP-15）・敵対的検証（GP-16）・
  work-plan（GP-17）・ロードマップ（GP-18）・成果物形態ゲート（GP-19）・密度監査（GP-20）・目標密度の 29148 導出
  （GP-21）・密度昇格の Verify 必須化（GP-22）・中断耐性と仮説ログ（GP-28）・セッション境界の手順化（GP-100）・進捗状態の正本一元化（GP-101）・手順書付録の条件付き配置（GP-102）・ゲートの適用単位を量で縛る（GP-103）・**tier で段階配達する（GP-104。実測で撤去＝欠番スタブ）**・ドメイン固有知識の Playbook 分離（GP-105）・Tier ゲートと HOLD トリガー（GP-106）。各エントリの一言サマリは pipeline.md 冒頭のサマリ表を参照（改番の履歴は pipeline.md の欠番スタブが正本）。
- **`playbook.md`（SB-1〜SB-21・SB-100〜102。SB-22〜33 は欠番）** — 「何を守るか」= 仕様品質の不変条件。裏取り（SB-1）・網羅性（SB-2）・
  トレーサビリティ（SB-3）・事実/推測分離（SB-4）・非破壊（SB-5）・動的挙動（SB-6）・外部 I/F（SB-7）・
  入口/UI 精読（SB-8）・データ全数突合（SB-9）・横断文書の確定更新（SB-10）・分母消化（SB-11）・高影響宣言の
  独立検証（SB-12）・進化途上コード（SB-13）・記録鮮度（SB-14）・カテゴリ対称性（SB-15）・成果物形態（SB-16）・
  密度対称性（SB-17）・目標密度宣言（SB-18）・密度ゲートの区別（SB-19）・fabricated=0 反映ゲート（SB-20）・
  Verify 必須（SB-21）・停止条件の機械化（SB-100）・実証なき因果確定の禁止（SB-101）・**ゲートの適用単位の量（SB-102）**。各エントリの一言サマリは playbook.md 冒頭のサマリ表を参照。

**正本の向き**: 各 GP は関連する SB を相互参照する（例: GP-2 → SB-2、GP-4 → SB-1/SB-3）。**GP と SB が同一テーマの
対を成す場合（GP-19↔SB-16、GP-20↔SB-19、GP-21↔SB-18、GP-22↔SB-20/21、GP-16↔SB-12、GP-6↔SB-10/11、GP-106↔SB-100、GP-28↔SB-101、GP-101↔SB-14、GP-103↔SB-102）、
手順・ゲート実装の詳細は GP が正本**で、SB 側は「不変条件の宣言＋失敗サマリ＋正本 GP への参照」に圧縮されている。
SB を編集するときこの構造を崩さない（詳細を SB に書き戻して二重記述を復活させない）。

## 追記・改廃ファイルの規約

`pipeline.md`（GP-N）、`playbook.md`（SB-N）、`lessons-learned.md.template`（LL-N）、`decisions.md.template`（ADR-N）は
いずれも末尾の `<!-- ENTRIES END -->` マーカーの**直前**に新エントリを挿入する（マーカーは移動しない）。連番採番。

- **ADR**: 過去エントリを変更せず、覆す場合は新規 ADR で `Supersedes: ADR-N` を参照する（従来どおり追記専用）。
- **GP/SB**: 追記に加えて**明示的改廃を許可する**。既存エントリを統合・置換する場合、統合先に `Supersedes: GP-N/SB-N`
  を明記し、旧エントリの本文を「→ [統合先] へ統合（git 履歴参照）」のスタブに置換してよい。**番号は欠番として保持し
  再利用しない**（GP-9 の永続 ID 原則）。サマリ表の行もスタブ化する。git 履歴が全文アーカイブ（知見は消えない）。
  GP/SB の追記時は「手順書のどの Step に反映するか」を対で決める（各ファイルの追記・改廃ルール参照）。
- **FB（実運用フィードバック）**: `playbook.md` の「実運用フィードバック（FB-N）」表が定義の正本。**追記専用・改廃しない**（起きた事実は覆らない）。
  GP/SB 本文から `FB-N` で参照する。`selftest.sh` T5 がリンク閉包を検査する。

### 採番権の所在（プロジェクトとフレームワークの分離）

**無印の `GP-N` / `SB-N` / `FB-N` を採番できるのはこのフレームワークリポジトリだけ**である。
`init.sh` が生成先へコピーする `pipeline.md` / `playbook.md` は**参照専用の台帳**で、冒頭に採番禁止の宣言が
自動注入される。プロジェクトが得た汎用知見は `GP-<spec-name>-N` / `SB-<spec-name>-N` の名前空間で追記し、
完了時に `dev/backport-procedure.md` の手順でフレームワークへ還元する（そこで改めて採番される）。

**還元は「プロジェクトの情報が配布物へ流れ込む唯一の経路」でもある。** 出所の名前を書く前に
`backport-procedure.md` 手順 2b で秘匿性を判定し、公開できない出所は**匿名ラベル**にして
`dev/backport-sources.allow`（許可リスト）へ登録する。禁止リストは作らない——公開できない名前を
列挙したファイルはそれ自体が索引になる。`selftest.sh` T6 が出所欄と許可リストを突合するが、
**守るのは出所欄だけ**で、本文に混ざった業務語は人が抽象化する（手順 2b の 3・4）。

この分離は実際の失敗への対策である: 実運用で `fineract-1.15.0-spec` が独自に GP-23〜25 / SB-22〜30 を採番し、フレームワーク本体の次の空き番号と衝突していた（GP-9 違反）。<!-- refcheck:ignore -->
**還元候補の判定は「既存エントリの改訂」を優先し、安易に新番号を起こさない**
（同一テーマの兄弟エントリを増やすと GP↔SB の正本構造が崩れる）。

## テンプレートを編集するときの注意

- `*.template` 内の `<PLACEHOLDER>`（`<PRODUCT_NAME>`, `<SOURCE_PATH>`, `<SPEC_PURPOSE>` など）は
  生成後に埋められる意図的なプレースホルダー。**このリポジトリ内で埋めてはいけない**。
- `<SOURCE_PATH>` と `<SPEC_NAME>` のみ `init.sh` が実行時に置換する（`AGENTS.md` 内）。
  それ以外は生成先の初回セッションで人が埋める。
- 説明・原則を変更するときは README.md / playbook.md / AGENTS.md.template / 該当テンプレートの
  記述が食い違わないよう横断的に更新する。
