#!/bin/bash
# =============================================================================
# gates.sh — 実行可能ゲート（GP-6 ルール7 の実装）
# =============================================================================
#
# 監査ゲートを「散文中のコマンド例」から「配布される実行物」に移したもの。
# 「必須ゲートでない散文ルールは自己申告で素通りする」（FB-4/SB-11/SB-12/SB-16/SB-19 の
# メタ原理）への根治として、ゲートの実行有無・書式を AI の裁量から外す。
#
# 使い方（spec リポジトリのどこから実行してもよい。git ルート起点で自己解決する）:
#   bash spec-extraction/03-audit/gates.sh <subcommand>
#     phase1    Phase 1 完了ゲート（コードグラフ・work-plan の形式検査）
#     phase2    Phase 2 **途中確認**（完了条件ではない。進行中でも欠陥を意味するゲートだけ）
#     phase3    Phase 3 完了ゲート（front-matter・index・リンク閉包）
#     phase4    Phase 4 完了ゲート（全ゲート。完了/レディ宣言の前提）
#     all       phase1 + phase3 + phase4
#     density   密度ゲートのみ（Phase B で実装。gate-config.env の DENSITY_GATES に従う）
#     metrics   メトリクススナップショット（Phase D で実装）
#     session   セッション終了チェック（GP-100。gate-results.md には書き込まない）
#     source-index  逆引き索引を生成する（成果物。gate-results.md には書き込まない）
#     source-baseline  解析対象の今の状態を記録する（init.sh が呼ぶ。意図して変えたら ADR を書いてから呼び直す。G-SOURCE-INTACT が比べる）
#
# 判定は 5 種: PASS / **FAIL（欠陥）** / **INCOMPLETE（まだ終わっていない）** / WARN / SKIP
#   FAIL と INCOMPLETE はどちらも非ゼロ終了（完了条件は緩めない）。分けるのは優先順位の判別のため。
# 詳細行は既定 10 件までに絞り、全件は 03-audit/gate-details.log に残す（GATES_DETAIL_MAX で変更可）。
#
# 終了コード: 0 = 全通過 / 1 = 未達あり（欠陥または未完了） / 2 = 実行前提エラー（構成不備）
# 出力: 標準出力（人間可読）＋ spec-extraction/03-audit/gate-results.md へ追記（検証結果の正本）
#
# 設計原則:
#   - 検査は grep/awk/wc のみ（ツール非依存: GP-9。DB・外部コマンド依存を作らない）
#   - 失敗時は「どのファイルのどの行が未達か」を必ず出力する（0/1 だけのゲートは直せない）
#   - 機械化不能なゲート（独立検証の実施・列挙の実行そのもの）は「記録欄が埋まっているか」の
#     存在検査に落とす。「機械化できない」を「検査しない」にしない（GP-6 設計原則）
# =============================================================================
set -uo pipefail

# ---- パス解決（git ルート起点で自己完結） ----
# 【この診断は CRLF でも印字される必要がある】このファイル自身が CRLF だと bash は
# `set: pipefail: invalid option name` を経てここに来る（リポジトリの中にいるのに「外だ」と言う）。
# **複数行の if を挟むと `syntax error: unexpected end of file` で死ぬ**ので 1 行に閉じる（実測）。
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: git リポジトリ内で実行してください（このファイル自身が CRLF の可能性: Windows の core.autocrlf。(1) .gitattributes を置いて commit（共有なら push）、(2) リポジトリ全体を取得し直す。(1) を飛ばすと取得し直しても元に戻る。このファイルだけ取り直しても仕様書の .md が CRLF のまま残り別のゲートが誤って FAIL になる。git add --renormalize は index だけで作業ツリーは直らない）" >&2; exit 2; }
SPECS="$REPO_ROOT/specs"
WROOT="$REPO_ROOT/spec-extraction"
AUDIT="$WROOT/03-audit"
CODEGRAPH_DIR="$WROOT/01-code-graph"
CODEGRAPH="$CODEGRAPH_DIR/code-graph.md"
WORKPLAN="$WROOT/01-code-graph/work-plan.md"
ROADMAP="$WROOT/01-code-graph/roadmap.md"
SCOPE="$WROOT/00-ingestion/scope.md"
DECISIONS="$WROOT/docs/decisions/decisions.md"
RESULTS="$AUDIT/gate-results.md"
GATE_CONFIG="$WROOT/00-ingestion/gate-config.env"
# 【定義がここにある理由】下の設定値検証が中断する前に**痕跡を残す**必要があるため
# （上限の設計理由は後段の DETAIL_MAX の注記が正本）。
DETAILS_FILE="$AUDIT/gate-details.log"

# 【使い方は設定検証より前に読めること】設定値が不正なら入口で `exit 2` して中断する設計にした結果、
# **直し方を読むための `--help` すら中断に巻き込まれていた**（実測）。
# 【なぜ CRLF 診断より後なのか】`case` を先頭に置くと、このファイル自身が CRLF のときに
# 行末の CR で `esac` が壊れて **CRLF の診断そのものが出なくなる**（実測。同じ罠を `init.sh` で
# 踏んで「1 行に閉じる」形にした経緯がある）。診断を通したうえで、設定読み込みより前に置く。
# 【行数を決め打ちしない】`grep '^#     ' | head -8` にしていたため、**実在する
# `source-index` が help に出ず**、表に 1 行足しても出ないままだった（同じ 1 行が入口と `*)` に
# 重複してもいた）。「使い方」見出しから最初の空コメント行までを範囲で取る。
print_usage() {
  # 【起動方法の行も出す】`^#     `（5 スペース）だけを拾っていたため、**どう起動するか**を書いた
  # 3 スペースの行が落ちて、いきなりサブコマンド名から始まる出力になっていた（実測）。
  LC_ALL=C awk '/^# 使い方/ { f = 1; print; next } f && /^#[[:space:]]*$/ { exit } f { print }' "$0"
}
case "${1:-}" in
  -h|--help|help) print_usage; exit 0 ;;
esac

[ -d "$SPECS" ] && [ -d "$WROOT" ] || {
  echo "ERROR: specs/ または spec-extraction/ が見つかりません（root=${REPO_ROOT}）" >&2; exit 2; }

# gate-config.env（Phase B で init.sh が生成。無ければ既定値）
PURPOSE="unknown"
# 生成時の目的（`init.sh` が記録する）。**既存リポジトリはこのキーを持たない**ので既定は空にし、
# 空のときは「変更を追跡できない」ことを情報として出す（黙って素通しにしない）。
PURPOSE_INITIAL=""
DENSITY_GATES="warn"
# 本質層（specs/rebuild/）を作るかどうか。init.sh が purpose から決める
#   off      = 作らない（purpose=maintenance）
#   skeleton = 骨子のみ（purpose=evaluation）
#   full     = フル（purpose=rebuild）
# 【既定を full にする理由】**既存リポジトリはこのキーを持たない**。既定を off にすると
# 本質層の要求が黙って消え、`purpose=rebuild` の既存リポジトリで検査が緩む（fail-open）。
# 未設定は「最も厳しい側」に倒す。
REBUILD_LAYER="full"
INTEGRATED_VIEW_DOC=""
# 解析対象ソースのルート。**既存リポジトリはこのキーを持たない**ので既定は空にし、
# 空のときは索引化を諦めるのではなく「解決なし」に縮退する（GP-4 ルール7）。
SOURCE_PATH=""
# 解析対象からの除外（POSIX ERE）。ビルド生成物のディレクトリ名はスタック固有なので
# 汎用ゲートに決め打ちしない（GP-105）。Playbook の enumeration.md が規定し Phase 0 で設定する。
SOURCE_EXCLUDE=""
# Playbook 名（GP-105）。**既定値の宣言が無いと、将来どれかのゲートが読んだ瞬間に
# `gate-config.env` を持たない既存リポジトリで unbound になる**。
PLAYBOOK=""
# 併用した Playbook の全部（空白区切り。1 つ目が主＝PLAYBOOK。GP-105 ルール11）。
# 未設定の既存リポジトリでは空で、そのときは PLAYBOOK だけを使っているとみなす。
PLAYBOOKS=""
# 【設定の構文エラーを黙って無視しない】実測（2026-09-09）:
#   `source` は構文エラーの行を**黙って捨てて rc=0 を返す**（後続の行は読まれる）。
#   `bash -n` も rc=0 を返すので、**終了コードでは検出できない**。stderr の有無で見るしかない。
#   実害: `SOURCE_EXCLUDE=(^|/)target/` のように**引用符を付け忘れると値が未設定になり**、
#   ゲートは「除外なし」で走る。**設定したつもりの条件が効かないまま緑になる。**
# shellcheck disable=SC1090
if [ -f "$GATE_CONFIG" ]; then
  # 【mktemp の rc を見る】失敗すると `_gc_err=""` になり、`source … 2>""` の**リダイレクトが失敗して
  # source 自体が実行されない**。それでも `[ -s "" ]` は偽なので**設定を丸ごと無視して既定値で走る**
  # （実測: TMPDIR=/nonexistent で DENSITY_TIER 3 → 1、DENSITY_GATES on → warn に落ちた）。  [撤去の記録]
  # このブロックの目的そのものが同じ形で破れていた。
  if ! _gc_err="$(mktemp "${TMPDIR:-/tmp}/gates-gc.XXXXXX")" || [ -z "$_gc_err" ]; then
    echo "ERROR: 一時ファイルを作れません（TMPDIR=${TMPDIR:-/tmp}）。設定を読めないまま走らせないため中断します" >&2
    echo "  gate-results.md / gate-verdicts.tsv の内容は前回の実行のもので、今回の判定は 1 件も記録していません" >&2
    echo "# gates.sh: 一時ファイルを作れず中断（判定は 1 件も記録していない）" > "$DETAILS_FILE" 2>/dev/null || true
    exit 2
  fi
  source "$GATE_CONFIG" 2>"$_gc_err"
  if [ -s "$_gc_err" ]; then
    echo "ERROR: gate-config.env に構文エラーがあります（値が未設定のまま走るため中断します）" >&2
    sed 's/^/  /' "$_gc_err" >&2
    echo "  正規表現などの値は引用符で囲むこと: SOURCE_EXCLUDE='(^|/)target/'" >&2
    rm -f "$_gc_err"; exit 2
  fi
  rm -f "$_gc_err"
fi

# 【値の末尾の CR を剥がす（Windows でチェックアウトすると CRLF になる）】
# `source` は `PURPOSE=rebuild\r` を**CR 込みの値**として代入するので、
#   - 修正前（比較のみ）: `[ "$PURPOSE" = "rebuild" ]` が外れて**検査が黙って消える**（fail-open）
#   - 値の検証を入れた後: 正当な値でも不正と判定され、**端末では CR が不可視なので
#     「許可値と同一の文字列を不正と言う」**自己矛盾になり、読者に解決手段がない
# どちらも受け入れられないので、**CR は剥がして受ける**。
# 【ただしこれは 2 段目の防御】1 段目は `.gitattributes`（`* text=auto eol=lf`）である。
# **本体と「これから生成する」リポジトリには `init.sh` が置くが、既に生成済みの
# リポジトリには届かない**——そちらは手で追加する。**順序が要る**（すべて実測）:
#   (1) `.gitattributes` を置いて **commit**（共有リポジトリなら push）
#   (2) **リポジトリ全体を**取得し直す
#   **(1) を飛ばすと取得し直しても元に戻る**——未コミットの `.gitattributes` は再クローン先に
#   存在しない。**1 ファイルだけ取り直す形（`rm` ＋ `git checkout`）は勧めない**——
#   `gates.sh` は直るが**仕様書の `.md` が CRLF のまま残り、`G-REPAIR` / `G-SYMMETRY` /
#   `G-INDEX` が誤って FAIL / WARN になる**（実測。判定は厳しい側にしか動かないので
#   偽の緑にはならないが、出力が CR に言及しないので受け取った人は直せない）。
#   `git add --renormalize .` は index だけを直し、**作業ツリーの CR は 1 バイトも剥がさない**。
#   （`docs/release-notes.md` の移行手順に記載）
# 1 段目が無いと Git for Windows 既定の `core.autocrlf=true` で
# **`gates.sh` 自身が CRLF になり、設定を読む前に「git リポジトリ内で実行してください」と
# 誤診して止まる**（実測）。CR 剥がしはその先の防御であって代わりにはならない。
PURPOSE="${PURPOSE%$'\r'}"
PURPOSE_INITIAL="${PURPOSE_INITIAL%$'\r'}"
DENSITY_GATES="${DENSITY_GATES%$'\r'}"
REBUILD_LAYER="${REBUILD_LAYER%$'\r'}"
INTEGRATED_VIEW_DOC="${INTEGRATED_VIEW_DOC%$'\r'}"
SOURCE_PATH="${SOURCE_PATH%$'\r'}"
SOURCE_EXCLUDE="${SOURCE_EXCLUDE%$'\r'}"
PLAYBOOK="${PLAYBOOK%$'\r'}"
PLAYBOOKS="${PLAYBOOKS%$'\r'}"

# 【解析対象を物理パスに直す（2026-09-24 の実測。FO-1）】
# `SOURCE_PATH` がシンボリックリンク経由だと**走査が黙って 0 件になる**。
# macOS / BSD grep 2.6.0-FreeBSD での実測（`link -> real` を走査。正解は 1 件）:
#
#   | 形                          | rc | 件数 |
#   |-----------------------------|----|------|
#   | `find link`                 | 0  | 0    | ← **無警告で 0**（最も危険）
#   | `find link \| xargs grep`   | 0  | 0    | ← **無警告で 0**
#   | `grep -rl … link`           | 1  | 0    |
#   | `grep -Rl … link`           | 1  | 0    | ← **`-R` でも追わない**
#   | `find -L link` / `find link/` | 0 | 1  | ← 正しい
#
# `cd … && pwd -P` で物理パスにすれば**裸の `find` でも正しい件数になる**（実測で確認）。
# ⇒ 走査形を 1 つずつ直すのではなく**入口で 1 回正規化する**（直し漏れが起きない）。
# 【`cd` 経由の既存走査は元から安全】`( cd "$SOURCE_PATH" && find . … )` は `cd` が解決するので
# 影響を受けない。ここで直すのは**パスを引数に渡す形**と、**この値を読んで人が書くコマンド**である。
# 【解決できないときは値を変えない】存在しない・権限が無いパスで空文字にすると
# 「SOURCE_PATH 未設定」に化けて `G-SOURCEINDEX` が黙って縮退する（fail-open）。元の値を残して
# 後段の `[ -d ... ]` 検査に判定させる。
if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then
  _sp_phys="$(CDPATH= cd -- "$SOURCE_PATH" 2>/dev/null && pwd -P)" || _sp_phys=""
  [ -n "$_sp_phys" ] && SOURCE_PATH="$_sp_phys"
  unset _sp_phys
fi

# 【設定値の妥当性を 1 箇所で検証する（2026-09-14）】
# 実測で 2 つの fail-open があった——どちらも**綴り違い 1 文字で検査が消える**:
#   (1) `PURPOSE=Rebuild` にすると `[ "$PURPOSE" = "rebuild" ]` が外れ、`gate_tier` の
#       「tier 3 未到達」の未達が消えた（`Rebuild` / `REBUILD` で再現）。  [撤去の記録]
#   (2) `DENSITY_GATES=On` にすると `case` の `*)` に落ち、密度ゲート 4 本が**一本も走らず**
#       `rc=0` になった（`on` では rc=1 だった）。`off` より緩い状態が作れていた。
# 個々の条件式を fail-closed に直しても、**設定値を見る箇所が増えるたびに同じ穴が空く**。
# よって「どの値なら走ってよいか」を**入口で 1 度だけ**判定する。
# 【なぜ WARN でなく中断か】上の構文エラー検査と同じ理由——「設定したつもりの条件が効かないまま
# 緑になる」のが実害で、WARN は終了コードに影響しないので緑を止められない。
# 不正値は人が 1 行直せば解ける（誰も直せない未達にはならない）。
# 【`unknown` は正当な既定値】gate-config.env を持たない既存リポジトリがこれになる。
_cfg_bad=""
# 【`unknown` は「キーが無い」ことの既定値としてだけ許す】ファイルに `PURPOSE=unknown` と
# **書いてある**場合は弾く——`rebuild` → `unknown` の 1 語編集で `gate_tier` の
# 「tier 3 未到達」の未達が消えるため（実測。綴り違いと同じ穴を許可リスト側に開けていた）。  [撤去の記録]
# キー欠落の既存リポジトリは `grep` が偽になるので通る（そちらは壊さない）。
case "$PURPOSE" in
  rebuild|maintenance|evaluation) ;;
  unknown)
    # 【`export` 付きも拾う】`export PURPOSE=unknown` と書くと `source` では値が入るのに
    # この検証を素通りしていた（実測。1 語で入口検証が無効化できた）。
    if [ -f "$GATE_CONFIG" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?PURPOSE=' "$GATE_CONFIG" 2>/dev/null; then
      _cfg_bad="${_cfg_bad}  PURPOSE='unknown'（rebuild / maintenance / evaluation。unknown はキーが無いときの既定値で、明示して書く値ではない）"$'\n'
    fi ;;
  *) _cfg_bad="${_cfg_bad}  PURPOSE='${PURPOSE}'（rebuild / maintenance / evaluation）"$'\n' ;;
esac
case "$PURPOSE_INITIAL" in rebuild|maintenance|evaluation|"") ;; *) _cfg_bad="${_cfg_bad}  PURPOSE_INITIAL='${PURPOSE_INITIAL}'（rebuild / maintenance / evaluation。空 = 旧リポジトリ）"$'\n' ;; esac
# 【ファイルがあるのにキーが無い場合は弾く（2026-09-24 の実測。FO-3）】
# 空文字は rc=2 で止めているのに**キーの行ごと削除すると通っていた**（非対称）。
# 実測: `DENSITY_GATES` の行を消すと既定 `warn` に落ち、`G-LEDGER` が INCOMPLETE → WARN、
# `density` の rc が **1 → 0** になる。**検査対象を壊すのが最も簡単な全通過方法**という
# `G-LEDGER` が名指しで禁じている型そのものである。
# 【「キーが無い旧リポジトリ」と混同しない】許すのは **`gate-config.env` 自体が無い**場合だけ。
# ファイルがあるなら `init.sh` が必ずこの 3 キーを書いているので、無いのは**編集の結果**である
# （当初の検査は*ファイルを残したままキーだけ消して*「中断しない」を確認しており、
# 根拠コメントの「gate-config.env を持たない旧リポジトリ」を検査できていなかった）。
# 【3 キーに限る】実在の 9 リポジトリを実測すると、うち 5 つが後から足した
# `PURPOSE_INITIAL` / `SOURCE_PATH` / `SOURCE_EXCLUDE` を持たない。**それらを必須にすると
# 稼働中のリポジトリが止まる**ので、ゲートの厳しさを決める 3 キーだけを要求する。
if [ -f "$GATE_CONFIG" ]; then
  for _k in PURPOSE DENSITY_GATES REBUILD_LAYER; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?${_k}=" "$GATE_CONFIG" 2>/dev/null \
      || _cfg_bad="${_cfg_bad}  ${_k} のキーが無い（ファイルはあるので削除された。既定値に落ちて検査が緩むため中断する）"$'\n'
  done
  unset _k
fi
case "$DENSITY_GATES" in on|warn|off) ;; *) _cfg_bad="${_cfg_bad}  DENSITY_GATES='${DENSITY_GATES}'（on / warn / off）"$'\n' ;; esac
case "$REBUILD_LAYER" in off|skeleton|full) ;; *) _cfg_bad="${_cfg_bad}  REBUILD_LAYER='${REBUILD_LAYER}'（off / skeleton / full）"$'\n' ;; esac
if [ -n "$_cfg_bad" ]; then
  echo "ERROR: gate-config.env の値が不正です（検査が黙って消えるため中断します）" >&2
  printf '%s' "$_cfg_bad" >&2
  echo "  ${GATE_CONFIG#"$REPO_ROOT"/} を修正してください（値は大文字小文字を区別します）" >&2
  # 【正本が陳腐化して見えることを言う】判定を書かずに終わるので gate-results.md は前回の内容が
  # そのまま残る。**読者はそれを今回の結果と誤読しうる**ので、中断時に必ず断る（実測で起票）。
  echo "  gate-results.md / gate-verdicts.tsv の内容は前回の実行のもので、今回の判定は 1 件も記録していません" >&2
  # 【中断も痕跡を残す】判定を書かずに終わるため gate-results.md にも verdicts にも行が出ず、
  # かつ詳細ログの初期化は dispatch の後なので**前回の詳細がそのまま残っていた**（実測）。
  # 陳腐化した詳細を今回の結果と誤読しうるので、ここで上書きして中断の事実だけを残す。
  { echo "# gates.sh: 設定値が不正なため中断（判定は 1 件も記録していない）"; printf '%s' "$_cfg_bad"; } \
    > "$DETAILS_FILE" 2>/dev/null || true
  exit 2
fi

# ---- 共通ヘルパ ----
FAIL_COUNT=0
WARN_COUNT=0
INCOMPLETE_COUNT=0
declare -a REPORT_LINES=()

# 詳細行の出力上限（GP-6 ルール13）。
# 【なぜ上限が必要か】設計原則は「失敗行を必ず出力する（0/1 だけのゲートは直せない）」だが、
# **作業途中に走らせると未消化 170 件を毎回 170 行出す**ことになり、情報ではなくノイズになる。
# 実測（roller v5・2026-08-19）: 作業途中の `phase4` 1 回で **481 行 / 79KB ≒ 22,700 トークン**。
# 106 回実行で**ゲート出力だけで約 240 万トークン相当**を消費し、コンテキスト圧縮と
# セッション分割を招いて、そのたびに常時ロード 77KB を読み直す往復が実時間を膨らませた。
# 上限を切っても「直せる」ことは失われない——**先頭 N 件を出し、全件は gate-details.log に残す**。
DETAIL_MAX="${GATES_DETAIL_MAX:-10}"

# 出力量の実測値を残す（FB-12 の再発検知）。
# 【なぜ記録するか】FB-12 の切り分けでは「1 回の出力が何バイトだったか」を**後から測れなかった**ため、
# gate-results.md の実行回数と手元の再実行から推定するしかなかった。
# 推定に頼ると「効いたかどうか」が主観になる（SB-101: 実証なき因果確定の禁止）。
# 1 実行 1 行の TSV に残せば、**次の run と機械的に比較できる**。
RUNS_TSV="$AUDIT/gate-runs.tsv"
DETAIL_LINES_FULL=0     # 上限を切らなければ出力していた行数
DETAIL_LINES_SHOWN=0    # 実際に標準出力へ出した行数
PASS_COUNT=0

# ゲート**別**の判定履歴（`G-REGRESS`。GP-6 ルール17 / FB-10）。
# 【なぜ集計値では足りないか】`gate-runs.tsv` は 1 実行 1 行の**集計**（pass/fail の件数）なので、
# 「どのゲートが FAIL から PASS に転じたか」が分からない。FB-10 の最悪の点は
# **「ゲートが壊れている事実が記録に残らなかった」**ことで、集計値では同じ穴が残る。
# 【gates.sh の指紋を一緒に残す理由】FAIL→PASS の遷移そのものは正常（是正すれば起きる）。
# 検出したいのは**ゲート定義が変わって判定が反転した**場合＝「対象を直したのではなく
# ゲートを緩めて通した」疑いがあるケースで、これは指紋の差分がないと区別できない。
VERDICTS_TSV="$AUDIT/gate-verdicts.tsv"
declare -a VERDICT_LINES=()
GATES_SHA=$( { shasum -a 256 "$AUDIT/gates.sh" 2>/dev/null \
            || sha256sum "$AUDIT/gates.sh" 2>/dev/null \
            || cksum "$AUDIT/gates.sh" 2>/dev/null; } | awk '{print substr($1,1,12); exit}' )
GATES_SHA="${GATES_SHA:-unknown}"

# report <PASS|FAIL|INCOMPLETE|WARN|SKIP> <gate-id> <説明> [詳細(複数行可)]
#
# 【INCOMPLETE の意味（GP-6 ルール14）】「まだ終わっていない」と「壊れている」を区別する。
# 実測で、作業途中の FAIL 10 件のうち **9 件は未完了の signal で欠陥ではなかった**
# （未消化ノード 170・draft 18・未検証 53 …）。同じゲートが 31 回ずつ FAIL し続け、
# **毎回 10 件を読んで切り分ける**コストが積み上がっていた。
# **終了コードは変えない**（INCOMPLETE も非ゼロ）。完了/レディ宣言の条件は緩めない——
# 変えるのは「何を先に見るべきか」が判別できるようになることだけである。
report() {
  local status="$1" gate="$2" desc="$3" detail="${4:-}"
  case "$status" in
    FAIL)       FAIL_COUNT=$((FAIL_COUNT + 1)); local icon="❌" ;;
    INCOMPLETE) INCOMPLETE_COUNT=$((INCOMPLETE_COUNT + 1)); local icon="🚧" ;;
    WARN)       WARN_COUNT=$((WARN_COUNT + 1)); local icon="⚠️ " ;;
    PASS)       PASS_COUNT=$((PASS_COUNT + 1)); local icon="✅" ;;
    SKIP)       local icon="⏭️ " ;;
    # 【語彙外を受けても死なない】既定枝が無いと `icon` が未定義で `set -u` によりシェルが落ち、
    # **判定を 1 つも書かずに中断する**（`rc=2` と区別できない）。畳み込みの `rank()` は
    # 語彙外を最強側（FAIL より強い）に倒すので、ここも欠陥として数える。
    *)          FAIL_COUNT=$((FAIL_COUNT + 1)); local icon="⁉️ " ;;
  esac
  echo "${icon} [${status}] ${gate}: ${desc}"
  REPORT_LINES+=("| ${gate} | ${status} | ${desc//|/\\|} |")
  # ゲート別の判定を残す（G-REGRESS が次回に前回と突合する）。SKIP は履歴に入れない
  # ——「対象が無くて測っていない」を「通った」と読ませないため。
  [ "$status" = "SKIP" ] || VERDICT_LINES+=("${gate}"$'\t'"${status}")
  if [ -n "$detail" ] && [ "$status" != "PASS" ]; then
    local n shown; n=$(echo "$detail" | grep -c . || true)
    shown=$(( n < DETAIL_MAX ? n : DETAIL_MAX ))
    DETAIL_LINES_FULL=$((DETAIL_LINES_FULL + n))
    DETAIL_LINES_SHOWN=$((DETAIL_LINES_SHOWN + shown))
    echo "$detail" | grep . | head -n "$DETAIL_MAX" | sed 's/^/      /'
    if [ "${n:-0}" -gt "$DETAIL_MAX" ]; then
      echo "      … 他 $((n - DETAIL_MAX)) 件（全件: ${DETAILS_FILE#"$REPO_ROOT"/}）"
    fi
    # 全件は必ずファイルに残す（上限は「出力を絞る」だけで「記録を捨てる」ではない）
    { echo "### ${gate} [${status}] ${desc}"; echo "$detail" | grep .; echo ""; } >> "$DETAILS_FILE"
  fi
}

# note_detail <gate-id> <見出し> <詳細>
# PASS でも見せたい付随情報（受容済みの逸脱など）を出す。
# `report` は PASS の詳細を捨てる（PASS を静かに保つ設計）が、
# **「超過しているが verified なので受容した」は静かに捨ててはいけない**——
# 記録が残らないと、次に読む人が「超過が無い」と誤読する。
note_detail() {
  local gate="$1" title="$2" detail="$3"
  [ -n "$detail" ] || return 0
  local n; n=$(echo "$detail" | grep -c . || true)
  echo "      ℹ️  ${title}"
  echo "$detail" | grep . | head -n "$DETAIL_MAX" | sed 's/^/      /'
  [ "${n:-0}" -gt "$DETAIL_MAX" ] && echo "      … 他 $((n - DETAIL_MAX)) 件（全件: ${DETAILS_FILE#"$REPO_ROOT"/}）"
  { echo "### ${gate} [INFO] ${title}"; echo "$detail" | grep .; echo ""; } >> "$DETAILS_FILE"
  return 0
}

# specs/ 配下の実仕様ファイル（テンプレート除外）を列挙
# 【`xargs` には必ず `-r` を付ける（GNU / BSD で挙動が分かれる。実運用で踏んだ）】
# **空入力のとき GNU xargs はコマンドを引数なしで 1 回実行し、BSD xargs は実行しない。**
# `find ... | xargs grep -L PATTERN` で対象が 0 件だと、GNU では `grep` が
# **標準入力を読み `(standard input)` を「違反ファイル」として出力する**。
# 実測（2026-09-03・Windows / Git Bash = GNU xargs）: 空カテゴリ（`specs/api/` 等）が原因で
# `G-DENSITY` が **17 件の偽陽性**を出した（実仕様側の違反は 0 件だった）。
# macOS（BSD xargs）では同じコードが正常に動くため、**macOS の selftest では原理的に検出できない**。
# `-r` は BSD xargs でも受け付けられる（互換のため用意されている）ので、**全箇所に付ける**。
# `selftest.sh` が (a) 全 xargs に `-r` があるか (b) GNU 模倣シムで偽陽性が出ないか を検査する。
# ドメイン能力仕様（本質層のうち「能力」を書いたもの）を列挙する。
# 【なぜ artifact-key で選ぶか】`specs/rebuild/` には画面マップ・帳票・ジョブ・非機能など
# **別の成果物形態**も入る。それらに「分母の割当」や「可視性の不変条件」を要求すると
# **対象でないものが未達に数えられ、直せない未達が残ってゲートが外される**。
# 【tier 語彙を使わない（2026-09-12）】旧実装は `artifact-key: tier1-rebuild` だけを見ていた。  [撤去の記録]
# その値と宣言元の雛形は `GP-104`（tier）とともに導入されたもので、**段階配達の撤去で消える資産**である。  [撤去の記録]
# tier 非依存の値 `capability-spec` を正とし、**旧値も受ける**（既存リポジトリの成果物を壊さない）。  [撤去の記録]
# 【`REBUILD_LAYER` で条件化】本質層を作らない設定（`off`）では 0 件になる＝要求が消える。
# **`gate_artifact_form` とは除外集合が違う**（あちらは `off` と `skeleton`、ここは `off` のみ）:
# `skeleton` では本質層の骨子が実在するので列挙は続ける。**この非対称は意図的だが、
# 「骨子に何をどこまで要求すべきか」は未定義**（`dev/developing-the-framework.md` に起票済み）。
# `REBUILD_LAYER` は `GP-104`（tier）より前から存在する設定値なので、tier 撤去後も残る。  [撤去の記録]
capability_specs() {
  [ "$REBUILD_LAYER" = "off" ] && return 0
  [ -d "$SPECS/rebuild" ] || return 0
  find "$SPECS/rebuild" -name '*.md' -not -name '_*' 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    # 【旧値も受ける（2026-09-16 に落としかけて戻した）】  [撤去の記録]
    # 2026-09-12 の改名より**前**に生成された能力仕様はこの目印を持つ。
    # 落とすと `capability_specs` が空集合になり、**`G-DENOM` は「未割当 0」と PASS を出す**
    # ——検査していないのに「検査した」と言う fail-open で、実測で HEAD 版 INCOMPLETE /
    # 落とした版 PASS の差を再現した。**`G-REBUILD` は front-matter で数えるので消えない**＝
    # 姉妹ゲートの非対称になる。配布雛形と利用者向け文書が「旧値も受ける」と書いている根拠でもある。
    grep -qE "$CAP_KEY_RE" "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}

# --- sum_lines: ファイル一覧の総行数を数える（`wc -l` のバッチ分割に耐える） ---
# 【`tail -1` を使わない（申し送り 5 の #1）】`xargs` が引数を複数バッチに分割すると
# `wc -l` は**バッチごとに `total` 行を出す**ので、`tail -1` は**最終バッチ分しか読まない**。
# 実測: 400 ファイル（総計 1,200 行）を強制分割すると **90 行**（真値の 7.5%）になった。
# 【`total` 行の合計にもしない】単一バッチかつ 1 ファイルのときは `total` 行が出ないので 0 になる。
# ⇒ **`total` 行を除いて各ファイルの行数を合計する**（両方で正しい。実測: 3 / 1,203）。
# 【`$2` で判定して安全な理由】`wc -l` の第 2 フィールドは必ずパス（ディレクトリ接頭辞付き）なので
# `total` と一致しない。空白入りパスでも `$2` がパスの先頭語になるだけで `total` にはならない。
# 入力は改行区切りのファイル一覧（stdin）。**2 箇所で同じ式を書かない**（片方だけ腐るのを防ぐ）。
# 【`LC_ALL=C` が必須】GNU `wc` は総計ラベルを **gettext に通す**ので、翻訳カタログがある環境では
# `total` が別語（例: `合計`）になり、**総計行を実データとして数え込んで値が 2 倍になる**
# ——しかも**分割の有無に関係なく全規模で**効く（実測: 真値 24 に対し 48）。
# 直そうとしたバグ（バッチ分割）は実プロジェクト規模では起きないので、これを外すと
# **得るより失うほうが大きい**。同ファイルの他の `LC_ALL=C xargs` と同じ規約である。
# **翻訳する `wc` はシムで模倣できるので、この機でも検査できる**（`selftest` に動的検査がある。
# 「開発機では再現しない」と当初書いたのは誤りだった＝`SB-101`）。
# 【呼び出し側の契約】**ディレクトリ接頭辞付きのパス**を渡すこと。相対パスで先頭語が `total` の
# ファイル（`total`・`total sp.md` 等）を渡すと除外されて落ちる（実測: 真値 4 → 1）。
# 現行の 2 呼び出しは `find "$SPECS/$c"` の絶対パスなので安全。
sum_lines() { nul_pack | LC_ALL=C xargs -0 -r wc -l 2>/dev/null | awk '$2 != "total" { s += $1 } END { print s + 0 }'; }

# --- nul_pack: 改行区切りのファイル一覧を NUL 区切りへ詰め替える（xargs の語分割対策） ---
# 【なぜ必要か（2026-09-12 に実測。申し送り 4-①）】`find`/`spec_files`/`grep -l` の出力を
# そのまま `xargs` に渡すと**パスに空白があると語分割する**。実測（実プロジェクト複製を
# 空白入りディレクトリに置いて `gates.sh density`）:
#   `G-DENSITY`     FAIL（必須節の欠落 11 件）→ **SKIP「検査対象の実仕様がまだ無い」**
#                   ＝**実在する欠陥 11 件が消える fail-open**。しかも SKIP は gate-verdicts に残らない
#   `G-BLOCK-SIZE`  測定不能 63 件 → **709 件**（「マーカーが無い」は虚偽。実在する）
# `find -print0` に統一できないのは、`grep -l` の出力を次の `xargs` に渡す連鎖があるため
# （`grep -lZ` は GNU 専用）。**どの一覧でも同じ形で挟める**この関数に寄せる。
# 【限界】**ファイル名に改行が含まれる場合は救えない**（中間経路が改行区切りなので原理的に無理）。
# その場合は awk/grep が開けず rc≠0 になり、fail-closed 側に倒れる。
# 【末尾の `:`】`[ -n ... ] && printf` はループ最終行が空だと rc=1 になり、`pipefail` 下で
# パイプライン全体を失敗させる。`:` で rc を 0 に固定する。
# 【`|| [ -n "$_l" ]` が必要】`read` は**末尾に改行が無い最後の行で rc=1 を返す**ため、
# それだけだと最終行を黙って落とす（実測: `printf 'a.md\nb.md'` で `b.md` が消える）。
# 現在の呼び出し元（`find` / `grep -l` / `echo`）は末尾改行を出すので実害は無いが、
# `printf '%s'` 型の呼び出し元が将来加わると**静かに fail-open する**ので今のうちに塞ぐ。
nul_pack() { while IFS= read -r _l || [ -n "$_l" ]; do [ -n "$_l" ] && printf '%s\0' "$_l"; done; :; }

# 【大小を無視して実在するファイルに解決する（移植性。2026-09-26 に実測して追加）】
# `[ -f "$p" ]` は**ファイルシステムによって答えが変わる**。macOS の APFS（既定）と NTFS は
# 大小を区別しないので `[ -f README.md ]` が `readme.md` にも真を返すが、
# Linux 系のファイルシステムは偽を返す。⇒ **同じ成果物が OS で違う判定になる。**
# 実測（2026-09-26。ある Windows 機の WSL Ubuntu 24.04。`findmnt -no FSTYPE` の実測値）:
#   `/tmp`（`wslfs` と報告された＝WSL1）= 大小を区別する ／ `/mnt/d`（NTFS）= 区別しない
#   ——**同一機械の中でも割れた。**「OS で割れる」ではなく「パスで割れる」。
#   **FS 名に依存した判断をしない**（WSL2 なら `/tmp` は ext4 になる）。見るのは区別するか否かだけ。
# これは `[ -f ]` を統合ビュー文書の探索・除外に使っていた 2 箇所（G-VIEW / G-REBUILD）で
# **判定を反転させていた**（大小を区別する側では `readme.md` が rebuild の実体に数えられ、
# **統合ビュー 1 枚で床が満たせる fail-open** になる）。
# ツール非依存を核心価値に置くので、**判定は常に「大小を無視する」側に寄せる**
# （区別する側に寄せると、macOS / Windows の利用者の `readme.md` が統合ビューと認識されなくなる）。
resolve_ci_all() { # $1=期待するパス → 大小を無視して実在する実ファイルを 1 行ずつ（無ければ何も出さない）
  local _d _b _p
  [ -n "${1:-}" ] || return 0
  _p="$1"
  # 【字面を正規化する】出力は除外リストとして `grep -vxF`（完全一致）で突合されるので、
  # `./` や `//` が残ると**数える側の字面と一致せず黙って除外に失敗する**（fail-open）。
  # `INTEGRATED_VIEW_DOC` は利用者が書く値なので `./specs/…` や `specs//rebuild/…` が来る。
  while :; do
    case "$_p" in
      */) _p="${_p%/}" ;;
      ./*) _p="${_p#./}" ;;
      *//*) _p=$(printf '%s' "$_p" | LC_ALL=C sed 's|//*|/|g') ;;
      */./*) _p=$(printf '%s' "$_p" | LC_ALL=C sed 's|/\./|/|g') ;;
      *) break ;;
    esac
    [ -n "$_p" ] || return 0
  done
  # 【先頭が `-` のパスを渡さない】`dirname` / `basename` がオプションと誤解して失敗する（実測）
  case "$_p" in -*) _p="./$_p" ;; esac
  _d=$(dirname "$_p" 2>/dev/null) || return 0
  _b=$(basename "$_p" 2>/dev/null) || return 0
  [ -n "$_d" ] && [ -n "$_b" ] || return 0
  [ -d "$_d" ] || return 0
  # 【glob メタ文字を含む名前は大小無視にしない】`-iname` はグロブなので `*` を含む指定が
  # **別のファイルまで巻き込む**（`INTEGRATED_VIEW_DOC` は利用者が書く値なので起こりうる）。
  case "$_b" in
    *'*'* | *'?'* | *'['* ) [ -f "$_p" ] && printf '%s\n' "$_p"; return 0 ;;
  esac
  # 【`-L` が必須】`-type f` は symlink を**たどらない**ので、`-L` が無いと
  # **symlink で置かれた統合ビューが除外されない**（実測 2026-09-26）。
  # 数える側（`find -L "$SPECS/rebuild" -type f -iname '*.md'`）は `-L` 付きで symlink の実体を
  # **数える**ので、除外側に `-L` が無いと**統合ビュー 1 枚で床が満たせる fail-open が復活し**、
  # 同時に `G-VIEW` は候補を見つけられず**偽の FAIL** になる。1 つの欠落で両方向に壊れる。
  # `-L` を付けても **壊れた symlink と `.md` という名のディレクトリは `-type f` が落とす**（実測）。
  find -L "$_d" -maxdepth 1 -iname "$_b" -type f 2>/dev/null | LC_ALL=C sort
  return 0
}

spec_files() {
  # 【-type f が必要】壊れたシンボリックリンクや特殊ファイルが混ざると、それを開く awk/grep が
  # **異常終了して以降のファイルが全部落ちる**（実測: 引用 7,624 → 2,562 に減った）。
  # 【AGENTS.md を除外する】`specs/AGENTS.md` は仕様ではなく**読む側の規範**である。
  # 除外しないと、規範が説明のために書いた語（`UNKNOWN[blocking]` の解説表など）を
  # ゲートが実データとして拾い、**誰も直せない未達が永久に残る**
  # （実測: G-FRESH が INCOMPLETE になり phase4 が exit 0 に到達しなくなった。
  #  唯一の解消手段が「規範を編集する」で、それは規範自身が禁じている）。
  # 同型の先例: 機械生成の逆引き索引が G-TIER を踏んだ件（gate_tier の generated 除外）。  [撤去の記録]
  find "$SPECS" -type f -name '*.md' -not -name '_*template*' -not -name '_template.md' \
    -not -name 'AGENTS.md' -not -name 'CLAUDE.md' 2>/dev/null
}

# 【本文を読む検査は生成物の索引を除く（2026-10-01）】`specs/source-index.md` の「入口から引く」表は
# コードグラフの文字列を写すので、本文として読むと**どの仕様にも書かれていない識別子・語が本文に実在する**ことになる
# （反証レビューで実測: 識別子の突合が索引だけで満たされた）。仕様の本文を読む検査はこちらを使う。
content_spec_files() {
  spec_files | grep -vxF "$SPECS/source-index.md" || true
}

# 【レディ・監査の宣言文書（GP-6 ルール20）】
# `specs/` の参照閉包（GP-9 ルール7）は**配布単位の自己完結**が目的なので走査を `specs/` に限る。
# しかし「レディ」「監査完了」を宣言するのは `03-audit/` の文書で、**そこが存在しない成果物を
# 根拠に引用していても、どのゲートも見ていなかった**（実運用で「必須カテゴリを 1 件も作らないまま
# 完了を宣言できた」事例。7 巡・累積 459 主張の独立検証を通しても検出されなかった）。
# 【この 3 つに限る】`worklog/` と `investigation-notes/` は**作業中**の文書で、
# 未解決の前方参照が正常に存在する（広げると偽の未達が大量に出る）。
ready_audit_files() {
  local f
  for f in "$AUDIT/rebuild-readiness.md" "$AUDIT/traceability.md" "$AUDIT/observed-anomalies.md"; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# code-graph.md の**実ノード行だけ**を返す（分母の唯一の定義）。
# 【なぜヘルパーにするか】`grep '^| NODE-'` は表ヘッダ `| NODE-ID | ... |` にも一致するため
# **ヘッダが実ノードとして数えられる**（テンプレ実測: 6 行中ヘッダ 3・実ノード 3。
# 実運用では 169 → 187 に膨らんだ）。以前は 5 箇所のうち 1 箇所だけが
# `grep -v '^| NODE-ID'` で除外しており、**ゲート間で分母が食い違っていた**（同型バグの水平展開漏れ）。
# 個別に除外を足すと再びドリフトするので、**分母の定義を 1 箇所に集約**する。
# 【パターン】`NODE-<種別>-<連番>`。種別は 2 段以上ありうる（実運用に `NODE-EP-MVC-01` が実在）。
# `NODE-ID` は「連番で終わる」条件を満たさないため自然に除外される
# （ヘッダ名の変更に依存しない＝テンプレを直しても既存リポジトリで壊れない）。
# 【エッジ行を除く】`^| NODE-…` はエッジレジストリの From 列にも一致する。実走検証の実測で
# **ノード数が 177 → 255 に膨らみ、エッジ行の最終列が「仕様化状態」として読まれて語彙外エラー**
# になった。エッジ行は `NODE-A → NODE-B` の形なので**矢印を含む行を除く**
# （`→` と ASCII の `->` の両方。表記ゆれで漏れる。教訓 30）。
NODE_ROW_RE='^\| NODE-([A-Za-z0-9]+-)+[0-9]+[^|]*\|'
NODE_EDGE_RE='(→|->)'

# 【HTML コメントは行の位置で消す】`sed '/<!--/,/-->/d'` は**範囲指定**なので、
# 開始行が範囲の始まりに一致すると**終了パターンを次の行から探す**。
# `<!-- density-block: DB-001 -->` は 1 行で閉じているのに、次の `-->`（＝終了マーカー）まで
# **ブロックの中身が丸ごと削除され「必須節が空」と誤判定**された（実走検証で実際に踏んだ。
# 再現: `printf '<!-- x -->\n本文\n' | sed '/<!--/,/-->/d'` → 空）。
# 1 行で閉じているコメントは**その行だけ**を消し、複数行にまたがるものだけ範囲で消す。
strip_html_comments() {
  LC_ALL=C awk '
    # 1 行で閉じているコメントは行内から除去する（残りが実データなら残す）
    { line = $0
      while (match(line, /<!--/)) {
        a = index(line, "<!--")
        b = index(substr(line, a + 4), "-->")
        if (b == 0) break                      # 閉じていない＝複数行コメントの開始
        line = substr(line, 1, a - 1) substr(line, a + 4 + b + 2)
      }
    }
    # 複数行コメントの中は捨てる
    # 【閉じ行は「最初の `-->` まで」を落とし、行数は保存する（2026-09-21 修正）】
    # 初版 `^[^>]*-->` は **閉じ行の中に `>` があると 1 文字も落ちず行がまるごと残った**
    # （実測: `<!-- … （<rule> / N …） 〜 -->` の閉じ行が残り `G-RECON` が自分の説明文で FAIL した）。
    # `<rule>` のような山括弧は説明文に普通に出るので、この穴は日常的に踏む。
    # 【貪欲マッチにしてはいけない】`sub(/^.*-->/, ...)` にすると
    # `閉じ行 --> 本文A --> 本文B` で**コメント外の本文 A が落ちる**（実測）。
    # `index` で**最初の `-->`** を探し、その後ろだけを残す。
    # 【行を削除しない】`next` で捨てると**下流の `grep -n` / `awk NR` の行番号が詰まり、
    # 原文の行番号とずれる**（実測: 真の行 12 を 10 と報告した）。
    # 「直す場所が分からない未達」になるので、**空行を出して行数を保つ**。
    inc { if ((p = index(line, "-->")) > 0) { line = substr(line, p + 3); inc = 0 } else { print ""; next } }
    { if (match(line, /<!--/)) { a = index(line, "<!--"); line = substr(line, 1, a - 1); inc = 1 } }
    { print line }'
}

# --- strip_code_spans: バッククォートで囲んだコード表記を除去する（2026-09-21 新設） ---
# 【なぜ共通化するか】**プレースホルダ／状態の検出器がコード表記と説明文に当たる**型を
# **3 ゲートで踏んだ**（効果測定の実測。`G-RECON` が自分の説明文で FAIL ／
# `G-INDEP` が `` `<file>:<line>` `` を未記入と誤検出 ／ `G-HOLD-ADR` が別形式の表に反応）。
# `G-PROVISIONAL` だけが「コード表記を剥がしてから判定する」規律を持っていたが、**他に未適用だった**。
# 【`gate_unfilled` とは要求が違う】あちらは**囲みの中の未記入も検出したい**ので
# バッククォートを「文字として」剥がす（span は残す）。ここは**例示・引用を無視したい**ので
# **span ごと落とす**。2 つの要求を 1 つの関数にまとめない（混ぜると片方が壊れる）。
# 【HTML コメント除去と束ねない】束ねた初版は `<!-- … -->` を探す `gate_provisional` から
# **使えず**、同型の処理が 2 実装残った。呼び出し側で `strip_html_comments | strip_code_spans`
# と合成する（説明文は複数行コメントの中にあり、開始マーカーの行だけ除くと継続行が残る）。
# 【コード表記の定義は 1 箇所に置く】`gate_provisional` は**判定は除去後・出力は原文**という
# 要求なので単純なフィルタとしては共有できない（原文を失う）。実装は共有できないが、
# **「コード表記とは何か」の定義は共有する**——片方だけ直して穴が残る事故を避けるため。
CODE_SPAN_RE='`[^`]*`'
strip_code_spans() {
  LC_ALL=C awk -v cs="$CODE_SPAN_RE" '{ line = $0; gsub(cs, "", line); print line }'
}
# --- strip_code_spans_prose: 散文の行だけコード表記を落とす（表の行は落とさない） ---
# 【表の行に適用してはならない】適用した初版は、**プレースホルダをバッククォートで囲むだけで
# 空テンプレが「合計が一致」になった**（実測: `G-RECON` が FAIL → PASS）。
# 塞ぎたかった偽陽性は**散文のチェックリスト行**と**HTML コメント継続行**の 2 種だけであり、
# 表の行を剥がす必要は無い。プレースホルダ検出にはこちらを使う。
strip_code_spans_prose() {
  LC_ALL=C awk -v cs="$CODE_SPAN_RE" '{ line = $0; if (line !~ /^[ \t]*\|/) gsub(cs, "", line); print line }'
}
# --- strip_quoted_markup: 引用したマークアップだけを落とし、プレースホルダは残す ---
# 【`strip_code_spans` で代用してはならない】`G-READABLE` の雛形判定でコード表記を丸ごと
# 落とした版は、**雛形のプレースホルダを囲むだけで実体として通った**
# （実測: `` `<誰>` `` の雛形行が PASS になった＝偽陽性を塞いだ副作用で fail-open を開けた）。
# 【判別の基準】`<誰>` `<アクター>`（プレースホルダ）と `<c:forEach>`（引用マークアップ）は
# バッククォートを外すと同形なので、**マークアップにしかない形**で分ける:
#   (a) 閉じタグ `</…>` (b) 属性つき `<x name="…">` (c) 自己閉じ `<x/>`
#   (d) 小文字始まりの要素名 `<action>` (e) 名前空間つき（接頭辞 1〜2 文字）`<s:submit>`
# `gate_unfilled` が実測（誤爆 44 件の内訳）で到達した形と**同一**なので、
# **定義を 1 箇所に置いて両方から呼ぶ**（片方だけ直して穴が残る事故を避ける。教訓 30）。
strip_quoted_markup() {
  LC_ALL=C sed -e 's/`//g' \
               -e 's|</[A-Za-z][^>]*>||g' \
               -e 's|<[A-Za-z][A-Za-z0-9:-]* [^<>]*="[^"]*"[^<>]*>||g' \
               -e 's|<[A-Za-z][A-Za-z0-9:-]* */>||g' \
               -e 's|<[a-z][A-Za-z0-9-]*>||g' \
               -e 's|<[a-z][a-z0-9]\{0,1\}:[a-z][A-Za-z0-9-]*>||g' \
               -e 's|<[a-z][A-Za-z0-9:-]*\( [a-z][a-z-]*\)\{1,\}>||g' \
               -e 's/<[= ]/ /g'
  # 【2026-10-01 追加の 2 枝（完走試験で証跡の書き換えを強いた形）】
  #   (f) 値の無い属性つき要素 `<meta http-equiv>`（小文字の要素名＋小文字の属性名だけ）
  #   (g) 比較演算子 `$3 < 5`・`x <= 2`——**`<` の直後が空白か `=` のものはプレースホルダの開始ではない**
  #       （雛形のプレースホルダはすべて `<` の直後が文字）。残すと `< 5 && $4 >` が「空白を含む <…>」に当たった。
}
node_rows() {
  # 第 1 列に矢印がある行＝エッジ行なので落とす（第 2 列以降の矢印は本文なので残す）。
  # 【第 2 列が NODE-ID の行も落とす（2026-09-21 追加。実プロジェクトで踏んだ）】
  # 配布テンプレートのエッジ表は `| From (NODE-ID) | To (NODE-ID) | 種別 | 根拠 |` ＝
  # **矢印を持たない 2 列形式**である。矢印だけで判定すると
  # **テンプレどおりに書いた全リポジトリでエッジ行がノード行として読まれ**、
  # 最終列（`path:line`）が「仕様化状態」として扱われて `G-HOLD-ADR` が語彙外で FAIL する
  # （実測: 語彙外 33 件。記述を変えるしか回避手段が無い＝誰も直せない未達）。
  # 【ヘッダ行で判別する（2026-09-22 追加）】第 2 列の内容だけで見る形は、
  # **ノード表が親ノード列を持つと本物のノード行を落とす**（分母が静かに縮む）。
  # 雛形は 2 つのレジストリを別のヘッダで持つので、**直近のヘッダ**で決める:
  #   ノード表 = 第 1 列が `NODE-ID` ／ エッジ表 = 第 1 列に `From` を含む
  # ヘッダが無い（旧版の）文書では従来の推定にフォールバックする——**判定を落とさない**。
  grep -E "$NODE_ROW_RE|^\| *(NODE-ID|From)" "${1:-$CODEGRAPH}" 2>/dev/null \
    | awk -F'|' -v E="$NODE_EDGE_RE" '
        function trim(v) { gsub(/^[ \t]+|[ \t]+$/, "", v); return v }
        # ヘッダ行そのものは出力せず、直近のレジストリ種別を覚える
        trim($2) == "NODE-ID" { reg = "node"; next }
        trim($2) ~ /^From/    { reg = "edge"; next }
        # 【エッジ領域でも「エッジの形」でなければ落とさない】ヘッダだけで決めた初版は、
        # **エッジ表の後に追記されたノード行**（置き場所を間違えただけの行）を落とし、
        # 対象外ノードの告発が消えた（実測: 既存検査が「告発が出る状態を作れない」で赤くなった）。
        # 誤って落とすのは**分母が静かに縮む**ことなので、エッジ判定は第 2 列の形も要求する。
        reg == "edge" {
          c2 = trim($3)
          gsub(/（[^）]*）/, "", c2); gsub(/\([^)]*\)/, "", c2); c2 = trim(c2)
          if ($2 ~ E || c2 ~ /^NODE-([A-Za-z0-9]+-)+[0-9]+$/) next
          print; next
        }
        reg == "node" { print; next }
        # --- ヘッダが未出現のときだけ推定に頼る（旧版の文書） ---
        $2 ~ E { next }
        {
          c = $3
          gsub(/^[ \t]+|[ \t]+$/, "", c)
          gsub(/（[^）]*）/, "", c)
          gsub(/\([^)]*\)/, "", c)
          gsub(/^[ \t]+|[ \t]+$/, "", c)
          if (c ~ /^NODE-([A-Za-z0-9]+-)+[0-9]+$/) next
          print
        }' || true
}

# =============================================================================
# 個別ゲート
# =============================================================================

# --- G-FRESH: 鮮度（未決マーカー残存, GP-6 ルール7 / SB-10 / GP-5） ---
gate_freshness() {
  local hits
  # 【全角コロンは選択で書く】`[:：]` は C ロケールでバイト集合になり、`UNKNOWN（` など全角文字の先頭バイトにも当たる。
  # 【タグの無い `UNKNOWN:` も未決】タグを外せば下の範囲検査を迂回できる（絵文字・空白の有無は問わない。
  #  完走した参照成果物 3 本で 0 件を確認済み）。
  hits=$(content_spec_files | nul_pack | xargs -0 -r grep -n 'UNKNOWN\[blocking\]\|UNKNOWN:\|UNKNOWN：\|（推測\|裏取り予定\|確認予定\|仮説段階' 2>/dev/null \
         | grep -v '~~.*~~ \*\*解消済' || true)
  # 【規約外のタグも未決】`UNKNOWN[partal]` のような綴りや独自タグで範囲検査を避けられないようにする。
  #  `[...]` は凡例の書き方なので除く（参照成果物の凡例で実測）。
  local tagbad
  tagbad=$(content_spec_files | nul_pack | xargs -0 -r grep -n 'UNKNOWN\[' 2>/dev/null \
           | grep -v '~~.*~~ \*\*解消済' | awk '{
               s = $0
               while (match(s, /UNKNOWN\[[^]]*\]/)) {
                 t = substr(s, RSTART + 8, RLENGTH - 9)
                 if (t != "blocking" && t != "deferred" && t != "out-of-scope" && t != "undecidable" && t != "partial" && t != "...") {
                   print $0 "  ← 規約外のタグ「" t "」"; break
                 }
                 s = substr(s, RSTART + RLENGTH)
               }
             }' || true)
  # `partial` は「読み残したまま完了する」印（GP-5 ルール10）。**範囲の無い未確認は読み手が何も使えない**ので、
  # partial ごとに `確認した範囲:` を探し、**その範囲の中**（最初の `）` か `。` まで）に原典の位置が無ければ未決とする。
  # 【範囲で切る】行全体で位置を探すと、行末の `[[分析物 ID]]` が「確認した範囲: なし」を通した（反証レビューで再現）。
  # 【ADR は実在を見る】HOLD-9 の (B) は範囲に `[[ADR-N]]` を書く（GP-103 ルール3）。その ADR が decisions.md に無ければ
  #  「調べた位置」の置き場が空になるので未決とする。`[[` だけで通していた初版の穴（`[[x` でも通った）も `[[ID]]` の形に締める。
  # 【位置の述語は主張行と同じ】`CLAIM_LINE_RE`（バッククォートの `path:line`・継続形 `:NN`）か `[[ID]]`。2 箇所目の定義を作らない。
  # 完了を妨げるのはこの書き漏れだけで、件数ではない。
  local unv
  unv=$(content_spec_files | nul_pack | xargs -0 -r grep -n 'UNKNOWN\[partial\]' 2>/dev/null \
        | grep -v '~~.*~~ \*\*解消済' | awk -v LOC="$CLAIM_LINE_RE" -v ADRS=" $(live_adr_numbers | tr '\n' ' ') " '{
            rest = $0; ok = 1; why = ""; key = "確認した範囲"
            while ((i = index(rest, "UNKNOWN[partial]")) > 0) {
              rest = substr(rest, i + length("UNKNOWN[partial]"))
              j = index(rest, key); if (j == 0) { ok = 0; break }
              r = substr(rest, j + length(key))
              sub(/^[ *]+/, "", r)
              if (index(r, ":") == 1) r = substr(r, 2)
              else if (index(r, "：") == 1) r = substr(r, length("：") + 1)
              else { ok = 0; break }
              k = index(r, "）"); k2 = index(r, "。")
              if (k2 > 0 && (k == 0 || k2 < k)) k = k2
              if (k > 0) r = substr(r, 1, k - 1)
              if (r ~ LOC) continue
              if (!match(r, /\[\[[A-Za-z0-9_-]+\]\]/)) { ok = 0; break }
              ref = substr(r, RSTART + 2, RLENGTH - 4)
              if (ref ~ /^ADR-[0-9]+$/ && index(ADRS, " " ref " ") == 0) { ok = 0; why = "（" ref " が decisions.md に無い）"; break }
            }
            if (!ok) print $0 "  ← partial の「確認した範囲:」に原典の位置（`path:line` か [[ID]]）が無い" why
          }' || true)
  hits=$(printf '%s\n%s\n%s' "$hits" "$tagbad" "$unv" | grep . || true)
  local npart
  npart=$(content_spec_files | nul_pack | xargs -0 -r grep -o 'UNKNOWN\[partial\]' 2>/dev/null | grep -c . || true)
  if [ -z "$hits" ]; then
    # partial の件数を判定文に出す——レディ宣言はこの行（gate-results.md）から写す（GP-13 ルール10）。
    report PASS G-FRESH "specs/ に未決マーカー（UNKNOWN[blocking]・タグの無い／規約外の UNKNOWN・範囲に位置の無い partial・推測・裏取り予定等）が残っていない（partial ${npart:-0} 件は確認した範囲付きで残存。範囲外は利用時に要確認）"
  else
    report INCOMPLETE G-FRESH "未決マーカーが残存（$(echo "$hits" | wc -l | tr -d ' ') 件）" "$hits"
  fi
}

# 【`verification:` の扱い（2026-09-16 に明示的に決着させた）】
# 撤去した段階配達のゲートは「本質層の成果物に `verification: unverified` を機械可読で持つこと」も
# 要求していた。**この要求は移設せず、密度台帳の `verify_status` に一本化した**——
# 台帳は `G-LEDGER` が全行を読む正本（CLAUDE.md「進捗状態の正本」）で、
# **同じ状態を 2 箇所で持つと必ず乖離する**（`GP-101` が禁じる型）。
# front-matter の `verification:` は**表示**として残す（雛形と `init.sh` が書き続ける）。
# ただし**値の語彙だけは検査する**——語彙外の値は「読めば分かる」ものではないため。
# 実測: 参照成果物 2 件で語彙外の値は 0 件（`unverified` / `verified` のみ）。
# **持っていないことは未達にしない**（完走した参照成果物の 14 件は 1 つも持っていない）。
gate_verification_vocab() {
  # 【front-matter 領域だけを見る】本文（コードフェンス内の書き方の説明など）に
  # `verification: <unverified|verified>` と書いただけで FAIL になり、**説明を消すしか回避手段が無い**
  # 偽陽性が出た（実測）。front-matter は先頭の `---` ブロックなのでそこに限る。
  # 【値の取り出しは貪欲マッチで剥がす】`grep -Hn` の出力は `パス:行番号:行` なので、
  # **パスに `verification:` を含むと固定オフセットがパス側に当たる**（実測: ディレクトリ名を
  # 変えるしか回避手段が無い偽陽性）。最後の `:N:verification:` まで貪欲に落とす。
  local bad=""
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    local vline
    vline=$(LC_ALL=C awk '/^---[[:space:]]*$/ { n++; if (n >= 2) exit; next } n == 1 && /^verification:/ { print; exit }' "$vf" 2>/dev/null || true)
    [ -n "$vline" ] || continue
    local vv
    vv=$(printf '%s' "$vline" | LC_ALL=C sed -e 's/^verification:[[:space:]]*//' -e 's/\r//g' \
         | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$vv" in
      unverified|verified) ;;
      *) bad="${bad}${vf#"$REPO_ROOT"/}: verification: ${vv}"$'\n' ;;
    esac
  done < <(spec_files)
  if [ -z "$bad" ]; then
    report PASS G-VERIFY-VOCAB "front-matter の verification: が語彙内（unverified / verified）"
  else
    report FAIL G-VERIFY-VOCAB "verification: の値が語彙外（unverified / verified のいずれかにする）" "$bad"
  fi
}

# --- G-DRAFT: coverage-status: draft 残存（GP-9 / SB-10） ---
# 【母集団外を表せるようにする（2026-09-22）】能力を限定した抽出では、`init.sh` が実 `spec-id` 付きで
# 置く `specs/overview.md` のような文書が**必ず未記入の draft として残る**。埋めると成果物が増えて
# 母集団が変わり、埋めないと未達が残る——どちらも選べない形だった（実測: 参照成果物 1 本で発生）。
# ⇒ `coverage-status: out-of-scope` ＋ **理由行 `scope-exclusion: <理由>`** で「今回の母集団外」を宣言できる。
# 【理由を必須にする】宣言だけで通ると「分からない」を「やらない」に落とす経路になる。
# 理由が無い／未記入のままなら未達にする。**件数は PASS 文にも出す**（黙って消えない）。
gate_draft() {
  local hits oos oos_bad
  hits=$(spec_files | nul_pack | xargs -0 -r grep -ln '^coverage-status:[[:space:]]*draft[[:space:]]*$' 2>/dev/null || true)
  # 【front-matter に限定する】行頭アンカーすら無い形で書いた初版は、**本文・表・HTML コメント・
  # コードフェンスの中に書いた文字列**を宣言として数えた（この framework 自身をドッグフードする
  # repo では現実的）。さらに `scope-exclusion:` を**本文の任意の行頭に 1 行足すだけ**で
  # 理由要求を満たせた。`gate_tier` の除外が front-matter 限定になっているのと揃える
  # （同ファイル内の先例: 「本文記載では除外集合が一致しない」）。
  oos=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk '
    FNR==1 { fm = 0; seen = 0 }
    FNR==1 && /^---[[:space:]]*$/ { fm = 1; next }
    fm && /^---[[:space:]]*$/ { fm = 0; nextfile }
    fm && /^coverage-status:[[:space:]]*out-of-scope[[:space:]]*$/ && !seen { print FILENAME; seen = 1 }
  ' 2>/dev/null || true)
  oos_bad=""
  if [ -n "$oos" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local why
      # 理由も front-matter の中だけを見る
      why=$(LC_ALL=C awk '
        FNR==1 && /^---[[:space:]]*$/ { fm = 1; next }
        fm && /^---[[:space:]]*$/ { exit }
        fm && /^scope-exclusion:/ { sub(/^scope-exclusion:[[:space:]]*/, ""); print; exit }
      ' "$f" 2>/dev/null || true)
      why=$(printf '%s' "$why" | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/[[:space:]]*$//')
      if [ -z "$why" ] || ! printf '%s' "$why" | LC_ALL=C grep -q '[^[:space:]]'; then
        oos_bad+="  ${f#"$REPO_ROOT"/}: out-of-scope なのに front-matter に scope-exclusion: の理由が無い"$'\n'
      elif printf '%s' "$why" | grep -q '<[^<>]*>'; then
        oos_bad+="  ${f#"$REPO_ROOT"/}: scope-exclusion: の理由が未記入（${why}）"$'\n'
      elif ! printf '%s' "$why" | LC_ALL=C grep -qE 'ADR-[0-9]+'; then
        # 【ADR を要求する】母集団から文書を外すのはスコープの判断である。既存の
        # `UNKNOWN[out-of-scope]` は「ADR で意図的に範囲外とした」ことを要求しており、
        # 自由記述の理由だけを受けると**同じ語で厳しさが 2 段**になる（`G-DENOM` も ADR の実在を見る）。
        oos_bad+="  ${f#"$REPO_ROOT"/}: scope-exclusion: に ADR 参照が無い（ADR-N を書く。既存の UNKNOWN[out-of-scope] と同じ厳しさに揃える）"$'\n'
      fi
    done <<EOF
$oos
EOF
  fi
  local oos_n=0
  [ -n "$oos" ] && oos_n=$(printf '%s\n' "$oos" | grep -c . || true)
  if [ -n "$oos_bad" ]; then
    report INCOMPLETE G-DRAFT "母集団外（out-of-scope）の宣言に理由または ADR 参照が無い（宣言 ${oos_n} 件のうち）" "$oos_bad"
  elif [ -z "$hits" ]; then
    report PASS G-DRAFT "coverage-status: draft の仕様ファイルが残っていない（母集団外の宣言 ${oos_n} 件・いずれも ADR 参照つき）"
  else
    report INCOMPLETE G-DRAFT "draft のままの仕様が残存（$(echo "$hits" | wc -l | tr -d ' ') ファイル。母集団外なら front-matter に coverage-status: out-of-scope ＋ scope-exclusion: ADR-N <理由> を書く）" "$hits"
  fi
}

# --- G-LINK: リンク閉包（[[...]] 参照の解決, GP-4 / GP-9 / GP-15 ルール7） ---
# 【分析物 ID の記法は 1 箇所で持つ】引用側（`[[` 付き）と定義側（素の ID）で式が乖離すると
# **片方だけが広い**状態になり、突合が静かに壊れる（教訓 30: 文字を列挙する検査は漏れる）。
# ドメイン接頭辞（`EN-` / `AX-` / `AD-` 等）を任意個許す——実運用の ID は接頭辞を持つ。
# 【能力仕様の目印は 1 箇所で持つ】新値 `capability-spec` と旧値（改名前）の両方を受ける。
# 受け入れ集合が箇所ごとに違うと、**あるゲートは対象に含めるのに別のゲートは含めない**
# という非対称ができる（実測で 4 箇所のうち 1 箇所だけが旧値を受けていた）。
CAP_KEY_RE='artifact-key: (capability-spec|tier1-rebuild)'  # [撤去の記録]
# 【別名は 1 箇所で解決する】雛形から取り出した `artifact-key` で実仕様を探す箇所が 3 つある
# （`G-ARTIFACT` の複製実体・`G-DENSITY` の対象決定・`metrics`）。そこが新値だけを見ていると、
# **`capability_specs` は対象に含めるのに他のゲートは含めない**という非対称になる。
artifact_key_re() { # $1=雛形の artifact-key → grep -E 用のパターン
  # 【行頭に固定する（2026-10-01）】目印は行頭の `<!-- artifact-key: X -->`（または front-matter の `artifact-key:`）。
  #  固定しないと、**散文に「artifact-key: capability-spec」と書いただけの仕様**が能力仕様の検査対象に入った（偽の未達）。
  #  完走した参照成果物 3 本で、目印を持つ仕様はすべて行頭に書いていた（取りこぼし 0）。
  case "$1" in
    capability-spec) printf '^(\357\273\277)?[[:space:]]*(<!--[[:space:]]*)?%s' "$CAP_KEY_RE" ;;
    *)               printf '^(\357\273\277)?[[:space:]]*(<!--[[:space:]]*)?artifact-key: %s' "$1" ;;
  esac
}
# 目印を持たない（＝汎用雛形の対象）かの判定も同じ形で見る。本文に語として書いただけで汎用の検査から外れない。
ARTIFACT_KEY_ANY_RE="^($(printf '\357\273\277'))?[[:space:]]*(<!--[[:space:]]*)?artifact-key: "
ANA_CAT_RE='(REQ|API|ARCH|DATA|BHV|BEHAVIOR|SEC|NFR)'
ANA_ID_BARE_RE="([A-Z][A-Z0-9]*-)*${ANA_CAT_RE}-[0-9A-Za-z-]*[0-9]+"
ANA_ID_RE="\\[\\[${ANA_ID_BARE_RE}"

gate_link_closure() {
  # 参照の全出現（SPEC-/CC-/REF- 系）を抽出し、定義の実在と突合する。
  # 定義とみなす場所: specs/ 内 front-matter の spec-id、cross-cutting の CC-N 行、references.md の REF-n 行。
  # プレースホルダ例（[[SPEC-...]]・[[CC-N]]・[[REF-n]]）は実参照とみなさない:
  #  - CC-/REF- は数字必須（CC-N / REF-n を除外）
  #  - "..." を含む ID・"-" で終わる ID を除外（SPEC-... / SPEC-data-... 等の記法例）
  local refs unresolved=""
  # 【監査文書も対象にする（GP-6 ルール20）】定義側は `specs/` のまま（配布単位の自己完結は変えない）。
  # 【プレースホルダは全角 … も除く】ASCII の `...` と末尾 `-` だけでは足りない
  # ——実測で監査文書が `[[SPEC-…]]` と書いており、範囲を広げるとこれ 1 件だけが未解決になった。
  # **配布物が記法として示していない形でも人は書く。** 実 ID に `…` は現れないので誤って隠さない。
  refs=$( { spec_files; ready_audit_files; } | nul_pack | xargs -0 -r grep -oh '\[\[\(SPEC-[A-Za-z0-9_.-]*\|CC-[0-9][0-9]*\|REF-[0-9][0-9]*\)' 2>/dev/null \
         | sed 's/^\[\[//' | grep -v -e '\.\.\.' -e '…' -e '-$' | sort -u || true)
  # 【分析物 ID を早期 return の前に集める】`SPEC-`/`CC-`/`REF-` が 0 件でも
  # **分析物 ID の引用はある**（配布雛形は `[[REQ-...]]` しか例示していないので、
  # Phase 3 の最初の仕様は自然にこの状態になる）。ここで return すると
  # **ハルシネーションした分析物 ID が最も出やすい時期に検査が黙る**（反証レビューが実測）。
  # 【ドメイン接頭辞を許す】実運用の ID は `[[EN-REQ-01]]` のように接頭辞を持つ。
  # 接頭辞を許さない式では**参照成果物の引用 1,178 件のうち 22 件（1.9%）しか見ていなかった**（実測）。
  local ana_cited
  # 【3 接頭辞を除く】`ANA_ID_BARE_RE` の接頭辞は任意なので `[[SPEC-API-01]]` のような
  # **大文字 category の `spec-id`** も拾ってしまい、「02-analysis/ に実在しない」と FAIL になる
  # ——解消手段が「永続キーである `spec-id` を改名する」しかない＝誰も直せない未達。
  # 上の分類（`case`）が担当する 3 接頭辞は分析物 ID ではないので、両側から落とす。
  ana_cited=$( { content_spec_files; ready_audit_files; } | nul_pack | xargs -0 -r grep -ohE "$ANA_ID_RE" 2>/dev/null \
              | sed 's/^\[\[//' | grep -v -e '\.\.\.' -e '…' -e '-$' \
              | LC_ALL=C grep -vE '^(SPEC|CC|REF)-' | sort -u || true)
  if [ -z "$refs" ] && [ -z "$ana_cited" ]; then
    # 【「参照なし」と言えるのは本当に 0 件のときだけ】小文字接頭辞（`[[en-REQ-01]]`）は
    # 現行の式の対象外なので、**引用があるのに「参照なし」と言う**経路が残る。事実だけ書く。
    local bracket_n
    bracket_n=$(spec_files | nul_pack | xargs -0 -r grep -ohE '\[\[[A-Za-z]' 2>/dev/null | grep -c . || true)
    if [ "${bracket_n:-0}" -eq 0 ]; then
      report PASS G-LINK "検査対象の [[…]] 参照なし（未生成段階）"
    else
      report PASS G-LINK "検査対象の [[SPEC/CC/REF]] 参照と分析物 ID 参照なし（[[…]] は ${bracket_n} 件あるが、いずれも検査対象の記法ではない）"
    fi
    return
  fi

  # 【性能】定義側を**1 パスで集合化**してから突合する（参照 1 件ごとに `grep -r` を回さない）。
  # 初版は参照 ID ごとに specs/ 全体を再走査しており **O(参照数 × specs 総バイト)** だった。
  # 実測（roller-spec: 223 参照 / specs 5.1MB）で**この 1 ゲートだけで 34 秒**かかり、
  # phase3 と phase4 の両方に入っているため 1 回の監査で 70 秒近くを消費していた。
  # 仕様が増えるほど二乗で悪化するため、実運用が「ゲートを回さない」に倒れる圧力になる（FB-7 と同型）。
  # 集合比較なら O(specs + 参照数) で済む（ID 集合の比較は selftest の ID drift 検査と同じ技法）。
  local defined_spec defined_cc defined_ref
  defined_spec=$(spec_files | nul_pack | xargs -0 -r grep -h '^spec-id: ' 2>/dev/null | sed 's/^spec-id: *//' | sed 's/[[:space:]]*$//' | sort -u || true)
  defined_cc=$(grep -oE '^\| CC-[0-9]+ ' "$SPECS/cross-cutting.md" 2>/dev/null | tr -d '| ' | sort -u || true)
  defined_ref=$(grep -oE '^\| REF-[0-9]+ ' "$WROOT/00-ingestion/references.md" 2>/dev/null | tr -d '| ' | sort -u || true)
  while IFS= read -r id; do
    case "$id" in
      SPEC-*)
        echo "$defined_spec" | grep -qxF "$id" || unresolved+="UNRESOLVED: [[${id}]]（specs/ 内に spec-id 定義なし）"$'\n' ;;
      CC-*)
        echo "$defined_cc" | grep -qxF "$id" || unresolved+="UNRESOLVED: [[${id}]]（cross-cutting.md に定義なし）"$'\n' ;;
      REF-*)
        echo "$defined_ref" | grep -qxF "$id" || unresolved+="UNRESOLVED: [[${id}]]（references.md に定義なし）"$'\n' ;;
    esac
  done <<< "$refs"
  # 【分析物 ID も閉包検査する（2026-09-16 に旧 `gate_tier` (7) から移設）】
  # 上の 3 接頭辞（`SPEC-`/`CC-`/`REF-`）しか見ていなかったため、
  # **分析物 ID（`REQ-`/`API-`/… ＝ GP-4 の 2 段トレーサビリティの中段）は
  # どのゲートでも実在検査されていなかった**（実運用で偽陰性として実証）。
  # 唯一の強制点が段階配達のゲートの中にあり、**その撤去で失われるところだった**。
  # 【無条件にする】旧実装は刻印 2 以上に限っていたが、**刻印は撤去された**。
  # 「引用した ID は実在する」は段の概念に依存しない（`G-POPULATION` と同じ判断）。
  # 【引用が 0 件なら何も要求しない】Phase 2 前は分析物がまだ無く、要求すると直せない未達になる。
  # （2026-09-23 まではこれに「本質層を先に書く段」も該当した。順序を反転したので
  #  本質層を書く時点では分析物が存在するが、Phase 2 前の段はなお該当する。）
  # 【集合突合にする（性能と正確さの両方）】ID ごとに `grep -r` を回すと
  # **O(参照数 × バイト数)** になる（上の 3 接頭辞側が 34 秒かかって最適化された理由と同じ）。
  # 実測: 参照成果物の 1,178 ID を ID ごとに走査すると **23.7 秒**、集合突合なら **0.33 秒**（70 倍）。
  # あわせて**完全一致**になる——`grep -F` の部分一致では `REQ-7` が `REQ-77` に一致して通っていた。
  # 定義側からも `_*`（雛形）を外す——配布雛形の例示 ID（`REQ-01` / `ARCH-01`）が
  # 「定義」として通ると、**プロジェクトが最初に採る ID がまさにそれ**なので検査が空になる。
  local ana_unresolved="" ana_n=0
  if [ -n "$ana_cited" ]; then
    ana_n=$(find "$WROOT/02-analysis" -type f -name '*.md' -not -name '_*' 2>/dev/null | grep -c . || true)
    if [ "${ana_n:-0}" -eq 0 ]; then
      ana_unresolved+="UNRESOLVED: 02-analysis/ に分析物が 1 件も無いのに分析物 ID を引用している（GP-4 の 2 段トレーサビリティ）"$'\n'
    else
      # 【`mktemp` の rc を見る】失敗を無視すると空ファイルと突合して**全件を未解決と報告する**
      # （偽陽性で埋まる）。作れなかったら判定せず INCOMPLETE にする（fail-closed）。
      local ana_def_f ana_cit_f
      if ! ana_def_f="$(mktemp "${TMPDIR:-/tmp}/gl-anadef.XXXXXX")" || [ -z "$ana_def_f" ] \
         || ! ana_cit_f="$(mktemp "${TMPDIR:-/tmp}/gl-anacit.XXXXXX")" || [ -z "$ana_cit_f" ]; then
        rm -f "${ana_def_f:-}" "${ana_cit_f:-}"
        # 【すでに検出した未解決を捨てない】ここで INCOMPLETE だけを返すと、
        # **実在する欠陥（3 接頭辞側の未解決）が出力から消え**、「まず FAIL を直す」という
        # 優先順位の案内も働かなくなる（FAIL=欠陥 / INCOMPLETE=未完了を混ぜない設計に反する）。
        if [ -n "$unresolved" ]; then
          report FAIL G-LINK "未解決参照あり（$(echo -n "$unresolved" | grep -c . ) 件）＋ 分析物 ID の突合は実行できなかった（TMPDIR=${TMPDIR:-/tmp} に一時ファイルを作れない）" "$unresolved"
        else
          report INCOMPLETE G-LINK "分析物 ID の突合ができない（TMPDIR=${TMPDIR:-/tmp} に一時ファイルを作れない）"
        fi
        return
      fi
      find "$WROOT/02-analysis" -type f -name '*.md' -not -name '_*' -print0 2>/dev/null \
        | xargs -0 -r grep -ohE "$ANA_ID_BARE_RE" 2>/dev/null \
        | LC_ALL=C grep -vE '^(SPEC|CC|REF)-' | sort -u > "$ana_def_f" || true
      printf '%s\n' "$ana_cited" | sort -u > "$ana_cit_f"
      while IFS= read -r aid; do
        [ -n "$aid" ] || continue
        ana_unresolved+="UNRESOLVED: [[${aid}]]（02-analysis/ に実在しない）"$'\n'
      done < <(comm -23 "$ana_cit_f" "$ana_def_f")
      rm -f "$ana_def_f" "$ana_cit_f"
    fi
  fi
  unresolved="${unresolved}${ana_unresolved}"

  if [ -z "$unresolved" ]; then
    report PASS G-LINK "全 [[SPEC/CC/REF]] 参照と分析物 ID 参照が解決する（UNRESOLVED 0）"
  else
    report FAIL G-LINK "未解決参照あり（$(echo -n "$unresolved" | grep -c . ) 件）" "$unresolved"
  fi
}

# --- G-SPECID: spec-id 一意（GP-9 / GP-15 ルール7） ---
# 【主張の型を表す語は 1 箇所で持つ】`metrics` の型別密度（`assertion_density_*`）と
# `G-POPULATION` が同じ語を別々に列挙すると必ず乖離する（文字を列挙する検査は漏れる。教訓 30）。
# **全称・唯一・不在は「母集団を宣言しないと検証官が判定できない」型**でひとまとめにする
# ——反例 1 件で結論の向きが変わるのは 3 型とも同じで、判定の重さも同じ。
CLAIM_ABSENT_RE='(^|[^0-9])0 件|存在しない|持たない|皆無|無い'
CLAIM_UNIQUE_RE='唯一|のみ|だけ'
CLAIM_UNIVERSAL_RE='すべて|全域|例外なく|全て|全経路|全書き込み経路|どの経路でも'
# 【母集団を要求する語は狭くする（実測で決めた）】`metrics` の型別密度は「測るだけ」なので
# 広い語でよいが、**合否を持つ検査に同じ広さを使うと偽陽性で埋まる**。実データ（主張行 7,294）で
# 測った発火行数: `のみ` 642 ／ `だけ` 715 ／ `無い` 556 ——**いずれも日常語**で全数主張の
# 指標にならない（「指定が無い」「〜のみ実装」等）。`持たない` 70・`皆無` 4 も個別事実の記述だった。
# 残すのは**全数を主張していることが語形から確定するもの**だけ:
#   全称（すべて 169 / 全て 8 / 全域 1 / 例外なく 1）／不在（0 件 253 / 存在しない 104）／唯一（92）
# 【経路の全称（2026-10-01 追加。GP-5 ルール10 / FB-18）】「全経路で数えた」は数え上げの一覧が無いと裏取りできない。
# 否定文（「全経路は数えていない」）にも当たるが、実測で主張行に当たったのは数千ブロック中 1（検証済み）なので許容する。
# 同じ語を CLAIM_UNIVERSAL_RE にも足したので、metrics の assertion_density_universal は 2026-10-01 を境に不連続になる。
# 【`0 件` は数字の続きでないこと】`10 件`・`500 件` に部分一致していた（完走試験で実測。2026-10-01）。
CLAIM_NEEDS_POP_RE='(^|[^0-9])0 件|存在しない|唯一|すべて|全域|例外なく|全て|全経路|全書き込み経路|どの経路でも'
# 【主張行の述語は 1 箇所に定義する（2026-09-28。完走試験で実測）】
# 以前は同じ正規表現を 5 箇所に書き写しており、**パスを省いた継続形（`:105,160-165`。直前のファイルを指す）を
# どこも拾わなかった**。実測で千行を超える主張行が数えられず、
# 全称主張の一部が `G-VERIFY-ORDER` に、母集団を要する主張の一部が `G-POPULATION` に見えていなかった。
# ⇒ **検査の網（母集団・検証順・ブロック外）は広い述語で見る。**
# 【G-BLOCK-SIZE の判定だけは狭い述語のまま】広げると完走した参照成果物でも上限超過が 8 → 55 件になる
# （実測。完成品が FAIL する要求はゲートを外させる＝GP-103）。広い数え方の超過は**列挙だけ**する。
# 【awk の `-v` を使わず、正規表現リテラルへ埋め込む】`-v` はバックスラッシュを解釈するので `\.` を `[.]` で書いてある。
CLAIM_LINE_RE='`[^`]+[.][A-Za-z0-9]+:[0-9]+|^[|][[:space:]]*`|`:[0-9]+'
CLAIM_LINE_NARROW_RE='`[^`]+[.][A-Za-z0-9]+:[0-9]+|^[|][[:space:]]*`'

gate_specid_unique() {
  local dups
  dups=$(spec_files | nul_pack | xargs -0 -r grep -h '^spec-id: ' 2>/dev/null \
         | grep -v 'TEMPLATE-DO-NOT-INDEX' | sort | uniq -d || true)
  if [ -z "$dups" ]; then
    report PASS G-SPECID "spec-id に重複がない"
  else
    report FAIL G-SPECID "spec-id が重複" "$dups"
  fi
}

# --- G-COMMIT: source-commit 断面一致（GP-9 / GP-15 ルール7） ---
gate_source_commit() {
  local scope_commit
  # scope.md の「解析断面」か表形式（| コミットハッシュ（あれば） | <hash> |）から読む（G-SOURCE-INTACT と共有）
  scope_commit=$(scope_commit_of)
  if [ -z "$scope_commit" ]; then
    report WARN G-COMMIT "scope.md に断面コミットが未記録（Phase 0 未完か、断面なし対象）"
    return
  fi
  local mismatch
  mismatch=$(spec_files | nul_pack | xargs -0 -r grep -l '^source-commit: ' 2>/dev/null \
             | nul_pack | xargs -0 -r grep -H '^source-commit: ' 2>/dev/null \
             | grep -v "$scope_commit" | grep -v '<断面コミット' || true)
  if [ -z "$mismatch" ]; then
    report PASS G-COMMIT "全 front-matter の source-commit が scope.md の断面（${scope_commit:0:12}）と一致"
  else
    report FAIL G-COMMIT "source-commit 不一致の仕様あり" "$mismatch"
  fi
}

# --- G-SOURCE-INTACT: 解析対象が初期状態から変わっていない（SB-5。「起きたら気づいて戻す」） ---
# 【止めるのではなく気づく】ホストの承認では解析対象への書き込みを止めきれない（シェル経由で書ける。
# 承認を広く許すホストもある）。init.sh が `gates.sh source-baseline` で記録した**全ファイルの中身の指紋**と今を比べ、違えば FAIL にする。
# 【git の状態ではなく中身で比べる（2026-10-26 の再レビュー）】初版は `git status --porcelain` の行の集合を比べており、
# 既に変更済みのファイルの再変更・既存の未追跡ディレクトリの中・.gitignore 済みのパス・`status.showUntrackedFiles=no` を見逃した。
# git でない対象の「記録より新しいファイル」も、削除・`cp -p`・展開を見逃した。中身の指紋（cksum）は git の設定にも時刻にも依らない。
# 【限界】比べるのはゲートを走らせた時点だけ。写してから消せば、次のゲートまでに気づけない。除くのは `.git/` と `.DS_Store` だけ。
# 【断面】記録した HEAD が scope.md の断面コミットと違えば WARN（init の後に断面を checkout したなら記録し直す）。
source_fingerprint() { # 解析対象の全ファイル（.git と .DS_Store を除く）を「cksum サイズ 相対パス」で、パスの順に出す
  ( cd "$SOURCE_PATH" 2>/dev/null && find . -type f ! -path '*/.git/*' ! -name .git ! -name .DS_Store -print0 2>/dev/null \
      | LC_ALL=C sort -z | xargs -0 -r cksum 2>/dev/null )
}
scope_commit_of() { # scope.md に記録した断面コミット（無ければ空）
  local c
  c=$(grep -A2 '解析断面' "$SCOPE" 2>/dev/null | grep -o '[0-9a-f]\{7,40\}' | head -1 || true)
  [ -n "$c" ] || c=$(grep 'コミットハッシュ' "$SCOPE" 2>/dev/null | grep -o '[0-9a-f]\{7,40\}' | head -1 || true)
  printf '%s' "$c"
}
run_source_baseline() { # 解析対象の今の状態を記録する（init.sh が呼ぶ。意図して解析対象を変えたら ADR を書いて人が呼び直す）
  [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ] || { echo "ERROR: SOURCE_PATH が無い・存在しない（gate-config.env）: [${SOURCE_PATH}]" >&2; return 2; }
  local sb="$WROOT/00-ingestion/source-baseline.env" lst="$WROOT/00-ingestion/source-baseline.files" kind=files head=none n
  if git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    kind=git
    # 【-q --verify】コミットが 1 つも無いリポジトリで `rev-parse HEAD` は stdout に HEAD を出して失敗する（値が 2 行になった。再レビュー）
    head=$(git -C "$SOURCE_PATH" rev-parse -q --verify HEAD 2>/dev/null || echo none)
  fi
  source_fingerprint > "$lst.tmp" || { rm -f "$lst.tmp"; echo "ERROR: 解析対象の指紋を取れない: ${SOURCE_PATH}" >&2; return 2; }
  mv "$lst.tmp" "$lst"
  n=$(grep -c . "$lst" || true)
  cat > "$sb" << EOF
# 解析対象の初期状態（gates.sh source-baseline が記録。G-SOURCE-INTACT が全ファイルの中身の指紋 source-baseline.files と今を比べる）
# 意図して解析対象を変えた（断面を進めた等）ときだけ、ADR を書いてから bash spec-extraction/03-audit/gates.sh source-baseline で記録し直す。
# kind: git = git の作業ツリー（戻すのは git checkout）/ files = git でない（戻す手段が無い。複製を取っておく）
SOURCE_BASELINE_KIND=${kind}
SOURCE_BASELINE_HEAD=${head}
SOURCE_BASELINE_FILES=${n}
SOURCE_BASELINE_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  echo "記録した: ${sb#"$REPO_ROOT"/}（kind=${kind}・HEAD=${head:0:12}・ファイル ${n} 件）"
  if [ "$kind" = files ]; then echo "⚠ 解析対象が git の作業ツリーではない。書き換えられても戻す手段が無いので、複製を取っておくこと"; fi
  return 0
}
gate_source_intact() {
  local sb="$WROOT/00-ingestion/source-baseline.env" lst="$WROOT/00-ingestion/source-baseline.files" kind head sc diffs nd
  if [ ! -f "$sb" ] || [ ! -f "$lst" ]; then
    report WARN G-SOURCE-INTACT "解析対象の記録（source-baseline.env / .files）が無い（この検査より前に作ったリポジトリ）。解析対象の変更は検出していない。作るなら bash spec-extraction/03-audit/gates.sh source-baseline"
    return
  fi
  [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ] || { report INCOMPLETE G-SOURCE-INTACT "SOURCE_PATH が無い・存在しない（gate-config.env）。解析対象の変更を確かめられない"; return; }
  kind=$(grep -m1 '^SOURCE_BASELINE_KIND=' "$sb" | cut -d= -f2- || true)
  head=$(grep -m1 '^SOURCE_BASELINE_HEAD=' "$sb" | cut -d= -f2- || true)
  # 記録と今を相対パスで突き合わせる（変更・追加・削除）。パスに空白があってよい（3 列目以降をパスとして読む）
  diffs=$(source_fingerprint | LC_ALL=C awk '
      function pth(l,  a, b) { a = index(l, " "); b = index(substr(l, a + 1), " "); return substr(l, a + b + 1) }
      function sig(l,  a, b) { a = index(l, " "); b = index(substr(l, a + 1), " "); return substr(l, 1, a + b - 1) }
      NR == FNR { base[pth($0)] = sig($0); next }
      { p = pth($0); if (!(p in base)) print "追加: " p; else if (base[p] != sig($0)) print "変更: " p; seen[p] = 1 }
      END { for (p in base) if (!(p in seen)) print "削除: " p }' "$lst" - | LC_ALL=C sort)
  if [ -n "$diffs" ]; then
    nd=$(printf '%s\n' "$diffs" | grep -c . || true)
    if [ "$kind" = git ]; then
      report FAIL G-SOURCE-INTACT "解析対象が記録から変わった（${nd} 件。SB-5）。git -C <解析対象> status と git checkout で戻す（未追跡・無視されたファイルは手で消す）。意図した変更なら ADR を書いて gates.sh source-baseline で記録し直す" "$(printf '%s\n' "$diffs" | head -50)"
    else
      report FAIL G-SOURCE-INTACT "解析対象が記録から変わった（${nd} 件。SB-5）。git でないので自動では戻せない（複製から戻す）。意図した変更なら ADR を書いて gates.sh source-baseline で記録し直す" "$(printf '%s\n' "$diffs" | head -50)"
    fi
    return
  fi
  sc=$(scope_commit_of)
  if [ "$kind" = git ] && [ -n "$sc" ] && [ "$head" != none ] && [ "${head#"$sc"}" = "$head" ]; then
    report WARN G-SOURCE-INTACT "解析対象は記録のままだが、記録した HEAD（${head:0:12}）が scope.md の断面（${sc:0:12}）と違う。断面を checkout してから gates.sh source-baseline で記録し直す"
    return
  fi
  report PASS G-SOURCE-INTACT "解析対象は記録のまま（ファイル $(grep -c . "$lst" || true) 件の中身が一致。kind=${kind}$([ "$kind" = files ] && printf '・git でないので戻す手段は無い')）"
}
# --- G-DENOM: カバレッジ分母の消化（SB-11 / GP-10 ルール8） ---
gate_denominator() {
  [ -f "$CODEGRAPH" ] || { report FAIL G-DENOM "code-graph.md が存在しない"; return; }
  local hits
  hits=$(grep '^| NODE' "$CODEGRAPH" | grep -n '⏸️\|🔄\|未着手\|分析中' || true)

  # 【分母の割当表「未割当 0」（旧 gate_tier (3) の移設先。2026-09-12）】
  # 実測: 割当を省くと**系統が丸ごと欠落し、しかもそれに気づけない**（別経路・別アクターを落とす）。
  # **`gates.sh` でこれを要求するのは元は `gate_tier` だけ**で、`GP-104` の撤去で失われる
  # ——`gate_tier` 自身が「**全 tier で要求する**」と書いていた＝tier 非依存の要求である。  [撤去の記録]
  # 【移設先の理由】`G-DENOM` の「未消化ノード 0」と、割当表の「未割当 0」は
  # **同じ不変条件を別の成果物側から見たもの**である（コードグラフ側 / 能力仕様側）。
  # 統合すると分母の強制点が 1 つになる（[[GP-101]]）。
  # 対象は `capability_specs`（tier 語彙を使わない述語。`REBUILD_LAYER=off` なら 0 件）。  [撤去の記録]
  local unassigned=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q '^## 分母の割当' "$f" 2>/dev/null || {
      unassigned+="  ${f#"$REPO_ROOT"/}: 「分母の割当」節が無い（未割当 0 を示せない）"$'\n'; continue; }
    # 「未割当: 0 件」以外（TBD・空・非ゼロ）は未達
    local u
    u=$(grep -m1 -oE '未割当: *\*{0,2}[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' || true)
    if [ -z "$u" ]; then
      unassigned+="  ${f#"$REPO_ROOT"/}: 未割当の件数が数値で書かれていない"$'\n'
    elif [ "$u" -ne 0 ]; then
      unassigned+="  ${f#"$REPO_ROOT"/}: 未割当 ${u} 件（0 でなければ未完）"$'\n'
    fi
  done < <(capability_specs)

  if [ -n "$hits" ] || [ -n "$unassigned" ]; then
    local n_h=0 n_u=0
    [ -n "$hits" ] && n_h=$(echo "$hits" | wc -l | tr -d ' ')
    [ -n "$unassigned" ] && n_u=$(printf '%s' "$unassigned" | grep -c . || true)
    report INCOMPLETE G-DENOM "分母が未消化または未割当（未消化ノード ${n_h} 件 / 割当表の未達 ${n_u} 件）。範囲縮小なら ADR かユーザー確認が必要（SB-11 ルール6 / GP-13 ルール10）" "${hits}${hits:+$'\n'}${unassigned}"
  else
    # 【対象 0 件を「検査した」と言わない】`capability_specs` が空なら割当は**見ていない**。
    # 実測: 参照成果物の本質層 9 件は `artifact-key` を持たず、対象 0 件のまま
    # 「未割当 0」と報告していた（検査していないのに検査したと言う型）。
    if [ "$(capability_specs 2>/dev/null | grep -c . || true)" -eq 0 ]; then
      report PASS G-DENOM "コードグラフに「未着手」「分析中」ノードがゼロ（分母消化）。能力仕様は対象 0 件（artifact-key: capability-spec を持つ仕様が無いため割当は未検査）"
    else
      report PASS G-DENOM "コードグラフに「未着手」「分析中」ノードがゼロ（分母消化）。能力仕様の分母の割当も未割当 0"
    fi
  fi
}

# --- G-RECON: reconciliation 実施（SB-2 §2b / FB-4） ---
gate_reconciliation() {
  local trace="$AUDIT/traceability.md"
  [ -f "$trace" ] || { report FAIL G-RECON "traceability.md が存在しない"; return; }
  # 【説明文とコード表記を見ない】初版は `grep -v '<!--'` で開始マーカーの行だけを除いていたため、
  # **複数行コメントの継続行**と**コード表記で引用したチェックリスト行**に当たって
  # **自分の説明文で FAIL した**（効果測定の実測）。共通ヘルパで両方を落としてから探す。
  local placeholders
  placeholders=$(strip_html_comments < "$trace" | strip_code_spans_prose \
                   | LC_ALL=C grep -n '<rule>\|^| N |' || true)
  if [ -n "$placeholders" ]; then
    report FAIL G-RECON "reconciliation が空テンプレのまま（<rule> / N プレースホルダ残存）" "$placeholders"
    return
  fi
  # 合計一致の算術検査: 「抽出総数 | captured | not_applicable | delegated | unreachable | not_accounted_for」行
  # 【節で窓を切らない（2026-09-21 に方式を変えた）】一度 `## …reconciliation` 見出しから
  # 次の見出しまでで窓を切ったが、**2 つの fail-open を作った**（実測）:
  #   (a) 節の中に小見出し（`### 2b-2. …`）があると**そこで窓が閉じ**、以降の不一致を見逃す
  #   (b) 見出しから `reconciliation` の語を外すだけで**一度も走らず PASS** になる
  # どちらも「検査していないのに『合計が一致』と書く」形で、`G-HOLD-ADR` の設計と逆である。
  # ⇒ **ヘッダ行を起点に、その表のデータ行だけを見る**（窓は切らないが対象は表に閉じる）。
  # 【行の形だけで選ぶ方式は使わない】「disposition 5 列がすべて純粋な数値の行」で選んだ版は、
  # **実データで最も多い書き方（`**0**` のように太字にしたセル）を非数値と見て行ごと検査対象外にし、
  # 0 行検査のまま「合計が一致」と報告した**（実測: 検査行数が 7 → 0 / 1 → 0 になった）。
  # 同時に、通し番号つきの全数値表（層別の実測表など）を reconciliation 行と誤認もしていた。
  # ⇒ (a) セルは `**`／バッククォート／空白を落としてから数値化する（現に使われている形を拒否しない）
  #    (b) 数値化できないセルがあれば**スキップせず「算術検査できない」として落とす**
  #    (c) データ行が 1 行も無ければ PASS にしない（`G-INDEP` の「欄の不在を FAIL にする」と同じ規律）
  # 【行番号は原文のまま出す】`strip_html_comments` は行数を保存するので `NR` が原文と一致する。
  # 【ヘッダも正規化して照合する】素の文字列で照合した初版は、**ヘッダを太字にする・全角スペースを
  # 混ぜる・語を和訳する**だけで表が見つからなくなり、**合計が正しい完成品が落ちた**（実測 3 形）。
  # `GP-103`: 完成品が FAIL する要求はゲートを外させる。⇒ 装飾と空白は吸収する。
  # ただし**語の言い換えと列順の入れ替えは吸収しない**（吸収すると別の表を誤って算術検査する）。
  # 第 1 列が `抽出総数` であることを表の目印にする（列順が違えば表として認識せず未達になる＝fail-closed）。
  # 【認識できなかったヘッダを数える（表が複数あるときの沈黙を塞ぐ）】
  # 「データ行が 0 件なら未達」だけでは**表が 1 つのときしか効かない**。実測: 参照成果物は
  # reconciliation 表を **7 個**持ち、そのうち 1 つの第 1 列を言い換えるだけで
  # **その表だけが黙って検査対象外**になり、他の表が正しいので PASS になった（合計 500 ≠ 1 を見逃した）。
  # ⇒ disposition 名が**別々の列に 3 つ以上**ある表の行で、第 1 列が `抽出総数` でないものを
  #    「ヘッダとして認識できない表」として落とす（実測: 参照成果物 3 本と配布雛形で誤検出 0 件）。
  #    1 つのセルに 5 つの値を並べた説明行（`captured/not_applicable/…`）は列で数えるので外れる。
  local sum_check
  sum_check=$(strip_html_comments < "$trace" | LC_ALL=C awk -F'|' '
    function norm(v) { gsub(/\*\*|`|[ \t]|　/, "", v); return v }
    function isdisp(c) { return (c == "captured" || c == "not_applicable" || c == "delegated" \
                                 || c == "unreachable" || c == "not_accounted_for") }
    norm($2) == "抽出総数" && NF >= 8 { t = 1; tr = 0; thdr = NR; saw_hdr = 1; cand = 0; next }
    # 【区切り行は行全体で判定する】`^\|[ \t]*-` で見た初版は 2 つの穴を開けた（実測）:
    #   (a) 寄せ記法（`|:---|---:|`）を**データ行と数えて完成品を FAIL** にした
    #   (b) 第 1 列がハイフンのデータ行（`| - | 500 | … |`）を**区切り行として飛ばし**、
    #       総数が読めないのに PASS にした
    # 【区切り行はハイフンを 1 つ以上要求する】`[-:| \t]+` で見た初版は、**全セル空のデータ行
    # （`| | | | | | |`）を区切り行として飛ばし**、欄を空けたまま PASS にした。
    $0 ~ /^[ \t]*\|[-:| \t]*-[-:| \t]*$/ { if (t) next; next }
    {
      nd = 0
      for (i = 3; i <= NF; i++) if (isdisp(norm($i))) nd++
      # 【先頭の `|` を要求しない】要求した初版は、**先頭 `|` を省いた GFM 表**
      # （`抽出総数 | captured | … | 突合`）がヘッダ規則にも未認識規則にも掛からず沈黙した。
      # disposition 名が別々の列に 3 つ以上あること自体が強い判別条件なので `|` の有無は問わない。
      if (nd >= 3 && norm($2) != "抽出総数") {
        # 【凡例表を叱らない】disposition の意味を列で並べた説明表（`| 区分 | captured | … |`）まで
        # 落とすと「記述を変えるしか回避手段が無い未達」になる。**続く 3 行以内に数値セルを 2 つ以上
        # 持つ行があるとき**だけ「突合表なのに認識できない」と判定する（実データでは未発生の誤検出を予防）。
        cand = NR; cl = $0; t = 0; next
      }
      if (cand && NR - cand <= 3) {
        nn = 0
        for (i = 2; i <= NF; i++) if (norm($i) ~ /^[0-9]+$/) nn++
        if (nn >= 2) {
          printf "行 %d: reconciliation 表のヘッダとして認識できない（第 1 列を「抽出総数」にする。列順の入れ替え・言い換えは認めない。disposition の凡例表なら 5 つの値を 1 セルにまとめる）\n", cand
          cand = 0
        }
      } else if (cand) cand = 0
    }
    t {
      # 【表単位でデータ行を数える】ファイル単位の合計（`rows`）だけで見た初版は、
      # **表が複数あると「ヘッダは認識したがデータ行が 0 件の表」が沈黙**した
      # （他の表に行があるので `rows > 0`）。引用の中の表・ヘッダだけ先に作った表がこれに当たる。
      if ($0 !~ /^[ \t]*\|/) {
        if (tr == 0) printf "行 %d: reconciliation 表にデータ行が無い（ヘッダだけの表を残さない）\n", thdr
        t = 0; tr = 0; next
      }
      rows++; tr++
      bad = ""
      for (i = 2; i <= 7; i++) { c = norm($i); if (c !~ /^[0-9]+$/) bad = bad sprintf(" 第%d列[%s]", i - 1, c) }
      if (bad != "") { printf "行 %d: 数値でないセルがあり算術検査できない:%s\n", NR, bad; next }
      total = norm($2) + 0
      s = norm($3) + norm($4) + norm($5) + norm($6) + norm($7)
      if (total != s) printf "行 %d: 抽出総数 %d ≠ disposition 合計 %d\n", NR, total, s
    }
    END {
      if (t && tr == 0) printf "行 %d: reconciliation 表にデータ行が無い（ヘッダだけの表を残さない）\n", thdr
      if (rows == 0 && !saw_hdr) print "NOROWS"
    }' || true)
  # 【判定文を実態に合わせる】「データ行が無い」を「合計不一致」と報告した初版は、
  # **自分が塞いだ型（検査していないのに検査したと書く）の逆版**だった。
  if [ "$sum_check" = "NOROWS" ]; then
    report FAIL G-RECON "reconciliation の数値表が見つからない（検査していない状態を PASS にしない）" \
      "第 1 列が「抽出総数」で、以降に disposition 5 列（captured / not_applicable / delegated / unreachable / not_accounted_for）がある表を置く（装飾・空白・全角空白は吸収するが、語の言い換えと列順の入れ替えは認めない）"
  elif [ -z "$sum_check" ]; then
    report PASS G-RECON "reconciliation が実データで埋まり、合計が一致"
  else
    report FAIL G-RECON "reconciliation の突合が成立しない（合計不一致／算術検査できないセル／認識できないヘッダ）" "$sum_check"
  fi
}

# --- G-TEMPLATE: 未記入テンプレ・未チェック残存（FB-4） ---
# --- G-PROVISIONAL: 暫定記述マーカーの残存（GP-28。調査中の仮置きを完了宣言に混ぜない） ---
# 調査のための暫定記述は `<!-- PROVISIONAL: 理由 -->` を付けて後で戻せるようにする。
# 解析対象は変更しない（SB-5）ため in-code マーカーは不要だが、spec 側の暫定記述には同型の問題がある。
gate_provisional() {
  local hits
  # 除外: ゲート自身・結果ファイル・雛形（_template）・受け皿ディレクトリ・
  #       規約を説明している行（プレースホルダ例やチェックリストの文言）。
  # 検出したいのは「実際に付けられた `<!-- PROVISIONAL: 理由 -->` マーカー」だけである。
  # **マーカー形式（PROVISIONAL: <理由>）だけを検出する。**
  # ゲート ID の言及（G-PROVISIONAL）や規約の説明文を拾うと、規約を書いた瞬間に FAIL する
  # （初版は GP-28 のサマリ行に含まれる "G-PROVISIONAL" を拾って誤検出した）。
  # 【設計上の注意（実測した 2 つの穴を塞いだ形）】
  #  (1) 表記ゆれで回避された: 小文字 `provisional`・全角・コロンなしはすべて素通りした。
  #      → **大文字小文字を無視し（-i）、コロンを必須にしない**。
  #  (2) 誤検出回避のための `grep -vE 'PROVISIONAL: *<'` が**そのまま抜け道**になっていた
  #      （理由を `<調査中>` と書けば不可視）。→ プレースホルダ判定は
  #      **雛形ファイルの除外**だけで行い、本文の内容では除外しない。
  #  (3) 逆に「全出現」を拾うと**規約の説明文で FAIL する**（作業ツリー台帳の分類名
  #      `provisional`／「未検証（暫定・provisional）」等）。規約を書いた瞬間に落ちるゲートは使えない。
  # → **HTML コメント形式のマーカーだけを検出する**（`<!-- ... PROVISIONAL ... -->` の 1 行）。
  #   大文字小文字と全角コロン・コロン無しは許容し、表記ゆれでの回避を塞ぐ。
  #   説明文（バッククォート内・地の文）はコメント形式でないので拾わない。
  #  (4) 規約文が記法を**バッククォートで引用**している行も拾ってしまう
  #      （`` `<!-- PROVISIONAL: <理由> -->` を付ける `` という説明）。
  #      → 各行から**コード表記（`...`）を除去してから**判定する。
  hits=$(grep -rniE '<!--[^>]*PROVISIONAL' "$SPECS" "$WROOT" 2>/dev/null \
         | grep -v 'gate-results' | grep -v 'investigation-notes' \
         | grep -v '_template' | grep -v 'subtask-plan' \
         | grep -v '/gates.sh:' \
         | awk -v cs="$CODE_SPAN_RE" '
             # 【貼り付けたゲート出力に自己一致しない（2026-09-28。反証レビューで実証）】
             # 実行記録に「phase4 の出力をそのまま貼る」と、このゲートの詳細行
             # （`specs/x.md:12:<!-- PROVISIONAL … -->`）が記録の中で再び一致し、**一度発火すると
             # 記録がある限り永久に FAIL** する（G-TEMPLATE で実測した型と同じ）。
             # 本文が「`<パス>.md:<行>:`」で始まる行は**他のファイルを指すゲート出力の引用**なので数えない。
             # フェンスで囲んでも防げない（CODE_SPAN_RE は行内の `…` しか除かない）ので、形で判定する。
             # 【Windows のドライブ文字を許す（2026-11-07）】Git for Windows の `git rev-parse --show-toplevel` は `D:/…` を返すので、
             #  `^[^:]*:` がドライブの `:` で止まって行番号に届かない（G-TEMPLATE で実害。下の同型を参照）。
             { c = $0; sub(/^([A-Za-z]:)?[^:]*:[0-9]+:/, "", c)
               if (c ~ /^[[:space:]>|*-]*[^[:space:]:]+[.](md|tsv|txt|log):[0-9]+:/) next
               line = $0; gsub(cs, "", line)
               if (line ~ /<!--/ && toupper(line) ~ /PROVISIONAL/) print $0 }' || true)
  if [ -z "$hits" ]; then
    report PASS G-PROVISIONAL "暫定記述マーカー（PROVISIONAL）が残っていない"
  else
    report FAIL G-PROVISIONAL "暫定記述が残存（$(echo "$hits" | wc -l | tr -d ' ') 件）。調査の仮置きを完了宣言に混ぜない（GP-28）" "$hits"
  fi
}

# --- G-HOLD-ADR: 分母を縮めたのに対応 ADR が無い（GP-106 HOLD-1 の機械化） ---
# Phase H の限界（HOLD が散文ルールのままで機械強制されていない）への緩和策。
# 「トリガーが発火したのに停止しなかった」は直接検出できないが、
# **停止すべき判断の痕跡（対象外ノード）に対して ADR が実在するか**は検査できる。
gate_hold_adr() {
  local hold_fence_odd=""   # フェンス奇数で突合を保留したか（判定に残すため関数全体で持つ）
  [ -f "$CODEGRAPH" ] || { report SKIP G-HOLD-ADR "code-graph.md が無い（未生成段階）"; return; }

  # 【最重要】まず**状態語彙の許可リスト検査**を行う。
  # 「対象外」という語だけを探すゲートは、**語彙外の状態を書けば素通りする**
  # （実測: 状態列に「スコープ外」と書くと G-DENOM も G-HOLD-ADR も PASS し、
  #  ノードが分母から静かに消えた＝SB-11 の失敗が再現した）。
  # 許可語彙: 未着手 / 分析中 / 仕様化済 / 対象外 の 4 語のいずれかを**必ず含む**こと。
  local bad_vocab=""
  while IFS= read -r line; do
    local state
    state=$(echo "$line" | awk -F'|' '{print $(NF-1)}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$state" in
      *未着手*|*分析中*|*仕様化済*|*対象外*) ;;
      '') ;;   # 空欄は G-CODEGRAPH（形式検査）の担当
      *) bad_vocab+="  語彙外の状態「${state}」: $(echo "$line" | cut -c1-70)"$'\n' ;;
    esac
  done < <(node_rows)
  if [ -n "$bad_vocab" ]; then
    report FAIL G-HOLD-ADR "仕様化状態が語彙外（未着手/分析中/仕様化済/対象外 のみ。語彙外は分母から静かに消える）" "$bad_vocab"
    return
  fi

  # 「対象外」ノードを抽出し、各行が ADR-N を引いているかを見る（HOLD-1 は ADR 必須）
  local excluded missing=""
  # 【エッジ行だけを除く（`node_rows` を流用しない。2026-09-22）】
  # 語彙検査はフィルタ後、対象外抽出はフィルタ前という**非対称**があり、
  # エッジ行が「対象外」の語を含むと対象外ノードとして ADR を要求してしまう。
  # ただし `node_rows` をそのまま使うと**捕捉範囲が狭まる**——`node_rows` の行正規表現は
  # ID の末尾に数字を要求するので、`| NODE-HAX |` のような ID 規約から外れたノードが
  # **対象外の告発から静かに消える**（実測: 既存検査の告発が出なくなった）。
  # 分母を縮めないことが優先なので、**捕捉は `^| NODE` のまま**にして
  # **エッジ行（第 2 列が NODE-ID、または第 1 列に矢印）とヘッダだけを除く**。
  # 逆に `node_rows` の正規表現を緩めるのは採れない——実データでは
  # 分母突合の表の行（`| NODE-MOD | ビルド定義の宣言数 … |`）まで拾う（実測 11 件）。
  excluded=$(grep '^| NODE' "$CODEGRAPH" 2>/dev/null \
    | LC_ALL=C awk -F'|' -v E="$NODE_EDGE_RE" '
        function trim(v) { gsub(/^[ \t]+|[ \t]+$/, "", v); return v }
        trim($2) == "NODE-ID" { next }
        {
          c2 = trim($3)
          gsub(/（[^）]*）/, "", c2); gsub(/\([^)]*\)/, "", c2); c2 = trim(c2)
          if ($2 ~ E || c2 ~ /^NODE-([A-Za-z0-9]+-)+[0-9]+$/) next
          print
        }' | grep '対象外' || true)
  if [ -z "$excluded" ]; then
    report PASS G-HOLD-ADR "対象外ノードが無い（分母を縮めていない）／状態語彙は全件正当"
    return
  fi
  while IFS= read -r line; do
    echo "$line" | grep -qE 'ADR-[0-9]+' || \
      missing+="  ADR 参照なし: $(echo "$line" | cut -c1-90)"$'\n'
  done <<< "$excluded"
  # ADR 番号が decisions.md に**実エントリとして**実在するかを突合する。
  # 【注意】`decisions.md` の記載例は HTML コメント内の `## ADR-1:` なので、
  # コメント内を除外しないと **ADR-1 を引くだけで通る**（実測でこの回避が成立した）。
  local dangling=""
  if [ -f "$DECISIONS" ]; then
    local live_adrs
    live_adrs=$(live_adr_numbers)   # コメント内・コードフェンス内のドラフトは実エントリと見なさない
    # 【フェンスが奇数なら「無い」と言わない】閉じ忘れがあると抽出が不完全になり、
    # **実在するのに「実エントリに無い」**という直せない未達を出す（許可側とは逆向きの配慮）。
    # 【蓄積の前にフラグを立てる】以前は `dangling=""` を**ループの前**に置いていたため
    # **抑止が no-op** で、「保留した」と言いながら同じ実行で告発を出していた（実測。出力が自己矛盾）。
    # 【`note_detail` は判定の後に出す】前に出すと 6 スペース字下げが**直前のゲート**の
    # 付随情報として読まれる（`gate_rebuild_layer` で実測した誤帰属と同型）。ここではフラグだけ立てる。
    if decisions_fence_odd; then
      hold_fence_odd=1
    fi
    while IFS= read -r adr; do
      [ -n "$hold_fence_odd" ] && continue
      echo "$live_adrs" | grep -qx "$adr" || dangling+="  ${adr} が decisions.md の実エントリに無い（記載例のコメントは無効）"$'\n'
    done < <(echo "$excluded" | grep -oE 'ADR-[0-9]+' | sort -u)
  fi
  if [ -z "$missing" ] && [ -z "$dangling" ]; then
    # 【保留したなら PASS にしない】告発を止めたうえで PASS を出すと、**1 行のデータ編集で
    # FAIL → PASS に反転し、正本には「実在する ADR が紐づく」と書かれる**（実測でそうなった）。
    # `G-REGRESS` は指紋が同じなので見逃す（`FB-10` 型）。**測っていないことを判定に残す。**
    if [ -n "$hold_fence_odd" ]; then
      report INCOMPLETE G-HOLD-ADR "decisions.md のコードフェンスが奇数のため ADR の突合を保留した" \
        "閉じ忘れがあると実エントリの抽出が不完全になるため、突合を実施していない（PASS にはしない）。
decisions.md のコードフェンスを閉じてから再実行すること。"
      note_detail G-HOLD-ADR "G-HOLD-ADR: コードフェンスが奇数（閉じ忘れの可能性）" \
        "実在しない ADR の告発は保留した。フェンスを閉じると突合が再開する。"
    else
      report PASS G-HOLD-ADR "全対象外ノードに実在する ADR が紐づく（$(echo "$excluded" | wc -l | tr -d ' ') 件。HOLD-1）"
    fi
  else
    report FAIL G-HOLD-ADR "分母を縮めた判断に ADR が伴っていない（HOLD-1 は ADR 必須。GP-106）" "${missing}${dangling}"
  fi
}

# --- G-TIER: 撤去済み（2026-09-16） ---  [撤去の記録]
# `GP-104`（成果物を tier で段階配達する）とともに撤去した。判断の根拠は**実走検証**（1 能力を最深まで進めた実測。2026-09-15）で、  [撤去の記録]
# **1 能力・24 ブロックという最小規模でも 4 ラウンドで tier 3 に到達しなかった**（未到達で確定）。  [撤去の記録]
# 段階配達の機構そのものは回った（tier 1 は到達）が、**それを選ぶ理由が無い**という判定である。  [撤去の記録]
# 【残したもの】`REBUILD_LAYER`（tier より前から存在する設定値）と `G-REBUILD`（本質層の実体の床）。  [撤去の記録]
# 密度軸のゲート（`G-BLOCK-SIZE` / `G-DENSITY` / `G-LEDGER`）も tier 起因ではないので残る。  [撤去の記録]
# 【未到達の原因は tier ではない】実走検証の分析では「全数 `fabricated=0`」という反映ゲート（`SB-20`）の  [撤去の記録]
# 形に原因があり、**是正が新しい検証対象を生む**構造が収束を妨げていた。tier を撤去してもこの壁は残る  [撤去の記録]
# ——別の着手単位として `dev/developing-the-framework.md` に起票してある。


# --- G-IDENT: 実装に必要な識別子が仕様本文に実在するか（GP-20 ルール5 / SB-19 / FB-11） ---
# ノード数が分母と一致していても「その仕様から実装できる」とは限らない。
# 実運用（FB-11）では**全 23 縦串が「分母消化 100%・漏れ 0」を通過したのに、257 表のうち 90 表が
# 物理表名で specs/ に一度も登場していなかった**（割当表への参照で代替 64 / クラスパスのみ 26）。
# どちらも path:line の裏取りと 2 段トレーサビリティは満たしている——
# ゲートが見ていたのは「ノード数の一致」で「その仕様から DDL を書けるか」ではなかった。
# 【設計】自己申告の件数一致では検出できない（per-slice では自己完結して見える）ので、
# **ゲートが差集合を自分で計算する**。何が識別子かはスタック依存なので、抽出は Playbook
# （enumeration.md / gate-snippets.sh）が担当し、その出力ファイルを本ゲートが突合する。
# 【性能】識別子 1 件ごとに specs/ を grep すると O(識別子数 × specs) になり、
# 実運用規模（257 表 × 5MB）で数分かかる（G-LINK で実際に踏んだ二乗劣化）。
# **specs/ を 1 パスでトークン集合にしてから集合比較する**（O(specs + 識別子数)）。
gate_identifiers() {
  local iddir="$CODEGRAPH_DIR/identifiers"
  if [ ! -d "$iddir" ]; then
    report FAIL G-IDENT "01-code-graph/identifiers/ が無い（実装識別子の抽出が未実施。GP-20 ルール5 / FB-11）" \
      "  enumeration.md の抽出コマンドで <種別>.txt（1 行 1 識別子）を作ること"
    return
  fi
  local files
  files=$(find "$iddir" -name '*.txt' -not -name '*.excluded' 2>/dev/null | sort || true)
  if [ -z "$files" ]; then
    report FAIL G-IDENT "identifiers/ に *.txt が無い（抽出結果が空。分母の識別子を保存すること）"
    return
  fi

  # specs/ 本文を 1 パスでトークン化して集合にする（識別子は語として実在することを要求する）。
  # 部分一致を許すと `m_loan` が `m_loan_charge` に一致して**偽の PASS** になるため、語単位で突合する。
  local tokens
  # 【生成物の索引を数えない（2026-10-01）】`specs/source-index.md` の「入口から引く」表はコードグラフの入口を写すので、
  #  数えると**どの仕様にも書かれていない識別子が「本文に実在する」ことになる**（反証レビューで実測: ある型では 58/58 件）。
  # 【パスの中の語も数える（2026-10-01）】`/` と `.` を語の一部にしていたため、`…/PageServlet.java:12` や
  #  `/roller-ui/authoring/maintenance!index.rol` から `PageServlet`・`maintenance` が語として取り出されず、
  #  仕様に書いてあるのに「未記載」と数えた。区切りを変えた 2 通りの分割の和集合にする（部分一致はしない）。
  tokens=$( { content_spec_files | nul_pack | xargs -0 -r cat 2>/dev/null | tr -c 'A-Za-z0-9_./-' '\n'
              content_spec_files | nul_pack | xargs -0 -r cat 2>/dev/null | tr -c 'A-Za-z0-9_-' '\n'; } \
            | sed '/^$/d' | sort -u || true)
  local tokfile="${TMPDIR:-/tmp}/gates-tokens.$$"
  echo "$tokens" > "$tokfile"

  local total=0 missing_all="" kinds=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    kinds=$((kinds + 1))
    local kind ids n miss
    kind=$(basename "$f" .txt)
    # 空行・コメント行を除いた識別子集合
    ids=$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u || true)
    n=$(echo "$ids" | grep -c . || true)
    [ "${n:-0}" -eq 0 ] && continue
    total=$((total + n))
    # 語として実在しないものを抽出（トークン集合との差集合）。
    # トークン化で表現できない識別子（`/loans/{id}` 等の記号入り）は個別に部分一致で救済する。
    miss=$(comm -23 <(echo "$ids") "$tokfile" 2>/dev/null || true)
    if [ -n "$miss" ]; then
      local still=""
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        if echo "$id" | grep -qE '^[A-Za-z0-9_./-]+$'; then
          still+="$id"$'\n'          # 語形なのにトークン集合に無い＝本当に未記載
        else
          content_spec_files | nul_pack | xargs -0 -r grep -qF -- "$id" 2>/dev/null || still+="$id"$'\n'
        fi
      done <<< "$miss"
      # ADR つきで除外されているものを差し引く（真に対象外のケースの逃げ道。ADR の実在を突合する）
      local exc="$iddir/${kind}.excluded"
      if [ -n "$still" ] && [ -f "$exc" ]; then
        local live_adrs=""
        [ -f "$DECISIONS" ] && live_adrs=$(awk '/<!--/{c=1} /-->/{c=0;next} !c' "$DECISIONS" \
          | grep -oE '^## ADR-[0-9]+' | grep -oE 'ADR-[0-9]+' | sort -u || true)
        local kept=""
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          local line adr
          line=$(grep -F -- "$id" "$exc" 2>/dev/null | head -1 || true)
          adr=$(echo "$line" | grep -oE 'ADR-[0-9]+' | head -1 || true)
          if [ -n "$adr" ] && echo "$live_adrs" | grep -qx "$adr"; then
            continue                  # 実在する ADR で除外済み
          fi
          if [ -n "$line" ] && [ -z "$adr" ]; then
            kept+="  ${kind}: ${id}（excluded に ADR 参照が無い。理由を ADR にすること）"$'\n'; continue
          fi
          if [ -n "$adr" ]; then
            kept+="  ${kind}: ${id}（${adr} が decisions.md に実在しない）"$'\n'; continue
          fi
          kept+="  ${kind}: ${id}"$'\n'
        done <<< "$still"
        still="$kept"
      elif [ -n "$still" ]; then
        # 【空行に接頭辞を付けない】末尾の改行が空行になり、`  kind: ` だけの行が 1 件と数えられた（未記載 1 件が 2 件になった）
        still=$(printf '%s\n' "$still" | grep . | sed "s/^/  ${kind}: /")$'\n'
      fi
      [ -n "${still//[$'\n']/}" ] && missing_all+="$still"
    fi
  done <<< "$files"
  rm -f "$tokfile"

  if [ "$total" -eq 0 ]; then
    report FAIL G-IDENT "identifiers/*.txt が空（抽出結果 0 件。分母の識別子を保存すること）"
    return
  fi
  local nmiss; nmiss=$(echo -n "$missing_all" | grep -c . || true)
  if [ "${nmiss:-0}" -eq 0 ]; then
    report PASS G-IDENT "実装識別子 ${total} 件（${kinds} 種別）すべてが仕様本文に実在（GP-20 ルール5）"
  else
    report INCOMPLETE G-IDENT "仕様本文に実在しない実装識別子 ${nmiss} 件（分母は合っていても実装できない。FB-11）" \
      "${missing_all}  → 分母を変えずに記述を補う。真に対象外なら identifiers/<種別>.excluded に「<識別子> ADR-N」を書く"
  fi
}

# --- G-FALSEPOS: 偽陽性を手で除外し続けている＝ゲートが壊れている（GP-6 ルール12 / FB-10） ---
# 「毎回同じ偽陽性が出るので毎回手で除外している」は運用でカバーできている状態ではない。
# 手で除外し続ける限り (a) 偽陰性に気づけない (b) 判断が記録に残らない (c) 件数が信頼できない。
# 実運用（FB-10）では 8 例が 9 縦串以上にわたって温存され、**「実質 0 件」と報告されたため
# ゲートが壊れている事実が記録に残らなかった**。規約化しても、コマンドが書かれている場所を
# 直さなければ効かず、規約化済みの欠陥が 2 か月間偽陽性を出し続けた。
# 【判定】同一ゲート ID について「偽陽性」の記述が 2 回以上あれば FAIL（GP-6 ルール12 の「2 回以上除外したらコマンドを直す」）。
gate_false_positive() {
  # 【対象は人が書く記録だけ】gate-results.md は gates.sh 自身が追記する機械ログなので**見ない**。
  # 見ると FAIL の詳細文（偽陽性の語を含む）が追記され、次の実行でそれを数え直して
  # **一度 FAIL したら二度と PASS に戻せない**（是正しても消えない＝運用不能なゲートになる。FB-7 と同型）。
  local files=() f
  for f in "$AUDIT/traceability.md" "$WROOT/worklog/worklog.md"; do
    [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    report SKIP G-FALSEPOS "突合対象（traceability / worklog）が無い"
    return
  fi
  # HTML コメント（規約の説明文・記載例）を除去してから数える。
  # 説明文に「偽陽性」が含まれるため、素朴に grep すると新規リポジトリで誤検出する（G-REPAIR で踏んだ）。
  # 【重要】**巨大な文字列を変数に入れない**。`${body//[[:space:]]/}` のような
  # パターン置換は bash 内で O(n^2) 近くになり、**子プロセスを持たないまま数十秒〜分単位で固まる**
  # （実測: 本ゲートの初版がこれで selftest をハングさせた。原因の切り分けに手間がかかる形の欠陥である）。
  # awk 1 パスで「偽陽性を述べている行」だけを取り出す（FNR==1 でファイルごとにコメント状態を戻す）。
  local fp_lines fixed_gates offenders=""
  fp_lines=$(awk 'FNR==1{c=0} /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
                  /偽陽性|false positive/{print}' "${files[@]}" 2>/dev/null || true)
  [ -z "$fp_lines" ] && { report PASS G-FALSEPOS "偽陽性を手で除外している記録がない（GP-6 ルール12）"; return; }

  # 【是正の逃げ道を用意する】走査コマンドを直した記録があるゲートは対象外にする。
  # これが無いと「直しても FAIL のまま」になり、ゲート自体が外される（対策の形骸化）。
  #
  # 【重要な追加（実運用で踏んだ）】**壊れているゲートがフレームワーク側の場合、
  # プロジェクトは走査コマンドを直せない。** 実測（roller v5・2026-08-19）:
  # `G-IDENT` が BSD sed の `[ \t]` で末尾 `t` の識別子を切り詰め、
  # **specs に実在する識別子 8 件を「未記載」と誤報**していた。現場はこれを
  # GP-6 ルール12 の要求どおり worklog に正しく記録したが、**その記録自体が
  # 本ゲートを発火させ、しかも解除手段が無かった**（自分では直せないコマンドなので
  # 「走査コマンドを是正」と書けない）。**正しい報告を罰するゲートは運用で外される。**
  # よって「フレームワーク側の欠陥として報告・起票した」記録も解除条件に含める。
  fixed_gates=$(awk 'FNR==1{c=0} /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
                     /コマンドを是正|走査を修正|ゲートを修正|走査コマンドを直|ゲート(側)?の欠陥|framework|フレームワーク側|還元キュー|BACKPORT|起票/{print}' "${files[@]}" 2>/dev/null \
                | grep -oE 'G-[A-Z-]+' | sort -u || true)

  # ゲート ID ごとの回数（2 回以上 = 同じものを繰り返し手で除外している）
  while read -r cnt gid; do
    [ -z "${gid:-}" ] && continue
    if [ -n "$fixed_gates" ] && echo "$fixed_gates" | grep -qx "$gid"; then continue; fi
    offenders+="  ${gid}: 偽陽性の記述が ${cnt} 回（2 回以上は走査コマンドを直す。GP-6 ルール12）"$'\n'
  done < <(echo "$fp_lines" | grep -oE 'G-[A-Z-]+' | sort | uniq -c | awk '$1 >= 2 {print $1, $2}')

  # ゲート ID を伴わない記述も 3 回以上なら同じ問題（ID を書かなければ回避できる穴を塞ぐ）
  if [ -z "$offenders" ]; then
    local anon; anon=$(echo "$fp_lines" | grep -c . || true)
    if [ "${anon:-0}" -ge 3 ] && [ -z "$fixed_gates" ]; then
      offenders="  ゲート ID なしの偽陽性の記述が ${anon} 回（どの走査が壊れているかを特定して直す）"$'\n'
    fi
  fi

  if [ -z "$offenders" ]; then
    report PASS G-FALSEPOS "同一ゲートの偽陽性を繰り返し手で除外している記録がない（GP-6 ルール12）"
  else
    report FAIL G-FALSEPOS "偽陽性を手で除外し続けている＝ゲートが壊れている（運用でカバーではない。FB-10）" \
      "${offenders}  → 走査コマンドを直したら「<ゲート ID> の走査コマンドを是正」と記録すれば本ゲートは解除される"
  fi
}

# --- G-REGRESS: ゲート定義を変えて FAIL→PASS に転じた事実を記録に残す（GP-6 ルール17 / FB-10） ---
# 【塞ぐ穴】ルール12（`G-FALSEPOS`）は**偽陽性**＝拾い過ぎを扱う。**偽陰性**＝拾うべきものを
# 落としている状態は構造的に検出できない（落としたものは出力に現れない）。
# ただし**特殊ケースは機械的に捕まえられる**——「ゲート定義を変えたら、そのゲートの判定が
# FAIL から PASS に転じた」場合は、対象を直したのではなく**ゲートを緩めて通した**疑いがある。
# FB-10 の最悪の点は「ゲートが壊れている事実が記録に残らなかった」ことなので、
# ここで止めたいのは緩和そのものではなく**記録の不在**である。
#
# 【なぜ FAIL→PASS の遷移だけでは鳴らさないか】是正すれば必ず起きる正常な遷移で、
# それを警告にすると正常運用で鳴り続ける（FB-7 と同型＝運用不能なゲートは外される）。
# **gates.sh の指紋が変わっていることが必要条件**である。
# 【なぜ INCOMPLETE か】欠陥（矛盾）ではなく記録の未完なので、書けば解除される（GP-6 ルール14）。
# 【解除条件】`G-FALSEPOS` と同じ語彙で worklog / traceability に理由を書く
# （語彙を分けると「どちらに書けばよいか」が増える。正しい報告を罰しない設計も同じ）。
gate_regression() {
  [ -f "$VERDICTS_TSV" ] || { report SKIP G-REGRESS "gate-verdicts.tsv が無い（初回実行）"; return; }
  # 各ゲートについて「最新」と「その 1 つ前」を取り、FAIL → PASS かつ指紋が変わった組を出す。
  # 【1 パスで完結させる】ゲート ID ごとに grep すると 38 プロセス起動する（macOS ＋ EDR では
  # exec 1 回が 8〜12ms。判定ではなくプロセス起動回数が実時間を作る。教訓 25 と同型）。
  local flipped
  flipped=$(awk -F'\t' 'NR > 1 && $4 != "" {
      g = $4
      prev_v[g] = last_v[g]; prev_s[g] = last_s[g]; prev_d[g] = last_d[g]
      last_v[g] = $5; last_s[g] = $6; last_d[g] = $1 " " $2
    }
    END {
      for (g in last_v)
        if (prev_v[g] == "FAIL" && last_v[g] == "PASS" && prev_s[g] != "" && prev_s[g] != last_s[g])
          print g "\t" prev_d[g] "\t" prev_s[g] "\t" last_d[g] "\t" last_s[g]
    }' "$VERDICTS_TSV" 2>/dev/null || true)
  [ -n "$flipped" ] || { report PASS G-REGRESS "ゲート定義の変更に伴う FAIL→PASS の反転なし（判定履歴 $(awk 'NR>1' "$VERDICTS_TSV" | grep -c . || true) 件）"; return; }

  # 解除条件: 反転したゲート ID について、worklog / traceability に理由の記録があること。
  local files=() f
  for f in "$AUDIT/traceability.md" "$WROOT/worklog/worklog.md"; do
    [ -f "$f" ] && files+=("$f")
  done
  local recorded=""
  if [ "${#files[@]}" -gt 0 ]; then
    # HTML コメント（規約の説明文・記載例）は除く（G-FALSEPOS と同じ理由。新規リポジトリで誤検出する）。
    recorded=$(awk 'FNR==1{c=0} /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
                    /コマンドを是正|走査を修正|ゲートを修正|走査コマンドを直|判定を緩め|ゲート(側)?の欠陥|偽陽性/{print}' "${files[@]}" 2>/dev/null \
              | grep -oE 'G-[A-Z-]+' | sort -u || true)
  fi
  local unrecorded=""
  while IFS=$'\t' read -r g pd ps ld ls; do
    [ -n "${g:-}" ] || continue
    if [ -n "$recorded" ] && echo "$recorded" | grep -qx "$g"; then continue; fi
    unrecorded+="  ${g}: ${pd} は FAIL（gates.sh ${ps}）→ ${ld} は PASS（gates.sh ${ls}）。理由の記録が無い"$'\n'
  done < <(printf '%s\n' "$flipped")

  if [ -z "$unrecorded" ]; then
    report PASS G-REGRESS "ゲート定義の変更に伴う反転はすべて理由が記録済み（FB-10 の「記録に残らない」を塞いだ）"
  else
    report INCOMPLETE G-REGRESS "ゲート定義を変えて FAIL→PASS に転じたが理由が記録されていない（緩和と是正が区別できない。FB-10）" \
      "${unrecorded}  → worklog に「<ゲート ID> の走査コマンドを是正（偽陽性）」等を記録すれば解除される"
  fi
}

# --- G-REPAIR: 是正は再検証するまで完了ではない（GP-28 ルール10 / SB-101 / FB-8） ---
# 実運用の失敗（FB-8）: 同一箇所を 2 度是正し、1 度目の是正が誤っていた
# （「4 箇所」→「15 呼出 / 11 ファイル」→「呼出 13 件 / 9 ファイル ＋ インライン 2 方式」）。
# 1 度目は grep 結果からメソッド**定義**を除かずに数えており「過小 → 過大」に振れただけだった。
# 直接原因は「何を数えたか」を宣言していなかったこと＝**単位を語彙で強制する**。
# 【設計】「再検証したか」は実行履歴なので直接見えない。見えるのは**記録の対応**である:
#   (a) 是正の痕跡があるのに記録表が空 → FAIL（記録せずに是正した）
#   (b) 記録行の単位が語彙外 → FAIL（語彙外は「数えた対象が不明」と同義）
#   (c) 再検証日が日付形式でない → FAIL（TBD・未 で通る存在検査にしない。教訓 15）
gate_repair() {
  local trace="$AUDIT/traceability.md"
  local worklog="$WROOT/worklog/worklog.md"
  [ -f "$trace" ] || { report SKIP G-REPAIR "traceability.md が無い（未生成段階）"; return; }

  # 節の実在を最初に検査する（節を削除すれば通る回避を塞ぐ。教訓 23）。
  grep -qE '^## 3b\.' "$trace" || {
    report FAIL G-REPAIR "是正記録の節（§3b）が無い（節の削除による回避は不可。GP-28 ルール10）"
    return
  }

  # §3b の実体行を取り出す（HTML コメント・見出し・区切り行・記載例プレースホルダを除く）。
  local rows
  rows=$(awk '/^## 3b\./{f=1;next} f&&/^## /{exit}
    /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
    f && /^\|/ && $0 !~ /^\|[- |]*\|$/ && $0 !~ /対象 *\|/ { print }' "$trace" \
    | grep -v '<SPEC-ID' || true)

  # 是正の痕跡（worklog / traceability 本文）。記録表が空なのに痕跡があれば FAIL。
  # 【重要】**HTML コメントを除去してから数える**。本節の説明文自体が「是正」を含むため、
  # 素朴に grep すると**新規リポジトリで必ず FAIL する**（偽陽性）。
  # 記載例・規約の説明を実データと誤認しない（教訓 18 と同型）。
  # 【撤回も是正である（GP-28 ルール11）】語彙に `撤回` / `取り消` を含める。
  # 撤回は**仕様の内容を書き換える操作**なので、記録も再検証も必要なのに、
  # 初版の語彙（是正／訂正／REFUTED）では**撤回だけが素通り**していた
  # （worklog に「ANO-15 を撤回した」と書いて §3b を空にすると PASS した）。
  # 配布前に確認済み: `templates/` の HTML コメント外に上記 3 語は 0 件＝新規リポジトリは PASS のまま。
  local traces=0
  traces=$(for f in "$trace" "$worklog"; do
             [ -f "$f" ] && awk '/<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next } {print}' "$f"
           done 2>/dev/null | grep -oE 'を是正|に訂正|REFUTED|是正した|を撤回|撤回した|を取り消' | wc -l | tr -d ' ')

  if [ -z "$rows" ]; then
    # 「なし」と明記されていれば是正が無い状態として通す（ただし痕跡があれば矛盾）。
    if [ "${traces:-0}" -gt 0 ]; then
      report FAIL G-REPAIR "是正・撤回の痕跡が ${traces} 件あるのに是正記録表が空（記録せずに直した。撤回も是正なので §3b に記録し再検証する。GP-28 ルール10/11 / FB-8）"
    else
      report PASS G-REPAIR "是正記録なし・是正/撤回の痕跡もなし"
    fi
    return
  fi

  local bad_unit="" bad_date="" bad_empty=""
  while IFS= read -r line; do
    local target chg unit cmd rdate rev
    # 【列位置の取り方】走査コマンド列は `grep -E 'A|B'` のようにパイプを含みうる。
    # Markdown の列区切りとして解釈されて列がずれるため、
    # **コマンド列より後ろの列は末尾から数える**（再検証日 = NF-2、逆方向 = NF-1）。
    # コマンド列より手前（対象・原記述・単位）は左から数えて安全。
    # コマンド自身は「非空か」だけを見るので、断片になっても判定は変わらない。
    target=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    chg=$(echo    "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    unit=$(echo   "$line" | awk -F'|' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    cmd=$(echo    "$line" | awk -F'|' '{print $5}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    rdate=$(echo  "$line" | awk -F'|' '{print $(NF-2)}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    rev=$(echo    "$line" | awk -F'|' '{print $(NF-1)}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # 単位は語彙許可リスト。**記載例の「宣言 / 定義 / ...」を全部並べた行は未記入**と見なす
    # （雛形をそのまま残すのが最も簡単な回避になるため）。
    case "$unit" in
      *'/'*)  bad_unit+="  単位が未選択（記載例のまま）: ${target}"$'\n' ;;
      宣言|定義|呼出|参照|実体) ;;
      *) bad_unit+="  単位が語彙外「${unit}」: ${target}（宣言/定義/呼出/参照/実体 のみ）"$'\n' ;;
    esac

    # 再検証日は日付形式そのものを要求する（TBD・未・空で通る存在検査にしない）。
    echo "$rdate" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || bad_date+="  再検証日が日付形式でない「${rdate}」: ${target}（YYYY-MM-DD。是正後の再検証が未実施の疑い）"$'\n'

    # 走査コマンド・逆方向の確認・原記述は非空かつ定型語を拒否する。
    for pair in "走査コマンド:$cmd" "逆方向の確認:$rev" "原記述→是正後:$chg"; do
      local label="${pair%%:*}" val="${pair#*:}"
      if [ -z "$val" ] || echo "$val" | grep -qiE '^[`]?(TBD|未|なし|N/A|unknown|\?+)[`]?$'; then
        bad_empty+="  ${label} が未記入「${val}」: ${target}"$'\n'
      fi
    done
  done <<< "$rows"

  local n; n=$(echo "$rows" | wc -l | tr -d ' ')
  if [ -z "$bad_unit" ] && [ -z "$bad_date" ] && [ -z "$bad_empty" ]; then
    report PASS G-REPAIR "是正記録 ${n} 件すべてに単位・再検証日・走査コマンド・逆方向確認あり（FB-8）"
  else
    report FAIL G-REPAIR "是正が再検証まで完了していない（是正後の記述は新しい主張。GP-28 ルール10 / FB-8）" \
      "${bad_unit}${bad_date}${bad_empty}"
  fi
}

# --- G-QUEUE: session-context の 3 キューが機能しているか（GP-28） ---
# 「dirty なのに Active Investigation が空」＝中断時に何をしていたか復元できない状態を検出する。
gate_queue() {
  local sc="$WROOT/worklog/session-context.md"
  [ -f "$sc" ] || { report FAIL G-QUEUE "session-context.md が存在しない"; return; }
  # 【注意】単なる文字列検索だと、見出しを `###` に降格したり 1 行に潰しても通る
  # （実測でこの回避が成立した）。**`^## <節名>` の見出し行として実在するか**を検査する。
  local missing=""
  for sec in 'Active Investigation' 'Decision Queue' 'Verification Queue'; do
    grep -qE "^## .*${sec}" "$sc" || missing+="  節（^## 見出し）が無い: ${sec}"$'\n'
  done
  if [ -n "$missing" ]; then
    report FAIL G-QUEUE "session-context に引き継ぎキューの節が欠落（節の削除による回避。GP-28）" "$missing"
    return
  fi

  # 【GP-28 が守ろうとしている失敗モードの直接検査】
  # 「code-graph に `分析中` があるのに Active Investigation が空」＝中断時に何をしていたか
  # 復元できない状態。これを検出しないと「着手時に受け皿を開く」が散文ルールのまま残る。
  if [ -f "$CODEGRAPH" ]; then
    # 【注意】`grep -c` はヒット 0 件のとき **exit 1** を返す。`... || echo 0` と書くと
    # 「0」と「0」が連結して `0\n0` になり、数値比較が壊れて**判定に入らなくなる**
    # （実測でこの欠陥により偽陰性になった）。`wc -l` で数えて算術で潰す。
    local in_progress active
    in_progress=$(grep '^| NODE' "$CODEGRAPH" | grep '分析中' | wc -l | tr -d ' ')
    # Active Investigation 節の実体行（「なし」とコメント・見出し・表を除く）
    active=$(awk '/^## .*Active Investigation/{f=1;next} f&&/^## /{exit}
      /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
      f && NF && $0 !~ /^###/ && $0 !~ /^- *なし *$/ && $0 !~ /^\|/ { print }' "$sc" | wc -l | tr -d ' ')
    if [ "${in_progress:-0}" -gt 0 ] && [ "${active:-0}" -eq 0 ]; then
      report FAIL G-QUEUE "code-graph に「分析中」ノードが ${in_progress} 件あるが Active Investigation が空（着手の受け皿が無い。GP-28 ルール1）"
      return
    fi
  fi
  # 未解決の Decision Queue を残したまま完了宣言していないか。
  # 【注意】説明文・見出し行・雛形の選択肢例（「判断待ち / 承認済 / 取り下げ」）を拾わないよう、
  # **表のデータ行のうち第 2 列（判断事項）が埋まっているもの**だけを対象にする
  # （初版は説明文 2 行を誤検出した。GP-6 ルール12: ゲートのコマンド自体を検証する）。
  # 【注意】列番号に依存した判定は**列を空にする/ずらすだけで回避できた**（実測）。
  # 列位置ではなく「**行のどこかに状態語があり、かつ雛形の選択肢列挙でない**」で判定する。
  # 雛形行の見分け方: 選択肢を `/` で並べた説明（例「判断待ち / 承認済 / 取り下げ」）。
  # 【注意】HTML コメント内の記入例も表形式なので、**コメント内を除外**しないと
  # 雛形のまま FAIL する（実測でこの誤検出が起きた）。`c` フラグでコメント区間を飛ばす。
  local pending
  pending=$(awk '/^## .*Decision Queue/{f=1;next} f&&/^## /{exit}
    /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
    f && /^\|/ && /判断待ち/ {
      if ($0 ~ /判断待ち *\/|\/ *判断待ち/) next   # 選択肢の列挙＝雛形
      if ($0 ~ /^\|[- |]*\|$/) next                # 区切り行
      print "  " $0
    }' "$sc" || true)
  if [ -n "$pending" ]; then
    # 【行を外して通させない】宣言の判断待ち（HOLD-6）だけが残るのは、人に諮っている間の正しい状態である。
    # 実運用で、AI が判断待ちの行を一時的に外して phase4 を通し、後で戻した（exit 0 が「判断が済んだ」を意味しなくなる）。
    # 判定文で「そのまま諮る」ことを示す（手順書 Phase 4 完了条件の注記が正本）。
    report INCOMPLETE G-QUEUE "判断待ちの Decision Queue が残っている（HOLD の未解決。GP-106）。宣言の判断待ちならこの状態のまま人に諮る——行を外して phase4 を通さない" "$pending"
    return
  fi
  # 未検証の Verification Queue を残したまま完了宣言していないか（同じ方式）
  local unverified
  unverified=$(awk '/^## .*Verification Queue/{f=1;next} f&&/^## /{exit}
    /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
    f && /^\|/ && /未検証/ {
      if ($0 ~ /未検証 *\/|\/ *未検証/) next
      if ($0 ~ /^\|[- |]*\|$/) next
      print "  " $0
    }' "$sc" || true)
  if [ -n "$unverified" ]; then
    report INCOMPLETE G-QUEUE "未検証項目が Verification Queue に残っている（GP-28）" "$unverified"
  else
    report PASS G-QUEUE "引き継ぎキュー（3 種）が存在し、判断待ち・未検証が残っていない"
  fi
}

# --- G-NO-DUP-STATE: 進捗状態の複製禁止（GP-101） ---
# 同じ進捗が複数箇所にあると必ず乖離し、「どちらを信じるか」を AI が判断する余地が生まれる
# （SB-14 の記録鮮度の失敗と同型）。**正本を決めるだけでは足りず、正本以外に書けないようにする**
# （密度台帳を TSV 正本にした Phase C と同じ思想）。
gate_no_dup_state() {
  local sc="$WROOT/worklog/session-context.md"
  [ -f "$sc" ] || { report FAIL G-NO-DUP-STATE "session-context.md が存在しない"; return; }
  local dup=""
  # (1) ノードレジストリ行の複製（| NODE-... で始まる表）
  local node_rows
  node_rows=$(grep -nE '^\| *NODE-[A-Z]+-[0-9]+' "$sc" | grep -v '<!--' || true)
  [ -n "$node_rows" ] && dup+="$(echo "$node_rows" | sed 's/^/  ノード行の複製: /')"$'\n'
  # (2) 状態アイコン付きのノード/spec 一覧（旧 Current Status 形式）
  local icon_rows
  icon_rows=$(grep -nE '^- *(✅|🔄|⏸️|🚫).*(NODE-|SPEC-)' "$sc" | grep -v '<!--' || true)
  [ -n "$icon_rows" ] && dup+="$(echo "$icon_rows" | sed 's/^/  状態一覧の複製: /')"$'\n'
  if [ -n "$dup" ]; then
    report FAIL G-NO-DUP-STATE "session-context に進捗状態が複製されている（正本は code-graph / work-plan。GP-101）" "$dup"
  else
    report PASS G-NO-DUP-STATE "session-context に進捗状態の複製がない（正本を参照している）"
  fi
}

# --- G-SESSION-POINTER: Current Position のポインタが正本に実在するか（GP-101） ---
# ポインタ方式は「指す先が実在する」ことが前提。リンク閉包を状態にも適用する。
gate_session_pointer() {
  local sc="$WROOT/worklog/session-context.md"
  [ -f "$sc" ] || { report FAIL G-SESSION-POINTER "session-context.md が存在しない"; return; }
  local pos unresolved=""
  pos=$(awk '/^## Current Position/{f=1;next} f&&/^## /{exit}
    /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
    f && NF { print }' "$sc")
  if [ -z "$pos" ]; then
    report FAIL G-SESSION-POINTER "Current Position が空（いまどこにいるかを書く。GP-101）"
    return
  fi
  # WP-ID が work-plan に実在するか（プレースホルダ <WP-ID> は未着手として許容）
  while IFS= read -r wp; do
    [ -f "$WORKPLAN" ] || continue
    grep -qE "^\| *${wp} " "$WORKPLAN" 2>/dev/null || unresolved+="  ${wp} が work-plan.md (A) に無い"$'\n'
  # 【`\b` は POSIX ERE で表現できない（2026-09-25 実測）】外すと `XWP-99` から `WP-99` を
  # 誤抽出して**偽の未解決**を報告する（実測で確認）。`(^|[^A-Za-z0-9_])` で代替すると
  # `-o` が先行文字まで取るので剥がす処理が要り、失敗面が増える。⇒ `\b` を使う。
  # この BSD grep（2.6.0-FreeBSD）では正常動作することを実測済み。
  done < <(echo "$pos" | grep -oE '\bWP-[A-Za-z0-9-]+' | grep -v '^WP-ID$' | sort -u)   # gnuesc:ignore \b は POSIX 非対応・外すと誤抽出
  # NODE-ID が code-graph に実在するか
  while IFS= read -r nd; do
    [ -f "$CODEGRAPH" ] || continue
    grep -qE "^\| *${nd} " "$CODEGRAPH" 2>/dev/null || unresolved+="  ${nd} が code-graph.md に無い"$'\n'
  done < <(echo "$pos" | grep -oE '\bNODE-[A-Z]+-[0-9]+' | sort -u)   # gnuesc:ignore \b は POSIX 非対応・外すと誤抽出（上の注記参照）
  if [ -z "$unresolved" ]; then
    report PASS G-SESSION-POINTER "Current Position のポインタが正本に解決する"
  else
    report FAIL G-SESSION-POINTER "Current Position が実在しない項目を指している（状態のリンク閉包。GP-101）" "$unresolved"
  fi
}

gate_unfilled() {
  local hits
  # 【小文字の山括弧は XML 要素名と区別できない】`<[a-z_]+>` にしていたため、
  # 本文に `<action>` `<result>` `<module>` と書くと**未記入プレースホルダとして誤爆**した
  # （実走検証の実測。記述側で山括弧を外して回避せざるを得なかった）。
  # 【実測で決めた 3 枝】雛形のプレースホルダ 165 種を数えたところ**日本語を含むものが 120 種**で、
  # 大文字のみは 4 種しかない。「大文字を要求する」形は実態と合わない。
  #   (1) 大文字プレースホルダ `<PLACEHOLDER>` `<N>`
  #   (2) **非 ASCII を含む** `<解析断面のコミット>`（`[^ -~]` は POSIX の範囲指定で BSD でも動く。
  #       `[^\x00-\x7F]` は **GNU 拡張で BSD grep では機能しない**——実測で 0 件だった）
  #   (3) **XML 要素名にあり得ない文字**（空白・コロン・スラッシュ・等号・パーセント）を含む
  #       `<path:line>` `<M 件 / N 件 = X%>`
  # `<action>` `<result>` `<module>`（英数字のみ）はどの枝にも一致しない。
  # 【引用されたマークアップを誤爆から外す（2026-09-16。実データで測って決めた）】
  # 上の 3 枝は「監査文書の本文に XML/JSP を引用するのは稀」という前提で作ったが、
  # **`observed-anomalies.md` / `traceability.md` は設計上ソースを引用する文書**である。
  # 実測（完走した参照成果物）: 54 件のうち**閉じタグと属性つきタグが 27 件**を占め、
  # それらは**証跡を書き換えるしか回避手段がない＝誰も直せない未達**だった。
  # ⇒ **「マークアップにしかない形」だけを除く**: (a) 閉じタグ `</…>`
  #    (b) 属性を持つ `<x name="…">` (c) 自己閉じ `<x/>`。
  # 【要素名の形では除かない】`<path:line>` は**この framework 標準のプレースホルダ**であり、
  # `<s:submit>` と同じ「小文字:小文字」の形をしている。要素名の形で除くと**本物が落ちる**
  # （実測で `<path:line>` が検出されなくなった。偽陰性を作る是正だった）。
  # 実測（完走した参照成果物の `03-audit/*.md`。`gate-results.md` は除く）: **55 件 → 11 件**。
  # 落ちた 44 件は全部誤爆で、内訳は**引用マークアップ 25 件**（閉じタグ・属性つき 24 ＋ 自己閉じ 1）と
  # **バッククォート内のコード表記 19 件**（散文の中で `<` と `>` が離れて一致していたもの）。
  # 残った 11 件はすべて**真の未記入**（`<ADR-N>` `<behavior 軸>` `<data 仕様にする場合のリンク>` 等）。
  # プレースホルダ 5 形（大文字・日本語・`path:line`・`M 件 / N 件 = X%`・未チェック `[ ]`）は全部残る（両方向を確認）。
  # 【行を落とさず、引用部分だけを外す】除外を行単位にすると、**1 行の中に未記入と引用が混在**したとき
  # （Markdown 表は 1 行 = 1 行分の複数セル）**本物のプレースホルダが見えなくなる**。
  # 【バッククォート span を丸ごと消してはいけない】一度そう実装したところ、
  # **プレースホルダを 1 件も埋めずにバッククォートで囲むだけで 82 件 → 2 件**にできた（実測）
  # ——`G-LEDGER` が名指しで禁じている「検査対象を壊すのが最も簡単な全通過方法」である。
  # ⇒ **バッククォートは文字として剥がし、span の中身は残す**。マークアップだけを形で除く:
  #   (a) 閉じタグ `</…>` (b) 属性つき `<x name="…">` (c) 自己閉じ `<x/>`
  #   (d) **小文字始まりの要素名** `<action>` `<filter-mapping>`
  #   (e) **名前空間つき要素名。ただし接頭辞は 1〜2 文字に限る** `<s:submit>` `<fn:length>`
  #       ——`<path:line>` は**この framework 標準のプレースホルダ**で同じ「小文字:小文字」の形なので、
  #       接頭辞の長さで分ける（4 文字の `path:` は残す）。完全な両立解は無く、これが実測で最良だった。
  # 実測（完走した参照成果物の `03-audit/*.md`。`gate-results.md` は除く）:
  #   旧実装（span 丸ごと除去）11 件 / **バッククォートで囲むだけの回避版 8 件**（回避できた）
  #   現実装 **24 件** / 回避版も **24 件**（**回避が閉じる**）。増えた 13 件はすべて
  #   バッククォート内に書かれた真の未記入（`<ADR-N>` `<縦串>` 等）で、残る誤爆は 2 件
  #   （`<他人のhandle>` の URL 雛形と `<s:if test=…>`）。判定は INCOMPLETE のまま変わらない。
  # 【`grep -a` を付ける】NUL バイトが 1 個でもあると `grep` がバイナリ扱いして
  # **ファイル丸ごと検査対象から消える**（fail-open）。
  # 【動的確認 TODO の未チェックは正常（配布テンプレが用意した欄を叱らない）】
  # `observed-anomalies.md` の `## 動的確認 TODO（SB-6）` は**静的読解では断定できず、
  # 実際に動かして観測すべき項目**の置き場所で、雛形自身が「再構築/保守着手時に確認する」と書いている。
  # ⇒ **仕様生成の完了時点で未チェックであることが正常**なのに、`[ ]` を未記入と数えていた。
  # 実測: 参照成果物 3 本すべてが未チェック箱 0 件——**表に書き換えるなどして回避していた**
  # （テンプレが用意した形を使えない＝配布物とゲートの食い違い）。
  # **記入自体は要求する**: 中身が未記入（`<...>` が残る）行は従来どおり落とす。
  # 【HTML コメントを先に剥がす（2026-10-01）】`grep -v '<!--'` は開始行しか落とさないので、
  #  複数行コメントの続きの行（説明のための `- [ ]` を含む）が未記入に数えられ、**配布した雛形のままでも PASS できなかった**
  #  （observed-anomalies の雛形で再現）。行数は保つので行番号は原文のまま。
  # 【複数行コメントの開始は行頭の `<!--` だけ】行の途中の `<!--`（コード表記で引用した `grep '<!--.*'` など）を
  #  開始と見なすと、次の `-->` までの数百行が丸ごと検査から消えた（反証レビューで実測: 852 行。fail-open）。
  #  1 行の中で閉じるコメントは行内から除く。
  local _tf
  hits=$(for _tf in "$AUDIT"/*.md; do
           [ -f "$_tf" ] || continue
           # （bash 3.2 はコマンド置換の中の case の `)` を置換の終わりと読むので if で書く）
           if printf '%s' "$_tf" | grep -q 'gate-results'; then continue; fi
           LC_ALL=C awk -v F="$_tf" '
             { line = $0
               # コードフェンスの中の `<!--` はコメントの開始と見なさない（フェンスの中身は従来どおり検査する）
               if (line ~ /^[ \t]*(```|~~~)/ && !inc) { fence = !fence; print F ":" NR ":" line; next }
               if (fence) { print F ":" NR ":" line; next }
               if (inc) { if (index(line, "-->") > 0) { inc = 0; line = substr(line, index(line, "-->") + 3) } else line = "" }
               else if (line ~ /^[ \t]*<!--/ && index(line, "-->") == 0) { inc = 1; line = "" }
               else if (line ~ /^[ \t]*<!--.*-->[ \t]*$/) line = ""
               # 行の途中の `<!--` はその行だけを外す（従来と同じ扱い。コード表記で引用した `<!--.*?-->` を
               #  コメントとして剥がすと残りの断片がプレースホルダに見えた）。続く行には波及させない。
               else if (index(line, "<!--") > 0) line = ""
               print F ":" NR ":" line }' "$_tf"
         done 2>/dev/null \
         | LC_ALL=C awk -v ADRS=" $(live_adr_numbers | tr '\n' ' ') " '
             {
               line = $0
               # 【Windows のドライブ文字を許す（2026-11-07）】Git for Windows の `git rev-parse --show-toplevel` は `D:/…` を返す。
               #  `^[^:]*:` だとドライブの `:` で止まって行番号に届かず、全行が免除の判定（動的確認 TODO・`⚠️ 未達:` など）を
               #  素通りして未記入に数えられた（Windows の完走試験で実測: 本来除外される 13 行で FAIL）。
               if (!match(line, /^([A-Za-z]:)?[^:]*:[0-9]+:/)) { print; next }
               head = substr(line, 1, RSTART + RLENGTH - 1)
               body = substr(line, RSTART + RLENGTH)
               fn = head; sub(/:[0-9]+:$/, "", fn)
               if (fn != prevf) { insec = 0; prevf = fn }
               # 【見出しは `#` ＋ 空白に限る】`^#/` だけで見ると、引用したシェルコメントや
               # コード行（`# comment`）でも節が切れ、以降の記入済み箱が再び叱られる（診断困難な偽陽性）。
               if (body ~ /^#{1,6}[ \t]/) insec = (body ~ /動的確認 TODO/)
               # 節の中で、かつ中身が記入済み（山括弧が残っていない）未チェック箱だけ外す。
               # 【ファイル名は完全一致で見る】`/observed-anomalies\.md$/` だけだと
               # `foo-observed-anomalies.md` も免除対象になる（前方が開いている）。
               # 【箇条書き記号は `-` `*` `+` を許す】Markdown で合法な `* [ ]` を叱ると
               # **叱られた理由が利用者に分からない**（`-` だけを許す根拠は無い）。
               # 【免除の判定はプレースホルダの形で見る】`<[^<>]*>` で見ていたため、引用した `<result>` を含む行だけ
               #  免除が外れた（マークアップの除去はこの後段なので、ここでは本物のプレースホルダの 3 枝だけを見る）。
               if (insec && fn ~ /(^|\/)observed-anomalies\.md$/ \
                   && body ~ /^[ \t]*[-*+][ \t]*\[ \]/ \
                   && body !~ /<[A-Z_][A-Z0-9_]*>|<[^<>]*[^ -~][^<>]*>|<[A-Za-z][^<>]*[ :\/=%][^<>]*>/) next
               # 【満たしていない項目を正直に残す形（条件付きの完了。2026-10-01）】未チェックの箱でも、
               #  `⚠️ 未達: <理由>（ADR-N）` の形で理由と ADR を書いた行は未記入ではない（完了宣言の条件に並べる）。
               #  理由だけ・ADR だけでは免除しない。
               #  理由がプレースホルダのまま・理由が空・ADR が decisions.md に実在しない、のいずれかなら免除しない。
               if (body ~ /^[ \t]*[-*+][ \t]*\[ \]/ && match(body, /未達(:|：)/)) {
                 why = substr(body, RSTART + RLENGTH)
                 adr = ""; if (match(why, /ADR-[0-9]+/)) { adr = substr(why, RSTART, RLENGTH); why = substr(why, 1, RSTART - 1) }
                 # 【多バイトは選択で除く】`[（）、。]` は C ロケールでバイト集合になり、ひらがなのバイトまで削った（反証レビューで実測）
                 gsub(/ |\t|（|\(|）|\)|、|。|\*|：|:/, "", why)
                 # 中身の無い理由は免除しない（バイト数で 6 以上＝全角 2 文字以上、かつ定型の空語でない）
                 empty = (why == "なし" || why == "未定" || why == "後で" || why == "TBD" || why == "TODO" || why ~ /^[-—.…?？；;]+$/)
                 if (adr != "" && index(ADRS, " " adr " ") > 0 && length(why) >= 6 && !empty \
                     && body !~ /<[A-Z_][A-Z0-9_]*>|<[^<>]*[^ -~][^<>]*>|<[A-Za-z][^<>]*[ :\/=%][^<>]*>/) next
               }
               # 【箱を書き換えて逃げる経路を塞ぐ】`[ ]` を ✗・× に書き換えると未チェックが見えなくなった（完走試験で実測）。
               #  対象はチェックリストを持つ 2 文書に限る（他の文書の `- ✗ …` は記録として正当）。
               #  ✗ は多バイトなので角括弧の文字集合でなく選択（`|`）で書く（C ロケールでは集合がバイト単位になる）。
               if (fn ~ /(^|\/)(rebuild-readiness|traceability)\.md$/ \
                   && body ~ /^[ \t]*[-*+][ \t]*(✗|×|❌|\[(✗|×|-)\])/) { print line "  ← チェック欄を書き換えている（[ ] のまま残し、満たさないなら ⚠️ 未達: 理由（ADR-N）を書く）"; next }
               print
             }' \
         | strip_quoted_markup \
         | LC_ALL=C grep -E '<[A-Z_][A-Z0-9_]*>|<[^<>]*[^ -~][^<>]*>|<[^<>]*[ :/=%][^<>]*>|:[0-9]+:\| N \||\[ \]' \
         | grep -v '<!--' || true)
  if [ -z "$hits" ]; then
    report PASS G-TEMPLATE "監査文書に未記入プレースホルダ・未チェック [ ] が残っていない"
  else
    report INCOMPLETE G-TEMPLATE "監査文書に未記入・未チェックが残存（$(echo "$hits" | wc -l | tr -d ' ') 件）" "$hits"
  fi
}

# --- G-VIEW: 統合俯瞰ビューの実体図（GP-14 ルール6 / FB-3） ---
gate_integrated_view() {
  # 能力別分割の判定: specs/rebuild/ に複製実体（テンプレ以外の仕様）が 2 つ以上あるとき必須
  local rebuild_count
  rebuild_count=$(find "$SPECS/rebuild" -name '*.md' -not -name '_*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$rebuild_count" -lt 2 ]; then
    report SKIP G-VIEW "能力別分割なし（rebuild 実体 ${rebuild_count} 件）のため統合俯瞰ビュー検査をスキップ"
    return
  fi
  # 統合ビュー文書の探索: gate-config 指定 > usage-operations.md > rebuild/README.md > overview.md
  # 【`[ -f ]` で直に見ない】大小を区別するファイルシステムでは `readme.md` を見つけられず、
  # **同じ成果物が OS によって別の文書を統合ビューと見なす**（`resolve_ci_all` の説明を参照）。
  local view_doc="" _vc
  for cand in "${INTEGRATED_VIEW_DOC:-}" "$SPECS/usage-operations.md" "$SPECS/rebuild/README.md" "$SPECS/overview.md"; do
    [ -n "$cand" ] || continue
    # 【相対パスは REPO_ROOT 基準にする】`G-REBUILD` の除外側は `REPO_ROOT` を前置していたのに
    # ここだけカレントディレクトリ相対で、**同じ設定値が 2 つのゲートで別のファイルを指しえた**
    # （`gates.sh` は `REPO_ROOT` へ `cd` しない。変更前から存在した非対称）。
    case "$cand" in /*) ;; *) cand="$REPO_ROOT/$cand" ;; esac
    # 【`| head` を使わない】`set -uo pipefail` の下では head が先に抜けて上流が SIGPIPE で 141 になる。
    # ここは値だけを使うので実害は無いが、同じ書き方が判定式に回ると条件が反転する（教訓 61）。
    _vc=$(resolve_ci_all "$cand" | LC_ALL=C sed -n '1p')
    [ -n "$_vc" ] && { view_doc="$_vc"; break; }
  done
  [ -z "$view_doc" ] && { report FAIL G-VIEW "統合俯瞰ビュー文書が見つからない"; return; }
  local mermaid_count er_entities data_count
  mermaid_count=$(grep -c '```mermaid' "$view_doc" || true)
  if [ "$mermaid_count" -lt 3 ]; then
    report FAIL G-VIEW "統合ビュー（${view_doc#"$REPO_ROOT"/}）の mermaid 図が ${mermaid_count} 個 < 3（統合 ER・全画面遷移・能力依存グラフ）"
    return
  fi
  # 統合 ER のエンティティ数 ≥ specs/data/* 総数（部分 ER 誤認の防止）
  data_count=$(find "$SPECS/data" -name '*.md' -not -name '_*' 2>/dev/null | wc -l | tr -d ' ')
  er_entities=$(awk '/```mermaid/,/```$/' "$view_doc" | awk '/erDiagram/,0' \
                | grep -cE '^[[:space:]]+[A-Za-z_"][A-Za-z0-9_"-]*[[:space:]]*(\{|\|)' || true)
  # 【対象の不在を合格にしない（教訓 23）】`data_count=0` のとき初版は
  # `0 >= 0` が成立して **PASS** になり、**統合 ER を 1 枚も描いていなくても通った**
  # （実運用で観測。2026-09-03）。突合の分母が無い状態は「合格」ではなく「未完了」である。
  if [ "$data_count" -eq 0 ] && [ "$er_entities" -eq 0 ]; then
    report INCOMPLETE G-VIEW "統合 ER のエンティティが 0 件かつ specs/data/* も 0 件（突合の分母が無い＝ER 未作成の可能性。data 層を書くか、ER を実体で描く）"
  elif [ "$data_count" -gt 0 ] && [ "$er_entities" -lt "$data_count" ]; then
    report FAIL G-VIEW "統合 ER のエンティティ数（${er_entities}）< specs/data/* 総数（${data_count}）＝部分 ER の疑い"
  else
    report PASS G-VIEW "統合俯瞰ビューが実体図を持つ（mermaid ${mermaid_count} 図・ER エンティティ ${er_entities} ≥ data ${data_count}）"
  fi
}

# --- G-TRACKER: 進捗表の鮮度（SB-14。roadmap 使用時のみ） ---
gate_tracker() {
  # 【未記入の雛形と「非該当」を区別する（2026-09-22）】`| L0` 行の有無だけで判定していたため、
  # **能力 1 つで roadmap が非該当なのに未記入で残すと「進捗の更新漏れ」と読まれ**、
  # 実運用では `| L0` 行を消して回避していた（＝雛形を壊して通す経路）。
  # `GP-19` ルール5「該当性判断を二値にしない」と同型の問題がゲート側にあった。
  # ⇒ **理由つきの非該当宣言**を書ければ SKIP する。理由が無い／未記入なら未達にする
  #   （宣言だけで通ると「分からない」を「やらない」に落とす経路になる）。
  if [ -f "$ROADMAP" ] && LC_ALL=C grep -q '^roadmap-applicability:' "$ROADMAP" 2>/dev/null; then
    local ra why
    ra=$(LC_ALL=C grep -m1 '^roadmap-applicability:' "$ROADMAP" \
         | LC_ALL=C sed 's/^roadmap-applicability:[[:space:]]*//' \
         | LC_ALL=C sed 's/[[:space:]]*$//' | LC_ALL=C tr -d '\r')
    case "$ra" in
      非該当*|not-applicable*)
        # 【区切りを括弧に限定しない】全角括弧だけを見た初版は、`非該当: 理由` `非該当 — 理由`
        # `not-applicable: reason` を**理由ありなのに未達**にした（紙上検証で 3 形）。
        # 語の直後から**任意の区切り以降**を理由とみなす。
        why=$(printf '%s' "$ra" | LC_ALL=C sed -e 's/^非該当//' -e 's/^not-applicable//' \
                | LC_ALL=C sed -e 's/^[[:space:]]*[（(：:—ー-]*[[:space:]]*//' \
                              -e 's/[[:space:]]*[）)]*[[:space:]]*$//')
        # 【空の括弧を通さない】`[ -z "$ra" ]` を見た初版は **case に一致した時点で常に偽**の
        # デッドコードで、`非該当（）` `非該当（ ）` が理由なしで SKIP した（紙上検証）。
        # 判定すべきは `why` の空・空白のみ・雛形である。
        if [ -z "$why" ] || ! printf '%s' "$why" | LC_ALL=C grep -q '[^[:space:]]'; then
          report INCOMPLETE G-TRACKER "roadmap を非該当と宣言しているが理由が書かれていない（「非該当（ADR-N: <理由>）」の形で書く）" \
            "  roadmap-applicability: ${ra}"
        elif printf '%s' "$why" | grep -q '<[^<>]*>'; then
          report INCOMPLETE G-TRACKER "roadmap の非該当宣言の理由が未記入（雛形のまま）" \
            "  roadmap-applicability: ${ra}"
        elif ! printf '%s' "$why" | LC_ALL=C grep -qE 'ADR-[0-9]+'; then
          # 【ADR を要求する】適用可否は Phase 0 の判断で、雛形自身が「ADR に残す」と書いている。
          # ゲート側で自由記述の理由だけを受けると**同じ判断を 2 箇所で持つ**（GP-101 が禁じる型）。
          # `G-DENOM` が「スコープ縮小があれば対応 ADR の実在を確認」しているのと揃える。
          report INCOMPLETE G-TRACKER "roadmap の非該当宣言に ADR 参照が無い（適用可否は Phase 0 の判断なので ADR-N を書く。GP-101）" \
            "  roadmap-applicability: ${ra}"
        else
          report SKIP G-TRACKER "roadmap は非該当と宣言済み（理由: ${why}）"
        fi
        return ;;
      *)
        # 【語彙外を黙って落とさない】`N/A` `不要` `no` のような値は後段にフォールスルーして
        # **何も報告されなかった**。`G-VERIFY-VOCAB` が「語彙外は読めば分かるものではない」として
        # 落としているのと揃える。
        report INCOMPLETE G-TRACKER "roadmap-applicability の値が語彙外（非該当 / not-applicable のいずれかで書く）" \
          "  roadmap-applicability: ${ra}"
        return ;;
    esac
  fi
  if [ ! -f "$ROADMAP" ] || ! grep -q '^| L0' "$ROADMAP" 2>/dev/null; then
    report SKIP G-TRACKER "roadmap 未使用（小規模）のため進捗表鮮度の検査をスキップ"
    return
  fi
  local hits
  # 【チェックリストの行は数えない（2026-09-28。完走試験で実測）】雛形の完了チェックリストに
  # 「§4 割当表・§6 トラッカーに「未着手／未」が残っていない」という**この検査自身を説明する項目**があり、
  # 全行を `未着手` で探すと**その文面に一致して永久に未達**になった（`[x]` を付けても消えない。
  # 消すには監査記録を書き換えるしかない）。見るべきは割当表・トラッカーの**状態**なので、
  # 箇条書きのチェックボックス行（`- [ ]` / `* [x]` / `+ [ ]` / `1. [ ]`、空白なしの `-[ ]` も）を除外する。
  hits=$(grep -n '未着手\|未$' "$ROADMAP" | grep -v '<!--' \
         | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*\[[ xX]\]' || true)
  if [ -z "$hits" ]; then
    report PASS G-TRACKER "roadmap の割当表・トラッカーに「未」が残っていない"
  else
    report INCOMPLETE G-TRACKER "roadmap に「未」が残存（各縦串完了時の状態更新漏れの疑い）" "$hits"
  fi
}

# --- G-SYMMETRY: カテゴリ網羅の対称性（SB-15） ---
gate_category_symmetry() {
  local dist
  dist=$(spec_files | nul_pack | xargs -0 -r grep -h '^category: ' 2>/dev/null | sort | uniq -c | sort -rn || true)
  [ -z "$dist" ] && { report SKIP G-SYMMETRY "仕様ファイル未生成のためスキップ"; return; }
  # 1 件だけのカテゴリ（overview 除く）をフラグ（機械判定は警告まで。方針 ADR との照合は人手）
  local lonely
  # `index` は機械生成の索引カテゴリで**1 件が正常**（増えることを期待しない）。
  # 除かないとフレームワーク自身の生成物が毎回同じ偽陽性を出す（FB-10 / G-FALSEPOS の対象）。
  lonely=$(echo "$dist" | awk '$1 == 1 && $3 != "overview" && $3 != "index" {print $3}' | grep -v '^$' || true)
  # 【0 は非対称にならない（2026-09-24 追加。SB-15 ルール4）】
  # `dist` は**存在するファイルの `category:`** から作るので、**0 件のカテゴリは行が立たない**
  # ——全カテゴリが揃って 0 でも「対称」と見て通る（1 つだけ空なら `$1 == 1` で拾えた）。
  # 実運用の被害: 空カテゴリを作った後に密度ゲートの分母が 14 → 102 件に増え、
  # **そこで初めて 28 件の必須節欠落が露出した**（分母が成果物の存在に依存していた）。
  # 【逃げ道は「作らない」の宣言に限る】`grep -c "specs/api/"` のような緩い形は
  # **構造の説明で偶然満たされる**（実測: 完走した参照成果物の decisions.md に `specs/api/` が 2 件あった）。
  # **カテゴリ名と「作らない/非該当」が同じ行にある**ことを要求する（実測で偽の通過 0 件）。
  # 【完了ゲートでのみ走る】この関数は Phase 4 の完了ゲートにしか登録していない
  # ——縦串の途中でカテゴリが空なのは正常なので、途中の段で発火させてはいけない。
  local empty="" _c _cn
  for _c in modules api data behavior rebuild; do
    [ -d "$SPECS/$_c" ] || continue
    _cn=$(find "$SPECS/$_c" -maxdepth 1 -type f -name '*.md' -not -name '_*' 2>/dev/null | grep -c . || true)
    [ "${_cn:-0}" -gt 0 ] && continue
    # `rebuild` は `REBUILD_LAYER=off`（purpose=maintenance）なら空が正常
    if [ "$_c" = "rebuild" ] && [ "$REBUILD_LAYER" = "off" ]; then continue; fi
    if grep -E "(specs/)?${_c}(/|[^a-z])" "$DECISIONS" 2>/dev/null | grep -qE '非該当|該当しない|作らない|不要|対象外'; then continue; fi
    empty="${empty}  specs/${_c}/ が空（実仕様 0 件）で、作らないと決めた ADR も無い"$'\n'
  done
  unset _c _cn
  # 【1 回の report にまとめる】別々に出すと後の判定が前の early return に隠れる
  if [ -n "$empty" ]; then
    report INCOMPLETE G-SYMMETRY "空のカテゴリがある（$(printf '%s' "$empty" | grep -c .) 件。0 件は分布に現れないので「対称」と誤判定される。SB-15 ルール4）" \
      "${empty}対処は 2 つ。(1) そのカテゴリの仕様を作る。(2) 作らないなら **decisions.md にカテゴリ名と「作らない」を同じ行で**書く
（SB-15 ルール1 の「どのカテゴリを作るかを Phase 0 で全ドメイン共通の方針として決める」の実行物）。
**空のまま完了を宣言しないこと**——密度ゲートの分母は存在する成果物から作るので、空カテゴリの中身は 1 件も検査されない。$(echo; echo "$dist")"
  elif [ -z "$lonely" ]; then
    report PASS G-SYMMETRY "カテゴリ分布に 1 件だけの突出/欠落がなく、空のカテゴリも無い" "$dist"
  else
    report WARN G-SYMMETRY "1 件だけのカテゴリあり（Phase 0 のカテゴリ方針 ADR と照合すること）" "$(echo "$dist"; echo "→ 要確認: $lonely")"
  fi
}

# --- G-ARTIFACT: 成果物形態の存在（GP-19 / SB-16。artifact-key 方式） ---
gate_artifact_form() {
  local unmet=""
  local found_templates=0 skipped_templates=0
  # 【除外の極性は「緩める値のときだけ緩める」】`!= "full"` と書くと、綴り違い・空値でも
  # 本質層の要求が黙って消える（fail-open）。冒頭の既定値宣言が「未設定は最も厳しい側に
  # 倒す」と決めているのと同じ理由で、**緩める値を列挙**する（`capability_specs` と同じ形）。
  # 不正値は `full` 扱い（要求する側）に倒し、事実を記録に残す。
  # 値の妥当性は入口で検証済み（off / skeleton / full のいずれか）。
  local rl_excluded=""
  case "$REBUILD_LAYER" in off|skeleton) rl_excluded="yes" ;; esac
  local _kind
  while IFS=$'\t' read -r _kind t; do
    if [ "$_kind" = "SKIPPED" ]; then skipped_templates=$((skipped_templates + 1)); continue; fi
    [ -e "$t" ] || continue
    found_templates=$((found_templates + 1))
    local key
    key=$(grep -o 'artifact-key: [a-z0-9-]*' "$t" | head -1 | sed 's/artifact-key: //')
    if [ -z "$key" ]; then
      unmet+="artifact-key 未記載: ${t#"$REPO_ROOT"/}（テンプレ先頭に <!-- artifact-key: ... --> が必要）"$'\n'
      continue
    fi
    # (a) 複製実体: artifact-key を持ちかつ spec-id が実 ID のファイル ≥1
    local dup
    dup=$(grep -rlE "$(artifact_key_re "$key")" "$SPECS" 2>/dev/null | grep -v '/_[^/]*$' \
          | nul_pack | xargs -0 -r grep -l '^spec-id: ' 2>/dev/null | nul_pack | xargs -0 -r grep -L 'TEMPLATE-DO-NOT-INDEX' 2>/dev/null | head -1 || true)
    # (b) 非該当 ADR: decisions.md に artifact-key への言及
    local adr
    adr=$(grep -c "${key}" "$DECISIONS" 2>/dev/null)
    adr="${adr:-0}"
    if [ -z "$dup" ] && [ "$adr" -eq 0 ]; then
      unmet+="未達: ${t#"$REPO_ROOT"/}（key=${key}: 複製実体 0・非該当 ADR 無し）"$'\n'
    fi
  done < <(find "$SPECS" -name '_*-template.md' 2>/dev/null \
            | while IFS= read -r _t; do
                # 【`REBUILD_LAYER` で本質層の成果物形態を条件化する（2026-09-13。`capability_specs` と同じ配線）】
                # `specs/rebuild/` の雛形は**本質層を作る設定のときだけ**対象にする。
                # 【量】現行の雛形はすべて `specs/rebuild/` 配下にあるので、`off` / `skeleton` では
                # **対象 0 件＝このゲートは常に PASS になる**（`SB-16` の機械的強制がその 2 つの
                # `purpose` では無くなる）。「一部の形態だけ外れる」ではない。
                # 実測: `REBUILD_LAYER=off`（`purpose=maintenance`）でも 5 形態
                # （capability-spec / screen-map / report-spec / job-spec / nonfunctional）を要求しており、
                # **設定が「作らない」と決めたものをゲートが要求していた**——`REBUILD_LAYER` を
                # 見ないゲートで 4 度目の同型再発。
                # 逃げ道（非該当 ADR）はあるが、**設定値が既に答えている形態に ADR を書かせるのは筋が通らない**。
                # `skeleton`（`evaluation`）も要求しない: 「骨子が十分か」の機械判定基準が定義されていない
                # ——定義のないものをゲート化すると、また「誰も直せない未達」を作る
                # （解除条件が書けないゲートは作らない）。
                if [ "${_t#"$SPECS"/rebuild/}" != "$_t" ] && [ -n "$rl_excluded" ]; then
                  printf 'SKIPPED\t%s\n' "$_t"; continue
                fi
                printf 'CHECK\t%s\n' "$_t"
              done)
  # 【「設定で対象外」と「雛形が無い」を区別する】除外の結果 0 件になったときに `SKIP` を返すと
  # **判定履歴（gate-verdicts.tsv）に残らず**（`report` は SKIP を履歴に入れない）、
  # 「測っていない」と「設定どおり対象が無い」が区別できなくなる。後者は `PASS` で記録する。
  if [ "$found_templates" -eq 0 ] && [ "${skipped_templates:-0}" -gt 0 ]; then
    report PASS G-ARTIFACT "本質層の成果物形態は対象外（REBUILD_LAYER=${REBUILD_LAYER}。除外 ${skipped_templates} 件・他の雛形は 0 件）"
  elif [ "$found_templates" -eq 0 ]; then
    report SKIP G-ARTIFACT "検査対象テンプレ（_*-template.md）なし"
  elif [ -z "$unmet" ]; then
    report PASS G-ARTIFACT "全テンプレ（${found_templates} 件）に複製実体または非該当 ADR が実在$([ "${skipped_templates:-0}" -gt 0 ] && printf '（REBUILD_LAYER=%s で %s 件は対象外）' "$REBUILD_LAYER" "$skipped_templates")"
  else
    report FAIL G-ARTIFACT "成果物形態の未達テンプレあり" "$unmet"
  fi
}

# --- live_adrs: `decisions.md` の「実エントリ」の ADR 番号を列挙する ---
# 【何を実エントリと見なさないか（すべて実測）】
#   (1) HTML コメント内の記載例（`decisions.md` の雛形が例を `<!-- -->` で囲んでいる）
#   (2) **コードフェンス内のドラフト**——雛形の HOLD 手順が「```markdown のフェンス内に ADR ドラフトを
#       提示し、**ユーザー承認後に**正式形へ展開する」と教えている。つまり**フレームワーク自身が
#       この形を作る**ので、除外しないと**未承認のドラフトが許可証になる**。
# 【共通化する理由】`gate_hold_adr`（分母縮小の ADR 突合）と `gate_rebuild_layer`（設定緩和の根拠）が
# 同じ判定を必要とし、片方だけ直すともう片方に穴が残る（実測でどちらも通った）。
# 【フェンス奇数の判定は 1 箇所で持つ】`gate_hold_adr` と `gate_rebuild_layer` が同じ事実を
# 別々に数えると乖離する（`live_adr_numbers` を共通化したのと同じ理由）。
decisions_fence_odd() { # 奇数なら真
  [ -f "$DECISIONS" ] || return 1
  [ $(( $(LC_ALL=C grep -E '^[[:space:]]*(```|~~~)' "$DECISIONS" 2>/dev/null | wc -l | tr -d ' ') % 2 )) -ne 0 ]
}
live_adr_numbers() {
  [ -f "$DECISIONS" ] || return 0
  # 【用途で厳しさの向きが逆なので縮退させない】この集合は 2 つの用途に使う:
  #   (a) 緩和の**許可**（`gate_rebuild_layer`）——**狭く**したい（未承認ドラフトを許可証にしない）
  #   (b) 参照の**不在告発**（`gate_hold_adr`）——**広く**したい（実在するのに「無い」と言わない）
  # フェンスが奇数のときにコメント除外だけへ縮退させると、(a) が**広がって fail-open** になる
  # （実測: 閉じ忘れ 1 行で未承認ドラフトが許可証になった）。よって縮退させず、
  # **フェンス内は常に除外**し、(b) 側は呼び出し元で「奇数なら告発を保留する」形にする。
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }   # コードフェンス内は対象外
    fence { next }
    { gsub(/<!--[^>]*-->/, "") }                        # 行内コメントを除去
    /<!--/ { c = 1 } /-->/ { c = 0; next } c { next }   # 複数行コメント内は対象外
    /^## ADR-[0-9]+/ { print }' "$DECISIONS" \
    | grep -oE 'ADR-[0-9]+' | sort -u
}

# --- G-PARALLEL: 並列プロファイル（GP-15 ルール12。Phase 4 だけで検査する） ---
# 【なぜゲートにするか】GP-15 を「ホストが並列を持つなら安全区間は並列が既定」に改めた。散文の既定は
# 自己申告で素通りする（FB 表のメタ原理）ので、**区間ごとの方式と、逐次にした理由を語彙で書かせて**機械で見る。
# 【合否にしないもの】並列か逐次かは合否にしない（逐次でも品質は成立する。費用を理由にした逐次は正当な縮退）。
# 判定文に「性能適合／品質適合」を出すだけで、欄が無い・行が欠ける・語彙の外のときだけ INCOMPLETE。
gate_parallel() {
  [ -f "$WORKPLAN" ] || { report INCOMPLETE G-PARALLEL "work-plan.md が無いので並列プロファイルを確認できない（GP-15 ルール12）"; return; }
  local sec
  # HTML コメントの中の表は数えない（G-WORKPLAN と同じ扱い。コメントで囲んだ表で通さない）
  sec=$(strip_html_comments < "$WORKPLAN" | awk '/^## \(D\)/{f=1;next} f&&/^## /{exit} f' 2>/dev/null | grep -E '^[|]' || true)
  if [ -z "$sec" ]; then
    report INCOMPLETE G-PARALLEL "work-plan.md に (D) 並列プロファイルが無い（並列でも逐次でも、安全区間ごとの方式を書く。GP-15 ルール12。この欄が入る前に作った計画書なら雛形の (D) を写す）" \
      "  雛形の (D) の表を写し、5 区間それぞれに 並列/逐次・同時数・逐次の理由（ホスト非対応/費用/依存/対象なし）を書く"
    return
  fi
  local out rc=0
  # 【LC_ALL=C 必須】macOS の awk は UTF-8 ロケールで `==` を strcoll で比べ、日本語どうしを「等しい」と判定する
  #  （実測: `"逐次"=="並列"` が真。全区間を逐次にして性能適合で PASS した）。バイト比較に固定する。
  out=$(printf '%s\n' "$sec" | LC_ALL=C awk -F'|' '
      function t(v) { gsub(/\*\*/, "", v); gsub(/`/, "", v); gsub(/^([ \t]|　)+|([ \t]|　)+$/, "", v); return v }
      # 補足の括弧書きは許す（「費用（〜のため）」「2〜4」）。語彙と数値は先頭で判定する
      function head(v) { sub(/（.*$/, "", v); sub(/\(.*$/, "", v); return t(v) }
      BEGIN { need["Phase 1 ノード列挙"]; need["Phase 2 分析"]; need["Phase 3 執筆"]; need["Phase 3 密度 Verify"]; need["Phase 4 監査"]
              r["ホスト非対応"]; r["費用"]; r["依存"]; r["対象なし"] }
      { k = t($2)
        if (k == "" || k == "区間" || k ~ /^-+$/ || k ~ /^:?-+:?$/) next
        if (!(k in need)) { bad = bad "\n認識できない区間名: " k "（Phase 1 ノード列挙 / Phase 2 分析 / Phase 3 執筆 / Phase 3 密度 Verify / Phase 4 監査 のいずれかで書く）"; next }
        if (k in seen) { bad = bad "\n" k ": 行が重複している"; next }
        seen[k] = 1; m = t($3); n = t($4); why = head($5); sub(/[^0-9].*$/, "", n)
        if (m == "並列") {
          npar++
          if (n !~ /^[0-9]+$/ || n + 0 < 2) bad = bad "\n" k ": 並列なのに同時数が 2 以上の数値でない（" n "）"
          if (why != "—" && why != "-" && why != "") bad = bad "\n" k ": 並列なのに逐次の理由が書かれている（" why "）"
        } else if (m == "逐次") { if (!(why in r)) bad = bad "\n" k ": 逐次の理由が語彙の外（" why "。ホスト非対応/費用/依存/対象なし）"; else nseq++ }
        else bad = bad "\n" k ": 方式が 並列/逐次 でない（" m "）" }
      END { for (k in need) if (!(k in seen)) bad = bad "\n" k ": 行が無い"
            printf "%d\t%d%s\n", npar + 0, nseq + 0, bad }') || rc=$?
  local npar nseq bad
  npar=$(printf '%s\n' "$out" | head -1 | cut -f1); nseq=$(printf '%s\n' "$out" | head -1 | cut -f2)
  # 【測れなかったことを PASS に落とさない】awk が異常終了・無出力なら判定を保留する
  if [ "$rc" -ne 0 ] || ! printf '%s' "$npar" | grep -qE '^[0-9]+$' || ! printf '%s' "$nseq" | grep -qE '^[0-9]+$'; then
    report INCOMPLETE G-PARALLEL "並列プロファイルを読み取れなかった（rc=${rc}。判定を保留する）"
    return
  fi
  bad=$(printf '%s\n' "$out" | tail -n +2 | grep . | LC_ALL=C sort || true)
  # 【能力をまたぐ突き合わせ（GP-15 ルール11）】work-plan (C) にその行があり、状態が 実施済 か ADR 付きの 該当なし であること。
  #  能力ごとの自己検査がすべて通っても能力間の矛盾は残った（完了ゲートも通過していた）。散文の完了条件は素通りするので、ここで見る。
  local xrow xst
  xrow=$(strip_html_comments < "$WORKPLAN" | awk '/^## \(C\)/{f=1;next} f&&/^## /{exit} f' | grep -E '^[|][^|]*能力をまたぐ突き合わせ' | head -1 || true)
  if [ -z "$xrow" ]; then
    bad=$(printf '%s\n%s' "$bad" "work-plan (C) に「能力をまたぐ突き合わせ」の行が無い（雛形の (C) の行を写す。能力が 1 つなら状態を 該当なし にする）" | grep . || true)
  else
    xst=$(printf '%s\n' "$xrow" | LC_ALL=C awk -F'|' '{ v = $(NF-2); gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')
    case "$xst" in
      実施済*) ;;
      該当なし*) printf '%s' "$xrow" | grep -qE 'ADR-[0-9]+' \
                 || bad=$(printf '%s\n%s' "$bad" "能力をまたぐ突き合わせが 該当なし なのに ADR が書かれていない（能力が 1 つ等の理由を ADR に残す）" | grep . || true) ;;
      *) bad=$(printf '%s\n%s' "$bad" "能力をまたぐ突き合わせの状態が「${xst}」（Phase 4 では 実施済 か ADR 付きの 該当なし）" | grep . || true) ;;
    esac
  fi
  if [ -n "$bad" ]; then
    report INCOMPLETE G-PARALLEL "並列プロファイル／能力をまたぐ突き合わせに未記入・重複・語彙の外がある（$(echo "$bad" | grep -c .) 件。GP-15 ルール11/12）" "$bad"
  elif [ "$npar" -eq 5 ] && [ "$nseq" -eq 0 ]; then
    report PASS G-PARALLEL "並列プロファイル記入済み: 5 区間すべて並列（性能適合。GP-15 ルール12）"
  else
    report PASS G-PARALLEL "並列プロファイル記入済み: 並列 ${npar} / 逐次 ${nseq}（理由は語彙の中。品質適合。GP-15 ルール12）"
  fi
}

# --- G-REBUILD: 本質層の実体の床（REBUILD_LAYER != off なら 0 件を許さない。GP-13 ルール15） ---
# 【なぜ独立ゲートか】この要求は元は `gate_tier` にあり、tier の撤去で失われる資産だった。  [撤去の記録]
# `G-ARTIFACT`（成果物形態）は代わりにならない——あちらは **(a) 複製実体 or (b) 非該当 ADR** の
# 選択で、**ADR で消化できる**。`GP-19` ルール 5 自身が「実運用で ADR がゲートの抜け道になった」と
# 記録しており、本質層を作ると宣言した設定で 0 件を ADR で消すのは**設定の表明と矛盾する**。
# よって**この床は ADR で消化できない**。
# 【`skeleton` も対象にする】`skeleton` は「作らない」ではなく**骨子（章立てと確定済みの事実）まで
# 作る**設定である（手順書付録 §1 の定義）。除外すると「作ると宣言した設定で 0 件」を許してしまい、
# しかも `full` → `skeleton` の 1 語編集で床が消える。**除外するのは `off` だけ。**
# 【床は深さを問わない】「骨子が十分か」の機械判定基準は無いので**深さは測らない**（測れないものを
# ゲート化すると誰も直せない未達になる）。ここで測るのは「実体が 1 件以上あるか」だけ。
# 【何を実体と数えるか】**front-matter に `spec-id`（値あり）と `category: rebuild` を持ち、本文が空でない**もの
# （下の (2) が正本。`G-ARTIFACT` (a) の `artifact-key` は**実データの本質層に無い**ので使えない——
# 詳細は (2) の注記）。単に `*.md` を数えると**0 バイトのファイル 1 個で通る**
# ——床が形態ゲートより緩くなり、抜け道になる。`-type f` も必須（`x.md` という名の**ディレクトリ**で通った）。
# 【設定で緩めるなら ADR を要求する】逃げ道を設定値にした代償として、**設定編集は痕跡が残らない**
# （`G-REGRESS` は `gates.sh` の指紋変化を必要条件にしているので config 編集の反転を検出できない）。
# `purpose` の既定より緩い値にしているときは、**`gate-config.env` の当該行に根拠 ADR の番号**を書かせ、
# その番号が `decisions.md` の実エントリとして在ることを突合する（`gate_hold_adr` と同じ方式）。
# 【判定を INCOMPLETE にする理由】欠陥ではなく「まだ書いていない」なので、書けば解除される（`GP-6` ルール14）。
rebuild_layer_rank() { # off < skeleton < full（緩い→厳しい）
  case "$1" in off) printf '1' ;; skeleton) printf '2' ;; full) printf '3' ;; *) printf '0' ;; esac
}
# 【purpose も方向で見る】要求の強さは maintenance < evaluation < rebuild（`unknown` は最も厳しい側に
# 倒すので rebuild と同順）。**要求が減る方向だけ**を止める——等値比較だけにしていたため
# `maintenance` → `rebuild`（要求が増える）まで ADR で止めており、しかも診断は「下げると」と
# 事実の逆を述べていた（実測。`REBUILD_LAYER` 側は方向を見ているので設計が非対称だった）。
purpose_rank() {
  case "$1" in maintenance) printf '1' ;; evaluation) printf '2' ;; rebuild|unknown) printf '3' ;; *) printf '0' ;; esac
}
PU_UNTRACKED=0
gate_rebuild_layer() {
  # 【旗は毎回リセットする】`gates.sh all` は phase3 / phase4 で 2 回呼ぶので、
  # 関数外の初期化だけでは前回の値が持ち越される（現状は同値で無害だが、持ち越しは事故の芽）。
  PU_UNTRACKED=0
  # 【定義は関数の入口に置く】`return` する経路すべてから呼べる必要がある。以前は (2) の直前に
  # 定義していたため、**ADR 不足で return する 3 経路（＝追跡できないと最も困る経路）から
  # 呼べなかった**（そこで呼ぶよう足すと定義前呼び出しになる。教訓 26）。
  pu_untracked_note() {
    [ "${PU_UNTRACKED:-0}" -eq 1 ] || return 0
    note_detail G-REBUILD "G-REBUILD: purpose の変更を追跡できない（生成時の値の記録が無い）" \
      "gate-config.env に PURPOSE_INITIAL が無く、初期コミットからも読めない（v1.22 より前に生成した、
または浅いクローン）。この状態では purpose を下げても検出できない。
gate-config.env に PURPOSE_INITIAL=<生成時の purpose> を 1 行足すこと。"
  }
  # (1) purpose の既定より緩めているなら ADR を要求する（設定 1 語で床を消せないように）
  # 【`unknown` を最も厳しい側に倒す】`gate-config.env` を持たない既存リポジトリは `PURPOSE=unknown`
  # になる。ここを素通りさせると**キーを持たないリポジトリで ADR 要求が不活性**になり、
  # `REBUILD_LAYER=off` の 1 行追記だけで無記録に床を消せる（実測で確認した経路）。
  # `REBUILD_LAYER` 未設定を既定 `full` に倒しているのと同じ理由で、こちらも厳しい側に倒す。
  local rl_adr_note=""
  # 【`PURPOSE` の 1 語編集で要求ごと消えるのを防ぐ（実測）】ADR 要求の発火条件が「`PURPOSE` の
  # 既定より緩いか」だけだと、**`PURPOSE` 自体を下げれば既定が下がって何も要求されない**
  # （`rebuild` → `maintenance` で本質層の床・成果物形態・tier 未達がまとめて消えた）。  [撤去の記録]
  # 生成時の値（`PURPOSE_INITIAL`）と違うなら、`PURPOSE` の行に根拠 ADR の番号を要求する。
  # 【生成時の値は git の初期コミットから引く】`gate-config.env` の `PURPOSE_INITIAL` キーだけを
  # 見ていると、**隣の 1 行を書き換える／消すだけで要求が消える**（実測: ADR を書いた正当経路と
  # 同一の結果になった）。`init.sh` は設定ファイルを**初期コミットに含めて**コミットするので、
  # そこから引けば設定ファイルの編集では変えられない（履歴の書き換えは別の痕跡が残る）。
  # 【既存リポジトリは初期コミットに設定ファイルが無い】その場合はキーへフォールバックし、
  # どちらも無ければ**追跡できないことを情報として出す**（黙って素通しにしない）。
  # 【git の初期コミットとキーの両方を見て、厳しい側を採る】git だけを信じると **shallow clone**
  # （`--depth 1`）で `rev-list --max-parents=0 HEAD` が **HEAD 自身**を返し、
  # 「現在の値＝生成時の値」になって要求が消える。しかもキーが正しく残っていても
  # 初期コミット側が非空なのでフォールバックせず、**キーだけを見ていた頃より弱くなる**（実測）。
  # よって候補を両方集め、**どれか 1 つでも現在値と違えば要求する**。
  # 【root は全部見る】orphan をマージすると root が複数になり、`head -1` は**新しい方**を選ぶ。
  # 設定ファイルを持つ root を全て走査する（実データにも root が 2 件のリポジトリがある）。
  local pu_gen="" pu_cands="" _r
  # 【古い git に `--is-shallow-repository` が無い】`|| echo true` だけだと**常に shallow 扱い**になり
  # 初期コミットを見なくなる（実測: そのオプションを拒否するシムで要求が消えた）。
  # 無い場合は `.git/shallow` の実在で判定する。
  local _shallow _gd
  _shallow=$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)
  if [ "$_shallow" = "unknown" ]; then
    _gd=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || true)
    case "$_gd" in /*) ;; ?*) _gd="$REPO_ROOT/$_gd" ;; esac
    if [ -n "$_gd" ] && [ -e "$_gd/shallow" ]; then _shallow="true"; else _shallow="false"; fi
  fi
  if [ "$_shallow" != "true" ]; then
    for _r in $(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD 2>/dev/null || true); do
      pu_gen=$(git -C "$REPO_ROOT" show "${_r}:spec-extraction/00-ingestion/gate-config.env" 2>/dev/null \
               | grep -E '^[[:space:]]*(export[[:space:]]+)?PURPOSE=' | tail -1 \
               | sed 's/.*PURPOSE=//; s/[[:space:]]*#.*//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//' || true)
      # 【`source` の実効値は最後の代入】現行ファイル側は `tail -1` を見ているので、
      # 初期コミット側だけ `head -1` だと同一キーが複数行あるとき参照行が食い違う。
      [ -n "$pu_gen" ] && pu_cands="${pu_cands}${pu_cands:+ }${pu_gen}"
    done
  fi
  [ -n "$PURPOSE_INITIAL" ] && pu_cands="${pu_cands}${pu_cands:+ }${PURPOSE_INITIAL}"
  # どれか 1 つでも**現在値より要求が強ければ**「緩めた」とみなす（厳しい側。等値・強化は素通し）
  local pu_changed="" pu_from="" pu_rc_cur
  pu_rc_cur=$(purpose_rank "$PURPOSE")
  for _r in $pu_cands; do
    [ "$(purpose_rank "$_r")" -gt "$pu_rc_cur" ] && { pu_changed="yes"; pu_from="$_r"; }
  done
  if [ -z "$pu_cands" ]; then
    # 【追跡できないことを黙らない】既存リポジトリは初期コミットに設定ファイルが無く、
    # キーも持たない。**保護されていない事実**を判定の後に情報として出す（下の note_detail）。
    PU_UNTRACKED=1
  fi
  if [ -n "$pu_changed" ]; then
    local pu_line pu_num
    pu_line=$(grep -nE '^[[:space:]]*(export[[:space:]]+)?PURPOSE=' "$GATE_CONFIG" 2>/dev/null | tail -1 || true)
    pu_num=$(printf '%s' "$pu_line" | grep -oE 'ADR-[0-9]+' | head -1 || true)
    local pu_fence_hint=""
    if decisions_fence_odd; then
      pu_fence_hint="
【まず確認すること】decisions.md のコードフェンスが奇数個ある。閉じ忘れがあると実在する ADR も
抽出対象から外れる（番号を書いてあるのに「無い」と言われる）。フェンスを閉じて再実行する。"
    fi
    if [ -z "$pu_num" ] || ! printf '%s\n' "$(live_adr_numbers)" | grep -qx "$pu_num"; then
      report INCOMPLETE G-REBUILD "purpose を生成時（${pu_from}）から ${PURPOSE} へ緩めているのに根拠 ADR が無い" \
        "purpose を緩めると本質層の床・成果物形態・密度の要求がまとめて消える。変更するなら
gate-config.env の PURPOSE の行に根拠 ADR の番号を書くこと（書式: PURPOSE=${PURPOSE}  # ADR-<番号>）。
その番号の ADR が spec-extraction/docs/decisions/decisions.md に実在することも確認する。
【なぜ番号を要求するか】設定編集は gates.sh の指紋を変えないので G-REGRESS では追跡できない。
【要求が増える方向は止めない】maintenance → rebuild のような強化は ADR 無しで通る。${pu_fence_hint}"
      pu_untracked_note
      return
    fi
    rl_adr_note="${rl_adr_note}。purpose 変更の根拠 ${pu_num}"
  fi
  local expected=""
  case "$PURPOSE" in
    rebuild|unknown) expected="full" ;;
    evaluation) expected="skeleton" ;;
    maintenance) expected="off" ;;
  esac
  if [ -n "$expected" ]; then
    local rc_cur rc_exp
    rc_cur=$(rebuild_layer_rank "$REBUILD_LAYER"); rc_exp=$(rebuild_layer_rank "$expected")
    if [ "$rc_cur" -lt "$rc_exp" ]; then
      # 【語の言及では判定しない（実データで破れた）】「`decisions.md` のどこかに `REBUILD_LAYER` を
      # 言及した実 ADR があるか」では**既存の ADR が緩和の許可証に流用できる**——実案件の ADR-1 は
      # `REBUILD_LAYER=full` と**逆向きに宣言**しており、それだけで `off` への 1 語編集が通った（実測）。
      # 本文の走査（箇条書き限定・見出し終端）でも塞げない: 許可の根拠が**特定の判断に紐づかない**限り、
      # どんな走査規則でも「無関係な言及」を排除できない。
      # 【`gate_hold_adr` の本当の方式に揃える】あれは**呼び出し側に ADR 番号を明示させ、
      # その番号の実在を突合する**。ここも同じ形にする——`gate-config.env` の当該行に
      # `# ADR-<番号>` を書かせ、その番号が `decisions.md` の実エントリとして在るかを見る。
      # これで (a) 許可が特定の判断に紐づき、(b) 本文の書式（`### 決定` / 箇条 / コードブロック）に
      # 依存しなくなる（実データの支配的な形を弾かない）。
      local rl_line rl_num
      # 【実効値を決める行を読む】`export REBUILD_LAYER=off` を後に書くと、
      # `^[[:space:]]*REBUILD_LAYER=` だけでは拾えず**目視で full と書いてある行の番号で通る**（実測）。
      rl_line=$(grep -nE '^[[:space:]]*(export[[:space:]]+)?REBUILD_LAYER=' "$GATE_CONFIG" 2>/dev/null | tail -1 || true)
      rl_num=$(printf '%s' "$rl_line" | grep -oE 'ADR-[0-9]+' | head -1 || true)
      if [ -z "$rl_num" ]; then
        report INCOMPLETE G-REBUILD "REBUILD_LAYER を purpose の既定より緩めているのに根拠 ADR の番号が無い" \
          "purpose=${PURPOSE} の既定は REBUILD_LAYER=${expected} だが ${REBUILD_LAYER} になっている。
gate-config.env の REBUILD_LAYER の行に根拠となる ADR の番号を書くこと。書式:
  REBUILD_LAYER=${REBUILD_LAYER}  # ADR-<番号>
その番号の ADR（^## ADR-<番号>）が spec-extraction/docs/decisions/decisions.md に実在することも確認する。
【なぜ番号を要求するか】設定編集は gates.sh の指紋を変えないので G-REGRESS では追跡できない。
かつ「decisions.md のどこかに REBUILD_LAYER の言及がある」では、**逆向きに full を宣言した既存 ADR**でも
解除できてしまう（実測）。許可は特定の判断に紐づける。"
        pu_untracked_note
        return
      fi
      # 番号が実エントリとして在るか（HTML コメント内の記載例では解除されない。`gate_hold_adr` と同じ）
      local live_adrs=""
      live_adrs=$(live_adr_numbers)
      rl_adr_note="${rl_adr_note}。根拠 ${rl_num}"
      if ! printf '%s\n' "$live_adrs" | grep -qx "$rl_num"; then
        # 【フェンスが奇数なら断定しない】許可集合は狭いまま（＝解除しない）で正しいが、**診断が
        # 事実と逆になる**——`## ADR-N` が実在するのに「実在しない」と言われ、decisions.md を見ても
        # 直せない（実測）。判定は変えず、原因の候補を必ず添える。
        local rl_fence_hint=""
        if decisions_fence_odd; then
          rl_fence_hint="
【まず確認すること】decisions.md のコードフェンス（\`\`\` / ~~~）が奇数個ある。閉じ忘れがあると
以降が全てフェンス内と見なされ、実在する ## ${rl_num} も抽出対象から外れる。フェンスを閉じて再実行する。"
        fi
        report INCOMPLETE G-REBUILD "REBUILD_LAYER の根拠 ADR（${rl_num}）を decisions.md の実エントリとして確認できない" \
          "gate-config.env は ${rl_num} を根拠として挙げているが、docs/decisions/decisions.md に
見出し ## ${rl_num} の実エントリが無い（HTML コメント内の記載例・コードフェンス内のドラフトは実エントリと見なさない）。
番号の書き間違いか、ADR をまだ書いていない。${rl_fence_hint}"
        pu_untracked_note
        return
      fi
    fi
  fi
  # (2) 床: `off`（作らないと表明した設定）以外は本質層に実体が 1 件以上
  if [ "$REBUILD_LAYER" = "off" ]; then
    # 【SKIP にしない】`report` は SKIP を判定履歴に残さないので、「測っていない」と
    # 「設定どおり対象が無い」が区別できなくなる。
    # 【許可した ADR 番号を正本に残す】「許可を特定の判断に紐づける」設計の成果物が
    # `gate-results.md` から見えないと、後から誰が何を根拠に緩めたか追えない。
    report PASS G-REBUILD "本質層の実体は対象外（REBUILD_LAYER=off${rl_adr_note}）"
    pu_untracked_note
    return
  fi
  # 【何を実体と数えるか】実測で 2 つの抜け道があった:
  #   (1) `spec-id` を持つ**索引 1 枚**（`category: index` / `coverage-status: generated`）で通った
  #   (2) `specs/rebuild/README.md` に `spec-id` を足すだけで通った
  #       ——そこは `G-VIEW` が統合ビュー候補として自ら指名している場所である
  # よって **front-matter が本質層の仕様だと宣言していること**（`category: rebuild`）を要求し、
  # 未記入の雛形複製・機械生成物・索引を除く。
  # 【`artifact-key` は使わない】`G-ARTIFACT` (a) と同じ述語にしようとしたが、**実データの本質層は
  # front-matter に `artifact-key` を持つかが**案件によって分かれる**（実測: ある案件は実体すべてが
  # 持たず、別の案件は 5 件中 4 件が持つ）。要求すると、持たない案件の実体が「0 件」と判定される＝偽の未達。
  local n=0
  if [ -d "$SPECS/rebuild" ]; then
    # 【名前で除外しない】雛形は front-matter が `TEMPLATE-DO-NOT-INDEX` なので下の述語で落ちる。
    # 名前で落とすと `<x>-template.md` という実仕様を取りこぼす（偽陰性の芽）。
    # 【`README.md` を数えない】そこは `G-VIEW` が**統合俯瞰ビュー**の置き場所として指名しており、
    # 実データでも `category: rebuild` を持つ統合ビューが置かれている（実測）。ビューは能力の仕様ではない。
    # 【中身のあるものだけ数える】front-matter だけのスタブ 1 枚で床が満たせては意味がない
    # （実測でそうなっていた）。**front-matter を除いた本文が空でない**ことを要求する
    # ——量を上げても雛形と実体は分離できないと測れたので、ここは下限だけを見る（理由は下の注記）。
    local _cand _f _body
    # 【名前ではなく「統合ビューとして解決されるパス」を除く】`-not -name 'README.md'` は
    # **大文字小文字**（`readme.md`）で抜けられ、`INTEGRATED_VIEW_DOC` で任意の名前にもできる（実測）。
    # `G-VIEW` の候補解決と同じ集合を除外する（教訓 30: 文字を列挙する検査は漏れる）。
    # 【`basename` の正規表現で除かない】メタ文字（`.` `[`）でパターンが壊れ、大小無視で別ファイルを
    # 誤除外し、`specs/` 直下の同名ファイルまで巻き込んだ（実測で 5 形）。**絶対パスの完全一致**で除く。
    # 大小無視にするのは、**`G-VIEW` の候補解決と同じ規則に揃える**ためである（両方 `resolve_ci_all`）。
    # 【意味の変化を明記する（2026-09-26）】大小を区別する FS で `INTEGRATED_VIEW_DOC=…/Cap.md` と
    # 書かれ、別物の `cap.md` が実在する場合、**`cap.md` は除外される**（旧実装は除外しなかった）。
    # これは「判定を大小無視側に寄せる」という設計宣言の帰結で、**向きは fail-closed**（偽の未達）。
    # 過去の `Cap.md` 事故（存在しない候補で実体が消えた）は `grep -i` の**行突合**が原因であり、
    # `resolve_ci_all` の**実在解決**では再発しない（存在しない名前は 1 行も出さない）。
    local _vf; _vf="$(mktemp "${TMPDIR:-/tmp}/gr-views.XXXXXX")" || _vf=""
    # 【作れなければ判定しない】除外リストを作れないまま進むと統合ビューが実体に数えられ、
    # **README.md 1 枚で床が満たせる fail-open** になる（測れないときは緑にしない）。
    if [ -z "$_vf" ]; then
      report INCOMPLETE G-REBUILD "一時ファイルを作れず統合ビューの除外ができないため本質層の判定を保留した" \
        "TMPDIR（${TMPDIR:-/tmp}）に書き込めるか確認して再実行すること。除外せずに数えると
統合俯瞰ビュー 1 枚で床が満たせてしまうため、判定を出さない。"
      pu_untracked_note
      return
    fi
    if [ -n "$_vf" ]; then
      # 【実在するものだけを、実際のファイル名に解決して除く】`-i`（大小無視）で行ごと突合すると
      # **存在しない `Cap.md` が候補にあるだけで実体 `cap.md` が消えた**（実測）。
      # ⇒ `resolve_ci_all` で**実在するファイルに解決してから完全一致で除く**
      # （`basename` の正規表現で除くとメタ文字でパターンが壊れ、別ディレクトリの同名まで巻き込む）。
      # 【`[ -f "$_v" ]` の前置きを外した（2026-09-26）】この 1 行がファイルシステム依存だった。
      # 大小を区別する FS では `[ -f README.md ]` が偽になって `continue` し、**`readme.md` が
      # rebuild の実体に数えられて床が満たせる**——統合ビュー 1 枚で通る fail-open が
      # **Linux でだけ**開いていた（WSL の `/tmp`＝wslfs で selftest が実測で検出。macOS の APFS では
      # 大小を区別しないので 1 度も露出しなかった）。解決は `resolve_ci_all` が実在確認も担う。
      for _v in "${INTEGRATED_VIEW_DOC:-}" "$SPECS/usage-operations.md" "$SPECS/rebuild/README.md" "$SPECS/overview.md"; do
        [ -n "$_v" ] || continue
        case "$_v" in /*) ;; *) _v="$REPO_ROOT/$_v" ;; esac
        resolve_ci_all "$_v" >> "$_vf" || true
      done
    fi
    # 【`-L` と `-iname`】`-type f` は symlink をたどらないので実体を外に置くと数えられず、
    # `-name '*.md'` は大小区別なので `CAP.MD` を取りこぼす（どちらも偽の未達の芽。教訓 30）。
    # `-L` を付けても `.md` という名の**ディレクトリ**は `-type f` が落とす。
    _cand=$(find -L "$SPECS/rebuild" -type f -iname '*.md' 2>/dev/null \
        | { [ -s "${_vf:-/dev/null}" ] && LC_ALL=C grep -vxF -f "$_vf" || cat; } || true)
    # 【front-matter の中だけを見る】以前は `grep -l '^category: rebuild'` でファイル全体を走査しており、
    # **本文のコードブロックに front-matter の例を書いた実体が誤除外**された（実測）。
    # 【先頭の HTML コメントを許す】配布雛形 `tier1-rebuild.md.template` は **1 行目が  [撤去の記録]
    # `<!-- artifact-key: … -->`** なので、「先頭の非空行が `---`」に限ると
    # **雛形どおりに書いた正当な仕様が偽の未達**になった（実測）。空行と HTML コメント行は読み飛ばす。
    # 【量は「中身のある行が 1 行以上」に留める】未記入の雛形複製を量で見分けようとしたが、
    # **行数・主張（`path:line`）数・プレースホルダ数のいずれでも実データと重なる**（実測:
    # 雛形は本文 115 行・主張 6 件・プレースホルダ 28 行で、実体の分布に収まる）。
    # 量を上げると**正当な仕様を止める**方が先に起きるので、床は「front-matter が本質層の仕様だと
    # 宣言し、本文が空でない」までにする。**雛形の中身を書き換えた偽装は `G-DENSITY` /
    # `G-READABLE` / `G-FRESH` が捕まえる領分**（この床の担当ではない）。
    n=0
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      # 【多バイト空白は awk のリテラルでは剥がれない】八進も 16 進も効かないので `-v` で渡す（実測）。
      LC_ALL=C sed "1s/^$(printf '\357\273\277')//" "$_f" 2>/dev/null \
        | awk -v ZW="$(printf '\342\200\213')" -v NB="$(printf '\302\240')" -v WS="$(printf '\343\200\200')" '
        function meat(l) {
          gsub(/[[:space:]]/, "", l)
          gsub(WS, "", l); gsub(NB, "", l); gsub(ZW, "", l)
          if (l == "") return 0
          # 開始タグを見ずに来た閉じタグ単独行（コメント塊の途中から始まるファイル）。
          # `A --> B` のような本文は残す——**行全体が `-->` のときだけ**落とす（実測で通り抜けた）。
          if (l == "-->") return 0
          return 1
        }
        # 【コメントの除去は位置で行う】正規表現で `<!--.*-->` を消すと**貪欲マッチ**が同じ行の
        # 本文まで飲み、`<!--[^>]*-->` は本文に `>` があると失敗する。さらに「行内に `-->` があれば
        # 閉じた」とみなすと `<!-- a --><!-- b`（同一行で閉じてから開く）や `--> ---` を追えず、
        # **正当な仕様が偽の未達になる**（実測）。開始位置と閉じ位置を数えて切り出す。
        # 閉じずに終わったときは OPEN=1 を立てて呼び出し元が継続状態を持つ。
        function strip_comments(t,   a, b) {
          while (1) {
            a = index(t, "<!--")
            if (a == 0) return t
            b = index(substr(t, a + 4), "-->")
            if (b == 0) { OPEN = 1; return substr(t, 1, a - 1) }
            t = substr(t, 1, a - 1) substr(t, a + 4 + b + 2)
          }
        }
        # 【値を取り出してから比べる】行末固定にしていたため `category: rebuild  # 本質層`・
        # `category: "rebuild"`・`category: Rebuild` を弾いていた（実測）。**3 述語すべてで使う**
        # ——`category` だけ直して `coverage-status` を行末固定のまま残したため、機械生成物が
        # `coverage-status: generated  # 自動` の 1 行で実体に数えられていた（fail-open。実測）。
        function fmval(l, key,   v) {
          v = l
          sub("^" key ":[[:space:]]*", "", v)
          sub(/[[:space:]]*#.*$/, "", v)
          gsub(/[[:space:]]+$/, "", v)
          # 引用符は 1 文字ずつ落とす（文字クラスに単一引用符を書くとシェルのクォートが壊れる。
          # `\047` は awk が解釈する単一引用符で、シェルからは素通しできる）
          gsub(/^"|"$/, "", v)
          gsub(/^\047|\047$/, "", v)
          gsub(/[[:space:]]+$/, "", v)
          return tolower(v)
        }
        # 【先頭コメントは複数行・複数塊になる】配布雛形の目印は 1 行ではなくコメント 3 塊 8 行で、
        # 「`<!--` で始まる行」だけを読み飛ばすと継続行で front-matter 認識が外れ、
        # **雛形どおりに書いた正当な仕様が偽の未達になっていた**（実測）。
        !seen {
          t = $0
          if (lead_c) {
            b = index(t, "-->")
            if (b == 0) next
            t = substr(t, b + 3); lead_c = 0
          }
          OPEN = 0
          t = strip_comments(t)
          if (OPEN) lead_c = 1
          tt = t; gsub(/[[:space:]]/, "", tt)
          if (tt == "") next
          seen = 1
          if (tt == "---") { fm = 1; next }
        }
        fm && /^---[[:space:]]*$/ { fm = 0; next }
        fm {
          if ($0 ~ /^spec-id:[[:space:]]*[^[:space:]]/) { has_id = 1; if ($0 ~ /TEMPLATE-DO-NOT-INDEX/) bad = 1 }
          if ($0 ~ /^category:/) {
            cv = fmval($0, "category")
            if (cv == "rebuild") has_cat = 1
            if (cv == "index") bad = 1
          }
          if ($0 ~ /^coverage-status:/ && fmval($0, "coverage-status") == "generated") bad = 1
          next
        }
        # 本文側も同じ関数でコメントを塊ごと落とす（説明コメントだけの本文を実体に数えない）
        {
          t = $0
          if (body_c) {
            b = index(t, "-->")
            if (b == 0) next
            t = substr(t, b + 3); body_c = 0
          }
          OPEN = 0
          t = strip_comments(t)
          if (OPEN) body_c = 1
          if (meat(t)) body++
        }
        END { print (has_id && has_cat && !bad && body >= 1) ? "1" : "0" }' 2>/dev/null \
        | grep -qx 1 && n=$((n + 1))
    done <<< "$_cand"
    [ -n "${_vf:-}" ] && rm -f "$_vf"
  fi
  # 【順序の検査（2026-09-23 追加。FB-16 / GP-13 ルール17）】
  # 書く順序は実装事実層 → 本質層に戻したが、**旧ボトムアップ（全能力の実装層を書いてから
  # 本質を凝縮する）には戻していない**——能力ごとに通し切る。その退行を検出する。
  # 【なぜ床（n==0）だけでは足りないか】床は完了宣言の時点でしか効かないので、
  # **全能力の実装層を書き終えるまで鳴らない**＝予算が尽きる直前まで検出できない（FB-13 の再発形）。
  # 【閾値の根拠（実データで先に測った）】参照成果物 2 件で 1 能力あたりの実装事実層の密度ブロックは
  # **3.3〜3.5 件**（roller-e2-spec 20/6・roller-spec 21/6）。⇒ **6 件 = 約 1.7 能力分**を超えて
  # 本質層が 0 件なら「1 能力目を通し切らずに 2 能力目の実装層へ進んだ」と判定できる。
  # 【偽陽性を先に確認した】参照成果物 2 件はいずれも能力仕様を持つので発火しない（実測）。
  # 【設定が作らないと決めたものは要求しない】REBUILD_LAYER=off はここに来ない（上で PASS 済み）。
  local rb_impl=0 rb_ledger="$AUDIT/density-ledger.tsv"
  if [ -f "$rb_ledger" ]; then
    rb_impl=$(LC_ALL=C awk -F'\t' '$1 ~ /^DB-/ && $2 ~ /specs\/(modules|api|data|behavior)\//' "$rb_ledger" 2>/dev/null | LC_ALL=C grep -c . || true)
  fi
  if [ "${n:-0}" -eq 0 ] && [ "${rb_impl:-0}" -ge 6 ]; then
    report INCOMPLETE G-REBUILD "実装事実層の密度ブロックが ${rb_impl} 件あるのに本質層が 0 件（能力ごとに通し切っていない）" \
      "手順書 Step 3-0 は**1 ドメイン能力を分析物 → 実装事実層 → 本質層 → Verify まで通し切ってから
次の能力に進む**ことを要求している（縦串 ＋ カナリア）。実装事実層のブロックが ${rb_impl} 件（1 能力あたりの
実測は 3.3〜3.5 件なので約 $((rb_impl * 10 / 35)) 割の能力分）登録されているのに本質層が 0 件なのは、
**1 能力目を通し切らずに次の能力の実装層へ進んだ**状態である。
これは FB-13（実装層を全ノード分書いてから本質を凝縮したため、再構築に使える層に到達する前に
予算が尽きた）の再発形である。**いま通している 1 能力の本質層を書いてから先に進むこと。**
本質層を作らない判断なら gate-config.env の REBUILD_LAYER を off にする（理由を ADR に書く）。"
  elif [ "${n:-0}" -eq 0 ]; then
    report INCOMPLETE G-REBUILD "REBUILD_LAYER=${REBUILD_LAYER} だが本質層に実体が無い" \
      "specs/rebuild/ に本質層の仕様が 1 件も無い（要件: front-matter に spec-id と category: rebuild を持ち、
spec-id が TEMPLATE-DO-NOT-INDEX でなく、機械生成物・索引（coverage-status: generated / category: index）でも
統合ビュー（README 等。G-VIEW が見る場所）でもなく、本文が空でないもの。
空行・空白だけの行・説明コメントだけの行は本文と数えない）。
非該当 ADR では解除されない——作らない判断なら gate-config.env の REBUILD_LAYER を off にすること（その理由を ADR に書く）。
skeleton は「作らない」ではなく「骨子まで作る」設定なので、この床の対象である（深さは問わない）。"
  else
    report PASS G-REBUILD "本質層に実体 ${n} 件（REBUILD_LAYER=${REBUILD_LAYER}${rl_adr_note}）"
  fi
  pu_untracked_note
}

# --- G-ENUM: 列挙完全性の記録（SB-2 ルール8。§2c の実行結果欄が埋まっているか） ---
# --- G-ENUM-SOURCE: 列挙の独立ソース表が埋まっているか（GP-105 / SB-2 ルール8） ---
# 「分母の数え方」はスタック依存であり、Playbook が enumeration.md で提供する。
# Playbook 未指定なら雛形が置かれるため、未記入のまま列挙に進むことを禁じる
# （「独立ソースが分からない」を「突合しない」に落とさない。GP-6 設計原則と同型）。
# 実測根拠: roller は @Path/@Table が 0 件で、汎用手順書の分母突合が計算不能だった。
enum_source_one() {
  local enum="$1" pb="$2"
  if [ ! -f "$enum" ]; then
    ges_set FAIL "ファイルが存在しない（列挙の分母が未定義。併用した Playbook は init.sh が enumeration-<名前>.md に置く。GP-105）"
    return
  fi
  # 独立ソース表のプレースホルダ残存を検出する（雛形のまま進んでいないか）
  local table unfilled
  # awk の範囲式は開始行が終了パターンにも一致すると即終了するため、フラグ方式で切り出す
  # 【行抽出の緩さを他表と揃える】ここだけ `'^| NODE'`（空白必須）で、**一部の行を
  # `|NODE-EP|…` に崩すとその行が無検査で素通りした**（実測。全行崩すと「表が無い」で fail-closed）。
  table=$(awk '/^## 独立ソース表/{f=1;next} f&&/^## /{exit} f' "$enum" | grep -E '^\|[[:space:]]*NODE' || true)
  if [ -z "$table" ]; then
    ges_set FAIL "enumeration.md に独立ソース表（| NODE... 行）が無い" \
      "ノード種別ごとに「独立ソース・全走査コマンド・突合の等式」を記述すること"
    return
  fi
  # プレースホルダ判定は **「雛形の語」の実在**で行う（`<...>` の有無では判定しない）。
  #
  # 初版は 2 度失敗した:
  #  (1) `sed 's/`[^`]*`//g'` でコード内容ごと削除 → 雛形の `<コマンド>` が全部消え、
  #      **未記入の表を「記入済み」と判定**していた（ゲートが完全に盲目）。
  #  (2) 除外リスト方式 → コマンド例の正規表現断片（`<createTable[^>]*`）が残り誤検出。
  # `<...>` はコマンド例・XML 要素名として正当に多数現れるため、そもそも判定材料に向かない。
  # 雛形が使う固定語（日本語の指示文）を直接探す方が確実で、誤検出も起きない。
  unfilled=$(echo "$table" | grep -nE '<(コマンド|等式[^>]*|例:[^>]*|N|M|YYYY-MM-DD|同上[^>]*|差分[^>]*)>' \
    | sed 's/^/  未記入行: /' || true)
  if [ -n "$unfilled" ]; then
    ges_set FAIL "独立ソース表にプレースホルダが残存（分母の定義が未完。GP-105）" "$unfilled"
    return
  fi
  # 独立ソース表の各行に「独立ソース」と「全走査コマンド」が実質的に書かれているか
  # （プレースホルダを消して空欄にする回避を塞ぐ。列は | 種別 | 独立ソース | コマンド | 等式 |）
  local empty_cells
  empty_cells=$(echo "$table" | LC_ALL=C awk -F'|' '
    { node=$2; srcdef=$3; cmd=$4
      gsub(/^[ \t]+|[ \t]+$/, "", node); gsub(/[ \t`]/, "", srcdef); gsub(/[ \t`]/, "", cmd)
      if (srcdef == "" || srcdef == "-" || srcdef == "—") print "  " node ": 独立ソースが空"
      else if (cmd == "" || cmd == "-" || cmd == "—") print "  " node ": 全走査コマンドが空"
    }' || true)
  if [ -n "$empty_cells" ]; then
    ges_set FAIL "独立ソース表に空欄がある（独立ソースと全走査コマンドは必須。GP-105 ルール2）" "$empty_cells"
    return
  fi
  # 「目印の系統」表を検査する（GP-2 ルール8 / FB-9）。
  # 網羅性は「走査範囲」ではなく**目印の集合**で決まる。走査範囲が全域でも目印が偏れば穴が開く
  # （実運用 FB-9: 識別子だけ走査してケバブケースの設定キーを落とす／基底クラスの継承だけ走査して
  #  インライン宣言を落とす／文字列接頭辞で数えて別種の識別子が混入する——3 件が同一原因だった）。
  # **系統が 1 つだと判断した場合も根拠欄は必須**（「分からない」を「1 つだけ」に落とさない）。
  local sys sys_bad
  sys=$(awk '/^## 目印の系統/{f=1;next} f&&/^## /{exit} f' "$enum" | grep -E '^\|[[:space:]]*NODE' || true)
  if [ -z "$sys" ]; then
    ges_set FAIL "「目印の系統」表が無い（節削除による回避。1 目印の全走査を網羅と呼ばない。GP-2 ルール8 / FB-9)"
    return
  fi
  # 系統列にパイプが入りうるため**根拠は末尾から数える**（#7 と同型の列ずれ対策）
  sys_bad=$(echo "$sys" | LC_ALL=C awk -F'|' '
    { node=$2; kinds=$3; basis=$(NF-1)
      gsub(/^[ \t]+|[ \t]+$/, "", node)
      gsub(/[ \t`]/, "", kinds); gsub(/[ \t`]/, "", basis)
      if (kinds ~ /^<.*>$/ || kinds == "" || kinds == "-" || kinds == "—") print "  " node ": 目印の系統が未記入"
      else if (basis ~ /^<.*>$/ || basis == "" || basis == "-" || basis == "—") print "  " node ": 単一系統である根拠が未記入（1 つだけと判断した場合も必須）"
    }' || true)
  # 散文で埋める回避も塞ぐ（TBD / 不明 / 未 で通させない）。
  sys_bad+=$(echo "$sys" | LC_ALL=C awk -F'|' '
    { node=$2; kinds=$3; basis=$(NF-1)
      gsub(/^[ \t]+|[ \t]+$/, "", node); gsub(/[ \t`]/, "", kinds); gsub(/[ \t`]/, "", basis)
      if (kinds ~ /^(TBD|不明|未|なし|N\/A|unknown|\?+)$/ || basis ~ /^(TBD|不明|未|なし|N\/A|unknown|\?+)$/)
        print "  " node ": 目印の系統／根拠が定型語（実際の系統名と根拠を書く）"
    }' || true)
  if [ -n "$sys_bad" ]; then
    ges_set FAIL "目印の系統が未定義（網羅性は走査範囲でなく目印の集合で決まる。GP-2 ルール8 / FB-9）" "$sys_bad"
    return
  fi

  # 「分母の 2 経路突合」表を検査する（GP-2 ルール8-4 / ルール9）。
  # 【なぜ必要か】規約は「分母を 2 経路で計算し、集合を要素単位で突合する」と書いており
  # `pipeline.md` のチェック方法にも載っているのに、**それを見るゲートが無かった**（散文のまま）。
  # 単一経路の合算値は検算できず、件数が一致しても集合は一致しない。
  # **`phase1` で見ることが「前倒し」の実体**——終盤で分母が覆ると 2 巡分の巻き戻しになる。
  local tp tp_bad
  # 【行抽出は `^| *NODE` にする】`| NODE` 固定だと `|NODE-EP|…`（空白なし）の行を**無検査で
  # 素通しした**（実測。残り 1 行が正常なら緑になる）。他の表の抽出と同じ緩さに揃える。
  tp=$(awk '/^## 分母の 2 経路突合/{f=1;next} f&&/^## /{exit} f' "$enum" | grep -E '^\|[[:space:]]*NODE' || true)
  if [ -z "$tp" ]; then
    ges_set FAIL "「分母の 2 経路突合」表が無い（単一経路の合算値は検算できない。GP-2 ルール8-4）" \
      "この節は 2026-09-15 に追加した。**それより前に生成したリポジトリには存在しない**ので、
Playbook（$([ -n "$pb" ] && printf '%s' "playbooks/${pb}" || printf '%s' 'playbooks/_template')/enumeration.md）から
節ごとコピーして 01-code-graph/$(basename "$enum") に追記すること。節を消して回避することはできない。"
    return
  fi
  # 列: | ノード種別 | 経路A 定義 | 経路B 定義 | 経路A 実数 | 経路B 実数 | 要素差分 |
  # 【列数を検査する】これを見ていなかったため、**定義列を削って 4 列にすると別のセルを定義と
  # 読んで PASS した**（実測。`da=$3="170"` / `db=$(NF-4)="NODE-EP"`）。列が欠けた表は
  # 「2 経路で数えた」ことを何も保証しない——このゲートの目的そのものが未達だった。
  # 【数値は末尾から数える】定義列に `|` が入ると前から数えた列がずれる（既存の根拠列と同じ対策）。
  # 【全角空白は `-v` で渡す】awk の**リテラル正規表現では八進エスケープが効かない**
  # （実測。教訓 39）。`gsub(/\343\200\200/…)` は無反応で、全角空白 1 文字の差分欄が
  # 「記入済み」として通っていた。`-v` 経由なら効く。
  tp_bad=$(echo "$tp" | awk -F'|' -v WS="$(printf '\343\200\200')" '
    function clean(v) { gsub(/[ \t`]/, "", v); gsub(WS, "", v); return v }
    # 【日本語どうしを == で比べない】macOS の awk は UTF-8 の照合順序で比べるので、`"差分なし" == "—"` が真になる
    # （完走試験で実測。等しくないものを等しいと読む）。長さと位置で比べる（照合順序に依らない）。
    # このブロックは length（文字数）と全角の文字クラスを使うので LC_ALL=C にはしない。
    function eq(a, b) { return (length(a) == length(b) && (length(b) == 0 || index(a, b) == 1)) }
    function unset_val(v) { return (v == "" || v == "-" || eq(v, "—") || v ~ /^<.*>$/ ||
                                    v ~ /^(TBD|不明|未|未定|なし|N\/A|unknown|\?+)$/) }
    # 【「差分ゼロ」の表現を正規化する】`0` `0件` `なし` `差分なし` `一致` `同一` はすべて
    # 「差分は無い」の意味。1 つだけを完全一致で見ていたため、**言い換えるだけで
    # 自己矛盾の検出を回避できた**（実測）。
    # 【補足を許す】完全一致にしていたため `差分なし（comm -3 の出力は空）` のような
    # **より情報量の多い書き方が落ちた**（実測。詳しく書くほど怒られる形だった）。
    function is_zero_diff(v) { return (v ~ /^(0|0件|ゼロ|ゼロ件|差分0件|差分ゼロ|なし|差分なし|差分無し|一致|同一)([（(].*)?$/) }
    # 【要素が列挙されているか】件数だけ・語だけでは検証官が突き合わせられない。
    # 区切り記号で 1 個以上の要素が並んでいることを要求する（量の指定＝FB-6 対策）。
    # 【全角コロンも区切りとして認める】日本語で書かせる欄なのに半角 `:` だけを見ていた（実測）
    function has_elements(v) { return (v ~ /[,、;；]/ || v ~ /[:：][^:：]+$/) }
    { node = $2; gsub(/^[ \t]+|[ \t]+$/, "", node)
      # 表の行は `| a | b | c | d | e | f |` → awk -F"|" で NF=8（先頭と末尾が空）。
      # 定義列に `|` が入ると NF は増えるので**下限**で見る（減っている＝列の欠落は必ず捕まえる）。
      # 【厳密一致にする】下限（`NF < 8`）だと、定義欄に `|` が入って NF が増えたときに
      # **経路A（前基準 `$3`）と経路B（末尾基準 `$(NF-4)`）が別の列を指す**——同一判定が
      # 偽陰性にも偽陽性にもなった（実測）。表にパイプを書かない規約と対で厳密に見る。
      if (NF != 8) { print "  " node ": 列数が合わない（" (NF - 3) " 列。定義 2 列・実数 2 列・差分 1 列。**欄の中にパイプを書かない**——`\\|` でも分割される）"; next }
      diff = clean($(NF-1)); nb = clean($(NF-2)); na = clean($(NF-3)); db = clean($(NF-4)); da = clean($3)
      if (unset_val(da) || unset_val(db)) { print "  " node ": 経路の定義が未記入（数え方が違う 2 経路を書く。分からないときは enumeration.md の探索手順に従う）"; next }
      # 【同じものを 2 回数えても検算にならない】定義が一致していたら 1 経路である。
      if (eq(da, db)) { print "  " node ": 経路A と経路B の定義が同一（同じ数え方を 2 回書いても検算にならない）"; next }
      # 【単一経路しか無い場合の免除】2 経路が原理的に作れない種別が実在する（片側に目印が無い等）。
      # そこで**経路B 定義に「単一経路」と書いた行だけ**実数を免除する。ただし
      # **免除には理由を要求する**（差分欄に 10 文字以上）——`0` や `170` を書かせると
      # **数えていない数値の捏造**になる（SB-4 違反。実測でその形しか通らなかった）。
      # 【否定形を除く】部分一致にしていたため「単一経路ではない」と書いた行で免除が発火した（実測）。
      # 「単一経路にはできない」のような言い方も外す（`な(い|く|ら)` の直前に助詞を挟む形）。
      # 【否定形の除外は助詞で限定する】広く取ったため「単一経路（別経路がない）」
      # 「単一経路しかない」——**免除を要求する最も自然な言い方**——まで落とし、しかも診断が
      # 「単一経路と書け」と既に満たしている条件を指示していた（実測。誰も直せない未達）。
      # 外すのは「単一経路**では**ない／単一経路**で**ない／単一経路に**は**できない」のように
      # **単一経路の直後に否定の助詞が付く形**だけにする。
      if (db ~ /単一経路/ && db !~ /単一経路(では|でな|には?でき|とは?いえ)/) {
        if (length(diff) < 10) { print "  " node ": 経路B を「単一経路」としているが理由が無い（差分欄に、なぜ 2 経路目が作れないかを書く）"; next }
        if (!unset_val(na) && na !~ /^[0-9]+$/) { print "  " node ": 経路A の実数が数値でない（A=" na "）"; next }
        if (unset_val(na)) { print "  " node ": 経路A の実数が未記入（単一経路でも A は数える）"; next }
        next
      }
      if (unset_val(na) || unset_val(nb)) { print "  " node ": 経路の実数が未記入（Phase 1 で数えて書く。2 経路が作れないなら経路B 定義に「単一経路」と書き、差分欄に理由を書く）"; next }
      if (na !~ /^[0-9]+$/ || nb !~ /^[0-9]+$/) { print "  " node ": 経路の実数が数値でない（A=" na " B=" nb "。単位・桁区切りを付けない。**欄の中にパイプがあると列がずれてこの診断になる**——差分欄にコマンドを貼らない）"; next }
      # 【差分欄は「0 件」でも埋めさせる】空欄は「差分なし」と「測っていない」を区別できない
      if (unset_val(diff)) { print "  " node ": 要素差分が未記入（差分が無ければ「0 件」と書く。空欄は測っていないことと区別できない）"; next }
      if (na + 0 != nb + 0) {
        # 実数が違うなら差分は必ず存在する。ゼロを主張したら自己矛盾。
        if (is_zero_diff(diff)) { print "  " node ": 実数が違う（A=" na " B=" nb "）のに要素差分が無いと書いている（どちらかが誤り）"; next }
        # 【量を指定する】件数だけ・語だけでは突き合わせられない。要素名の列挙を要求する。
        if (!has_elements(diff)) { print "  " node ": 要素差分に要素名が無い（「" diff "」）——差 " (na>nb ? na-nb : nb-na) " 件の**要素名を全件**書く"; next }
      } else {
        # 【一致していても差分欄の意味を見る】ここを非空チェックだけで通していたため、
        # **`差分 5 件`（A=B なのに差があると書く自己矛盾）や `確認済み`（自己申告）が素通りした**
        # ——このゲートの看板は「件数一致は集合一致を意味しない」（ルール9）なのに、
        # **その主要ケースだけが検査されていなかった**（実測）。
        # 一致しているなら「差分は無い」と明示するか、要素名を挙げて説明する。
        if (!is_zero_diff(diff) && !has_elements(diff)) {
          print "  " node ": 実数が一致（" na "）しているのに要素差分が「" diff "」——`0 件` と明示するか、要素名を挙げる（件数一致は集合一致を意味しない。ルール9）"; next
        }
      }
    }' || true)
  # 【行を削る回避を塞ぐ】1 行だけ残して他を消せば「その 1 行は正しい」ので通っていた（実測）。
  # **「目印の系統」表の行キー集合を分母**にして、欠けている種別を名指しする
  # （系統表自体は上で記入済みを確認しているので、これが分母として使える）。
  local tp_keys sys_keys tp_missing
  key_of() { printf '%s\n' "$1" | LC_ALL=C awk -F'|' '{ k=$2; gsub(/`/,"",k); gsub(/^[ \t]+|[ \t]+$/,"",k); if (k!="") print k }' | LC_ALL=C sort -u; }
  sys_keys=$(key_of "$sys"); tp_keys=$(key_of "$tp")
  tp_missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$sys_keys") <(printf '%s\n' "$tp_keys") | grep -v '^$' || true)
  if [ -n "$tp_missing" ]; then
    tp_bad="${tp_bad}$(printf '%s\n' "$tp_missing" | sed 's/^/  /; s/$/: 「目印の系統」に在るのに 2 経路突合の行が無い（行の削除による回避）/')"$'\n'
  fi
  # 【両方の表から同じ種別を消す回避を塞ぐ（2026-10-01。E1）】上の検査は「目印の系統」を分母にしているので、
  #  **系統表と 2 経路突合の両方から同じ種別を消すと通った**（1 種別まるごとの分母縮小を誰も見ていなかった）。
  #  外部のアンカーとして、**コードグラフのノード種別と独立ソース表の種別の和集合**を分母にする。
  #  `NODE-MOD`（分母の割当の単位）と `NODE-ID`（実装識別子。G-IDENT が別経路で全数突合）は 2 経路突合の対象ではない。
  #  それ以外を外すなら、2 経路突合の節に `- 対象外: NODE-XXX（理由）` と書く（黙って消さない）。
  #  完走した参照成果物 2 本で、この分母は 2 経路突合の表と一致した（取りこぼし 0）。
  local anchor_kinds exempt_kinds kind_missing
  anchor_kinds=$( { [ -f "$CODEGRAPH" ] && node_rows | LC_ALL=C awk -F'|' '{ k = $2; gsub(/[` \t]/, "", k); if (match(k, /^NODE-[A-Z]+/)) print substr(k, 1, RLENGTH) }'
                    awk '/^## 独立ソース表/{f=1;next} f&&/^## /{exit} f' "$enum" | grep -oE '^[|][[:space:]]*NODE-[A-Z]+' | grep -oE 'NODE-[A-Z]+'; } 2>/dev/null \
                  | grep -vxE 'NODE-(MOD|ID)' | LC_ALL=C sort -u || true)
  exempt_kinds=$(awk '/^## 分母の 2 経路突合/{f=1;next} f&&/^## /{exit} f' "$enum" | strip_html_comments \
                 | grep -E '^[[:space:]]*[-*][[:space:]]*対象外(:|：)[[:space:]]*NODE-[A-Z]+[[:space:]]*(（|\().+(\)|）)' | grep -v '<[^<>]*>' \
                 | grep -oE 'NODE-[A-Z]+' | LC_ALL=C sort -u || true)
  kind_missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$anchor_kinds" | grep .) \
                   <( { printf '%s\n' "$tp_keys" | grep -oE '^NODE-[A-Z]+'; printf '%s\n' "$exempt_kinds"; } | grep . | LC_ALL=C sort -u) || true)
  if [ -n "$kind_missing" ]; then
    tp_bad="${tp_bad}$(printf '%s\n' "$kind_missing" | sed 's/^/  /; s/$/: コードグラフ・独立ソース表に在る種別なのに 2 経路突合の行が無い（系統表ごと消しても分母は縮まない。外すなら「- 対象外: 種別（理由）」）/')"$'\n'
  fi
  if [ -n "$tp_bad" ]; then
    ges_set FAIL "分母が 2 経路で突合されていない（件数一致は集合一致を意味しない。GP-2 ルール8-4 / ルール9）" "$tp_bad"
    return
  fi

  # 実行記録（独立ソースの実数 vs ノード登録数）も検査する。
  # **不在は WARN でなく FAIL**（節ごと削除による回避を許さない。独立ソース表の不在と同格）
  local rec rec_bad
  # 【`exit` を必ず置く】以前は末尾まで読んでいたため、**実行記録より後ろに表を足すと
  # その `| NODE` 行を実行記録の行として数値検査に掛けて誤診 FAIL した**（実測）。
  # 実行記録は最終節なので現状の挙動は変わらないが、**節を足す人が踏む罠を残さない**。
  rec=$(awk '/^## 実行記録/{f=1;next} f&&/^## /{exit} f' "$enum" | grep -E '^\|[[:space:]]*NODE' || true)
  if [ -z "$rec" ]; then
    ges_set FAIL "「実行記録」表が無い（節削除による回避。Phase 1 で実数を記録すること。GP-105 ルール3）"
    return
  fi
  # 実数の妥当性まで検査する: 独立ソース数・ノード登録数が**数値**であること、日付が形式に合うこと。
  # 「TBD」「unknown」等の散文で埋めると通ってしまう穴を塞ぐ（プレースホルダ検査だけでは足りない）。
  # 【重要】実行日は固定インデックス `$6` ではなく **末尾から数えて** 取る。
  # Markdown のセルにパイプを含む文字列（走査コマンドの `grep -E 'A|B'` 等）を書くと
  # 列区切りとして解釈されて列がずれ、**正しい記録を書いたのに「実行日が YYYY-MM-DD でない」と
  # 誤検出する**（偽陽性。ゲートのロジックではなく列位置への依存が原因）。
  # 実行日は表の最終データ列なので `$(NF-1)`（行末の `|` が空フィールドを作るため）で安定して取れる。
  # 実数・登録数は説明列より**手前**にあるため固定インデックスで安全。
  rec_bad=$(echo "$rec" | tr -d '`' | LC_ALL=C awk -F'|' '
    {
      node=$2; src=$3; reg=$4; date=$(NF-1)
      gsub(/^[ \t]+|[ \t]+$/, "", node); gsub(/[ \t]/, "", src)
      gsub(/[ \t]/, "", reg); gsub(/[ \t]/, "", date)
      bad=""
      if (src  !~ /^[0-9]+$/)                 bad = bad " 独立ソース数が数値でない(" src ")"
      if (reg  !~ /^[0-9]+$/)                 bad = bad " ノード登録数が数値でない(" reg ")"
      if (date !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) bad = bad " 実行日が YYYY-MM-DD でない(" date ")"
      if (bad != "") print "  " node ":" bad
    }' || true)
  if [ -n "$rec_bad" ]; then
    ges_set FAIL "列挙の実行記録が未記入または実数でない（独立ソースの実数とノード登録数の突合。SB-2 ルール8）" "$rec_bad"
    return
  fi
  # 差分がある行に説明が書かれているか（「だいたい合っている」で閉じさせない）
  local undoc
  undoc=$(echo "$rec" | tr -d '`' | LC_ALL=C awk -F'|' '
    {
      node=$2; src=$3; reg=$4; note=$5
      gsub(/^[ \t]+|[ \t]+$/, "", node); gsub(/[ \t]/, "", src); gsub(/[ \t]/, "", reg)
      gsub(/^[ \t]+|[ \t]+$/, "", note)
      if (src != reg && (note == "" || note ~ /^(-|—|なし|TBD|unknown)$/))
        print "  " node ": 差分 " src " vs " reg " の説明が無い"
    }' || true)
  if [ -n "$undoc" ]; then
    ges_set FAIL "独立ソースとノード登録数の差分が未説明（1 件でも説明できない差は列挙が不完全。SB-2 ルール8）" "$undoc"
    return
  fi
  # 【分母の粒度の処分（旧 gate_tier (6) の移設先。2026-09-12）】
  # `G-DENOM` の PASS は「分母を使い切った」ことしか言わず「**分母が正しい**」ことは言わない。
  # 実運用では終盤でこれに気づき、入口の定義が狭かったため**分母を拡張して 2 巡（約 2 日）を追加**した。
  # 【なぜここに移したか】この検査は `enumeration.md` の**実行記録の表**を読む。
  # `G-ENUM-SOURCE` は**同一ファイル・同一表**を読んでおり（上の `rec` / `undoc`）、
  # `G-DENOM` は `code-graph.md`＝**別ファイル**である。当初 `G-DENOM` を移設先に選んだのは誤りだった。
  # 【無条件にする】元は `DENSITY_TIER >= 2` でのみ発火していたが、  [撤去の記録]
  # **「処分せよ」は tier に依存せず、tier が決めていたのは「いつ処分するか」だけ**である。  [撤去の記録]
  # 無条件化のコストは参照成果物で **1 件**（DDL 33 表を 3 ノードに集約＝この検査が想定した失敗そのもの）。
  # 【なぜ「説明あり」では足りないか】上の `undoc` は説明の**有無**しか見ない。
  # 集約は「粒度の決定」なので**説明（＝観察）ではなく ADR（＝決定）を要求する**。
  local granularity
  granularity=$(echo "$rec" | tr -d '`' | LC_ALL=C awk -F'|' '
    { node=$2; src=$3; reg=$4; note=$5
      gsub(/^[ \t]+|[ \t]+$/, "", node); gsub(/[ \t,]/, "", src); gsub(/[ \t,]/, "", reg)
      if (src !~ /^[0-9]+$/ || reg !~ /^[0-9]+$/) next
      # 【処分の判定】ADR 番号の言及だけでは足りない。実測で、粒度とは無関係な ADR
      # （スコープ確定の `ADR-1`）が説明文に含まれていたため**集約が処分済みと誤判定**された。
      has_adr = (note ~ /ADR-[0-9]+/ && note ~ /粒度|実装できる|この単位/)
      # 【集約を示す語がある行だけを対象にする（2026-09-12 無条件化に伴う修正）】
      # 元の (i) は「実数に差があれば」発火していたが、**無条件化して tier 1 でも走るようにした結果、  [撤去の記録]
      # 集約でない差（「差 1 = 対象外（ADR-3）」のようなスコープ除外）まで拾って偽陽性を出した**。
      # 差の説明の有無は既に上の `undoc` が検査している。ここで追加で問うのは
      # **「集約という粒度の決定なのに ADR が無い」ことだけ**である。よって集約語を発火条件にする。
      # 【否定文を除く】実運用で「集約**していない**」でも発火した（偽陽性）。
      is_aggr = (note ~ /集約|束ね|まとめ/ \
                 && note !~ /集約(して|でも)?(い)?な|束ね(て|ては)?(い)?な|まとめ(て|ては)?(い)?な|集約ではな|重複計上/)
      if (!is_aggr || has_adr) next
      # (i) 実数の差として現れた集約
      if (src != reg) {
        print "  " node ": 独立ソース " src " に対しノード " reg "（差 " (src-reg) "）を集約と説明。ADR で粒度を宣言すること"
        next
      }
      # (ii) 実数が一致しているのに散文で集約を述べている行（規約より前に作られた記録への保険。
      #      実測: 69→16 の集約が「16 = 16」と記録され差が 0 になっていた）。
      print "  " node ": 実数は一致だが説明が集約を述べている（" src " = " reg "）。ADR で粒度を宣言すること"
    }' || true)
  if [ -n "$granularity" ]; then
    ges_set INCOMPLETE "分母の粒度が未処分（集約を ADR で宣言していない。GP-2 ルール8-7 / FB-14）" "$granularity"
  else
    ges_set PASS "列挙の独立ソース表と実行記録が記入済み（分母が定義され実数で突合済み・粒度も処分済み）"
  fi
}

# 【併用（GP-105 ルール11）】`init.sh --playbook A --playbook B` は B を `enumeration-B.md` に置く。
# 検査は 1 ファイルずつ同じ規則で行い、**判定は 1 件だけ出す**（同じゲート ID を複数回 report すると
# G-REGRESS の判定履歴が重複する）。最も悪い判定を採り、どのファイルかを説明の先頭に書く。
# 【従の名前は 1 か所から取らない】`PLAYBOOKS` だけを信じると、**その 1 行を書き換えてファイルを消す**だけで
# 検査が消える（反証レビューの実測）。次をすべて集め、どれか 1 つにでも載った名前のファイルを要求する:
#   (1) 現在の `PLAYBOOKS`  (2) 初期コミットの gate-config.env の `PLAYBOOKS`（PURPOSE_INITIAL と同じ考え方）
#   (3) 配置の痕跡 `03-audit/gate-snippets-<名前>.sh` / `docs/knowledge/playbook-<名前>.md`（主の名前を除く）
#   (4) ディスクの `enumeration-*.md`（手で足した併用）
# 主は位置でなく**名前**で除く（`PLAYBOOKS` の 1 つ目が主とは限らない編集を受けても従を落とさない）。
GES_ST="" GES_DESC="" GES_DETAIL=""
ges_set() { GES_ST="$1"; GES_DESC="$2"; GES_DETAIL="${3:-}"; }
ges_add() { # $1=名前 → 未登録なら従として加える（呼び出し元の files / pbs / listed / badnames を更新）
  local n="$1"
  [ -n "$n" ] || return 0
  [ "$n" != "${PLAYBOOK:-}" ] || return 0
  case "$listed" in *" ${n} "*) return 0 ;; esac
  listed="${listed}${n} "
  case "$n" in
    *[!A-Za-z0-9._-]*) badnames="${badnames}  ${n}"$'\n'; return 0 ;;
  esac
  files+=("$CODEGRAPH_DIR/enumeration-${n}.md"); pbs+=("$n")
}
# 【主の名前を語のまとまりのまま除いてから分割する】主は外部パスなら空白を含む名前を受ける（init.sh）が、
# PLAYBOOKS は空白区切りなので、そのまま分割すると `my pb` が従の `my` と `pb` に化け、存在しない
# enumeration-my.md / enumeration-pb.md を要求して必ず FAIL する（MR レビューの実測）。従の名前は init.sh が
# 空白を拒むので、除くのは主だけでよい。位置でなく名前で除く（主が 1 つ目とは限らない編集を受けても従を落とさない）
# 除くのは 1 回だけ（主は 1 つ。繰り返すと主 `x y` のとき従の `x` `y` まで消える）。パターン置換 `${v/ "$p" / }` は
# 引用の扱いが bash の版で揺れうるので使わず、`case` の一致と `%%` / `#` の切り出し（引用部は文字どおり）で書く（macOS は bash 3.2）
ges_strip_primary() { # $1=PLAYBOOKS の値 → 主の名前を除いた残り
  local v=" $1 " p="${PLAYBOOK:-}"
  [ -n "$p" ] || { printf '%s' "$1"; return 0; }
  case "$v" in
    *" $p "*) printf '%s' "${v%%" $p "*} ${v#*" $p "}" ;;
    *) printf '%s' "$1" ;;
  esac
}
gate_enumeration_source() {
  local files=() pbs=() f name i rank worst=0 wst="PASS" wfile="" wdesc="" wdetail="" others="" listed=" " badnames=""
  local _pbl=() _r _ini
  files+=("$CODEGRAPH_DIR/enumeration.md"); pbs+=("${PLAYBOOK:-}")
  # (1) 現在の PLAYBOOKS（read -a は glob 展開しない。`for x in $PLAYBOOKS` は `*` を展開する）
  read -r -a _pbl <<< "$(ges_strip_primary "$PLAYBOOKS")" || true
  for name in "${_pbl[@]+"${_pbl[@]}"}"; do ges_add "$name"; done
  # (2) 初期コミットの PLAYBOOKS（root は全部。shallow なら HEAD が返るだけで、(1) と同じ値になる）
  for _r in $(git -C "$REPO_ROOT" rev-list --max-parents=0 HEAD 2>/dev/null || true); do
    _ini=$(git -C "$REPO_ROOT" show "${_r}:spec-extraction/00-ingestion/gate-config.env" 2>/dev/null \
           | grep -E '^[[:space:]]*(export[[:space:]]+)?PLAYBOOKS=' | tail -1 \
           | sed 's/.*PLAYBOOKS=//; s/[[:space:]]*#.*//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//' || true)
    _pbl=(); read -r -a _pbl <<< "$(ges_strip_primary "$_ini")" || true
    for name in "${_pbl[@]+"${_pbl[@]}"}"; do ges_add "$name"; done
  done
  # (3) 配置の痕跡
  for f in "$CODEGRAPH_DIR/../03-audit"/gate-snippets-*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"; ges_add "${name#gate-snippets-}"
  done
  for f in "$CODEGRAPH_DIR/../docs/knowledge"/playbook-*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"; name="${name#playbook-}"
    # 主の README は playbook-<主>.md。主の名前は ges_add が除く
    ges_add "$name"
  done
  # (4) ディスクの enumeration-*.md
  for f in "$CODEGRAPH_DIR"/enumeration-*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"; ges_add "${name#enumeration-}"
  done
  if [ -n "$badnames" ]; then
    report FAIL G-ENUM-SOURCE "併用の Playbook 名に使えない文字がある（英数字と . _ - のみ。GP-105 ルール11）" "$badnames"
    return
  fi
  i=0
  while [ "$i" -lt "${#files[@]}" ]; do
    GES_ST="" GES_DESC="" GES_DETAIL=""
    enum_source_one "${files[$i]}" "${pbs[$i]}"
    case "$GES_ST" in PASS) rank=0 ;; INCOMPLETE) rank=1 ;; *) rank=2 ;; esac
    if [ "$rank" -gt "$worst" ]; then
      [ -z "$wfile" ] || others="${others}  ${wfile}（${wst}）"$'\n'
      worst=$rank wst="$GES_ST" wfile="$(basename "${files[$i]}")" wdesc="$GES_DESC" wdetail="$GES_DETAIL"
    elif [ "$rank" -gt 0 ]; then
      others="${others}  $(basename "${files[$i]}")（${GES_ST}）"$'\n'
    fi
    i=$((i + 1))
  done
  if [ "$worst" -eq 0 ]; then
    if [ "${#files[@]}" -gt 1 ]; then
      report PASS G-ENUM-SOURCE "列挙の独立ソース表と実行記録が記入済み（併用 ${#files[@]} ファイルすべて。分母が定義され実数で突合済み・粒度も処分済み）"
    else
      report PASS G-ENUM-SOURCE "列挙の独立ソース表と実行記録が記入済み（分母が定義され実数で突合済み・粒度も処分済み）"
    fi
    return
  fi
  # 【他の未完ファイルは説明文に出す】詳細は DETAIL_MAX 行で切られるので、詳細の後ろに足すと
  # 主の詳細が長いときに端末から消える（反証レビューの指摘）
  local others_inline=""
  [ -z "$others" ] || others_inline="（他にも未完: $(printf '%s' "$others" | sed 's/^  //' | tr '\n' ' ' | sed 's/ *$//')）"
  report "$wst" G-ENUM-SOURCE "${wfile}: ${wdesc}${others_inline}" "$wdetail"
}

gate_enumeration_recorded() {
  local trace="$AUDIT/traceability.md"
  [ -f "$trace" ] || { report FAIL G-ENUM "traceability.md が存在しない"; return; }
  # §2c の表行（| 独立ソース... 以降のデータ行）で「実行結果」列（最終列）が空のものを検出
  local section
  # 【重要】awk の**範囲式は使わない**。範囲式は開始・終了パターンを同一レコードで評価するため、
  # 開始行「## 2c. 列挙完全性の突合」が終了パターン `^## [0-9]` にも一致し、**その行で範囲が即終了する**
  # （＝表を実データで埋めても「表が見つからない」WARN が出続ける）。
  # 最悪なのは、この WARN の文言が「突合を実施していない」場合と同じで、
  # **列挙完全性の突合をサボっても機械検出されない**＝ゲートの存在意義が消えることである。
  # 本ファイルの他の節切り出しは全てフラグ方式で、ここだけが取り残されていた（同型バグの水平展開漏れ）。
  # データ行の選択は **`| NODE` で始まる行**に限る。以前は `grep -v '独立ソース'` で
  # ヘッダを除いていたが、本文セルに「独立ソース」と書いた行が**黙って検査対象から落ちる**
  # （＝記入したのに検査されない／未記入なのに検出されない）。行頭の種別名で選ぶ方が回避不能。
  section=$(awk '/^## 2c\./{f=1;next} f&&/^## [0-9]/{exit} f' "$trace" | grep '^| *NODE' || true)
  # 表が無いのは「欠陥」であって警告ではない。WARN にすると「突合していない」場合と
  # 区別がつかず、素通りする（このゲートの存在意義が消える。GP-6 ルール7）。
  [ -z "$section" ] && {
    report FAIL G-ENUM "§2c（列挙完全性）に \`| NODE...\` のデータ行が無い" \
      "独立ソースの実数とノード登録数を転記すること（正本は 01-code-graph/enumeration.md）"
    return; }
  # 【重要】**空欄検査だけでは雛形が素通りする。** 雛形の各セルには `<N>` `<M>` 等の
  # プレースホルダが入っており、「空でない」ので PASS になっていた（実測: init.sh 直後の
  # 未記入 traceability.md で G-ENUM が PASS した）。空欄とプレースホルダの両方を見る。
  # 判定材料は G-ENUM-SOURCE と同じ「雛形の固定語の実在」（`<...>` の有無では判定しない）。
  local bad
  bad=$(echo "$section" | grep -nE '<(N|M|同上[^>]*|差があれば[^>]*|enumeration\.md[^>]*)>' \
    | sed 's/^/  プレースホルダ残存: /' || true)
  # 列は NF 相対で取る（先頭に列を足されても、セル内の `|` はエスケープ前提。既存の他ゲートと同じ規約）。
  # 末尾 `|` があるため $NF は空。$(NF-1)=差分の説明 / $(NF-2)=ノード登録数 / $(NF-3)=独立ソースの実数。
  [ -n "$bad" ] && bad="${bad}
"
  bad="${bad}$(echo "$section" | LC_ALL=C awk -F'|' '
    { node=$2; real=$(NF-3); reg=$(NF-2); diff=$(NF-1)
      gsub(/^[ \t]+|[ \t]+$/, "", node)
      gsub(/[ \t`,]/, "", real); gsub(/[ \t`,]/, "", reg); gsub(/[ \t]/, "", diff)
      if (real !~ /^[0-9]+$/) print "  " node ": 独立ソースの実数が数値でない(" real ")"
      else if (reg !~ /^[0-9]+$/) print "  " node ": ノード登録数が数値でない(" reg ")"
      else if (diff == "" || diff == "-" || diff == "—") print "  " node ": 差分の説明が空（差が無いなら「差分なし」と書く）"
    }' || true)"
  if [ -z "$bad" ]; then
    report PASS G-ENUM "列挙完全性（§2c）が実数で突合済み"
  else
    report FAIL G-ENUM "列挙完全性の突合が未完（独立・全走査の列挙と件数突合を実施し実数で記録すること）" "$bad"
  fi
}

# --- G-INDEP: 高影響宣言の独立検証の記録（SB-12。記録欄の存在検査） ---
gate_independent_verification() {
  local readiness="$AUDIT/rebuild-readiness.md"
  local trace="$AUDIT/traceability.md"
  local unfilled=""
  for f in "$readiness" "$trace"; do
    [ -f "$f" ] || continue
    # 「独立検証の記録」欄に <...> プレースホルダが残っていれば未実施。
    # 【アンカーを見出しパターンに固定する】素の `独立検証の記録` で拾うと、最初に当たるのは
    # **チェックリスト行**（「…下記『独立検証の記録』に残した」）で、**本来の記入欄が永久に
    # 検査されなかった**（欠陥注入で、この枝の処理を消しても検査が 1 件も赤くならないことを確認）。
    # 検証範囲側で既に採っている規律（アンカーを `^- **…` に固定する）と揃える。
    # 【`head -1` にしない（すべての欄を見る）】先頭だけ見た初版は、**2 つ目以降の記録欄が
    # 一切検査されなかった**（参照成果物は検証範囲ブロックを 3 個持つ）。逆に先頭に古い不完全な
    # ブロックが来ると完成品が落ちるという、両方向に壊れる形だった。
    # 【欄名は 2 通り受ける】`traceability.md` 側の雛形の欄名は
    # `- **高影響宣言の独立検証（SB-12…）**:` で、`独立検証の記録` に一致しない
    # ——固定したアンカーだけを見た初版は **traceability 側のループが空回り**していた。
    local hits
    hits=$(LC_ALL=C grep -n '^- \*\*\(独立検証の記録\|高影響宣言の独立検証\)' "$f" || true)
    if [ -z "$hits" ]; then
      # 【両ファイルで不在を未達にする】`rebuild-readiness.md` だけ未達にした初版は、
      # **traceability 側は欄を削除するか字下げするだけで検査ごと消えた**。
      # 手順書は「traceability §4b・rebuild-readiness の両方に残す」と要求しているので揃える。
      unfilled+="${f#"$REPO_ROOT"/}: 独立検証の記録の欄が存在しない（削除による回避。SB-12）"$'\n'
    else
      local line_no record
      while IFS= read -r h; do
        [ -n "$h" ] || continue
        line_no="${h%%:*}"
        # 【1 行だけ見ない】`sed -n "Np"` で 1 行だけ見た初版は、**記録欄が複数行のとき
        # 2 行目以降のプレースホルダを見逃した**（実データの記録欄は最大 8 行に渡る）。
        # 窓は検証範囲と同じ「次のトップレベル項目（`- ` 始まり）か見出しまで」に揃える。
        record=$(awk -v start="$line_no" 'NR==start { print; next }
                                         NR>start { if (/^- / || /^#/) exit; print }' "$f")
        # 【コード表記を剥がしてから判定する】`` `<file>:<line>` `` のように**例示として書いた山括弧**を
        # 「未記入」と誤検出した（効果測定の実測）。記述を変えるしか回避手段が無い偽陽性だった。
        record=$(printf '%s\n' "$record" | strip_html_comments | strip_code_spans)
        # 【語彙を列挙しない】`<手段` / `<実施者` / `<結果` / `<...>` だけを見た初版は、
        # 配布雛形の実文（`実施手段 <別エージェント反証 / …>`）に**当たらず部分記入で緑になった**。
        # 検証範囲側と同じ「コード表記を剥がした後に残る `<...>`」に揃える（非対称を消す）。
        if printf '%s\n' "$record" | grep -q '<[^>]*>'; then
          unfilled+="${f#"$REPO_ROOT"/}:${line_no}: 独立検証の記録が未記入（未実施なら「未検証（暫定）」と明示すること）"$'\n'
        fi
      done <<EOF
$hits
EOF
    fi
    # 検証範囲（GP-16 ルール10 / FB-6）: 「実施した」だけの記録を許さない。
    # 母集団の 0.6% を意図的に選んだ標本で「レディ」を宣言し、後の層化無作為抽出で
    # 誤り率 29.2% が判明した失敗の対策。
    #
    # 設計上の注意（初版の 3 つの穴を塞いだ形。GP-6: ゲートのコマンド自体を検証する）:
    #  (1) 節ごと削除で回避されないよう、**欄の不在を FAIL にする**（不在＝スキップにしない）
    #  (2) アンカーは見出しパターン `^- **検証範囲` に固定する（本文中の「検証範囲」という語に
    #      引っかかると窓が外れる。初版は同じ diff で足した説明文に当たって 5 項目中 1 項目しか見ていなかった）
    #  (3) 窓は固定行数でなく「次のトップレベル項目まで」の範囲で取る（行を 1 行足すと外れる問題の回避）
    # rebuild-readiness.md のみ対象（traceability.md には検証範囲欄が無い）
    case "${f##*/}" in
      rebuild-readiness.md) ;;
      *) continue ;;
    esac
    # 【`head -1` にしない（すべてのブロックを見る）】先頭だけ見た初版は、参照成果物が持つ
    # **3 個の検証範囲ブロックのうち 2 個を一切検査しなかった**。逆に先頭に古い不完全ブロックが
    # 来ると完成品が落ちる——両方向に壊れていた。
    local scope_line
    scope_line=$(grep -n '^- \*\*検証範囲' "$f" || true)
    if [ -z "$scope_line" ]; then
      unfilled+="${f#"$REPO_ROOT"/}: 検証範囲の欄が存在しない（削除による回避。GP-16 ルール10, FB-6）"$'\n'
    else
      local s_no scope_body scope_nocomment scope_stripped
      while IFS= read -r sl; do
        [ -n "$sl" ] || continue
        s_no="${sl%%:*}"
      # 見出しの次行から、次のトップレベル項目（'- ' 始まり）か見出し（'#'）までを窓にする
      scope_body=$(awk -v start="$s_no" 'NR>start { if (/^- / || /^#/) exit; print }' "$f")
      # 【HTML コメントは本文ではない】コメントを残したまま語の有無を見た初版は、
      # `<!-- 母集団: … / 検証件数: … / 標本の選び方 / 層別 / 誤りの分類 -->` を窓に置くだけで
      # **5 項目が充足**した（文書上は何も主張していない）。語の判定はコメント除去後で行う。
      scope_nocomment=$(printf '%s\n' "$scope_body" | strip_html_comments)
      # 【ここでは表の行もコード表記を剥がす】表の行を残した初版は、**窓内の表セルに
      # `` `<file>:<line>` `` を書くと未記入と誤検出**した（実運用で踏み、記述を変えるしか
      # 回避手段が無いと記録されていた偽陽性）。ここで剥がしても、下の「量の要求」が
      # 囲むだけの回避を塞ぐので穴にならない（`G-RECON` の表とは要求が違う）。
      scope_stripped=$(printf '%s\n' "$scope_nocomment" | strip_code_spans)
      # プレースホルダ（<...>）または未記入の定型語が残っていれば未記入とみなす
      if echo "$scope_stripped" | grep -q '<[^>]*>' \
         || echo "$scope_stripped" | grep -qE '(^|[[:space:]])(TBD|TODO|N/A|未記入|未定|後で)([[:space:]]|$)'; then
        unfilled+="${f#"$REPO_ROOT"/}:${s_no}: 検証範囲が未記入（母集団・件数・割合・標本の選び方・層別結果。GP-16 ルール10, FB-6）"$'\n'
      fi
      # 【量の裏付けを要求する（コード表記で囲むだけの回避を塞ぐ。FB-6）】
      # 上の `<...>` 判定はコード表記を剥がしてから行うので、**プレースホルダをバッククォートで
      # 囲むだけで通る**（実測: `` `<母集団の定義>` `` = `` `<N>` `` 行 で INCOMPLETE → PASS になった）。
      # 「実施した」だけの記録を許さないというこのゲートの目的は**量が書いてあること**なので、
      # 量を持つ 2 項目には**コード表記とプレースホルダを除いた上で数字を要求する**（不在＝未記入）。
      # 【「量でないもの」を引き算しない（量の形を正面から要求する）】
      # ID・日付・節番号を引き算する方式にした初版は、**列挙が終わらなかった**——
      # 和式日付（`2026年9月21日`）・空白入りの `ルール 10`・`第3章`・`(1)` がすべて量として通り、
      # 逆に**全角数字の正当な量（`１６４ 行`）が落ちた**。⇒ **数字＋単位**を要求する
      # （実測: 参照成果物 3 本の 5 ブロック 10 項目すべてが充足し、攻撃形 5 つはすべて却下）。
      # 既知の弱点: `95% CI` のような**量でない百分率**は通る（単位の列挙ではこれ以上絞れない）。
      # 【項目の窓で見る（キーワード行だけを見ない）】キーワード行だけを見た初版は、
      # `- **母集団の定義と件数**:` の**次行に数を書く自然な整形**で未達になった。
      local kw_missing_qty=""
      for kw in 母集団 検証件数; do
        local kw_line
        # キーワードを含む行から、次の項目（`- ` 始まり）までを 1 項目の窓とする
        kw_line=$(printf '%s\n' "$scope_nocomment" | LC_ALL=C awk -v kw="$kw" '
          index($0, kw) > 0 { w = 1; print; next }
          w { if ($0 ~ /^[ \t]*- /) w = 0; else print }')
        kw_line=$(printf '%s\n' "$kw_line" | strip_code_spans | LC_ALL=C sed 's/<[^>]*>//g' \
                    | LC_ALL=C sed 's/０/0/g;s/１/1/g;s/２/2/g;s/３/3/g;s/４/4/g;s/５/5/g;s/６/6/g;s/７/7/g;s/８/8/g;s/９/9/g;s/％/%/g')
        printf '%s\n' "$kw_line" | LC_ALL=C grep -qE '[0-9]+ *(件|行|個|本|語|%|／|/)' \
          || kw_missing_qty+="${kw} "
      done
      if [ -n "$kw_missing_qty" ]; then
        unfilled+="${f#"$REPO_ROOT"/}:${s_no}: 検証範囲に量が書かれていない（${kw_missing_qty}に「数字＋単位（件 / 行 / 個 / 本 / 語 / % / ／）」が無い。コード表記で囲んだプレースホルダは量とみなさない。GP-16 ルール10, FB-6）"$'\n'
      fi
      # 5 項目すべてが揃っているか（項目ごと削除して 1 行だけ埋める回避を防ぐ）
      # 【語の有無はコード表記を剥がす前の本文で見る】strip 後で見た初版は、**項目名をコード表記で
      # 書いた瞬間に「欠落」**になった（文書にはその語が見えているのに欠落と言う＝塞いだはずの偽陽性の再発）。
      local missing_fields=""
      for kw in 母集団 検証件数 標本の選び方 層別 誤りの分類; do
        echo "$scope_nocomment" | grep -q "$kw" || missing_fields+="${kw} "
      done
      if [ -n "$missing_fields" ]; then
        unfilled+="${f#"$REPO_ROOT"/}:${s_no}: 検証範囲の項目が欠落（${missing_fields}。GP-16 ルール10）"$'\n'
      fi
      done <<EOF
$scope_line
EOF
    fi
  done
  if [ -z "$unfilled" ]; then
    report PASS G-INDEP "独立検証の記録欄と検証範囲が記入済み（内容の妥当性は SB-12 の段階的縮退で担保）"
  else
    report INCOMPLETE G-INDEP "独立検証の記録・検証範囲が未記入のまま（自己申告での完了/レディ宣言は SB-12 違反）" "$unfilled"
  fi
}

# --- G-INDEX: specs/index.md の存在と整合（GP-9 ルール8） ---
gate_index() {
  if [ ! -f "$SPECS/index.md" ]; then
    report FAIL G-INDEX "specs/index.md（SPEC-ID → ファイルパス索引）が存在しない"
    return
  fi
  # front-matter の全 spec-id が index に載っているか
  local missing=""
  while IFS= read -r id; do
    grep -q "$id" "$SPECS/index.md" || missing+="index 未掲載: ${id}"$'\n'
  # 【機械生成の索引は除く】`gates.sh source-index` の生成物（spec-id: SPEC-source-index）まで要求すると、
  # 自分の生成物で自分のゲートが落ちる（実運用で、手で index.md に足す回避が要った）。他の本文の検査と同じ content_spec_files を使う
  done < <(content_spec_files | nul_pack | xargs -0 -r grep -h '^spec-id: ' 2>/dev/null | sed 's/spec-id: //' | grep -v 'TEMPLATE-DO-NOT-INDEX' | sort -u)
  if [ -z "$missing" ]; then
    report PASS G-INDEX "specs/index.md が存在し、全 spec-id が掲載されている"
  else
    report FAIL G-INDEX "index.md に未掲載の spec-id あり" "$missing"
  fi
}

# --- G-DENSITY: 密度ゲート（SB-18/GP-20/GP-21。required-sections の存在＋非空検査） ---
# 機械化の割り切り: 担保できるのは「必須節が存在し空でない」という密度の床まで。
# 「中身が実装に足るか・引用が正しいか」は GP-22 の Verify（別コンテキスト突合）の領分。
gate_density() {
  local mode="$1"   # on | warn
  local violations=""
  local checked=0
  # テンプレ→実仕様の対応付け:
  #  - 専用テンプレ（_<key>-template.md）→ 同じ artifact-key を持つ実仕様
  #  - 汎用テンプレ（_template.md）      → 同ディレクトリで artifact-key を持たない実仕様
  while IFS= read -r tmpl; do
    local req_line
    req_line=$(grep -o 'required-sections: [^-]*' "$tmpl" | head -1 | sed 's/required-sections: //; s/ *-*$//')
    [ -z "$req_line" ] && continue
    local cat_dir tmpl_key
    cat_dir=$(dirname "$tmpl")
    tmpl_key=$(grep -o 'artifact-key: [a-z0-9-]*' "$tmpl" | head -1 | sed 's/artifact-key: //')
    # 対応する実仕様を列挙
    local targets
    if [ -n "$tmpl_key" ]; then
      targets=$(grep -rlE "$(artifact_key_re "$tmpl_key")" "$SPECS" 2>/dev/null | grep -v '/_[^/]*$' || true)
    else
      targets=$(find "$cat_dir" -name '*.md' -not -name '_*' 2>/dev/null \
                | nul_pack | xargs -0 -r grep -LE "$ARTIFACT_KEY_ANY_RE" 2>/dev/null || true)
    fi
    while IFS= read -r spec; do
      [ -z "$spec" ] && continue
      checked=$((checked + 1))
      local IFS_OLD="$IFS"
      IFS=','
      for section in $req_line; do
        # 前後空白を除去
        section=$(echo "$section" | sed 's/^ *//; s/ *$//')
        [ -z "$section" ] && continue
        # 見出しの存在（部分一致: 「## 契約」内の「### parameters（全項目...）」等に対応）
        local head_line
        # 【H1 は題名なので見ない（2026-10-01）】題名の中の語に先に当たり、本物の節の代わりに題名の直後を「空」と判定した。
        head_line=$(grep -n "^#\{2,4\} .*${section}" "$spec" | head -1 | cut -d: -f1)
        local head_lvl
        head_lvl=$(sed -n "${head_line:-0}p" "$spec" 2>/dev/null | sed 's/^\(#*\).*/\1/' | awk '{print length($0)}')
        if [ -z "$head_line" ]; then
          violations+="${spec#"$REPO_ROOT"/}: 必須節「${section}」の見出しが無い"$'\n'
          continue
        fi
        # 節の非空: 見出しから次見出しまでに、コメント/空行/表罫線以外の実データ行が ≥1
        local body
        # 【同じかより浅い見出しまでを本文とする（2026-10-01）】次の見出しで切っていたため、直後に `###` の小節が来ると
        #  その節は「空」と判定された（小節が中身なのに）。小節の**中身**を数え、見出し行そのものは数えない
        #  （空の小節の見出しだけで「非空」にしない）。
        body=$(awk -v start="$head_line" -v L="${head_lvl:-4}" 'NR > start { if (match($0, /^#+ /) && RLENGTH - 1 <= L) exit; print }' "$spec" \
               | strip_html_comments \
               | grep -v '^[[:space:]]*$' | grep -v '^|[-| ]*|$' | grep -vE '^#+ ' || true)
        if [ -z "$body" ]; then
          violations+="${spec#"$REPO_ROOT"/}: 必須節「${section}」が空（見出しのみ）"$'\n'
        fi
      done
      IFS="$IFS_OLD"
    done <<< "$targets"
  done < <(find "$SPECS" \( -name '_template.md' -o -name '_*-template.md' \) 2>/dev/null)

  if [ "$checked" -eq 0 ]; then
    report SKIP G-DENSITY "検査対象の実仕様がまだ無い"
  elif [ -z "$violations" ]; then
    report PASS G-DENSITY "全実仕様（${checked} 件）が必須節（required-sections）を満たす（密度の床）"
  elif [ "$mode" = "warn" ]; then
    report WARN G-DENSITY "必須節の欠落/空あり（purpose=${PURPOSE} のため警告のみ）" "$violations"
  else
    report FAIL G-DENSITY "必須節の欠落/空あり（$(echo -n "$violations" | grep -c .) 件）。密度未達のまま「レディ」宣言不可（SB-18）" "$violations"
  fi
}

# --- G-SYMMETRY-D: カテゴリ密度の対称性（SB-17。行数は代理指標＝WARN まで） ---
gate_density_symmetry() {
  local stats=""
  local min_avg=999999 max_avg=0 min_cat="" max_cat=""
  for c in modules api data behavior rebuild; do
    local files count total avg
    files=$(find "$SPECS/$c" -name '*.md' -not -name '_*' 2>/dev/null)
    count=$(echo "$files" | grep -c . || true)
    [ "$count" -eq 0 ] && continue
    total=$(echo "$files" | sum_lines)
    avg=$((total / count))
    stats+="${c}: ${count} ファイル・平均 ${avg} 行"$'\n'
    if [ "$avg" -lt "$min_avg" ]; then min_avg=$avg; min_cat=$c; fi
    if [ "$avg" -gt "$max_avg" ]; then max_avg=$avg; max_cat=$c; fi
  done
  [ -z "$stats" ] && { report SKIP G-SYMMETRY-D "実仕様がまだ無い"; return; }
  # 最薄カテゴリが最厚の 1/5 未満なら昇格漏れの疑い（SB-17: 行数は代理・真の判定は G-DENSITY の必須節）
  if [ "$max_avg" -gt 0 ] && [ $((min_avg * 5)) -lt "$max_avg" ]; then
    report WARN G-SYMMETRY-D "カテゴリ密度の非対称: ${min_cat}（平均 ${min_avg} 行）が ${max_cat}（平均 ${max_avg} 行）の 1/5 未満＝地図のまま昇格されていない疑い（SB-17）" "$stats"
  else
    report PASS G-SYMMETRY-D "カテゴリ密度に極端な非対称なし" "$stats"
  fi
}

# --- G-LEDGER: 密度台帳の Verify 集計（GP-22 / SB-20 / SB-21。TSV 正本から機械集計） ---
# --- 台帳の「外」からの突合（旧 `gate_tier` (8a) の移設先。2026-09-13） ---
# 【何を塞ぐか】`GP-22` ルール2 は「Verify を通していない密度ブロックを完了と呼ばない」を要求するが、
# **台帳の中身だけを見ていると「そもそも 1 ブロックも登録されていない仕様」を検出できない**
# （実運用で密度ブロック 0 件のまま tier 2 を宣言できた）。台帳の外側＝仕様ファイル側から突合する。  [撤去の記録]
#
# 【発火条件】**`path:line` 主張または表形式の主張を 1 件以上持つ仕様**に限る。
# 引用が無い仕様（技術非依存の NFR 等）は裏取りする対象が無い——実測で引用 0・マーカー 0 の仕様に
# 登録を要求すると**誰も直せない未達**になった（主張 0 のブロックは `G-BLOCK-SIZE` が拒否する）。
# **台帳の有無・空/非空は条件にしない**（それを条件にすると塞ぐべき状態そのものを除外する）。
#
# 【刻印を述語にしない】旧実装は `density-tier` の刻印 2 以上に限っていたため、`GP-104` の撤去で  [撤去の記録]
# 刻印が消えると**検査ごと消える**。主張の有無は tier の概念に依存しない。  [撤去の記録]
#
# 【主張の定義は正本に合わせる】`path:line` を含む行 **＋ 先頭がコード表記の表データ行**
# （`GP-103` ルール1 / 台帳定義の注記）。実測で、表形式で 86 件の主張を持つ索引仕様が
# `G-BLOCK-OUTSIDE` には計上されるのに本検査では免除される、という食い違いが出た。
# 【`[[:space:]]` を使う】`grep` のブラケット式に `\t` を書くと BSD で効かない（教訓 29）。
#
# 出力: LU_N（未登録の件数）／ LU_DETAIL（名指しの詳細行）。**呼び出し元より前に評価する。**
LU_N=0
LU_DETAIL=""
LU_HAVE=0        # 主張を持つ仕様を 1 件以上列挙できたか（0 件と「測れなかった」を区別する）
ledger_unregistered() {
  LU_N=0; LU_DETAIL=""; LU_HAVE=0
  local ledger="$AUDIT/density-ledger.tsv" errf cs_tmp claim_specs rc=0
  # 【`mktemp` の rc を見る】失敗すると `errf` が空になり `2>""` のリダイレクトごと失敗して
  # **grep が実行されず `[ -s "" ]` も偽なので fail-closed の門を素通りする**（実測で虚偽の PASS）。
  # `gates.sh` 冒頭の設定読み込みが同じ罠を明文で禁じている（そこでは rc を見て exit 2 している）。
  errf="$(mktemp "${TMPDIR:-/tmp}/gates-lu-err.XXXXXX")" || {
    LU_N=-1; LU_DETAIL="  一時ファイルを作成できない（TMPDIR=${TMPDIR:-/tmp} を確認する）"; return; }
  # 【対象から外す 3 種（いずれも「裏取りすべき原典が無い」文書）】
  #   (a) `spec-id` を持たない文書 — 索引・横断表。旧 (8a) から踏襲した条件（移設時に落としていた）。
  #       実測: 仕様索引（SPEC-ID → パスの対応表）が「表形式の主張」に一致して未達になった。
  #   (b) **`coverage-status: generated`** — `gates.sh` 自身が生成する成果物。
  #       **`gate_tier` が同じ事故で入れた除外（上記 (1) 参照）を、その移設先で落としていた**。
  #       実測: `G-SOURCEINDEX` が生成を**強制**する `specs/source-index.md` が生成した瞬間に
  #       「台帳未登録」になり、**3 ゲートが循環して合格状態が存在しなくなった**
  #       （台帳に足す → `G-BLOCK-SIZE` がマーカー不在で未達／マーカーを書く → 再生成で消え
  #       `G-SOURCEINDEX` が陳腐化で FAIL／何もしない → `G-LEDGER` が未達）。
  #   (c) **`category: index`** — `spec-id` を持つ索引。(a) だけでは 1 リポジトリの実測に過適合で、
  #       別リポジトリの索引は `spec-id` を持つため多数の偽の未達を出した（反証レビューの実測）。
  # 【(b)(c) の判定は front-matter 内に限る】ファイル全体を `grep` すると**本文に 1 行足すだけで
  # 検査から外れる**（「検査対象に 1 行足すのが最も簡単な全通過方法」＝教訓 20 の回避経路）。
  # 先頭の `---` ブロック内だけを見て、**閉じ `---` があること**も要求する。
  # **除外条件を増やすときは必ず「どこに書けば効くか」を絞る。**
  # 【`gate_tier` の除外とは条件が違う（同一ではない）】`gate_tier` (1) は `coverage-status: generated` を
  # **全文・前方一致**で見る。こちらは **front-matter 限定・行末まで一致**なので、
  # `coverage-status: generated (auto)` や本文記載では**除外集合が一致しない**。
  # 揃えるなら `gate_tier` 側も front-matter 限定にする必要があるが、それは別の着手単位にする
  # （`gate_tier` は撤去予定だったので、ここで触ると撤去差分が読みにくくなる）。
  claim_specs=$(spec_files | nul_pack \
    | LC_ALL=C xargs -0 -r grep -lE "$CLAIM_LINE_RE" 2>"$errf" \
    | nul_pack | LC_ALL=C xargs -0 -r grep -l '^spec-id:' 2>>"$errf" \
    | nul_pack | LC_ALL=C xargs -0 -r awk '
        # 【開始判定を完全一致にしない（CRLF）】`$0 == "---"` は行末が CRLF だと一致せず、
        # **Windows の既定 checkout（core.autocrlf=true）で除外が 1 件も効かなくなる**。
        # 値の行は `[[:space:]]*$` が `\r` を吸うので効くため、開始だけが落ちる非対称になる。
        # 同じファイルの `run_source_index` が同型の対策を `(I4)` として持っている（既存の不変条件）。
        # 【閉じ `---` を要求する】閉じを消して本文に 1 行書けば除外できてしまう（自己免除の残り）。
        function flush() { if (curf != "" && !(skip && closed)) print curf }
        FNR == 1 { flush(); curf = FILENAME; skip = 0; closed = 0
                   infm = ($0 ~ /^---[[:space:]]*$/) }
        infm && FNR > 1 && /^---[[:space:]]*$/ { infm = 0; closed = 1 }
        infm && /^coverage-status:[[:space:]]*generated[[:space:]]*$/ { skip = 1 }
        infm && /^category:[[:space:]]*index[[:space:]]*$/ { skip = 1 }
        END { flush() }' 2>>"$errf" || true)
  # 【rc ではなく stderr で判定する】`grep -l` は「一致なし」で 1 を返し `xargs` が 123 に化けるので
  # rc からは異常を区別できない。**stderr が空でなければ測れていない**ので fail-closed にする
  # （申し送り 5 の罠 1: 潰すと集計が空になり「未登録 0 件」＝合格に見える）。
  if [ -s "$errf" ]; then
    LU_N=-1
    LU_DETAIL=$(grep . "$errf" | head -3 | sed 's/^/  /')
    rm -f "$errf"; return
  fi
  : > "$errf"          # awk 段で再利用する（消さない）
  # 【仕様ツリーが読めないのを「主張 0 件」にしない（M-1r）】`spec_files` は stderr を捨てるので、
  # `$SPECS` が読めないと**静かに空**になり「未登録 0 件」＝合格に化ける。
  # 部分的に読めないサブディレクトリは検出できない（全ゲート共通の限界）。
  if [ -d "$SPECS" ] && [ ! -r "$SPECS" ]; then
    LU_N=-1; LU_DETAIL="  ${SPECS#"$REPO_ROOT"/}: 読み取り権限が無く仕様を列挙できない"; rm -f "$errf"; return
  fi
  # ここで空なら「主張を持つ仕様が 0 件」＝要求は無い（測れなかったのではない）。
  [ -n "$claim_specs" ] || { LU_HAVE=0; rm -f "$errf"; return; }
  LU_HAVE=1
  # 【台帳が不在のときは /dev/null を渡す】パスをそのまま渡すと awk が開けず、
  # `2>/dev/null` で潰れて**「未登録 0 件」＝合格に化ける**（実測。自分の検査が検出した）。
  # 不在は「登録が 1 件も無い」であって「対象なし」ではない。
  local ledarg="$ledger"; [ -f "$ledger" ] || ledarg=/dev/null
  cs_tmp="$(mktemp "${TMPDIR:-/tmp}/gates-lu-cs.XXXXXX")" || {
    LU_N=-1; LU_DETAIL="  一時ファイルを作成できない（TMPDIR=${TMPDIR:-/tmp} を確認する）"; rm -f "$errf"; return; }
  printf '%s\n' "$claim_specs" | grep . > "$cs_tmp" || true
  # 台帳を先に読んで登録済みの集合を作り、次に仕様一覧を突合する。
  # `NR==FNR` は**台帳が空のとき誤判定する**ので `FILENAME` で切り分ける（既知の罠）。
  # 【末尾一致＋パス境界で突合する】basename だけで突合すると**同名の別ディレクトリの仕様が
  # 互いを隠す**（参照成果物に同名の組が複数あり、片方の登録が他方の未登録を隠して fail-open になった）。
  # 【前後空白を落とす】手書き TSV なので `spec_file` に空白が混じりうる。落とさないと
  # **対象の全件が「未登録」と誤報告**される（実測で確認）。
  LU_DETAIL=$(awk -F'\t' -v led="$ledger" -v root="$REPO_ROOT/" '
    function strip(f) { return (index(f, root) == 1) ? substr(f, length(root) + 1) : f }
    FILENAME == led {
      if (FNR == 1 || $0 ~ /^#/) next
      sf = $2; gsub(/^[ \t]+|[ \t]+$/, "", sf)
      if (sf == "") next
      # 【突合は「パス境界付きの後方一致」に統一する】台帳の `spec_file` の表記は 1 つに定まらない
      # ——雛形は「`specs/` からの相対パス」と書き、実データは「リポジトリルート相対」で、
      # ファイル名だけの行もありうる。表記ごとに分岐すると**片方が虚偽の未達、片方が fail-open**に割れる
      # （実測: 雛形どおりに書くと全件が「未登録」になり、`./` は HEAD では通っていたのに落ちた）。
      # ⇒ **末尾一致＋直前が `/` であること**を求める（`xz.md` は `z.md` に一致しない）。
      sub(/^\.\//, "", sf)
      if (index(sf, root) == 1) sf = substr(sf, length(root) + 1)
      regs[++nreg] = sf
      next
    }
    {
      if ($0 == "") next
      rel = strip($0); hit = 0
      for (i = 1; i <= nreg; i++) {
        L = length(regs[i])
        if (rel == regs[i]) { hit = 1; break }
        if (length(rel) > L && substr(rel, length(rel) - L + 1) == regs[i] \
            && substr(rel, length(rel) - L, 1) == "/") { hit = 1; break }
      }
      if (hit) next
      printf "  %s: 密度台帳に 1 ブロックも登録が無い（主張を持つのに Verify の対象になっていない。GP-22。台帳の spec_file 列の表記も確認する）\n", rel
    }' "$ledarg" "$cs_tmp" 2>"$errf" | sort) || rc=$?
  rm -f "$cs_tmp"
  # 【awk 段の rc / stderr も捨てない（H-2r）】ここを `2>/dev/null || true` で潰すと、
  # **台帳を読めなくするだけで（`chmod 000`）強制点が消える**（実測: PASS に化けた）。
  # 「検査対象を壊すのが最も簡単な全通過方法」を作らない（`G-SESSION-EXISTS` と同じ設計原則）。
  # 同じ罠を `gate_block_outside` のコメントが明文で禁じている——それを新規コードで踏んでいた。
  if [ "$rc" -ne 0 ] || [ -s "$errf" ]; then
    LU_N=-1
    LU_DETAIL=$(grep . "$errf" 2>/dev/null | head -3 | sed 's/^/  /')
    [ -n "$LU_DETAIL" ] || LU_DETAIL="  突合の awk が rc=${rc} で失敗（stderr は空）"
    rm -f "$errf"; return
  fi
  rm -f "$errf"
  [ -n "$LU_DETAIL" ] && LU_N=$(printf '%s\n' "$LU_DETAIL" | grep -c . || true)
  return 0
}

gate_density_ledger() {
  local ledger="$AUDIT/density-ledger.tsv"
  # 【台帳の「外」からの突合を**最初に**行う（台帳の有無・空/非空に依存させない）】
  # ここを台帳の存在チェックより後に置くと、**台帳が空のときに検査が効かなくなる**。
  # それは撤去した `GP-104` ルール14 が記録した実運用事故そのものの状態（＝ブロック 0 件のまま完了宣言）なので、
  # **移設で保存すべき強制点を移設で失う**ことになる（実測で `G-TIER` の未達 3 件 → 1 件に減った）。  [撤去の記録]
  ledger_unregistered
  # 【測れなかったを合格にしない】`LU_N=-1` は突合そのものが失敗した状態（読めない仕様ファイル等）。
  # `-gt 0` / `-eq 0` のどちらの分岐でも「未登録 0 件」と同じ扱いに落ちるので、**先に断つ**
  # （申し送り 5 の罠 1。`gate_block_outside` と同じ fail-closed の作り）。
  if [ "${LU_N:-0}" -lt 0 ]; then
    # 【原因を断定しない】仕様が読めない／台帳が読めない／一時ファイルが作れない のどれもここに来る。
    # 断定すると調査が空振りする（`gate_block_outside` が同じ理由で一般化した文言にしている）。
    report INCOMPLETE G-LEDGER "台帳と仕様の突合ができなかった（詳細行の原因を確認する）" "$LU_DETAIL"
    return
  fi
  local rows=""
  [ -f "$ledger" ] && rows=$(grep -v '^#' "$ledger" | grep -v '^block_id' | grep -v '^[[:space:]]*$' || true)
  if [ -z "$rows" ]; then
    # 台帳が無い / 空 ＝ 1 ブロックも登録されていない。**主張を持つ仕様があれば未達**である。
    if [ "$DENSITY_GATES" = "on" ]; then
      if [ "${LU_N:-0}" -gt 0 ]; then
        report INCOMPLETE G-LEDGER "密度台帳にブロックが 1 件も無いのに主張（path:line / 表形式）を持つ仕様が ${LU_N} 件ある（purpose=${PURPOSE}。**ブロック 0 件のまま完了を宣言できないようにする**。GP-22 / SB-20/21）" "$LU_DETAIL"
      else
        local _lstate2; _lstate2=$([ -f "$ledger" ] && printf '密度台帳にブロックが 1 件も無い' || printf '密度台帳ファイルが無い')
        report WARN G-LEDGER "${_lstate2}（purpose=${PURPOSE}。ただし主張を持つ仕様も 0 件なので登録要求は無い）"
      fi
    else
      if [ "${LU_N:-0}" -gt 0 ]; then
        local _lstate; _lstate=$([ -f "$ledger" ] && printf '密度台帳が空' || printf '密度台帳ファイルが無い')
        report WARN G-LEDGER "${_lstate}なのに主張を持つ仕様が ${LU_N} 件ある（purpose=${PURPOSE} のため警告のみ）" "$LU_DETAIL"
      else
        # 【不在と空を区別する】HEAD は不在を「存在しない」と報告していた。区別を失うと
        # 「台帳を消した」のか「まだ書いていない」のかが記録から読めない。
        local _lstate3; _lstate3=$([ -f "$ledger" ] && printf '密度台帳が空' || printf '密度台帳ファイルが無い')
        report SKIP G-LEDGER "${_lstate3}（purpose=${PURPOSE} では密度昇格は任意）"
      fi
    fi
    return
  fi
  local total unverified fab_open
  total=$(echo "$rows" | wc -l | tr -d ' ')
  # verified 以外（unverified/verifying/repairing）は未検証扱い（SB-21: レディ母数に入れない）
  unverified=$(echo "$rows" | awk -F'\t' '$5 != "verified" {n++} END {print n+0}')
  # fabricated_open の合計（反映ゲートは fabricated=0 = SB-20）
  # 【数値でない値を黙って飛ばさない（2026-09-23 是正。効果測定 E2 が発見）】
  # 旧実装は `$7 ~ /^[0-9]+$/` の行だけを足していたので、**空文字にすると合計 0 になり PASS した**
  # ——**完了条件（fabricated=0）を空欄で満たせる fail-open** だった。
  # 「測れなかった」を「0」と混ぜない。空・非数値は**別に数えて未達にする**。
  fab_open=$(echo "$rows" | awk -F'\t' '$7 ~ /^[0-9]+$/ {s+=$7} END {print s+0}')
  # 【`-` は正規の値（未測定）。空・空白だけを弾く】
  # 台帳は未検証行の未測定欄に `-` を書く規約なので、`-` を未達にすると**正常な台帳が落ちる**
  # （実測: selftest のフィクスチャ `DB-001` が `-` を使っており、既存検査 2 件が落ちた）。
  # 塞ぐべき穴は**空文字**である——列が空のまま「合計 0」と読まれる経路。
  local fab_bad fab_bad_detail
  fab_bad=$(echo "$rows" | awk -F'\t' '$7 !~ /^[0-9]+$/ && $7 !~ /^-$/ {n++} END {print n+0}')
  fab_bad_detail=$(echo "$rows" | awk -F'\t' '$7 !~ /^[0-9]+$/ && $7 !~ /^-$/ {printf "fabricated_open が空または数値でない: %s（%s, 値=[%s]）\n", $1, $2, $7}')
  # 突合は `ledger_unregistered`（本関数の直前で定義）が担う。結果は LU_N / LU_DETAIL。
  local detail
  detail=$(echo "$rows" | awk -F'\t' '$5 != "verified" {printf "未検証: %s（%s, %s）\n", $1, $2, $5}';
           echo "$rows" | awk -F'\t' '$7 ~ /^[0-9]+$/ && $7 > 0 {printf "fabricated 未修復: %s（open=%s）\n", $1, $7}';
           printf '%s' "$LU_DETAIL")
  # 【非数値があれば合計を信用しない】空欄で通せる経路を塞ぐ（PASS/WARN に落とさない）
  if [ "${fab_bad:-0}" -gt 0 ]; then
    report INCOMPLETE G-LEDGER "fabricated_open が空または数値でない行が ${fab_bad} 件あり合計を確定できない（空欄で「合計 0」と読ませない）" \
      "$(printf '%s' "$fab_bad_detail")
密度台帳の fabricated_open は**数値**か、未測定を表す **\`-\`** で書く（空欄にしない）。
旧実装は数値でない行を黙って飛ばして合計 0 とみなしたため、**空文字にすると完了条件（fabricated=0 = SB-20）を
空欄で満たせた**（効果測定 E2 が発見）。「測れなかった」を「0」と混ぜない。"
    return
  fi
  # 【ブロック単位で台帳と突き合わせる（2026-10-01）】`ledger_unregistered` は「仕様ファイルごとに 1 ブロックでも登録があるか」
  #  しか見ないので、**登録済みのファイルに未登録・未検証のブロックを足しても「全て verified」で通った**（SB-21 の穴）。
  #  あわせて**同じ `DB-N` を 2 箇所で開いた**ものを落とす（片方が verified だと他方も検査を免除された。完走試験で ID が数十件衝突した）。
  #  完走した参照成果物 3 本で、どちらも 0 件（完成品は落ちない）。台帳にだけある ID（閉じたブロック）は見ない。
  local mk_ids blk_unreg blk_dup
  mk_ids=$(content_spec_files | nul_pack | LC_ALL=C xargs -0 -r awk '
             /<!-- density-block:/ && !/<!-- \/density-block/ { if (match($0, /DB-[0-9]+/)) print substr($0, RSTART, RLENGTH) "\t" FILENAME }' 2>/dev/null \
           | sed "s|\t$REPO_ROOT/|\t|" | LC_ALL=C sort || true)
  blk_dup=$(printf '%s\n' "$mk_ids" | grep . | cut -f1 | LC_ALL=C sort | uniq -d \
            | while read -r _d; do printf '同じ密度ブロック ID を 2 箇所以上で開いている: %s（%s）\n' "$_d" "$(printf '%s\n' "$mk_ids" | awk -F'\t' -v k="$_d" '$1==k{printf "%s ", $2}')"; done)
  blk_unreg=$(LC_ALL=C comm -23 <(printf '%s\n' "$mk_ids" | grep . | cut -f1 | LC_ALL=C sort -u) \
                               <(printf '%s\n' "$rows" | awk -F'\t' '{ v = $1; gsub(/[ \t\r]/, "", v); if (v != "") print v }' | LC_ALL=C sort -u) \
              | sed 's/^/台帳に無い密度ブロック（未検証のまま）: /')
  if [ -n "$blk_dup" ]; then
    report FAIL G-LEDGER "同じ密度ブロック ID が複数の箇所で使われている（$(echo "$blk_dup" | grep -c .) 件。片方の検証が他方を免除してしまう。ID を振り直す）" "$blk_dup"
    return
  fi
  # 未登録のブロックは「台帳未登録」に合算して、下の判定（INCOMPLETE / WARN）に乗せる（ファイル単位の名指しを隠さない）
  if [ -n "$blk_unreg" ]; then
    LU_N=$(( ${LU_N:-0} + $(printf '%s\n' "$blk_unreg" | grep -c .) ))
    detail=$(printf '%s\n%s' "$detail" "$blk_unreg" | grep . || true)
  fi
  # 【HOLD-9 の切り出しは同じ主張で 1 回まで（GP-103 ルール3）】`notes` の `hold9-split-from: DB-N` を辿り、
  #  切り出したブロックをさらに切り出した（2 段重ね）ものを落とす。重ねると新しいブロックが 1 巡目から
  #  数え直され、収束しないまま終わらない（完走試験で毎回その場で選択肢を作っていたのを標準化した際の歯止め）。
  local split2
  split2=$(echo "$rows" | awk -F'\t' '{
             n = $10
             # 全角のコロン・空白でも素通りさせない（全角コロンで検査が素通りした先例がある）
             if (match(n, /hold9-split-from(:|：)( |　)*DB-[0-9]+/)) { p = substr(n, RSTART, RLENGTH); sub(/^.*DB-/, "DB-", p); b = $1; gsub(/[ \t\r]/, "", b); par[b] = p }
           }
           END { for (b in par) if (par[b] in par) printf "切り出しの 2 段重ね: %s ← %s ← %s\n", b, par[b], par[par[b]] }' | LC_ALL=C sort || true)
  if [ -n "$split2" ]; then
    if [ "$DENSITY_GATES" = "on" ]; then
      report FAIL G-LEDGER "HOLD-9 の切り出しを同じ主張で 2 回重ねたブロックが $(echo "$split2" | grep -c .) 件（(A) は 1 回まで。2 回目は (B) か (C)。GP-103 ルール3）" "$split2
直し方: 2 段目のブロックの主張を (B)（外して partial）か (C)（もう 1 巡）で扱い、ADR に残す。notes を消して通さない。
この判定を先に出すので、fabricated_open・未検証・未登録の件数は直したあとの再実行で出る。"
    else
      report WARN G-LEDGER "HOLD-9 の切り出しを 2 段重ねたブロックがある（purpose=${PURPOSE} のため警告のみ。GP-103 ルール3）" "$split2"
    fi
    return
  fi
  if [ "$unverified" -eq 0 ] && [ "$fab_open" -eq 0 ] && [ "${LU_N:-0}" -eq 0 ]; then
    if [ "${LU_HAVE:-0}" -eq 1 ]; then
      report PASS G-LEDGER "密度台帳 ${total} ブロック全て verified・fabricated_open 合計 0・主張を持つ仕様はすべて登録済み（SB-20/21）"
    else
      report PASS G-LEDGER "密度台帳 ${total} ブロック全て verified・fabricated_open 合計 0（主張を持つ仕様は 0 件なので登録要求は無い。SB-20/21）"
    fi
  elif [ "$DENSITY_GATES" = "on" ]; then
    # 「未検証が残っている」＝作業が進めば解消する未完了。
    # 「fabricated_open > 0」＝**検証で見つかった誤りが直っていない欠陥**（SB-20 の反映ゲート）。
    # 両者を同じ FAIL にすると、Verify を進めている最中と誤りを放置している状態が区別できない。
    # 「台帳未登録」も**作業が進めば解消する未完了**なので INCOMPLETE 側に置く。
    if [ "$fab_open" -gt 0 ]; then
      report FAIL G-LEDGER "fabricated_open 合計 ${fab_open} 件が未修復（未検証 ${unverified} 件 / 台帳未登録 ${LU_N} 件）。誤りを直すまで反映しない（SB-20）" "$detail"
    else
      report INCOMPLETE G-LEDGER "未検証 ${unverified} 件 / 台帳未登録 ${LU_N} 件（fabricated_open 0）。Verify を進めれば解消する（SB-21）" "$detail"
    fi
  else
    report WARN G-LEDGER "未検証 ${unverified} 件 / fabricated_open 合計 ${fab_open} / 台帳未登録 ${LU_N} 件（purpose=${PURPOSE} のため警告のみ）" "$detail"
  fi
}

# --- G-VERIFIER: 台帳の verifier 欄（GP-16 ルール2 / SB-12） ---
# 【何を塞ぐか】`verifier` は「隔離を機械で確かめた検証か」の記録だが、どのゲートも読んでいなかった。
# 実データで語彙外（`v2-agent2`）や、SB-12 が否定する同一セッションの切り直し（`fresh-context-same-session`）が
# 素通りしていた（dev/verifier-column-gate.md）。見るのは 2 つだけにする:
#   (1) `verified` / `repairing` の行の `verifier` が語彙内か（語彙外・空・`-` は記録の誤り＝FAIL）
#   (2) `subagent-isolated` 以外で `verified` になった行があれば、その件数を `rebuild-readiness.md` の
#       「検証手段の内訳」欄に**台帳と同じ数で**書いたか（弱い保証を件数で開示する。無い・違う＝INCOMPLETE）
# 【列は見出しの名前で探す】この欄は後から足された列なので位置を決め打ちしない。
gate_verifier_column() {
  local ledger="$AUDIT/density-ledger.tsv" readiness="$AUDIT/rebuild-readiness.md" out
  [ -f "$ledger" ] || { report SKIP G-VERIFIER "density-ledger.tsv が存在しない（G-LEDGER が扱う）"; return; }
  out=$(LC_ALL=C awk -F'\t' '
    function trim(v) { gsub(/\r/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    /^#/ || /^[[:space:]]*$/ { next }
    !h { for (i = 1; i <= NF; i++) { k = trim($i); if (k == "verifier") c = i; if (k == "verify_status") s = i }
         h = 1; if (!c || !s) { nocol = 1; exit }; next }
    { st = trim($s); v = trim($c)
      if (st != "verified" && st != "repairing") next
      if (v !~ /^(subagent-isolated|prompt-isolated|fresh-context|human)$/) printf "BAD\t%s\t%s\n", trim($1), v
      else if (st == "verified" && v != "subagent-isolated") weak++ }
    END { if (nocol) print "NOCOL"; printf "WEAK\t%d\n", weak + 0 }' "$ledger" 2>&1) || {
    report INCOMPLETE G-VERIFIER "密度台帳を読めない" "$out"; return; }
  local bad weak verdict="FAIL" soft="INCOMPLETE"
  [ "$DENSITY_GATES" = "on" ] || { verdict="WARN"; soft="WARN"; }
  # 【見出しの欠落も warn では WARN】他の未達と同じく DENSITY_GATES に従う（以前は warn でも INCOMPLETE だった）
  if printf '%s\n' "$out" | grep -q '^NOCOL'; then
    report "$soft" G-VERIFIER "密度台帳の見出しに verifier / verify_status の列が無い（templates/density-ledger.tsv の見出しに揃える）"
    return
  fi
  bad=$(printf '%s\n' "$out" | awk -F'\t' '$1=="BAD"{printf "  %s: verifier=[%s]\n", $2, $3}')
  weak=$(printf '%s\n' "$out" | awk -F'\t' '$1=="WEAK"{print $2}')
  if [ -n "$bad" ]; then
    report "$verdict" G-VERIFIER "verified / repairing の行の verifier が語彙外・空（$(printf '%s\n' "$bad" | grep -c .) 件。subagent-isolated / prompt-isolated / fresh-context / human のどれかを書く）" "$bad"
    return
  fi
  if [ "${weak:-0}" -gt 0 ] && [ "$REBUILD_LAYER" = "full" ]; then
    local line n
    line=$(grep -m1 '^- \*\*検証手段の内訳' "$readiness" 2>/dev/null || true)
    # 数は「verified <N> 件」の位置だけから取る（説明文の中の数字を拾わない。雛形の <N> は未記入）
    n=$(printf '%s' "$line" | LC_ALL=C grep -oE 'verified[[:space:]]*[0-9]+[[:space:]]*件' | grep -oE '[0-9]+' | head -1)
    if [ "$n" != "$weak" ]; then
      report "$soft" G-VERIFIER "隔離を機械で確かめていない verified が ${weak} 件あるのに、rebuild-readiness.md の「検証手段の内訳」に同じ数が無い（値: ${n:-なし}。SB-12）"
      return
    fi
  fi
  report PASS G-VERIFIER "verifier 欄が語彙内（機械で確かめていない verified ${weak:-0} 件$([ "${weak:-0}" -gt 0 ] && [ "$REBUILD_LAYER" = "full" ] && printf '・宣言に開示済み')）"
}

# --- G-BLOCK-OUTSIDE: 密度ブロックの外にある path:line 主張を列挙する（GP-22 / GP-103 ルール1） ---
# 【何を測るか】密度ブロックの外に置かれた主張は **Verify を受けていない**。`GP-22` 冒頭は
# 「Verify を通さなかった分は同率の誤り（実測 35%）が残っている前提で扱うべき」と要求している。
# よって**消すのではなく数字を出し続ける**（手順 5 の「機械化できないを検査しないにしない」）。
#
# 【判定に影響させない理由（`GP-103` ルール1 の第 3 の状態＝列挙のみ）】
# 旧実装（`gate_tier` (8b)）は**ブロック外 0 件を hard な未達**として要求していたが、
# それは `GP-103` が禁じた形——「0 許容を無制限の単位（ファイル全体）に課す」型である。
# 実測: ボトムアップで完走し `fabricated_open` 0 に到達した参照成果物でも
# **ブロック外に 1,000 行超**あり（現行の数え方での実測は 1,259 件 / 71 仕様。旧式の式では 1,019 行
# ——**式を直したので数字が変わった**。同一対象の 2 つの数字を見たらこの差を思い出すこと）、
# **完成品が FAIL する要求**だった。`WARN` は終了コードに
# 影響しない（終了コードは FAIL ＋ INCOMPLETE の合計）ので、列挙は判定を変えない。
#
# 【なぜ `G-BLOCK-SIZE` から独立した関数にするか（2026-09-12 の欠陥修正）】
# 一度は `G-BLOCK-SIZE` の 1 パスに相乗りさせたが、**その経路には黙るための門が 3 つ**あった
# （selftest 側の注記も同じ 3 つを指す。数え方を揃えてある）:
#   run_density の `DENSITY_GATES=off`（gate_block_size を呼ばない）
#   gate_block_size の「密度台帳が無い」→ SKIP して return
#   gate_block_size の「密度台帳が空」→ SKIP して return
# **密度ブロック化に着手していない段階（＝ブロック外の主張が最も多い状態）がまさにこれ**で、
# 移設の目的（`GP-104` 撤去後も失われないこと）を達していなかった。
# `DENSITY_GATES=off` は現行のどの purpose も設定しないが、**`maintenance` が `off` だった時期に
# 生成された既存リポジトリは持っている**ため休眠していない。
# ⇒ **台帳にも `DENSITY_GATES` にも依存しない独立ゲートにする**（`report` を分ける）。
# 単体でも呼べる形にする必要がある（`selftest` の `G-EQUIV` が単体呼び出しと突合するため）。
# 【`run_phase2` には登録しない】phase2 は「**進行中でも欠陥を意味するものだけ**」を出す場（GP-6
# ルール15）で、本ゲートは列挙のみ＝欠陥を意味しない。よって phase2 の趣旨に合わない。
# 目的（どんな状態でも失われない）は `run_density` 経由（`phase4` と `density`）で満たす。
#
# 【費用（実測。環境を明記する）】追加は `xargs` 1 パス（＋`spec_files` の `find` 1 回）である。
# 実測（mac / Apple M1 Pro・実プロジェクト複製で `gates.sh density`）:
#   相乗り版 42.10 秒 → 独立ゲート版 **42.82 秒（+0.72 秒＝+1.7%）**
# 参考値: awk の素の起動は **7.9ms**。仕様ごとに awk を起動する形（旧 (8b)）は 87 仕様で **1.31 秒**。
# **Windows / Git Bash ＋ EDR ではプロセス起動が約 0.2 秒**なので、逐次起動は同じ形が 20 倍高くつく
# ——だから「ファイルごとに起動しない」ことが要点で、1 パスなら scope を絞る必要がない。
# 【`spec_files` を 2 回呼ぶことを許容した理由】awk に件数を出させれば `find` 1 回に畳めるが、
# 番兵行の列を取り違えると偽 PASS になる（実際にこの移設で踏んだ）。0.7 秒のために同型を持ち込まない。
# --- G-SCANCMD: 記録された走査コマンドが構造的に再現しない形を検出（GP-22 ルール9） ---
# 【なぜ要るか】件数・不在の主張は「走査コマンド → N」で裏付けるが、**書かれたコマンドが正しい数を返すことは
# 誰も検査していなかった**。最も危ないのは ERE の中の `\|` で、`grep -cE 'A\|B'` は `\|` を**リテラルのパイプ**
# として扱うので**何が実在しても 0 を返す**——「0 件」の主張なら偽の裏取りが成立する（実測）。
# 【表のセルは対象外】Markdown の表では `\|` がパイプの正しいエスケープで、描画後は `a|b` になる
# （完走した参照成果物の 7 件はすべて表のセルで、正しい形だった）。対象は**表の外**のコード表記とコードブロック。
# 【見るのは grep -E / egrep だけ（既知の見逃し）】同じ型は `grep -P` / `sed -E` / `awk '/A\|B/'` / `rg` にもあるが、
# 書き方が多様で静的に確かめにくいので対象外にした。存在しないパス・大小の区別の食い違いも静的には言えない。
# これらは Verify の (b) 件数宣言の再現（検算官がコマンドを実行する）が見る。
gate_scan_command() {
  [ -d "$SPECS" ] || { report SKIP G-SCANCMD "specs/ が無い（未生成段階）"; return; }
  local hits rc
  hits=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk '
    # 【-E はフラグ列のどこにあってもよい】初版は `-cE` の形（E で終わる）しか拾わず、**`-Ec` / `-Eic` と
    # `grep -e 'A\|B' -E` を見逃した**（反証レビューが実測）。grep から次のパイプまでに -E を含むフラグがあれば ERE。
    # パターン中の `\|` はパイプではないので読み飛ばす。
    function ere(t) {
      if (t ~ /(^|[^A-Za-z])egrep([^A-Za-z]|$)/) return 1
      return (t ~ /(^|[^A-Za-z])grep(([^|]|[\\][|])*)[[:space:]](-[A-Za-z]*E[A-Za-z]*|--extended-regexp)([^A-Za-z]|$)/)
    }
    FNR == 1 { inf = 0 }
    /^[[:space:]]*(```|~~~)/ { inf = !inf; next }
    inf { if (ere($0) && index($0, "\\|")) print FILENAME ":" FNR ": " substr($0, 1, 160); next }
    /^[[:space:]]*\|/ { next }
    {
      t = $0
      while (match(t, /`[^`]+`/)) {
        sp = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        if (ere(sp) && index(sp, "\\|")) { print FILENAME ":" FNR ": " substr($0, 1, 160); break }
      }
    }'); rc=$?
  if [ "$rc" -ne 0 ]; then
    report INCOMPLETE G-SCANCMD "走査コマンドの検査が異常終了した（rc=${rc}。対象なしとは言えない）"
    return
  fi
  if [ -z "$hits" ]; then
    report PASS G-SCANCMD "記録された走査コマンドに、構造的に再現しない形（ERE の中の \\|）が無い"
  elif [ "$DENSITY_GATES" = "on" ]; then
    report FAIL G-SCANCMD "ERE（grep -E / egrep）の中に \\| がある走査コマンドが $(echo "$hits" | grep -c .) 件（\\| はリテラルのパイプになり常に 0 を返す。| に直して再実行し、件数を確かめる）" "$hits"
  else
    report WARN G-SCANCMD "ERE の中に \\| がある走査コマンドがある（purpose=${PURPOSE} のため警告のみ）" "$hits"
  fi
}

# --- G-POPULATION: 全称・唯一・不在の主張に母集団の宣言があるか（GP-103 ルール7） ---
# 【なぜ必要か】全称型・唯一型・不在型は**反例 1 件で結論の向きが変わる**のに、
# 母集団の定義が記述に埋め込まれていると**検証官が判定できず必ず差し戻る**（実運用の観測）。
# 「すべての X は Y である」と書かれても、X の数え方が書かれていなければ検証は始められない。
# **書かせることは機械化できる**（正しさは機械化できない——それは隔離 Verify の仕事）。
#
# 【なぜブロック単位か】節単位（`required-sections`）では粒度が粗く、1 仕様に複数ブロックがある。
# また全称主張を持たない仕様にも空節を強制してしまう（過大側の形骸化＝FB-6 の裏）。
#
# 【走査は `G-BLOCK-SIZE` と同じマーカーを使う】新しい走査を作らない（FB-12 の出力量・実時間対策）。
gate_population() {
  [ -d "$SPECS" ] || { report SKIP G-POPULATION "specs/ が無い（未生成段階）"; return; }
  # 【`verified` 済みのブロックは対象外】実データ（密度ブロック 709・`fabricated_open` 合計 0 で
  # 完走した参照成果物）を測ると、母集団行を持つブロックは **0 件**で、絞った語でも
  # **270 ブロックが未達**になった。**完成品が FAIL する要求は課さない**（`GP-103`。
  # `G-BLOCK-OUTSIDE` が同じ理由で「列挙のみ」に格下げされた前例がある）。
  # 目的は「**これから検証する**ブロックで検証官が判定できること」なので、検証が済んだものは要らない。
  # 台帳に無いブロックは「まだ検証していない」として対象に含める（不在を免除にしない）。
  local verified_ids=""
  if [ -f "$AUDIT/density-ledger.tsv" ]; then
    # 【CR と前後空白を落とす】Windows で編集された台帳は `verified\r` になり、
    # 除外が効かず**検証済みブロックまで未達に数える**（偽の未達）。両側を正規化する。
    verified_ids=$(awk -F'\t' '
      function trim(v) { gsub(/\r/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
      NR>1 { id = trim($1); st = trim($5); if (id != "" && st == "verified") print id }' \
      "$AUDIT/density-ledger.tsv" | sort -u || true)
  fi
  local _vf_pop=""
  if [ -n "$verified_ids" ]; then
    _vf_pop="$(mktemp "${TMPDIR:-/tmp}/gp-verified.XXXXXX")" || _vf_pop=""
    if [ -z "$_vf_pop" ]; then
      report INCOMPLETE G-POPULATION "一時ファイルを作れず検証済みブロックの除外ができないため判定を保留した" \
        "TMPDIR（${TMPDIR:-/tmp}）に書き込めるか確認して再実行すること。除外せずに数えると
検証済みのブロックまで未達に数えてしまうため、判定を出さない。"
      return
    fi
    printf '%s\n' "$verified_ids" > "$_vf_pop"
  fi
  # 【マーカー異常は測定不能として扱う】真偽値 `inblk` ＋ id 一致要求で書いた初版は、
  # **終了マーカー無し／id 不一致／コロン無し／入れ子／開始と終了が同一行**のいずれでも
  # ブロックが 1 つも切り出せず「対象なし」で PASS した（実測。しかも文言が事実に反する）。
  # `gate_block_outside` が 3 回作り直して到達した形（**深さで数え、異常は種別ごとに報告**）に揃える。
  # 【rc を捨てない】`2>/dev/null || true` は awk の fatal（読めないファイル）で集計を空にし、
  # **未達を 0 件に見せる**（fail-open。走査順に依存するので再現しにくい）。測れないなら未完了にする。
  local found rc=0 errf
  errf="$(mktemp "${TMPDIR:-/tmp}/gates-gp-err.XXXXXX")"
  found=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk \
      -v NEED="$CLAIM_NEEDS_POP_RE" -v VF="${_vf_pop:-}" '
    BEGIN { if (VF != "") { while ((getline l < VF) > 0) if (l != "") done_id[l] = 1 } }
    function flush() { if (depth > 0 && curf != "") unb[curf] = 1 }
    FNR==1 { flush(); depth = 0; curf = FILENAME; need = 0; haspop = 0; popline = ""; bid = "" }
    /<!-- density-block:/ {
      if (match($0, /DB-[0-9]+/)) {
        if (depth > 0) nest[FILENAME] = 1                  # 入れ子は未対応（別種として報告）
        if ($0 ~ /<!-- \/density-block:/) { same[FILENAME] = 1; next }   # 開始と終了が同一行
        depth++
        if (depth == 1) { bid = substr($0, RSTART, RLENGTH); need = 0; haspop = 0; popline = "" }
        next
      }
      nomark[FILENAME] = 1; next                            # `DB-N` を持たない開始マーカー
    }
    depth > 0 && /<!-- \/density-block[^:]/ { nocolon[FILENAME] = 1 }
    depth > 0 && /<!-- \/density-block:/ {
      depth--
      if (depth == 0 && bid != "") {
        # 【id の一致は要求しない】食い違いは `G-BLOCK-SIZE` が名指しする。ここで捨てると
        # **その主張が検査から消える**（偽 PASS）。深さで閉じたら判定する。
        if (need && !(bid in done_id)) printf "HIT\t%s\t%s\t%d\t%s\n", bid, FILENAME, haspop, popline
        bid = ""
      }
      next
    }
    depth > 0 {
      # 【行頭に限らない】`- 母集団: …`（箇条書き）`**母集団**: …`（強調）`> 母集団: …`（引用）は
      # Markdown の自然な書き方で、行頭固定では全部落ちた（実測）。
      # **表のセルに分けた `| 母集団 | 値 |` は対応しない**——コロンが無いので値の境界が決まらない。
      # 表の中に書くなら 1 セルに `母集団: 値` と書く（`|` は空白に替えるので認識できる）。
      # 【判定用と保存用を分ける】装飾を剥がした値をそのまま保存していたため、
      # **バッククォートが消えて「コマンドが書かれていない」と誤診した**（実測。配布文書が
      # 「コマンドを書け」と指示している形が必ず FAIL する＝誰も直せない未達だった）。
      # 剥がすのは強調（`*`）と引用（`>`）と箇条書きの記号だけ——**バッククォートは残す**。
      # 【表のセル境界を保つ】`|` を空白に替えていたため、`| 母集団: 全体 | 42 件を一覧した |` の
      # ように書くと**隣のセルが要件を満たして通った**（実測。散文でも通る回避路だった）。
      # `母集団` を含むセルで切り、**そのセルだけ**を値として採る。
      probe = $0
      gsub(/[*>]/, "", probe)
      sub(/^[[:space:]]*[-+*][[:space:]]*/, "", probe); gsub(/^[[:space:]]+/, "", probe)
      # 【表の行だけを分割する（2026-09-24 是正）】index(probe,"|") > 0 で全行に適用していたため、
      # **走査コマンドの中の | （パイプ・正規表現の代替・エスケープ）で値が途中で切れていた**。
      # 実測: 母集団行が「コマンド grep -cE ^\| NODE-(EP|MOD|BND)… <path>」の形のとき、
      # 最初の | までに切られて**列挙元のパスが消えていた**（列挙元の検査が空振りしていた）。
      # 表のセルを守る目的は満たしつつ（表の行は必ず | で始まる）、散文行は全文を残す。
      if (probe ~ /^\|/) {
        nc = split(probe, cells, "|"); probe = ""
        for (ci = 1; ci <= nc; ci++) {
          cv = cells[ci]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", cv)
          if (cv ~ /^母集団[[:space:]]*(:|：)/) { probe = cv; break }
        }
      }
      # 【複数行あるとき最後だけを見ない】良い行→悪い行の順で FAIL、逆順で PASS と
      # **両方向に誤っていた**（実測）。**全行を集めて 1 つでも要件を満たせば通す**
      # （区切りは `\002`。タブ区切りの出力を壊さない制御文字を使う）。
      if (probe ~ /^母集団[[:space:]]*(:|：)/) {
        haspop = 1
        # 保存は「`母集団` 以降の原文」——`|` は空白に替えてあるので表形式でも値が取れる
        keep = probe
        popline = popline (popline == "" ? "" : "\002") keep
        next
      }
      if ($0 ~ /'"$CLAIM_LINE_RE"'/) { if ($0 ~ NEED) need = 1 }
    }
    END {
      flush()
      for (f in unb)     printf "UNBAL\t-\t%s\t0\t\n", f
      for (f in nest)    printf "NEST\t-\t%s\t0\t\n", f
      for (f in nocolon) printf "NOCOLON\t-\t%s\t0\t\n", f
      for (f in same)    printf "SAMELINE\t-\t%s\t0\t\n", f
      for (f in nomark)  printf "NOMARK\t-\t%s\t0\t\n", f
    }' 2>"$errf") || rc=$?
  [ -n "${_vf_pop:-}" ] && rm -f "$_vf_pop"
  if [ "$rc" -ne 0 ]; then
    local why; why=$(grep . "$errf" 2>/dev/null | head -3 | sed 's/^/  /' || true); rm -f "$errf"
    report INCOMPLETE G-POPULATION "母集団の宣言を集計できなかった（rc=${rc}。仕様ファイルの走査 または awk が失敗した）" \
      "${why:-  stderr は空。仕様ディレクトリの読み取り権限（find が失敗していないか）を確認する}"
    return
  fi
  rm -f "$errf"
  # マーカー異常を先に処分する（測れないまま PASS を出さない）
  local broken
  broken=$(printf '%s\n' "$found" | awk -F'\t' -v r="$REPO_ROOT/" '
    function strip(p) { i = index(p, r); return (i == 1) ? substr(p, length(r) + 1) : p }
    $1=="UNBAL"    { printf "  %s: density-block の開始に対する終了が足りない（この中の主張は測れない）\n", strip($3) }
    $1=="NEST"     { printf "  %s: density-block が入れ子になっている（未対応。分割すること）\n", strip($3) }
    $1=="NOCOLON"  { printf "  %s: 終了マーカーにコロンが無い（`<!-- /density-block: DB-N -->` と書く）\n", strip($3) }
    $1=="SAMELINE" { printf "  %s: 開始と終了が同一行にある（本文が測れない）\n", strip($3) }
    $1=="NOMARK"   { printf "  %s: density-block の開始に `DB-<番号>` が無い\n", strip($3) }' | sort || true)
  if [ -n "$broken" ]; then
    report INCOMPLETE G-POPULATION "density-block のマーカーが測れないため母集団の宣言を確認できない" \
      "$broken"
    return
  fi
  local hits
  hits=$(printf '%s\n' "$found" | awk -F'\t' '$1=="HIT"' || true)
  # 【verified の列挙元の検査を飛ばさない（2026-10-01）】未検証の HIT が 0 件のとき先に PASS で返していたため、
  #  **全ブロックが verified の完成品では下の格下げ検査が一度も走らなかった**（反証レビューで実測）。
  if [ -z "$hits" ] && [ -z "$verified_ids" ]; then
    report PASS G-POPULATION "母集団の宣言が必要な未検証ブロックが無い（全数主張なし、または全て検証済み）"
    return
  fi
  # 【`off` では合否を持たせない】密度を測らない設定（`maintenance` 等）の案件で
  # `phase4` を止めるのは過剰。前例に挙げた `G-BLOCK-OUTSIDE` は**列挙のみ**のゲートで、
  # 「合否を持つが密度の強度に依らない」ゲートの前例ではなかった（反証レビューの指摘）。
  # `off` のときは**同じ内容を WARN で列挙**する（黙らせない・止めない）。
  local pop_verdict="FAIL"
  [ "$DENSITY_GATES" = "off" ] && pop_verdict="WARN"
  local miss="" bad="" n=0
  while IFS=$'\t' read -r _tag bid f haspop popline; do
    [ -n "${bid:-}" ] || continue
    n=$((n + 1))
    f="${f#"$REPO_ROOT"/}"
    if [ "${haspop:-0}" -eq 0 ]; then
      miss+="  ${f} ${bid}: 全数主張があるのに 母集団: の宣言が無い（検証官が判定できない）"$'\n'
      continue
    fi
    # 【量を指定する（FB-6）】数え方と件数の両方を要求する。散文（「全体」「該当するもの全部」）は未達。
    # 【1 つでも満たせば通す】ブロック内に母集団行が複数あるとき（追記で増える）、
    # **要件を満たす行が 1 つでもあれば宣言はされている**。全行を試して最後の診断を残す。
    local pv pv_h pop_ok=0 last_why=""
    while IFS= read -r pl; do
      [ -n "$pl" ] || continue
      pv=$(printf '%s' "$pl" | sed -e 's/^母集団[[:space:]]*:[[:space:]]*//' -e 's/^母集団[[:space:]]*：[[:space:]]*//')
      # 【全角数字も件数として読む】半角だけを見ていたため全角で書くと偽の未達になった（実測）
      pv_h=$(printf '%s' "$pv" | LC_ALL=C sed 's/０/0/g; s/１/1/g; s/２/2/g; s/３/3/g; s/４/4/g; s/５/5/g; s/６/6/g; s/７/7/g; s/８/8/g; s/９/9/g')
      if ! printf '%s' "$pv_h" | grep -qE '[0-9]'; then
        last_why="母集団に件数（数値）が無い（「${pv}」）——分母が無いと全数を主張できない"
      elif ! printf '%s' "$pv_h" | grep -qE '[1-9]'; then
        # 【母集団 0 件で全数主張はできない】`母集団: 定義は 0 件` が通っていた（実測）
        last_why="母集団の件数が 0（「${pv}」）——母集団が空なら全数主張は成立しない"
      elif printf '%s' "$pv" | grep -qE 'spec-extraction/|01-code-graph|02-analysis|03-audit|code-graph\.md|density-ledger|work-plan\.md|traceability\.md'; then
        # 【列挙元は原典に限る（GP-2 / GP-103 ルール7-(c)）】内部成果物を列挙元にすると
        # **隔離検証が原理的に成立しない**——検証官には原典しか渡らないので、
        # 分母が正しいかを確かめる手段が無い（実測で 3 ブロックが「分母未検証」のまま残った）。
        # **原典を走査する数え方に書き換えるか、密度ブロックから外す**（後者は verified を名乗らせない）。
        last_why="母集団の列挙元が内部成果物である（「${pv}」）——原典に対して独立に再実行できないので隔離検証が成立しない。原典を走査する数え方に書き換えるか、この主張を密度ブロックから外す"
      elif printf '%s' "$pv" | grep -qE '列挙元[^。]*(下表|本表|この表|上表)' \
           && ! printf '%s' "$pv" | grep -q 'ではなく'; then
        # 【循環定義を弾く】「列挙元 = 下表の N 行」は**測る対象そのものを分母の定義に使っている**ので、
        # 第三者が原典から同じ数に到達できない（数えているのは自分が書いた行数）。
        # 実測で、隔離検証がこの型を「原典から独立に数え直せない」として指摘した。
        # 【否定形を除外する】「列挙元は下表ではなく原典側の 4 走査」は**正しい書き方**なので通す
        # （語だけで拾うと、直した記述が未達になる。実測で 1 件の偽陽性が出た）。
        last_why="母集団の列挙元が自表である（「${pv}」）——測る対象を分母の定義に使う循環定義で、原典から独立に数え直せない。原典を走査する数え方に書き換えるか、この主張を密度ブロックから外す"
      elif printf '%s' "$pv" | grep -qE '(^|[^A-Za-z])(ISO|IEC|IEEE)[[:space:]/]*[0-9]{4,5}([^0-9A-Za-z]|$)'; then
        # 【外部規格を分母の権威にしない】実測で「ISO 25010 の 6 品質特性」と書いた分母があり、
        # **特性数が誤っていた**（2011 年版 8・2023 年版 9）。規格名を借りると件数が検証されないまま通り、
        # さらに「規格の全数を消化した」ように見えて未扱いの項目が隠れる。
        last_why="母集団の権威が外部規格である（「${pv}」）——原典から導出されないので検証できない（実測で特性数を誤ったまま通った）。仕様側の宣言だと明示して密度ブロックから外すか、原典を走査する分母に置き換える"
      elif ! printf '%s' "$pv" | grep -qE '`|コマンド|一覧|列挙|定義した|得た|抽出|走査'; then
        # 【「表」「定義」の単独一致をやめる】`母集団: 42 の表` が通っていた（実測）。
        # **数え方**＝コマンドか、どこから列挙したかを要求する。
        last_why="母集団に数え方が無い（「${pv}」）——件数だけでは再現できない（コマンドか列挙元を書く）"
      else
        pop_ok=1; break
      fi
    done <<< "$(printf '%s' "$popline" | tr '\002' '\n')"
    [ "$pop_ok" -eq 1 ] || bad+="  ${f} ${bid}: ${last_why}"$'\n'
  done <<< "$hits"
  # --- A の実行物: `verified` を名乗るブロックの列挙元も原典でなければならない ---
  # 【なぜ別経路が必要か】上の走査は `verified` 済みブロックを**除外している**（完成品が FAIL する
  # 要求を課さないため）。その結果、**分母が内部成果物のまま `verified` になっているブロックを
  # 誰も見ていなかった**——実測で、測定側が「隔離できなかったブロックは verified に上げない」と
  # 事前に決めていたのに 3 件が `verified` のまま残り、ブロック単位の格下げは 1 件も無かった。
  # 散文の約束が自己申告で素通りした型（FB-6）なので、**実行物にする**。
  local demote=""
  if [ -n "$verified_ids" ]; then
    # 【1 回の走査で表を作る（2026-10-01）】以前は verified の ID 1 件ごとに全仕様を読み直していたので、
    #  回数が「ID の数 × ファイルの数」に比例した（実測: verified 2,061 件の成果物でこのゲートだけ 746 秒）。
    #  全仕様を 1 回だけ読み、verified ブロックの母集団行を ID ごとに集めてから判定する。判定の規則は従来と同じ。
    # 【多バイトの文字集合を使わない】C ロケールの awk では `[^。]` がバイト集合になるので、「列挙元 … 。」の範囲は index で切る。
    local _vf2
    _vf2="$(mktemp "${TMPDIR:-/tmp}/gp-verified2.XXXXXX")" || _vf2=""
    if [ -z "$_vf2" ]; then
      report INCOMPLETE G-POPULATION "一時ファイルを作れず verified ブロックの列挙元を確認できない（判定を保留する）"
      return
    fi
    printf '%s\n' "$verified_ids" > "$_vf2"
    demote=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk -v VF="$_vf2" '
        BEGIN { while ((getline l < VF) > 0) if (l != "") ver[l] = 1 }
        FNR == 1 { cur = "" }
        /<!-- density-block:/ && !/<!-- \/density-block/ { cur = ""; if (match($0, /DB-[0-9]+/)) { id = substr($0, RSTART, RLENGTH); if (id in ver) cur = id }; next }
        /<!-- \/density-block/ { cur = ""; next }
        cur != "" {
          probe = $0
          gsub(/[*>]/, "", probe)
          sub(/^[[:space:]]*[-+*][[:space:]]*/, "", probe); gsub(/^[[:space:]]+/, "", probe)
          # 表の行だけをセルに分ける（走査コマンドの中の | で値を切らない。2026-09-24 是正と同じ）
          if (probe ~ /^\|/) {
            nc = split(probe, cells, "|")
            for (ci = 1; ci <= nc; ci++) {
              cv = cells[ci]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", cv)
              if (cv ~ /^母集団[[:space:]]*(:|：)/) { probe = cv; break }
            }
          }
          if (probe ~ /^母集団[[:space:]]*(:|：)/) agg[cur] = agg[cur] "\n" probe
        }
        END {
          for (id in agg) {
            v = agg[id]
            if (v ~ /spec-extraction\/|01-code-graph|02-analysis|03-audit|code-graph\.md|density-ledger|work-plan\.md|traceability\.md/) {
              print "  " id ": 列挙元が内部成果物なのに verified（隔離検証では分母を確かめられない）"; continue }
            self = 0; rest = v
            while ((k = index(rest, "列挙元")) > 0) {
              rest = substr(rest, k); e = index(rest, "。"); seg = (e > 0) ? substr(rest, 1, e) : rest
              if ((index(seg, "下表") || index(seg, "本表") || index(seg, "この表") || index(seg, "上表")) && !index(v, "ではなく")) self = 1
              rest = substr(rest, 4)
            }
            if (self) { print "  " id ": 列挙元が自表（循環定義）なのに verified（原典から独立に数え直せない）"; continue }
            if (v ~ /(^|[^A-Za-z])(ISO|IEC|IEEE)[[:space:]\/]*[0-9][0-9][0-9][0-9][0-9]?([^0-9A-Za-z]|$)/)
              print "  " id ": 分母の権威が外部規格なのに verified（原典から導出されない）"
          }
        }' 2>/dev/null | LC_ALL=C sort || true)
    rm -f "$_vf2"
    [ -n "$demote" ] && demote="${demote}"$'\n'
  fi
  # 【1 回の report にまとめる】別々に report すると**後の判定が前の early return に隠れる**
  # （実測: 未検証側の FAIL が出ると verified の格下げ要求が表示されなかった）。
  # 片方を直すまでもう片方が見えないのは、どちらも直させたい場面では有害である。
  if [ -n "$miss" ] || [ -n "$bad" ] || [ -n "$demote" ]; then
    local _pmsg="" _pdet="${miss}${bad}"
    if [ -n "$miss" ] || [ -n "$bad" ]; then
      _pmsg="全数主張（すべて / 全経路 / 唯一 / 0 件 等）に母集団の宣言が足りない（未検証 ${n} ブロック。GP-103 ルール7）"
    fi
    if [ -n "$demote" ]; then
      [ -n "$_pmsg" ] && _pmsg="${_pmsg} ／ "
      _pmsg="${_pmsg}分母が原典から再現できないブロックが verified になっている（$(printf '%s' "$demote" | grep -c .) 件。GP-2 / GP-103 ルール7-(c)）"
      _pdet="${_pdet}${demote}対処は 2 つ。(1) 母集団の数え方を**原典を走査する形**に書き換える
（例: 内部のレジストリ行数ではなく、原典を grep したファイル数）。(2) 書き換えられない分母（外部規格由来・
判断で決まる集合など）は**密度ブロックから外し**、台帳の状態を verified 以外に落として別枠で人が確認する。
**どちらも選ばずに verified を名乗らせない。**
"
      # 【verified の格下げ要求だけのときも未完了にする】PASS にすると自己申告が素通りする
      [ -n "$miss" ] || [ -n "$bad" ] || pop_verdict="INCOMPLETE"
    fi
    report "$pop_verdict" G-POPULATION "$_pmsg" "$_pdet"
    return
  fi
  # 【実力どおりに述べる】これは「母集団の行があり、件数と数え方らしい記述がある」ことの
  # **存在検査**である。宣言された母集団が正しいかは機械化しない（隔離 Verify の仕事）。
  if [ "$n" -eq 0 ]; then
    report PASS G-POPULATION "母集団の宣言が必要な未検証ブロックが無く、verified ブロックの列挙元も原典から再現できる形（全数主張なし、または全て検証済み）"
    return
  fi
  report PASS G-POPULATION "全数主張を含む未検証 ${n} ブロックに母集団の行がある（件数と数え方の記述を確認。正しさは Verify が見る）"
}

gate_verify_order() {
  local ledger="$AUDIT/density-ledger.tsv"
  [ -f "$ledger" ] || { report SKIP G-VERIFY-ORDER "density-ledger.tsv が存在しない（未登録段階）"; return; }
  local rows
  rows=$(grep -v '^#' "$ledger" | grep -v '^block_id' | grep -v '^[[:space:]]*$' || true)
  [ -n "$rows" ] || { report SKIP G-VERIFY-ORDER "密度台帳が空（対象ブロックなし）"; return; }
  # ブロックごとに優先型かを本文から導出する（`G-POPULATION` と同じ 1 パス走査の形）。
  # 【姉妹ゲートと対称にする】`G-POPULATION` で直した 2 つの欠陥を、こちらも同じ形で塞ぐ:
  #   (a) `2>/dev/null || true` で awk の fatal（読めないファイル）を捨てると集計が空になり
  #       **「高リスク型が無い」ことにして PASS する**（fail-open）。rc を見て未完了にする。
  #   (b) 真偽値 `inblk` ＋ id 一致要求では、マーカー異常（終了なし・入れ子・同一行）で
  #       ブロックが 1 つも切り出せず**やはり PASS する**。深さで数えて異常を報告する。
  local prio rc=0 errf
  errf="$(mktemp "${TMPDIR:-/tmp}/gates-vo-err.XXXXXX")"
  prio=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk -v NEED="$CLAIM_UNIVERSAL_RE" \
    -v ESSENCE="$( [ "$REBUILD_LAYER" = "off" ] && echo "" || echo "$SPECS/rebuild/" )" '
    function flush() { if (depth > 0 && curf != "") unb[curf] = 1 }
    FNR==1 { flush(); depth = 0; curf = FILENAME; bid = ""; p = 0; delete anc; maxlv = 0; infence = 0 }
    # 【コードフェンス内は見出しと見なさない】出力例に `## …` を貼ると分類が消え、
    # **虚偽の PASS 文が出た**（実測）。`ll_scan` / `G-HOLD-ADR` は既にフェンスを飛ばしている
    # ——**新しいゲートだけがその配慮を欠く**のは非対称なので揃える。
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    # 【見出しは階層で追う】直近の見出し 1 つだけを持っていたため、
    # `## 対外契約` の下に `### エンドポイント一覧` を挟むと**分類が失われて PASS になり、
    # しかも「高リスク型に未検証が残っていない」という虚偽の判定文が出た**（実測）。
    # 能力別・エンドポイント別のサブ節は自然な書き方なので、**祖先を各レベルで保持**する。
    # 【レベル 1 も拾う】`##+` にしていたため `# 別の章` で祖先が切れず、**節の外のブロックを
    # 高リスクと分類した**（実測）。見出しは階層の区切りなのでレベル 1 から扱う。
    /^#+[[:space:]]/ {
      lv = index($0 " ", " ") - 1
      anc[lv] = $0
      for (i = lv + 1; i <= maxlv; i++) delete anc[i]     # 浅い見出しが来たら深い側を捨てる
      if (lv > maxlv) maxlv = lv
      next
    }
    /<!-- density-block:/ {
      if (match($0, /DB-[0-9]+/)) {
        if (depth > 0) nest[FILENAME] = 1
        if ($0 ~ /<!-- \/density-block:/) { same[FILENAME] = 1; next }
        depth++
        if (depth == 1) {
          bid = substr($0, RSTART, RLENGTH)
          # 【前置きを許す】語頭アンカー（`^#+[[:space:]]*対外契約`）にしていたため、
          # **実データで支配的な `## 7. 対外契約（互換性要件）` を 1 件も分類できなかった**
          # （実測: 対外契約を含む見出し 17 本すべてが章番号か前置きを持ち、分類できたのは 0 件。
          # このゲートの根拠にしている「対外契約が最終日に初検証された」件がそのまま漏れていた）。
          # `G-DENSITY` の必須節の突合は `^#{1,4} .*<節名>`（前置き自由）なので**そちらに揃える**
          # ——同じ節の定義を 2 つのゲートが別々に持つと必ず乖離する（教訓 30）。
          # 否定形の節名（「対外契約ではない事項」）だけを外す。
          p = 0
          for (i = 1; i <= maxlv; i++)
            if ((i in anc) && anc[i] ~ /対外契約/ && anc[i] !~ /対外契約[^。]{0,4}?(では|で)?な(い|く)/) p = 1
          # 【本質層（specs/rebuild/）は層そのものを高リスク要因にする】
          # 全称主張と対外契約だけを見ていた初版は、**実測で最も誤りが集まる層を優先対象に
          # していなかった**。独立した 3 成果物の密度台帳で、`rebuild` の 1 ブロックあたり
          # fabricated は **3 本すべてで最上位か準最上位**（2.98 / 5.71 / 2.00）。
          # **modules・data との比では 1.4〜11.8 倍**（modules 0.99 / 4.00 / 0.33、data 1.50 / 1.67 / 0.17）。
          # ただし**全層と比べると最大ではない**——1 本では `cross-cutting`（6.00・n=1）が上、
          # 別の 1 本では `overview`（2.77・n=13）と実質同着である。**根拠は「上位に居続ける」ことの方**。
          # 本質層は全称主張・不変条件・母集団の集計が中心で、実装層の個別 `path:line` 対応と
          # 主張の型が違う（GP-16 ルール10-(7)）。
          # 【前置一致で判定する（部分一致にしない）】`FILENAME ~ /\/rebuild\//` と書いた初版は、
          # **`FILENAME` が絶対パスなのでリポジトリより上に `rebuild` という名のディレクトリが
          # 1 つあるだけで全ファイルが該当**した。全ブロックが高リスクになると「他型の検証済み数」が
          # 常に 0 になり、**追い越し条件が永久に偽＝安心させる文言つきの恒久 PASS（fail-open）**になる。
          # 本質層の述語は同ファイル内で `$SPECS/rebuild` の前置一致に統一されている（教訓 30: 同じ
          # 節の定義を 2 つのゲートが別々に持つと必ず乖離する）。
          # 【`REBUILD_LAYER=off` では効かせない】設定が「作らない」と決めた層の残置物
          # （雛形・purpose 変更前の生成物）を要求する型を再発させない（G-ARTIFACT は明示的に除外している）。
          if (ESSENCE != "" && index(FILENAME, ESSENCE) == 1) p = 1
        }
        next
      }
    }
    depth > 0 && /<!-- \/density-block:/ {
      depth--
      if (depth == 0 && bid != "") { printf "PRIO\t%s\t%d\n", bid, p; bid = "" }
      next
    }
    depth > 0 {
      if ($0 ~ /'"$CLAIM_LINE_RE"'/) { if ($0 ~ NEED) p = 1 }
    }
    END {
      flush()
      for (f in unb)  printf "UNBAL\t%s\t0\n", f
      for (f in nest) printf "NEST\t%s\t0\n", f
      for (f in same) printf "SAMELINE\t%s\t0\n", f
    }' 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    local why; why=$(grep . "$errf" 2>/dev/null | head -3 | sed 's/^/  /' || true); rm -f "$errf"
    report INCOMPLETE G-VERIFY-ORDER "検証順序を集計できなかった（rc=${rc}。仕様ファイルの走査 または awk が失敗した）" \
      "${why:-  stderr は空。仕様ディレクトリの読み取り権限（find が失敗していないか）を確認する}"
    return
  fi
  rm -f "$errf"
  local vo_broken
  vo_broken=$(printf '%s\n' "$prio" | awk -F'\t' -v r="$REPO_ROOT/" '
    function strip(p) { i = index(p, r); return (i == 1) ? substr(p, length(r) + 1) : p }
    $1=="UNBAL"    { printf "  %s: density-block の開始に対する終了が足りない（型を判定できない）\n", strip($2) }
    $1=="NEST"     { printf "  %s: density-block が入れ子になっている（未対応。分割すること）\n", strip($2) }
    $1=="SAMELINE" { printf "  %s: 開始と終了が同一行にある（本文が測れない）\n", strip($2) }' | sort || true)
  if [ -n "$vo_broken" ]; then
    report INCOMPLETE G-VERIFY-ORDER "density-block のマーカーが測れないため検証順序を確認できない" "$vo_broken"
    return
  fi
  prio=$(printf '%s\n' "$prio" | awk -F'\t' '$1=="PRIO" { print $2 "\t" $3 }' || true)
  if [ -z "$prio" ]; then
    report SKIP G-VERIFY-ORDER "密度ブロックのマーカーが 1 つも無い（粒度は G-BLOCK-SIZE が名指しする）"
    return
  fi
  # 台帳の verify_status と突き合わせて 4 つの数を出す
  local counts p_unv p_ver n_ver
  # 【台帳は `-v` で渡さない】`-v R="$rows"` で 700 行超を渡すと awk が改行をエスケープとして
  # 解釈して**空の結果**を返した（実測: 判定文の件数が空欄になった）。ファイルとして読む。
  # 【対象を名指しする】件数だけでは運用者が分類を手で再導出する必要があり、
  # **このゲート群が解決しようとした「判定できない」状態そのもの**になる（姉妹ゲートは列挙する）。
  local unv_list
  unv_list=$(printf '%s\n' "$prio" | awk -F'\t' -v LED="$ledger" '
    function trim(v) { gsub(/\r/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    BEGIN { while ((getline l < LED) > 0) {
              split(l, f, "\t"); id = trim(f[1])
              if (id != "" && id != "block_id" && id !~ /^#/) st[id] = trim(f[5]) } }
    $2 == 1 { key = trim($1); v = (key in st) ? st[key] : "unregistered"
              if (v != "verified") printf "  %s: 高リスク型（全称主張 / 対外契約 / 本質層）で未検証（%s）\n", key, v }' | sort || true)
  counts=$(printf '%s\n' "$prio" | awk -F'\t' -v LED="$ledger" '
    function trim(v) { gsub(/\r/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    BEGIN { while ((getline l < LED) > 0) {
              split(l, f, "\t")
              id = trim(f[1])
              if (id != "" && id != "block_id" && id !~ /^#/) st[id] = trim(f[5]) } }
    { key = trim($1)
      v = (key in st) ? st[key] : "unregistered"
      if ($2 == 1) { if (v == "verified") pv++; else pu++ }
      else         { if (v == "verified") nv++ } }
    END { printf "%d\t%d\t%d\n", pu + 0, pv + 0, nv + 0 }')
  p_unv=$(printf '%s' "$counts" | cut -f1); p_ver=$(printf '%s' "$counts" | cut -f2); n_ver=$(printf '%s' "$counts" | cut -f3)
  if [ "${p_unv:-0}" -eq 0 ]; then
    report PASS G-VERIFY-ORDER "高リスク型（全称主張・対外契約・本質層）に未検証が残っていない（検証済み ${p_ver} 件）"
    return
  fi
  if [ "${n_ver:-0}" -gt "${p_ver:-0}" ]; then
    # 【`off` では合否を持たせない】理由は `gate_population` と同じ（登録の対称性）。
    local vo_verdict="FAIL"
    # 【`warn` でも止めない】`warn` では Verify そのものが任意で、人が求めた範囲だけを検証する（手順書 Step 3-1d）。
    # 範囲の外に高リスク型の未検証が残るのは正常な状態なので、順序の違反として止めると範囲を限った検証ができない。
    [ "$DENSITY_GATES" != "on" ] && vo_verdict="WARN"
    report "$vo_verdict" G-VERIFY-ORDER "高リスク型を後回しにしている（未検証 ${p_unv} 件が残る一方で他型を ${n_ver} 件検証済み。GP-103 ルール6）" \
      "${unv_list}
【なぜ順序が要るか】誤りの密度は層で大きく違い、全称主張の型は引用型の 3〜5 倍の不良率が実測されている。
高リスクを後回しにすると、最終盤で結論の向きが変わる欠陥が出て手戻りが最大になる。
【何をすればよいか】上に挙げたブロックを先に Verify に回す。
並行は許すが、他型の検証済み数が高リスク型の検証済み数（${p_ver} 件）を超えないようにする。
【対象の見分け方】主張行に すべて／全て／全域／例外なく／全経路／全書き込み経路／どの経路でも を含むブロック、対外契約 の節の中のブロック、または specs/rebuild/（本質層）のブロック。"
    return
  fi
  report PASS G-VERIFY-ORDER "高リスク型を先に検証している（高リスク 検証済み ${p_ver} / 未検証 ${p_unv}・他型 検証済み ${n_ver}）"
}

gate_block_outside() {
  # 【主張の数え方は `G-BLOCK-SIZE` と同一にする】`GP-103` ルール1 の「1 主張 = 1 行」定義。
  # 内と外で式が違うと比率が無意味になる。**同一性は selftest が振る舞いで検査する**
  # （3 形式を外に置いてちょうど +3／内に置いて増えない）。実装文字列の grep では検査しない（教訓 5）。
  #
  # 【`-0` を必ず使う（申し送り 4-①。反証レビューで実測）】改行区切りで `xargs` に渡すと
  # **パスに空白があると語分割**し `awk: can't open file .../sp` になる。しかも本ゲートは rc を
  # fail-closed で見るので、**空白入りのパスに置かれたリポジトリは永久に INCOMPLETE** になる
  # ——利用者が直せない未達＝ゲートを外させる型である。`spec_files` は改行区切りなので
  # **NUL へ詰め替える**（`spec_files` 自体を `-print0` にすると全呼び出し元に影響するのでここで閉じる）。
  # 詰め替えは bash ビルトインだけで行う（`tr` でも動くがプロセスが 1 個増える＝Windows で 0.2 秒）。
  #
  # 【マーカーの扱いは「取りこぼさない側」に倒す】
  #   開始: `G-BLOCK-SIZE` と同じく `DB-N` を要求する
  #   終了: **id の一致を求めない**（id がずれたブロックで以降の主張が「内側」に隠れるのを防ぐ）
  #   **開始だけで終了が無い（不均衡）**: 内側と見なし続けると**以降の全主張が消えて
  #   「ブロック外 0 件」＝偽 PASS になる**（反証レビューで実測）。よって不均衡は `INCOMPLETE` にする。
  #   参照成果物（ボトムアップで完走した版）に不均衡は **0 件**なので完成品は落ちない（実測で確認）。
  local rows rc=0 errf
  errf="$(mktemp "${TMPDIR:-/tmp}/gates-bo-err.XXXXXX")"
  # 【出力は全行 3 列で揃える】`<種別>\t<ファイル>\t<件数>`。種別ごとに列数が違う形にすると
  # 列番号の取り違えで偽 PASS になる（相乗り版から移すとき実際に `$2`/`$3` を間違えて踏んだ）。
  rows=$(spec_files \
    | nul_pack \
    | LC_ALL=C xargs -0 -r awk '
    function flush() { if (depth > 0 && curf != "") unb[curf] = 1 }
    FNR==1 { flush(); depth=0; curf=FILENAME }
    # 【深さで数え、入れ子は「未対応」として明示的に止める】ここは 3 回作り直した。
    #   初版（真偽値 `inblk`）: 「ファイル内の**最後の**開始が閉じていない」場合しか捕まえられず、
    #     閉じ忘れの下に均衡ブロックを書くと**不均衡が消えたうえで飲まれた主張も消えた**。
    #   2 版（再オープン＝不均衡）: **正しく閉じた入れ子を不均衡と誤判定**し、診断文が
    #     「閉じマーカーが無い」と**事実に反する**ことを言った。内側を閉じた時点で深さが 0 に戻るので
    #     **外側の残りを「外」に誤計上**もした。
    #   3 版（深さで数え入れ子を通す）: `G-BLOCK-OUTSIDE` は通るが **`gate_block_size` は
    #     真偽値＋id 一致要求なので同じ入力を「マーカーが無い」で INCOMPLETE にした**
    #     ——「合法入力で exit 1・診断文が虚偽」が別ゲートへ移動しただけだった（5 巡目が実測）。
    # ⇒ **入れ子は未対応と決める**。入れ子はブロックの境界をぼかすので用途が無い（`GP-103` ルール1。旧: 1 エンティティ / 1 エンドポイントを
    #   上限としており入れ子に正当な用途が無い。**両ゲートの扱いを一致させ、文言を事実に合わせる**
    #   （「未対応」と言えば利用者は直せる。「閉じマーカーが無い」と言うと直せない）。
    /<!-- density-block:/ {
      if (match($0, /DB-[0-9]+/)) {
        if (depth > 0) nest[FILENAME] = 1          # 入れ子は未対応（別種として報告する）
        depth++
        # 【開始と終了が同一行】規約の記載例が 1 行形式だったため、素直に 1 行で書くと
        # 「閉じ忘れ」と誤報告していた（5 巡目が実測）。同一行の終了はここで閉じる。
        # なお 1 行形式は `gate_block_size` が測れないので、規約側で「独立した行に置く」に統一した。
        if ($0 ~ /<!-- \/density-block:/) depth--
        next
      }
    }
    # 【終了マーカーはコロンを要求する】`gate_block_size` が `<!-- /density-block:` を要求するので
    # 揃える（揃えないと「片方は均衡・もう片方は測定不能」という矛盾した報告になる。5 巡目 L5）。
    # 【コロンが無い終了マーカーは「閉じ忘れ」ではない（7 巡目 M-3）】そのまま無視すると
    # **実在する閉じマーカーについて「閉じ忘れ」と虚偽の診断を出す**（6 巡目 M-1 で
    # `G-BLOCK-SIZE` 側を直したのと同じ型が、こちらに残っていた）。別種として名指しする。
    depth > 0 && /<!-- \/density-block[^:]/ { nocolon[FILENAME] = 1 }
    depth > 0 && /<!-- \/density-block:/ { depth--; next }
    depth == 0 && ($0 ~ /'"$CLAIM_LINE_RE"'/) { out[FILENAME]++ }
    END {
      flush()
      for (f in out) printf "OUT\t%s\t%d\n", f, out[f]
      for (f in unb) printf "UNBAL\t%s\t0\n", f
      for (f in nest) printf "NEST\t%s\t0\n", f
      for (f in nocolon) printf "NOCOLON\t%s\t0\n", f
    }
  ' 2>"$errf") || rc=$?
  # 【rc を捨てない（申し送り 5 の罠 1）】awk は開けないファイルで fatal 終了し、
  # **それまでに読んだ分も出さない**（`END` に到達しないため）。`2>/dev/null || true` で
  # 潰すと集計が空になり「ブロック外 0 件」＝合格に見える（fail-open）。測れないなら未完了にする。
  # 【rc の出所を awk に決めつけない】`pipefail` 下では `spec_files`（`find`）の失敗も同じ rc に
  # 現れる（実測: 仕様ディレクトリを `chmod 000` にすると rc=1 だが awk の stderr は空）。
  # `spec_files` は stderr を捨てているので原因行が無いこともある——**そう書く**
  # （「awk が失敗」と断定すると調査が空振りする。gates.sh 冒頭の「名指しする」原則の範囲で最善を尽くす）。
  if [ "$rc" -ne 0 ]; then
    local why; why=$(grep . "$errf" 2>/dev/null | head -3 | sed 's/^/  /' || true); rm -f "$errf"
    report INCOMPLETE G-BLOCK-OUTSIDE "ブロック外の主張を集計できなかった（rc=${rc}。仕様ファイルの走査 または awk が失敗した）" \
      "${why:-  stderr は空。仕様ディレクトリの読み取り権限（find が失敗していないか）を確認する}"
    return
  fi
  rm -f "$errf"
  local n_specs
  n_specs=$(spec_files | grep -c . || true)
  if [ "${n_specs:-0}" -eq 0 ]; then
    report SKIP G-BLOCK-OUTSIDE "仕様ファイルが無い（未生成段階）"
    return
  fi
  # 【マーカー不均衡は測定不能として扱う】これを WARN や PASS に落とすと、閉じ忘れ 1 個で
  # そのファイルの主張が全部消える（偽 PASS）。列は常に `$1`=種別 `$2`=ファイル `$3`=件数。
  local unbal
  # 【`sub()` を使わない】`REPO_ROOT` に正規表現メタ文字（`.` `+` 等）が含まれると前置が剥がれず
  # **絶対パスが gate-details.log に残る**（実測。コミット対象の成果物に環境依存パスが混ざる）。
  # リテラル一致で剥がす。`gate_block_size` 側が使う `${f#"$REPO_ROOT"/}` と同じ意味にする。
  unbal=$(printf '%s\n' "$rows" | awk -F'\t' -v r="$REPO_ROOT/" \
    'function strip(f){ return (index(f,r)==1) ? substr(f,length(r)+1) : f }
     $1=="UNBAL"{ printf "  %s: 開始マーカーの数が終了マーカーの数を上回る（閉じ忘れ）\n", strip($2) }
     $1=="NEST" { printf "  %s: 密度ブロックが入れ子になっている（未対応。入れ子はブロックの境界をぼかす。GP-103 ルール1）\n", strip($2) }
     $1=="NOCOLON" { printf "  %s: 終了マーカーにコロンが無い（`<!-- /density-block: DB-N -->` と書く）\n", strip($2) }' | sort)
  # 【測れないファイルを集計から外す】不均衡・入れ子のファイルは主張が飲まれているので、
  # その件数を混ぜると**桁違いの過少値を「N 件」として提示する**ことになる（5 巡目が実測: 真値 54 に対し 4 件）。
  # 集計から外し、**残りの件数は「下限」と明示する**。
  # 【`awk -v` にファイル一覧を渡さない（6 巡目が実測）】**BSD/macOS awk は `-v` の値に改行を許さず**
  # `awk: newline in string …` で起動時に死ぬ。除外対象が **2 件以上**あると両方の集計が空になり、
  # **壊れた数値がコミット対象の成果物（gate-results.md / gate-details.log）に残り、
  # 絶対パスが stderr に漏れた**。しかも「複数ファイルで同時に閉じ忘れ」＝最も鳴ってほしい局面が該当する。
  # ⇒ **同じ 1 パスの中で除外集合を作る**（外から渡さない。プロセスも 1 つ減る）。
  local agg
  agg=$(printf '%s\n' "$rows" | awk -F'\t' '
    $1=="UNBAL" || $1=="NEST" || $1=="NOCOLON" { bad[$2]=1 }
    $1=="OUT" { o[$2]=$3 }
    END { n=0; t=0; for (f in o) if (!(f in bad)) { n++; t+=o[f] } printf "%d\t%d\n", n, t }')
  local files total
  files=$(printf '%s' "$agg" | cut -f1); total=$(printf '%s' "$agg" | cut -f2)
  if [ -n "$unbal" ]; then
    # 【測れた分の件数も出す】このゲートの存在理由は「消すのではなく数字を出し続ける」ことなので、
    # 未完了にするときも**測れた範囲の件数は併記する**（執筆途中＝不均衡が最も起きる局面で
    # 数字が消えると目的そのものが達成できない）。ただし**下限であることを明示する**。
    report INCOMPLETE G-BLOCK-OUTSIDE \
      "密度ブロックのマーカーが測れない箇所がある（$(printf '%s\n' "$unbal" | grep -c . || true) 件。閉じ忘れ / 入れ子 / 終了マーカーのコロン欠落。**1 仕様が複数該当しうる**）。以降の主張を数えられず 0 件に見えるので測定不能として扱う（測れた仕様だけの合計はブロック外 ${total} 件 / ${files} 仕様＝**下限**）" "$unbal"
    return
  fi
  if [ "${total:-0}" -eq 0 ]; then
    report PASS G-BLOCK-OUTSIDE "密度ブロックの外に path:line 主張が無い（検査 ${n_specs} 仕様）"
    return
  fi
  # 【「内 ＋ 外 ＝ 総数」は成立しない】深さで数えるので入れ子は正しく「内」に入るが、
  # 開始と終了で `DB-N` の番号が食い違うブロックは `G-BLOCK-SIZE` 側で未測定になる
  # （そちらが INCOMPLETE で可視化する）。よって**両ゲートの合計を突合に使ってはいけない**。
  report WARN G-BLOCK-OUTSIDE \
    "ブロック外の path:line 主張 ${total} 件 / ${files} 仕様（Verify を受けていない。GP-22 冒頭により約 35% の誤りが残っている前提で扱う。**判定には影響させない**）" \
    "$(printf '%s\n' "$rows" | awk -F'\t' -v r="$REPO_ROOT/" \
      'function strip(f){ return (index(f,r)==1) ? substr(f,length(r)+1) : f }
       $1=="OUT"{ printf "  %s: %d 件\n", strip($2), $3 }' | sort)"
}

# --- G-BLOCK-SIZE: 密度ブロックの粒度上限（GP-103 / SB-102） ---
# 【なぜ必要か】fabricated=0 は全数合格ゲートなので、1 ブロックの主張数が多いと
# 1 ラウンドで通る確率が指数的に下がる（1 主張 95% 正答でも 100 主張なら 0.6%）。
# 実運用（FB-7）で 1 ブロック ≒ 100 主張・52KB に課して 7 ラウンド／未収束となり、
# 現場は「2 ラウンド上限」＝反映ゲートの実質無効化に倒れた。
#
# 【主張の数え方（定義。実装と一致させる）】
#   **1 主張 = 1 行**。「`path:line` を含む行」＋「先頭がコード表記の表データ行」を数える。
#   **出現回数ではない**——データディクショナリ行は 1 行に 3〜5 個の `path:line` を持つため、
#   出現回数で数えると 16 列の表が「41 主張」になる（行単位なら 17）。skill の定義もこれに一致する。
#
# 【ブロック単位で測る（旧実装のファイル平均近似は両方向に外れた）】
# 旧実装は「ファイル合計 ÷ 同一ファイルのブロック数」で按分し「過小評価に倒す」と書いていたが、
# 実測（roller-spec）で**両方向に外れた**:
#   (a) 偽陰性: ブロックの大きさが不均等だと超過ブロックが平均に埋もれる
#       → ゲートは PASS だったが per-block では **7 ブロックが上限超過**（最大 20 主張行）。
#   (b) 偽陽性: ブロック外の散文がバイト数を水増しする
#       → per-block 最大 8,182 バイト（上限内）のファイルが平均 10,582 バイトと算出され FAIL。
# よって**ブロック境界マーカーで本文を切り出し、ブロック単位・行単位で数える**。
#
# 【マーカー規約】密度昇格ブロックは仕様本文を次で囲む（`init.sh` が配る台帳定義にも明記）:
#   <!-- density-block: DB-001（任意の説明） -->  …本文…  <!-- /density-block: DB-001 -->
# マーカーが無いブロックは**測定不能**なので INCOMPLETE で報告する（PASS に落とさない。GP-6 設計原則）。
# 【バイト数の数え方】本文の各行 ＋ 改行 1 バイトを合計する（マーカー行自身は含めない）。
# 開始マーカー直後の改行を含める実装とは **1 バイトだけ差が出る**（8192 の判定には影響しない）。
# 突合時に「1 バイトずれ」を欠陥と誤読しないよう、数え方をここに固定しておく。
#
# 【判定の設計】上限超過でも **verified に到達済みのブロックを機械的に FAIL にしない**。
# それをすると既存の verify-log と台帳の対応を捨てることになる（作り直しコストが対策を破る＝FB-7 と同型）。
#   超過 かつ 未 verified → FAIL（これから Verify するので今分割すれば安い）
#   超過 かつ verified   → 列挙のみ（受容済みの逸脱。分割は任意。ADR に記録する運用でよい）
BLOCK_MAX_CLAIMS="${BLOCK_MAX_CLAIMS:-15}"
BLOCK_MAX_BYTES="${BLOCK_MAX_BYTES:-8192}"
# CRLF の gate-config.env で正しい値が「数値でない」にならないよう、他の設定値と同じく CR を剥がす
BLOCK_MAX_CLAIMS="${BLOCK_MAX_CLAIMS%$'\r'}"; BLOCK_MAX_BYTES="${BLOCK_MAX_BYTES%$'\r'}"
# 【上限は締めることしか許さない（2026-10-01）】環境変数・gate-config.env から検証なしに入り、大きな値でも数値でない値
#  （`[ -gt ]` がエラーで偽になる）でも G-BLOCK-SIZE が PASS した。GP-103 の上限は収束の実測から決めた値なので、
#  **既定より緩い値・数値でない値は既定に戻し、そのことを G-BLOCK-SIZE が報告する**。
BLOCK_LIMIT_NOTE=""
case "$BLOCK_MAX_CLAIMS" in ''|*[!0-9]*|??????*) BLOCK_LIMIT_NOTE+="BLOCK_MAX_CLAIMS=${BLOCK_MAX_CLAIMS} は数値でない（または桁あふれ）; "; BLOCK_MAX_CLAIMS=15 ;; esac
case "$BLOCK_MAX_BYTES" in ''|*[!0-9]*|????????*) BLOCK_LIMIT_NOTE+="BLOCK_MAX_BYTES=${BLOCK_MAX_BYTES} は数値でない（または桁あふれ）; "; BLOCK_MAX_BYTES=8192 ;; esac
[ "$BLOCK_MAX_CLAIMS" -gt 15 ] && { BLOCK_LIMIT_NOTE+="BLOCK_MAX_CLAIMS=${BLOCK_MAX_CLAIMS} は既定 15 より緩い; "; BLOCK_MAX_CLAIMS=15; }
[ "$BLOCK_MAX_BYTES" -gt 8192 ] && { BLOCK_LIMIT_NOTE+="BLOCK_MAX_BYTES=${BLOCK_MAX_BYTES} は既定 8192 より緩い; "; BLOCK_MAX_BYTES=8192; }
# 【G-BLOCK-SIZE の列挙（判定に影響させない）】判定行の後に出すため、各出口から呼ぶ。
_bs_wide_note() {
  [ -n "${wide_over:-}" ] || return 0
  note_detail G-BLOCK-SIZE "パス省略形の引用（ファイル名を省いた :NN の形）を主張に数えると上限を超えるブロック $(echo -n "$wide_over" | grep -c .) 件（判定には影響させない。分割を検討する）" "$wide_over"
}
gate_block_size() {
  local ledger="$AUDIT/density-ledger.tsv"
  if [ -n "$BLOCK_LIMIT_NOTE" ]; then
    report FAIL G-BLOCK-SIZE "粒度の上限を緩める・壊す設定がある（既定 15 主張行 / 8192 バイトに戻して判定する。上限は締めることしかできない。GP-103）" "  ${BLOCK_LIMIT_NOTE}"
    return
  fi
  [ -f "$ledger" ] || { report SKIP G-BLOCK-SIZE "density-ledger.tsv が存在しない"; return; }
  local rows
  rows=$(grep -v '^#' "$ledger" | grep -v '^block_id' | grep -v '^[[:space:]]*$' || true)
  [ -n "$rows" ] || { report SKIP G-BLOCK-SIZE "密度台帳が空（対象ブロックなし）"; return; }

  # ブロック本文を 1 パスで切り出して測る（grep/awk のみ。外部言語に依存しない＝GP-9）。
  # LC_ALL=C で length() をバイト数として扱う（マルチバイトを文字数で数えると上限判定がずれる）。
  local measured
  measured=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk '
    FNR==1 { inblk=0; bid="" }
    /<!-- density-block:/ {
      if (match($0, /DB-[0-9]+/)) { bid=substr($0,RSTART,RLENGTH); inblk=1; claims=0; wclaims=0; bytes=0; next }
    }
    inblk && /<!-- \/density-block:/ {
      if (match($0, /DB-[0-9]+/) && substr($0,RSTART,RLENGTH)==bid) {
        printf "%s\t%d\t%d\t%s\t%d\n", bid, claims, bytes, FILENAME, wclaims
        inblk=0; bid=""; next
      }
    }
    inblk {
      bytes += length($0) + 1
      if ($0 ~ /'"$CLAIM_LINE_NARROW_RE"'/) claims++
      if ($0 ~ /'"$CLAIM_LINE_RE"'/) wclaims++
    }
    # 【ブロック外の主張は `G-BLOCK-OUTSIDE` が数える】一度ここに相乗りさせたが、
    # **このゲートは台帳が無い／空のとき早期 return する**ため、密度ブロック化前の段階では
    # 一度も走らなかった（2026-09-12 の欠陥修正）。独立ゲートに切り出した。
  ' 2>/dev/null || true)

  local bad="" accepted="" unmeasured="" wide_over="" total=0
  while IFS=$'\t' read -r bid _spec_file _c3 _c4 vstatus _rest; do
    [ -n "${bid:-}" ] || continue
    total=$((total + 1))
    local line n b f w
    line=$(echo "$measured" | awk -F'\t' -v b="$bid" '$1==b {print; exit}')
    if [ -z "$line" ]; then
      # 【文言を事実に合わせる（6 巡目）】マーカーが**実在しても**測れない形が 4 つある
      # （入れ子・開始と終了が同一行・開始と終了で id が食い違う・終了にコロンが無い）。
      # 「無い」と断定すると、その 4 形式では**唯一の手掛かりが虚偽**になり利用者が直せない。
      unmeasured+="  ${bid}: density-block マーカーが対になっていない（未記入／入れ子／開始と終了が同一行／id 不一致／終了のコロン欠落のいずれか。粒度を測定できない）"$'\n'
      continue
    fi
    n=$(echo "$line" | cut -f2); b=$(echo "$line" | cut -f3); f=$(echo "$line" | cut -f4); w=$(echo "$line" | cut -f5)
    f="${f#"$REPO_ROOT"/}"
    # 【主張 0 のブロックを通さない】実運用で、引用が分析物 ID だけのブロックが
    # **主張行 0 と測られて「上限内」で PASS**した（8 ブロック中 2 件）。
    # 「密度ブロックなのに密度が測れていない」状態はゲートを通してはならない——
    # 上限の検査は下限の検査を含意しない（GP-103 と同じ「量を指定する」原則の裏側）。
    # 【主張行 0 の判定は広い述語で見る（2026-09-28）】引用がすべてパス省略形（`:NN`）のブロックは
    # 主張を持つのに「主張行 0＝密度が測れない」と誤って未完了にしていた（参照成果物で実測）。
    if [ "${w:-0}" -eq 0 ]; then
      unmeasured+="  ${bid}: 主張行 0（path:line を持つ行が無い＝密度が測れない）— ${f}"$'\n'
      continue
    fi
    # 【広い数え方の超過は列挙だけ】判定は狭い述語のまま（CLAIM_LINE_RE の定義の注記を参照）。
    if [ "${w:-0}" -gt "$BLOCK_MAX_CLAIMS" ] && [ "${n:-0}" -le "$BLOCK_MAX_CLAIMS" ] && [ "${b:-0}" -le "$BLOCK_MAX_BYTES" ]; then
      wide_over+="  ${bid}: パス省略形の引用を含めると ${w} 主張行（ゲートの数え方では ${n}。上限 ${BLOCK_MAX_CLAIMS}）— ${f}"$'\n'
    fi
    if [ "${n:-0}" -gt "$BLOCK_MAX_CLAIMS" ] || [ "${b:-0}" -gt "$BLOCK_MAX_BYTES" ]; then
      local rec="  ${bid}: ${n} 主張行 / ${b} バイト（上限 ${BLOCK_MAX_CLAIMS} / ${BLOCK_MAX_BYTES}）— ${f}"
      if [ "${vstatus:-}" = "verified" ]; then
        accepted+="${rec} ← verified 済み（受容済みの逸脱。分割は任意）"$'\n'
      else
        bad+="${rec}"$'\n'
      fi
    fi
  done <<< "$rows"

  # マーカー未記入は「測れない」＝作業を進めれば解消する未完了（PASS に落とさない）
  if [ -n "$unmeasured" ] && [ -z "$bad" ]; then
    # 【判定行も事実に合わせる（7 巡目 M-2）】`gate-results.md` は検証結果の**正本**なので、
    # ここが「マーカー未記入」と断定していると、詳細行で「対になっていない」と書いても
    # **上位の行が虚偽のまま残る**（マーカーが実在しても測れない形が 4 つある）。
    report INCOMPLETE G-BLOCK-SIZE "粒度を測定できないブロックがある（マーカーが対になっていない または 主張行 0。$(echo -n "$unmeasured" | grep -c .) 件 / 全 ${total} 件）" "${unmeasured}${accepted}"
    _bs_wide_note
    return
  fi
  if [ -z "$bad" ]; then
    if [ -n "$accepted" ]; then
      report PASS G-BLOCK-SIZE "未検証ブロックはすべて粒度上限内（全 ${total} 件）。verified で超過するものは受容済みの逸脱"
      note_detail G-BLOCK-SIZE "受容済みの逸脱（verified で上限超過。分割は任意。ADR に残す運用でよい）" "$accepted"
    else
      report PASS G-BLOCK-SIZE "密度ブロック ${total} 件すべて粒度上限内（${BLOCK_MAX_CLAIMS} 主張行 / ${BLOCK_MAX_BYTES} バイト）"
    fi
  elif [ "$DENSITY_GATES" = "on" ]; then
    report FAIL G-BLOCK-SIZE "未検証のまま粒度上限を超えているブロックが $(echo -n "$bad" | grep -c .) 件（Verify が収束しない。分割せよ＝GP-103 ルール1）" "${bad}${unmeasured}${accepted}"
  else
    report WARN G-BLOCK-SIZE "粒度上限を超えているブロックがある（purpose=${PURPOSE} のため警告のみ）" "${bad}${unmeasured}${accepted}"
  fi
  _bs_wide_note
}

# --- Phase 1 用: work-plan の 3 部構成と分母一致（GP-17 / SB-11） ---
gate_workplan() {
  [ -f "$WORKPLAN" ] || { report FAIL G-WORKPLAN "work-plan.md が存在しない（GP-17: Phase 1 の最終成果物）"; return; }
  local missing=""
  grep -q '^## (A)' "$WORKPLAN" || missing+="(A) 作業項目一覧が見つからない"$'\n'
  grep -q '^## (B)' "$WORKPLAN" || missing+="(B) DoD チェックリストが見つからない"$'\n'
  grep -q '^## (C)' "$WORKPLAN" || missing+="(C) 一度きりの横断成果物リストが見つからない"$'\n'
  if [ -n "$missing" ]; then
    report FAIL G-WORKPLAN "work-plan の 3 部構成が不完全" "$missing"
    return
  fi
  # 分母一致の記録欄が未記入（<N = N プレースホルダ）でないか
  if grep -q '<N = N' "$WORKPLAN"; then
    report FAIL G-WORKPLAN "分母の一致確認が未記入（(A) ノード数 = コードグラフ総数 を確認・記録すること）"
    return
  fi

  # (C) の未完了行に「残量」が数値で入っているか（GP-17 ルール2 (C) / FB-14）
  # 実測: 繰り越しを **「5 件」と件数だけで書いた計画**があり、その中身は密度ブロック 709 件・
  # 証跡 905 件・2 巡目以降 194 件だった。「5 件」からこの規模は読めない。
  # **量を書かない繰り越しは「後でやる」と同義**で、FB-4（先送りが完了宣言に流れ込む）の再来になる。
  # 【設計】列は NF 相対で取る（セル内の `|` はエスケープ前提。他ゲートと同じ規約）。
  #   末尾 `|` があるため $NF は空。$(NF-1)=残量 / $(NF-2)=状態。
  #   **残量列そのものが無い旧版の計画書は INCOMPLETE で残す**（列をずらして誤読しない）。
  local c_section c_header
  c_section=$(awk '/^## \(C\)/{f=1;next} f&&/^## /{exit} f' "$WORKPLAN" 2>/dev/null | grep -E '^\|' || true)
  c_header=$(echo "$c_section" | grep -m1 -E '^\|[[:space:]]*成果物' || true)
  if [ -z "$c_header" ]; then
    report INCOMPLETE G-WORKPLAN "(C) の表ヘッダ（| 成果物 | …）が見つからない（表の形式が崩れている）"
    return
  fi
  case "$c_header" in
    *残量*) : ;;
    *)  report INCOMPLETE G-WORKPLAN "(C) に「残量」列が無い（旧版の計画書。GP-17 ルール2 (C) で必須になった）" \
          "  ヘッダに「残量（数値 ＋ 換算根拠）」列を追加し、実施済でない行に量を記入すること"
        return ;;
  esac
  local noqty
  noqty=$(echo "$c_section" | grep -vE '^\|[[:space:]]*成果物' | grep -vE '^\|[-:| ]+\|?[[:space:]]*$' \
    | awk -F'|' '
      { name=$2; state=$(NF-2); qty=$(NF-1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        gsub(/[[:space:]*`]/, "", state); gsub(/^[[:space:]]+|[[:space:]]+$/, "", qty)
        if (name == "") next
        # 完了・非該当の行は残量を要求しない
        if (state ~ /実施済|該当なし|対象外/) next
        # 【雛形判定は「セル全体が <...> の形」に限る】`<` が 1 文字あるだけで弾くと、
        # `<join-table>` `<allowed-methods>` のような**実在する要素名を残量欄に書けない**
        # （実運用で踏んだ偽陽性。2026-09-03）。雛形は `<N 件 / 換算: …>` の形なので
        # **先頭が `<` かつ末尾が `>`** のときだけ未記入と見なす。
        # 【バッククォートを先に剥がす】剥がさなかった初版は、**数字を含む雛形を
        # バッククォートで囲むだけで PASS になった**（実測: `` `<100 件 / 換算: 後で>` `` で
        # INCOMPLETE → PASS）。数字があるので「数値が無い」側の判定も抜ける。
        # `state` 側は既にバッククォートを剥がしており、**同じ行の中で非対称**だった。
        gsub(/`/, "", qty)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", qty)
        if (qty ~ /^<.*>$/)       { print "  " name ": 残量が雛形のまま（" qty "）"; next }
        if (qty !~ /[0-9]/)       { print "  " name ": 残量に数値が無い（状態=" state "）"; next }
      }' || true)
  # 【ここで return しない】残量とカナリアは**まとめて報告する**（下記）。
  # 1 件ずつ返すと「1 つ直すと次が現れる」状態になる。
  # 【カナリア実測（2026-09-16 に旧 `gate_tier` (9) から移設）】
  # 【塞ぐ穴】深掘りの手順は**実際に 1 能力を通して初めて** 8 件の欠落と
  # ゲートの偽陽性 1 件・偽陰性 3 件を露呈した——**手順を書いただけでは 1 件も出なかった**（FB-14）。
  # 同じことは各対象コードでも起きる（手順の前提と実装構造が合わない）。よって
  # **1 能力を先に通し切って実測し、その数値で残りの範囲を決める**ことを前提条件にする。
  # 【量を要求する理由】「試しに 1 件やった」だけでは FB-6 の再来（実施したことを根拠にする）。
  # 所要時間・fabricated・追加行数・残りの見積りを**数値で**残させる（[[SB-102]]）。
  #
  # 【発火条件は「深掘りに着手した能力の数」】代理指標を 2 回間違えたので経緯を残す:
  #   (1) 刻印 2 以上 → 刻印は撤去された。
  #   (2) 密度台帳の行数 → **1 能力分の作業でも 9 件**載る（api / data / modules / …）ので 1 件目で鳴った。
  #   (3) 能力仕様の件数 → **当時の**手順書 Step 3-0 は全能力の本質層を先に作ったので、
  #       **深掘りに 1 件も着手していない時点で真になった**（実測で再現。着手できなかった）。
  #       **2026-09-23 に順序を反転し、能力ごとに通し切る形にした**（`FB-16`）ので
  #       この代理指標でも動くようになったが、**下の「台帳に載った能力仕様の本数」の方が
  #       直接的なので変えない**（発火条件＝深掘りに着手した能力の数、という意味が明示的）。
  # ⇒ **台帳に載った能力仕様の本数**（= 深掘りに着手した能力の数）を数える。
  #   1 件目のカナリア中は 1 なので鳴らず、2 件目に着手した時点で 2 になる。
  # 【設定が作らないと決めたものは要求しない】`REBUILD_LAYER != full` は本質層を骨子までしか作らない、
  # `DENSITY_GATES=off` は密度を測らない設定である。深掘りの実測を要求すると
  # **設定が禁じたものをゲートが要求する**型になる（この framework で 4 度観測している型）。
  local canary="" canary_n=0 canary_skip=""
  if [ "$REBUILD_LAYER" != "full" ] || [ "$DENSITY_GATES" = "off" ]; then
    canary_skip="REBUILD_LAYER=${REBUILD_LAYER} / DENSITY_GATES=${DENSITY_GATES} では深掘りの実測を求めない"
  else
    # 【突合は `G-LEDGER` と同じ規約で行う】台帳の `spec_file` の表記は 1 つに定まらない
    # （雛形は「`specs/` からの相対パス」と書き、実データはリポジトリルート相対、ファイル名だけの行もある）。
    # **完全一致で突合すると、正当な表記で黙って 0 件になり「2 件目で検査する」と嘘を言う**
    # ——実測で `rebuild/capability-x.md` 表記が 2 → 0、末尾空白 1 つで 2 → 1 になった。
    # ⇒ 姉妹ゲートと同じ **前後空白と CR の除去 ＋ 末尾一致＋パス境界**を使う。
    #
    # 【読めないことを 0 件と混ぜない（fail-closed）】台帳を読めなくするだけで（`chmod 000`・
    # ディレクトリ化・削除）**「深掘りに着手した能力が 0 件」と虚偽の PASS** になる
    # ——`G-LEDGER` が「検査対象を壊すのが最も簡単な全通過方法を作らない」として名指しで禁じている型。
    # 「不在」と「測定不能」を別の判定にする。
    #
    # 【分母を目印に依存させない】`capability_specs` は `artifact-key` で選ぶので、
    # **その 1 行を消すだけでカナリアの要求が解除できた**（実測で INCOMPLETE → PASS）。
    # ⇒ `specs/rebuild/` の非雛形ファイルのうち、**他の成果物形態の目印を持たないもの**を能力仕様と見る
    # （目印が無いものも数える）。実測: 参照成果物の能力仕様 5 件は目印を持たないが
    # `jobs.md` / `nonfunctional.md` は自分の目印を持つので、除外は目印の**値**で行える。
    local wp_ledger="$AUDIT/density-ledger.tsv"
    # 【0 バイトも「測定不能」にする】`: > density-ledger.tsv` で切り詰めると
    # `getline` が 0 を返し「深掘り 0 件」＝ PASS になった（実測）。ヘッダ行の存在まで求める。
    if [ ! -f "$wp_ledger" ] || [ ! -r "$wp_ledger" ] || [ ! -s "$wp_ledger" ] \
       || ! LC_ALL=C grep -q '^block_id' "$wp_ledger" 2>/dev/null; then
      report INCOMPLETE G-WORKPLAN "密度台帳（03-audit/density-ledger.tsv）が読めずカナリア実測の突合ができない（存在しない場合は Phase 3 の深掘りに入る前。壊れている場合は復旧する）"
      return
    fi
    local cap_list
    cap_list=$(find "$SPECS/rebuild" -type f -name '*.md' -not -name '_*' 2>/dev/null | while IFS= read -r cf; do
      [ -n "$cf" ] || continue
      # 他の成果物形態（画面マップ・帳票・ジョブ・非機能）は能力仕様ではない。
      # 【先頭の宣言部だけを見る＋行頭アンカー】ファイル全体を見ると、
      # **本文に説明として `artifact-key: job-spec` と書いた 1 行**で能力仕様から外れた
      # （実測で INCOMPLETE → PASS の反転を再現）。削除方向の穴を塞いだのに**追記方向が開いていた**。
      # 目印は front-matter の前後に `<!-- artifact-key: … -->` として置かれる契約なので、
      # **先頭の `---` ブロックが閉じるまで**に限る（それ以降は本文）。
      LC_ALL=C awk '/^---[[:space:]]*$/ { n++; if (n >= 2) exit } { print }' "$cf" 2>/dev/null \
        | LC_ALL=C grep -qE '^<!--[[:space:]]*artifact-key: (screen-map|report-spec|job-spec|nonfunctional)' && continue
      printf '%s\n' "$cf"
    done || true)
    if [ -n "$cap_list" ]; then
      canary_n=$(printf '%s\n' "$cap_list" \
        | LC_ALL=C awk -v led="$wp_ledger" -v root="$REPO_ROOT/" '
            function strip(f) { return (index(f, root) == 1) ? substr(f, length(root) + 1) : f }
            function trim(v) { gsub(/\r/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); return v }
            BEGIN {
              n = 0; rc = 0
              while ((rc = (getline line < led)) > 0) {
                if (line ~ /^#/) continue
                split(line, f, "\t")
                sf = trim(f[2])
                if (sf == "" || sf == "spec_file") continue
                sub(/^\.\//, "", sf)
                led_sf[++n] = strip(sf)
              }
              close(led)
              # 【読み取り失敗は負値で返す】0 件（不在）と区別してシェル側で INCOMPLETE にする
              if (rc < 0) { print -1; exit }
            }
            {
              cap = strip(trim($0))
              if (cap == "") next
              for (i = 1; i <= n; i++) {
                s2 = led_sf[i]
                if (cap == s2) { hit[cap] = 1; break }
                # 末尾一致＋直前が `/`（`xz.md` は `z.md` に一致しない）
                if (length(cap) > length(s2) && substr(cap, length(cap) - length(s2) + 1) == s2 \
                    && substr(cap, length(cap) - length(s2), 1) == "/") { hit[cap] = 1; break }
              }
            }
            END { if (rc >= 0) { c = 0; for (k in hit) c++; print c } }' || true)
      if [ "${canary_n:-0}" -lt 0 ]; then
        report INCOMPLETE G-WORKPLAN "密度台帳を読めずカナリア実測の突合ができなかった（測定不能。0 件ではない）"
        return
      fi
    fi
  fi
  # 【旧い節名も受ける】改名前の計画書を持つリポジトリを落とさない。  [撤去の記録]
  local canary_sec_re='^### (深掘り|tier 昇格)のカナリア実測'  # [撤去の記録]
  if [ "${canary_n:-0}" -ge 2 ]; then
    local csec
    # 【HTML コメントを剥がす】説明用の表がコメント内にあると、そこに `<例>` を 1 つ書いただけで
    # **永久に「未記入」になる**（`G-DENSITY` が同じ形で踏んだ欠陥。`strip_html_comments` は既存ヘルパ）。
    csec=$(strip_html_comments < "$WORKPLAN" 2>/dev/null \
           | awk -v re="$canary_sec_re" '$0 ~ re {f=1;next} f&&/^#/{exit} f' || true)
    if [ -z "$csec" ]; then
      # 【ここに来た時点で「新しい雛形由来の計画書」が確定している】(C) の残量列の検査を
      # 通過しているため（旧版の計画書は残量列が無く、その手前で INCOMPLETE になる）。
      # よって**節の不在も未達にする**——`G-REPAIR` / `G-QUEUE` と同じ規律で、
      # **節を削除すれば通る**という抜け道を作らない（[[GP-6]] ルール14）。
      canary="  work-plan に「深掘りのカナリア実測」節が無い（雛形から節ごとコピーする。節の削除では解除されない）"
    else
      # 表のデータ行にプレースホルダ `<...>` が残っていれば未記入（実測していない）。
      # 【セル全体が `<...>` の形だけを未記入と見る】行のどこかに `<...>` があれば未記入と数えると、
      # 「手順と実装が合わなかった点」欄に**要素名を書いた瞬間に永久に未記入扱い**になる
      # （実測で PASS↔INCOMPLETE の反転を確認）。(C) の残量検査が 2026-09-03 の実運用偽陽性を受けて
      # 到達した規律と同じにする（同じ関数の中で非対称にしない）。
      local unfilled
      unfilled=$(printf '%s\n' "$csec" | LC_ALL=C awk -F'|' '
        /^\|/ && !/^\|[-: |]+\|?[[:space:]]*$/ {
          for (i = 2; i < NF; i++) {
            c = $i; gsub(/^[[:space:]]*`?|`?[[:space:]]*$/, "", c)
            if (c ~ /^<[^<>]*>$/) { print; next }
          }
        }' | grep -c . || true)
      [ "${unfilled:-0}" -eq 0 ] \
        || canary="  カナリア実測が未記入（${unfilled} 行がプレースホルダのまま。深掘りに着手した能力が ${canary_n} 件あるので 1 件目の実測値が必要）"
    fi
  fi
  # 【未達は種別をまとめて出す】1 件ずつ返すと**1 つ直すと次が現れる**状態になり、
  # 「残る未達が許容できるものだけか」を 1 回の実行で確かめられない
  # （撤去した実装がまさにこれを是正していた。利用者向け文書でも「まとめて全部表示」と説明済み）。
  local wp_unmet="" wp_detail=""
  [ -n "$noqty" ] && { wp_unmet="(C) の未完了項目に残量（数値）が無い"; wp_detail="${noqty}"$'\n'; }
  [ -n "$canary" ] && { wp_unmet="${wp_unmet}${wp_unmet:+ / }カナリア実測が未記入または節が無い"; wp_detail="${wp_detail}${canary}"$'\n'; }
  if [ -n "$wp_unmet" ]; then
    report INCOMPLETE G-WORKPLAN "${wp_unmet}（GP-17 ルール2 (C) / ルール6。件数だけの繰り越しは実行されない。FB-14）" "$wp_detail"
    return
  fi

  # 【検査していないことを「記録済み」と言わない】`G-DENOM` に入れた同じ修正を水平展開する。
  if [ -n "$canary_skip" ]; then
    report PASS G-WORKPLAN "work-plan が 3 部構成で存在し、分母一致と (C) の残量が記録済み（カナリア実測は対象外: ${canary_skip}）"
  elif [ "${canary_n:-0}" -lt 2 ]; then
    # 【原因を断定しない】0 件になる理由は「深掘りが 1 件目」「`specs/rebuild/` が無い」
    # 「台帳に載っていない」のいずれもありうる（`G-LEDGER` と同じ規律）。状態だけを書く。
    report PASS G-WORKPLAN "work-plan が 3 部構成で存在し、分母一致と (C) の残量が記録済み（深掘りに着手した能力が ${canary_n} 件なのでカナリア実測は未検査。2 件目で検査する）"
  else
    report PASS G-WORKPLAN "work-plan が 3 部構成で存在し、分母一致・(C) の残量・カナリア実測が記録済み"
  fi
}

# --- Phase 1 用: コードグラフの形式（ノード ID・プレースホルダ） ---
gate_codegraph_form() {
  [ -f "$CODEGRAPH" ] || { report FAIL G-CODEGRAPH "code-graph.md が存在しない"; return; }
  local node_count
  node_count=$(node_rows | grep -c . || true)
  if [ "$node_count" -eq 0 ]; then
    report FAIL G-CODEGRAPH "ノードが 1 件も列挙されていない"
    return
  fi
  # テンプレの空行ノード（NODE-MOD-01 | | | | 未着手 のような未記入）を検出
  local empty_nodes
  empty_nodes=$(node_rows | awk -F'|' '{gsub(/ /,"",$3); if ($3 == "") print "未記入ノード行: " $2}' || true)
  if [ -z "$empty_nodes" ]; then
    report PASS G-CODEGRAPH "コードグラフに ${node_count} ノードが記入済み"
  else
    report FAIL G-CODEGRAPH "内容が未記入のノード行がある（テンプレ行の残存）" "$empty_nodes"
  fi
}

# =============================================================================
# サブコマンド
# =============================================================================

run_phase1() {
  echo "=== Phase 1 完了ゲート ==="
  gate_codegraph_form
  gate_workplan
  gate_enumeration_source
  gate_enumeration_recorded
  gate_source_intact
}

# Phase 2（分析）の**途中確認**用。完了条件ではない（Phase 2 の完了は work-plan の DoD で管理する）。
# 【なぜ必要か】密度・分母消化・識別子・キューのゲートは phase4 にしかないため、
# 途中の健全性を見るには完了ゲート一式を回すしかなく、**未完了 signal が毎回 10 件出て**
# 切り分けコストと出力量（1 回 79KB）が積み上がっていた（GP-6 ルール13/14 の実測根拠）。
# ここには「進行中でも意味があり、途中で FAIL したら本当に欠陥」のものだけを置く:
#   G-LINK   書いた引用が解決するか（書いた時点で判定可能）
#   G-SPECID 仕様 ID の重複（永続キーなので早く見つけるほど安い）
#   G-COMMIT 断面のずれ（ずれたら以降の path:line が全て無効になる）
#   G-BLOCK-SIZE 密度ブロックの粒度（超過は Verify 発散の予兆。FB-7 を早期に止める）
# **列挙のみのゲート（G-BLOCK-OUTSIDE）はここに入れない**——「欠陥を意味するものだけ」に反する。
run_phase2() {
  echo "=== Phase 2 途中確認ゲート（完了条件ではない。進行中でも欠陥を意味するものだけ） ==="
  gate_link_closure
  gate_specid_unique
  gate_source_commit
  # 【`G-SOURCE-INTACT` は途中でも欠陥】解析対象が変わったら、以降の path:line が全て疑わしくなる
  gate_source_intact
  # 【`G-POPULATION` は phase2 にも入れる】書いたブロックに母集団の宣言が無いのは
  # **進行中でも欠陥**（検証官が判定できず必ず差し戻る）なので phase2 の趣旨に合う。
  # 早く出るほど手戻りが小さい——「前倒し」の実体はこの登録位置である。
  gate_population
  gate_verify_order
  # 【`G-BLOCK-OUTSIDE` は phase2 に足さない】phase2 は「**進行中でも欠陥を意味するものだけ**」を
  # 出す場（上の見出しのとおり）で、`G-BLOCK-OUTSIDE` は列挙のみ＝欠陥を意味しないので趣旨に合わない。
  # 列挙は `run_density` 経由（`phase4` と `density` サブコマンド）で必ず走るので目的は満たす。
  case "$DENSITY_GATES" in
    off) report SKIP G-BLOCK-SIZE "密度ゲートは purpose=${PURPOSE} のため無効（gate-config.env）" ;;
    *)   gate_block_size ;;
  esac
}

run_phase3() {
  echo "=== Phase 3 完了ゲート ==="
  gate_specid_unique
  gate_source_commit
  gate_source_intact
  gate_link_closure
  gate_index
  gate_readable
  gate_verification_vocab
  gate_source_index
  gate_rebuild_layer
  gate_population
  gate_scan_command
  gate_verify_order
  # 【Phase 3 の完了条件にも入れる】手順書は Phase 3 の完了確認を `phase3` と指定している。
  gate_workplan
}

run_phase4() {
  echo "=== Phase 4 完了ゲート（完了/レディ宣言の前提） ==="
  gate_freshness
  gate_draft
  gate_link_closure
  gate_specid_unique
  gate_source_commit
  gate_source_intact
  gate_denominator
  gate_reconciliation
  gate_unfilled
  gate_integrated_view
  gate_tracker
  gate_category_symmetry
  gate_artifact_form
  gate_enumeration_source
  gate_enumeration_recorded
  gate_provisional
  gate_hold_adr
  gate_repair
  gate_false_positive
  gate_regression
  gate_rebuild_layer
  gate_identifiers
  gate_queue
  gate_no_dup_state
  gate_session_pointer
  gate_independent_verification
  gate_index
  gate_readable
  gate_verification_vocab
  gate_source_index
  gate_parallel
  # 【`G-WORKPLAN` は `run_density` 経由で回る（2026-09-20）】ここで明示的に呼ぶと
  # `phase4` で 2 回判定され `gate-results.md` に 2 行出る。`run_density` に置いたので不要。
  run_density
}

# --- G-READABLE: 「読んで分かる床」は purpose に関係なく守る ---
# 【なぜ密度から切り離すか（実運用で判明した設計の誤り）】
# `責務`（何のためにあるか / 業務動線の位置 / 誰が使う）の必須化を `required-sections` で実装したため、
# **`DENSITY_GATES=off`（purpose=maintenance の既定）で一緒に無効化されていた**。
# つまり**人間の理解が目的の maintenance でだけ「読んで分かるか」の検査が切れていた**——逆である。
# 密度（実装できる深さ）と可読性（何のためにあるかが書かれているか）は別の要求なので分ける。
# **可読性は purpose に関係なく FAIL 判定**、密度は従来どおり on/warn/off で振る舞う。
#
# 【対象の決め方】仕様ファイル自身の `readable-sections:` マーカーで opt-in する。
# **マーカーが無ければ対象外**（既存リポジトリは雛形を差し替えるまで従来どおり動く＝移行措置が不要）。
gate_readable() {
  local violations="" checked=0 f tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/gates-readable.XXXXXX")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local req
    req=$(grep -m1 -o 'readable-sections:[^-]*' "$f" 2>/dev/null | sed 's/readable-sections:[[:space:]]*//' || true)
    [ -n "$req" ] || continue
    checked=$((checked + 1))
    local sec
    # 【`printf '%s'` にしない】改行が付かないと `read` が最後の行を読み落とし、
    # **ループ本体が 1 度も実行されない**（実測で踏んだ。検査が黙って PASS した）。
    printf '%s\n' "$req" | tr ',' '\n' | while IFS= read -r sec; do
      sec=$(printf '%s' "$sec" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -n "$sec" ] || continue
      if ! grep -qF "## ${sec}" "$f" 2>/dev/null; then
        printf '  %s: 節「%s」の見出しが無い（何のためにあるかが読めない）\n' "${f#"$REPO_ROOT"/}" "$sec"
      else
        # 見出しはあるが中身が空（HTML コメントと空行だけ）は「書いていない」と同じ。
        # 【雛形行を実体と数えない（2026-09-12 追加）】旧 `gate_tier` (5) は
        # `grep -vcE '<[^>]*>'` で雛形行を除外して**実体行 ≥1** を要求していたが、
        # ここは HTML コメントを除いた非空行しか見ていなかった。実測: 節の中身が
        # `| 1 | <アクター> | <対象> |` だけのとき **旧 (5) は FAIL / ここは PASS** に分かれた。
        # (5) をこのゲートへ移設するには**雛形除外が対で必要**である
        # （`G-ENUM-SOURCE` が既に持つ「プレースホルダ残存を検出する」検査の水平展開）。
        local body
        # 【表のヘッダ行も実体と数えない】実測: 中身が「ヘッダ ＋ 区切り ＋ 雛形 1 行」のとき、
        # 雛形行は除外できてもヘッダ行が残って PASS した（旧 (5) はヘッダを列名で除外していたが、
        # このゲートは節名を問わない汎用機構なので列名を決め打ちできない）。
        # **区切り行（`|---|`）の直前の行がヘッダ**という構造で判定する（節名に依存しない）。
        # 【引用マークアップだけを落とす（コード表記を丸ごと落とさない）】
        # 剥がさなかった初版は、**引用したマークアップを含む普通の文**を「雛形行」として
        # 実体から外し、**節が空だと誤判定**した（実測: 1 文だけの節で FAIL）。
        # 一方、**コード表記を丸ごと落とす**形に直した第 2 版は、**雛形のプレースホルダを
        # 囲むだけで実体として通った**（実測: `` `<誰>` `` の雛形行が PASS）——偽陽性を塞いだ
        # 副作用で fail-open を開けた（教訓 47 の型の再発）。
        # ⇒ `strip_quoted_markup`（`gate_unfilled` と共有）で**マークアップにしかない形だけ**を落とす。
        # 【見出しの照合は LC_ALL=C】macOS の UTF-8 ロケールの awk は日本語どうしの `==` を真にする
        # （`"## 責務"=="## 業務動線"` が 1。独立レビューで再現）。要求した節が空でも別の節の中身で PASS していた
        body=$(LC_ALL=C awk -v h="## ${sec}" '$0==h{f=1;next} f&&/^## /{exit} f' "$f" 2>/dev/null \
               | awk '/<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next } {print}' \
               | awk '
                   /^\|[-:| ]+\|?[[:space:]]*$/ { hdr=0; next }   # 区切り行は捨て、直前のヘッダも出さない
                   { if (hdr) print buf; buf=$0; hdr=1 }
                   END { if (hdr) print buf }' \
               | strip_quoted_markup \
               | grep . | grep -vcE '<[^>]*>' || true)
        [ "${body:-0}" -eq 0 ] && printf '  %s: 節「%s」が空または雛形のまま（プレースホルダ `<...>` は実体と数えない）\n' "${f#"$REPO_ROOT"/}" "$sec"
      fi
    done
  done < <(spec_files) > "$tmp" 2>/dev/null || true
  violations=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
  if [ "$checked" -eq 0 ]; then
    report SKIP G-READABLE "readable-sections マーカーを持つ仕様が無い（雛形が旧版。差し替えれば有効になる）"
  elif [ -n "$violations" ]; then
    report FAIL G-READABLE "「何のためにあるか」が書かれていない仕様がある（$(printf '%s' "$violations" | grep -c . || true) 件 / 検査 ${checked} 件）。**purpose に関係なく守る床**" "$violations"
  else
    report PASS G-READABLE "可読性の床を満たす（検査 ${checked} 件。何のためにあるか・業務動線・利用者が書かれている）"
  fi
}

run_density() {
  # 【`case` の外で呼ぶ】`DENSITY_GATES=off` でも走らせる——ブロック外の主張の列挙は
  # 密度ゲートの強さと無関係で、**`off` の既存リポジトリで黙るのが欠陥だった**（2026-09-12）。
  gate_block_outside
  # 【`DENSITY_GATES` に関係なく走らせる】母集団の宣言は密度の強さと無関係で、
  # **全称主張を書いた時点で必要**。ただし `off`（既定の purpose では選ばれない。手で設定した場合のみ）では**合否を持たせない**
  # ——密度を測らない設定の案件で `phase4` を止めるのは過剰で、前例に挙げた `G-BLOCK-OUTSIDE` も
  # 「列挙のみ」に格下げされたゲートである（根拠の取り違えを反証レビューが指摘）。
  gate_population
  gate_scan_command
  gate_verify_order
  # gate-config.env の DENSITY_GATES: on=FAIL 判定 / warn=警告のみ / off=スキップ（SB-18, GP-20/21）
  case "$DENSITY_GATES" in
    off)
      report SKIP G-DENSITY "密度ゲートは purpose=${PURPOSE} のため無効（gate-config.env）"
      ;;
    on|warn)
      gate_density "$DENSITY_GATES"
      gate_density_symmetry
      gate_density_ledger
      gate_verifier_column
      gate_block_size
      ;;
    *)
      # 到達しない（値は入口で検証済み）。**万一到達したら最も厳しい側で走らせる**——
      # 以前ここは WARN 1 行を出すだけで 4 本を走らせず、`off` より緩い状態を作っていた。
      report WARN G-DENSITY "DENSITY_GATES の値が不正: ${DENSITY_GATES}（on/warn/off）。on として実行する"
      gate_density on
      gate_density_symmetry
      gate_density_ledger
      # G-VERIFIER は $DENSITY_GATES を直接見るので、この枝では on を渡す（渡さないと WARN に落ちる。独立レビュー）
      DENSITY_GATES=on gate_verifier_column
      gate_block_size
      ;;
  esac
  # 【カナリア実測は深掘り中に見る（2026-09-20）】発火条件（深掘りに着手した能力 2 件以上）が
  # 真になるのは Phase 3 以降で、手順書が深掘り中に走らせるのは `density` である。
  # `phase1` だけに置くと**構造的に一度も鳴らない**（撤去した実装は phase2 と phase4 の両方にあった）。
  gate_workplan
}

# --- metrics: 完了時スナップショット（プロジェクト横断で「揺れ」を計測可能にする） ---
# 出力先: 03-audit/metrics.tsv（追記型。同一書式でプロジェクト間比較・改善効果測定に使う）
# =============================================================================
# session: セッション終了チェックリストの機械的裏打ち（GP-100）
# =============================================================================
# 散文チェックリストは自己申告で素通りするため、機械確認できる部分をゲート化する。
#
# 【重要】**このサブコマンドは gate-results.md に書き込まない。**
#   `gates.sh` は結果を gate-results.md（git 追跡対象）へ追記するため、
#   「未コミット変更ゼロ」を検査するゲートが**自分の書き込みで必ず FAIL する**
#   （設計時にこの自己矛盾を指摘され、metrics と同じ書き込みなし経路にした）。
run_session() {
  echo "=== セッション終了チェック（GP-100。Tier 1・指示を待たず実行） ==="
  local sc="$WROOT/worklog/session-context.md"
  local fails=0

  # --- G-SESSION-EXISTS: 引き継ぎファイルの実在（最初に検査する） ---
  # 【最重要】これが無いと以下の 3 ゲートが `[ -f "$sc" ]` で沈黙し、
  # **引き継ぎファイルを削除するのが最も簡単な「全通過」方法**になる（実測でこの回避が成立した）。
  # 検査対象の不在を「検査しない」に落とさない（GP-6 設計原則）。
  if [ ! -f "$sc" ]; then
    echo "❌ [FAIL] G-SESSION-EXISTS: worklog/session-context.md が存在しない（引き継ぎ情報が失われる。GP-100）"
    echo ""
    echo "--------------------------------------------------"
    echo "❌ 未達 1 件。session-context.md を復元してからセッションを終えること。"
    return 1
  fi
  echo "✅ [PASS] G-SESSION-EXISTS: 引き継ぎファイル（session-context.md）が存在する"

  # --- G-SESSION-CLEAN: 未コミット変更ゼロ ---
  # gates.sh 自身が生成する gate-results.md / metrics.tsv は除外する（自己汚染の回避）。
  local dirty
  # 【実行ビットの差を見ない】Windows 側のツールで作ったファイルは、WSL の git から見ると実行ビットだけが違い、
  #  内容の差が 0 行でも「未コミット」に数えられた（完走試験 2 回とも。仕様リポジトリは実行ビットを管理しない）。
  #  init.sh も core.fileMode=false を設定するが、設定はクローンに引き継がれないのでゲート側でも指定する。
  dirty=$(cd "$REPO_ROOT" && git -c core.fileMode=false status --short 2>/dev/null \
          | grep -v 'gate-results\.md' | grep -v 'metrics\.tsv' || true)
  if [ -z "$dirty" ]; then
    echo "✅ [PASS] G-SESSION-CLEAN: 未コミット変更なし（gate-results/metrics を除く）"
  else
    echo "❌ [FAIL] G-SESSION-CLEAN: 未コミット変更が残っている（$(echo "$dirty" | wc -l | tr -d ' ') 件）"
    echo "$dirty" | sed 's/^/      /'
    fails=$((fails + 1))
  fi

  # --- G-SESSION-CONSISTENT: dirty なのに作業ツリー台帳が空 ---
  # 「何だったか分からない変更」を次セッションに引き継ぐのを防ぐ（GP-28 ルール5）。
  if [ -n "$dirty" ]; then
    # 台帳の実体行を（ファイル名, 分類）で取り出す。
    # 【重要】単に「行があるか」ではなく **dirty な各ファイルが台帳に載っているか** を見る
    #   （無関係なファイルを 1 行書くだけで通る回避を塞ぐ。実測でこの回避が成立した）。
    # また分類語彙を許可リストで検査する（語彙外を書けば素通りする。教訓 17）。
    local ledger_rows unlisted="" bad_class=""
    ledger_rows=$(awk -F'|' '/^### .*作業ツリー台帳/{f=1;next} f&&/^##? /{exit}
      /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
      f && /^\|/ && $0 !~ /^\|[- |]*\|$/ && $0 !~ /ファイル *\|/ {
        fn=$2; cl=$3
        gsub(/^[ \t`]+|[ \t`]+$/,"",fn); gsub(/^[ \t]+|[ \t]+$/,"",cl)
        if (fn != "") print fn "\t" cl
      }' "$sc")
    if [ -z "$ledger_rows" ]; then
      echo "❌ [FAIL] G-SESSION-CONSISTENT: 未コミット変更があるのに作業ツリー台帳が空（分類を記録すること。GP-28 ルール5）"
      fails=$((fails + 1))
    else
      # 分類語彙の検査
      while IFS=$'\t' read -r fn cl; do
        case "$cl" in
          *provisional*|*candidate-fix*) ;;
          *) bad_class+="  分類が語彙外「${cl}」: ${fn}（provisional / candidate-fix のみ）"$'\n' ;;
        esac
      done <<< "$ledger_rows"
      # dirty な各ファイルが台帳に載っているか（無関係な 1 行での回避を塞ぐ）。
      # 【除外】session-context.md 自身と worklog/ 配下の記録は台帳の対象外
      #   （台帳を書く行為そのものが dirty を生むため、自己参照を要求すると必ず FAIL する）。
      while IFS= read -r line; do
        local path
        path=$(echo "$line" | awk '{print $NF}')
        case "$path" in
          *worklog/*) continue ;;
        esac
        echo "$ledger_rows" | cut -f1 | grep -qF "$(basename "$path")" \
          || unlisted+="  台帳に無い変更: ${path}"$'\n'
      done <<< "$dirty"
      if [ -n "$bad_class" ] || [ -n "$unlisted" ]; then
        echo "❌ [FAIL] G-SESSION-CONSISTENT: 作業ツリー台帳が dirty な変更を網羅していない（GP-28 ルール5）"
        printf '%s' "${bad_class}${unlisted}"
        fails=$((fails + 1))
      else
        echo "✅ [PASS] G-SESSION-CONSISTENT: dirty な全変更が作業ツリー台帳に分類済み"
      fi
    fi
  fi

  # --- G-SESSION-INVESTIGATION: 進行中の scratchpad が Active Investigation に載っているか ---
  local pads=0
  if [ -d "$WROOT/worklog/investigation-notes" ]; then
    pads=$(find "$WROOT/worklog/investigation-notes" -name '*.md' -not -name '_template.md' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "${pads:-0}" -gt 0 ]; then
    local active
    active=$(awk '/^## .*Active Investigation/{f=1;next} f&&/^## /{exit}
      /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
      f && NF && $0 !~ /^###/ && $0 !~ /^- *なし *$/ && $0 !~ /^\|/ { print }' "$sc" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${active:-0}" -eq 0 ]; then
      echo "❌ [FAIL] G-SESSION-INVESTIGATION: scratchpad が ${pads} 件あるが Active Investigation が空（完了なら worklog へ集約して削除する。GP-28）"
      fails=$((fails + 1))
    else
      echo "✅ [PASS] G-SESSION-INVESTIGATION: 進行中の調査が Active Investigation に記録済み"
    fi
  else
    echo "✅ [PASS] G-SESSION-INVESTIGATION: 進行中の scratchpad なし"
  fi

  # --- G-SESSION-NEXT: Next Actions が具体的か ---
  # プレースホルダのままだと次セッションが「何をするか」を復元できない。
  # 【重要】「行があるか」だけでは「1. つづき」のような**復元不能な記述**が通る
  # （GP-100 ルール7 が禁じている当のもの。実測でこの回避が成立した）。
  # **場所を特定できる情報（`path:line` / ファイル名 / WP-ID / NODE-ID）を含む行**を要求する。
  local next_lines next_vague=""
  next_lines=$(awk '/^## Next Actions/{f=1;next} f&&/^## /{exit}
    /<!--/{c=1} c{ if ($0 ~ /-->/) c=0; next }
    f && NF { print }' "$sc" | grep -vE '^[0-9]+\. *<' || true)
  if [ -z "$next_lines" ]; then
    echo "❌ [FAIL] G-SESSION-NEXT: Next Actions がプレースホルダのまま（次に手を動かす場所を path:line まで書く）"
    fails=$((fails + 1))
  else
    while IFS= read -r line; do
      # 場所の手がかり: 拡張子付きパス・path:line・WP-/NODE-/SPEC- の ID
      echo "$line" | grep -qE '[A-Za-z0-9_./-]+\.[a-z]{2,4}|:[0-9]+|WP-[A-Za-z0-9-]+|NODE-[A-Z]+-[0-9]+|SPEC-' \
        || next_vague+="  場所が特定できない: ${line}"$'\n'
    done <<< "$next_lines"
    if [ -n "$next_vague" ]; then
      echo "❌ [FAIL] G-SESSION-NEXT: Next Actions に場所の手がかりが無い（path:line / ファイル名 / WP-ID を書く。GP-100 ルール7）"
      printf '%s' "$next_vague"
      fails=$((fails + 1))
    else
      echo "✅ [PASS] G-SESSION-NEXT: Next Actions が具体的（$(echo "$next_lines" | wc -l | tr -d ' ') 件）"
    fi
  fi

  # --- G-SESSION-FRESH: Last Checkpoint の鮮度 ---
  # 【重要】プレースホルダ（YYYY-MM-DD）の検出だけでは「TBD」等の散文で通る（実測）。
  # **日付形式そのものを要求する**（教訓 15: 存在検査では内容の正しさを保証できない）。
  local date_line date_val
  date_line=$(grep -m1 -E '^\- \*\*Date:\*\*' "$sc" || true)
  date_val=$(echo "$date_line" | sed 's/^- \*\*Date:\*\* *//' | sed 's/[[:space:]]*$//')
  if echo "$date_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2})?$'; then
    echo "✅ [PASS] G-SESSION-FRESH: Last Checkpoint が更新されている（${date_val}）"
  else
    echo "❌ [FAIL] G-SESSION-FRESH: Last Checkpoint の Date が日付形式でない「${date_val}」（YYYY-MM-DD [HH:MM]。SB-14）"
    fails=$((fails + 1))
  fi

  echo ""
  echo "--------------------------------------------------"
  if [ "$fails" -eq 0 ]; then
    echo "✅ セッション終了チェック 全通過（$(cd "$REPO_ROOT" && git log --oneline -1 2>/dev/null || echo 'no commit')）"
    return 0
  fi
  echo "❌ 未達 ${fails} 件。解消してからセッションを終えること（記録が失われる）。"
  return 1
}

# ---------------------------------------------------------------------------
# 逆引き索引の生成（GP-4 ルール7）: ソース → それを引用する仕様
# ---------------------------------------------------------------------------
# 【なぜ必要か】`path:line` は「仕様 → ソース」の一方向にしか使えておらず、
# **「このソースが変わったらどの仕様が陳腐化するか」に答えられなかった**。
# 引用数の多いファイルは変更時に影響する仕様が多いファイルで、保守でも再構築でも判断の起点になる。
#
# 【索引の権威は front-matter の `source-paths` 宣言ではなく本文の引用である】
# 実運用の実測: 301 仕様のうち **144 が宣言の外を引用**（計 710 件）。宣言は索引として機能していなかった。
# SB-1 により全記述は引用で裏取りされているので、**引用こそが依存関係の実体**である。
# 宣言を直す案は採らない——front-matter に行を足すと本文の行番号が全部ずれ、
# **その仕様を指す `path:line` 参照が壊れる**（実測で仕様間参照は 2,357 件あった）。
#
# 【冪等でなければゲートにできない】自分の出力を走査対象に含めると、生成のたびに数字が増える。
# 実測（参考実装が踏んだ）: もう 1 つの生成索引を除外し忘れて仕様間参照が 88 → 574 に膨張し、
# `--check` が生成直後でも差分ありを返した。**生成物は必ず走査対象から外す。**
SOURCE_INDEX_DOC="$SPECS/source-index.md"

run_source_index() {
  local mode="${1:-}"
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/gates-si.XXXXXX")"
  local srclist="$tmpd/src.txt" refs="$tmpd/refs.tsv" out="$tmpd/out.md"
  local resolve=1 srcnote="" si_excluded=0 si_unclosed=""

  # (1) 解析対象のファイル一覧（引用を実ファイルへ解決するための分母）
  if [ -n "$SOURCE_PATH" ] && [ -d "$SOURCE_PATH" ]; then
    ( cd "$SOURCE_PATH" && find . -type f 2>/dev/null | sed 's|^\./||' ) > "$tmpd/src-all.txt"
    if [ -n "$SOURCE_EXCLUDE" ]; then
      # 除外の grep が壊れた正規表現で異常終了したら、静かに「除外なし」に転ばせない
      if grep -vE "$SOURCE_EXCLUDE" "$tmpd/src-all.txt" > "$srclist" 2>"$tmpd/ex.err"; then :; else
        if [ "$?" -ge 2 ] || [ -s "$tmpd/ex.err" ]; then
          echo "ERROR: SOURCE_EXCLUDE が正規表現として不正: $(head -1 "$tmpd/ex.err")" >&2
          rm -rf "$tmpd"; return 2
        fi
      fi
      si_excluded=$(( $(grep -c . "$tmpd/src-all.txt" || true) - $(grep -c . "$srclist" || true) ))
    else
      cp "$tmpd/src-all.txt" "$srclist"; si_excluded=0
    fi
  else
    : > "$srclist"
    resolve=0
    if [ -z "$SOURCE_PATH" ]; then
      srcnote="gate-config.env に SOURCE_PATH が無い（この仕組みより前に生成されたリポジトリ）"
    else
      srcnote="SOURCE_PATH のディレクトリが存在しない: ${SOURCE_PATH}"
    fi
  fi

  # (2) 仕様本文から引用を抽出する（front-matter は除く＝`source-paths` 宣言を混ぜない）。
  #     **自分の出力は必ず除外する**（冪等性）。テンプレートも除外する。
  #     find の結果は一時ファイル経由で渡す——`xargs` はパスの空白で黙って語分割する。
  # 【冪等性】**自分の出力を一覧そのものから外す。** 引用の抽出だけ除いても
  # 「走査した仕様」の件数が 1 増えて出力が変わり、`--check` が生成直後でも差分ありを返す（実測した）。
  # `grep -v "^…$"` はパスを正規表現として扱うため、`[` を含むパスで黙って一致しなくなる。
  # **文字列一致（-Fx）で除外する。**
  spec_files | grep -vxF "$SOURCE_INDEX_DOC" | LC_ALL=C sort > "$tmpd/specs.txt"
  # 【パスの空白】ファイル名を `$(cat …)` で渡すと語分割して awk が開けず、
  # **`2>/dev/null` と併せて「引用 0 件」を静かに返した**（実測。申し送り 4 の #1 と同型）。
  # 配列に読み込んで引用付きで渡し、**エラーは捨てない**。
  local -a si_files=(); local si_f
  while IFS= read -r si_f; do si_files+=("$si_f"); done < "$tmpd/specs.txt"
  [ "${#si_files[@]}" -gt 0 ] || { echo "ERROR: 仕様ファイルが 0 件（走査対象が無い）" >&2; rm -rf "$tmpd"; return 2; }
  # 【awk の正規表現リテラルに `/` は書けない】`[A-Za-z0-9_./-]` の `/` が `/.../` を終端し
  # `nonterminated character class` で異常終了する。**以前は `2>/dev/null` がこれを隠して
  # 「引用 0 件」を静かに返していた**（実測）。文字列で渡して動的正規表現にする。
  # `[.]` を使うのは `\.` の解釈が実装で揺れるのを避けるため（POSIX の括弧式は移植性がある）。
  awk -v root="$REPO_ROOT/" -v re='`[A-Za-z0-9_./-]+[.][A-Za-z0-9]+:[0-9]+([-,][0-9]+)*`' '
    # front-matter は飛ばす——`source-paths:` 宣言を引用と混ぜない（索引の権威は本文の引用）
    # 【パスを正規表現に使わない】`sub("^" root, ...)` は root を**動的正規表現**として扱うため、
    # リポジトリのパスに `+ ( ) * ? [` が含まれると一致せず、**生成物にホストの絶対パスが焼き込まれる**
    # （実測: `plus+repo` で 559 行すべてに絶対パスが出た）。前置一致で切る。
    FNR == 1 {
      rel = FILENAME
      if (substr(rel, 1, length(root)) == root) rel = substr(rel, length(root) + 1)
      sub(/\r$/, "")                      # CRLF ワークツリー（Windows の core.autocrlf）に耐える
      fm = ($0 == "---") ? 1 : 0
      if (fm) { openfm[rel] = 1; next }
      # front-matter を持たない文書の**1 行目の引用を落とさない**（無条件 next だと消えていた）
    }
    { sub(/\r$/, "") }                   # 以降の比較を改行コードに依存させない（I4）
    fm == 1 { if ($0 == "---") { fm = 0; closed[rel] = 1 } next }
    {
      line = $0
      while (match(line, re)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        p = tok; sub(/:[0-9]+([-,][0-9]+)*$/, "", p)   # ここは `/` を含まないのでリテラルで安全
        print rel "\t" p
      }
    }
    # front-matter が閉じていない仕様は**引用が 1 件も拾われない**（fm が最後まで 1 のまま）。
    # 黙って落とさず印にする（SB-11: 対象なしを合格にしない）。
    END { for (f in openfm) if (!(f in closed)) print "!UNCLOSED\t" f }
  ' "${si_files[@]}" > "$refs" || {
    # 【rc を捨てない】macOS の awk は**不正な UTF-8 で rc=2 で異常終了する**（実測）。
    # rc を見ないと「引用 0 件」を成功として返し、走査した仕様の件数だけが残って自己矛盾する。
    echo "ERROR: 引用の抽出（awk）が失敗しました（不正なバイト列・巨大な行など）" >&2
    rm -rf "$tmpd"; return 2
  }

  # front-matter が閉じていない仕様を分離する（refs に混ぜると引用として集計されてしまう）
  si_unclosed=$(grep '^!UNCLOSED	' "$refs" | cut -f2 | LC_ALL=C sort || true)
  grep -v '^!UNCLOSED	' "$refs" > "$refs.clean" || true
  mv "$refs.clean" "$refs"

  # (3) 解決 → 反転 → 集計。すべて awk 1 パスで行う（引用は数千件になるので 1 件ごとにプロセスを起こさない）
  # 【NR == FNR で第 1 ファイルを判別してはいけない】**第 1 ファイルが空だと第 2 ファイルの
  # 全レコードで NR == FNR が真になり、引用が 1 件も集計されない**（実測で確認）。
  # そのとき件数は全部 0 になり「解決できない引用 0 件」として **PASS に転ぶ**。
  # `FILENAME` で明示的に判別する（空ファイルでも取り違えない）。
  awk -F'\t' -v resolve="$resolve" -v srclist="$srclist" '
    function base(p) { n = split(p, a, "/"); return a[n] }
    FILENAME == srclist {             # 解析対象の一覧
      by_rel[$0] = 1
      b = base($0)
      cand[b] = (b in cand) ? cand[b] "\n" $0 : $0
      ncand[b]++
      next
    }
    {
      spec = $1; ref = $2; total++
      # 仕様リポジトリ自身の .md への参照は「ソース」ではない（別の関心事＝仕様間参照）。
      # **これを「解決できない引用」に混ぜると偽の穴に見える**（参考実装で実測 88 件）。
      if (ref ~ /\.md$/) { internal++; next }
      if (resolve == 0) { hit[ref "\t" spec]++; src_total[ref]++; nsrc[ref] = 1; next }
      r = ""
      if (ref in by_rel) { r = ref }
      else {
        b = base(ref)
        if (ncand[b] == 1) { r = cand[b] }
        else if (ncand[b] > 1) {
          # `.../` の省略記法は末尾一致で絞る
          norm = ref; sub(/^.*\.\.\.\//, "", norm)
          k = split(cand[b], cc, "\n"); m = 0; pick = ""
          for (i = 1; i <= k; i++) if (index(cc[i], norm) == length(cc[i]) - length(norm) + 1) { m++; pick = cc[i] }
          if (m == 1) { r = pick }
          else {
            # テスト配下を除いて一意なら採る
            m = 0; pick = ""
            for (i = 1; i <= k; i++) if (cc[i] !~ /(^|\/)(test|tests)\//) { m++; pick = cc[i] }
            if (m == 1) { r = pick }
          }
        }
      }
      if (r == "") {
        unres[ref]++; nunres++
        # 【どこを直せばよいか分かる形にする】件数だけでは恒久解（仕様側でフルパスを書く）に
        # 到達できず、結局 grep が必要になる（GP-6: 失敗行を出す）。引用元の仕様も出す。
        if (!((ref "\t" spec) in useen)) { useen[ref "\t" spec] = 1
          uspec[ref] = (ref in uspec) ? uspec[ref] " / `" spec "`" : "`" spec "`" }
        next
      }
      hit[r "\t" spec]++; src_total[r]++
    }
    END {
      for (k in hit) print "H\t" k "\t" hit[k]
      for (r in unres) print "U\t" r "\t" unres[r] "\t" uspec[r]
      print "S\ttotal\t" total + 0
      print "S\tinternal\t" internal + 0
      print "S\tunresolved\t" nunres + 0
      n = 0; for (r in src_total) n++
      print "S\tindexed\t" n
    }
  ' "$srclist" "$refs" > "$tmpd/agg.tsv" || {
    echo "ERROR: 引用の集計（awk）が失敗しました" >&2
    rm -rf "$tmpd"; return 2
  }

  # (3b) 入口から引く（GP-14 ルール8）。仕様を機能単位で書くと、入口（URL・アクション）から 1 回で届かなくなる。
  #      **手で書かせない**——コードグラフの入口ノード（NODE-EP）ごとに、その ID を本文に書いた仕様を機械で集める。
  #      ID を書いていない入口は「参照されていない」と明示する（黙って落とさない）。
  local ep_tsv="$tmpd/ep.tsv" ep_hit="$tmpd/ep-hit.tsv" n_ep=0 n_ep_ref=0
  : > "$ep_tsv"; : > "$ep_hit"
  if [ -f "$CODEGRAPH" ]; then
    # 【列はヘッダから引く】列構成はプロジェクトで違う（`| ID | URL | path | 状態 |` 等）。直近のヘッダ行で
    #  「エントリポイント」「URL」「パス」を含む列を探し、無ければ第 3 列（雛形の位置）にする。
    # 【ラベルからバッククォートを外す】`:245` のような値が主張行の述語に当たり、索引に意味の無い主張行が増えた。
    local ep_rc=0
    # 【エッジ表を読まない】`node_rows` と同じく直近のヘッダで決める（第 1 列に `From` を含む表＝エッジ表）。
    #  エッジ行の第 1 列にも NODE-EP が現れるので、ヘッダを見ないと入口がエッジの記述で上書きされる。
    # 【表の種類は表ごとに決め直す】区切り行（`|---|`）の直前の行を見出しとして読み、第 1 列が
    #  `NODE-ID` / `ID` / `ノード` の表だけを入口の登録表とする。**認識できない見出しの表は飛ばす**——
    #  状態を引き継ぐと、別名だけを並べた表（`| 役割 ID | … |`）の行を入口と読んだ（反証レビューで実測 8 件）。
    # 【LC_ALL=C】日本語の見出しを `==` で比べる（UTF-8 ロケールの macOS awk は日本語どうしを等しいと判定する）。
    LC_ALL=C awk -F'|' '
        /^[|][[:space:]:|-]+$/ {
          tbl = "other"; col = 3
          h1 = hp[2]; gsub(/[` \t]/, "", h1)
          if (h1 == "NODE-ID" || h1 == "ID" || h1 == "ノード") {
            tbl = "node"
            # 入口を表す列を優先し、無ければ「内容」の列、それも無ければ第 3 列（雛形の位置）
            c2 = 0
            for (i = hn; i >= 2; i--) { v = tolower(hp[i]); if (v ~ /エントリポイント|url|パス|アクション名/) col = i; else if (v ~ /内容/) c2 = i }
            if (col == 3 && c2 > 0 && tolower(hp[3]) !~ /エントリポイント|url|パス|アクション名/) col = c2
          }
          next }
        /^[|]/ {
          hn = split($0, hp, "|")
          if (tbl != "node") next
          if ($2 ~ /→|->/) next
          id = $2; gsub(/[` \t]/, "", id)
          # ID の形だけを採る（集計表の `NODE-EP-ACT（…）| 59 |` のような行を入口と読まない）
          if (id !~ /^NODE-EP-[A-Za-z0-9_-]*[A-Za-z0-9]$/) next
          if (seen[id]++) next
          lab = $(col ? col : 3); gsub(/`/, "", lab); gsub(/^[ \t]+|[ \t]+$/, "", lab); gsub(/\t/, " ", lab)
          # 【切り詰めない】C ロケールの substr はバイト単位で、多バイト文字の途中で切ると
          #  macOS の awk が後段で「multibyte conversion failure」で落ちる（実測）。
          print NR "\t" id "\t" lab
        }' "$CODEGRAPH" > "$ep_tsv" || ep_rc=$?
    if [ "$ep_rc" -ne 0 ]; then
      echo "ERROR: 入口ノードの読み取り（awk）が失敗しました（rc=${ep_rc}）" >&2; rm -rf "$tmpd"; return 2
    fi
    n_ep=$(grep -c . "$ep_tsv" || true)
    if [ "${n_ep:-0}" -gt 0 ]; then
      awk -v root="$REPO_ROOT/" '
        FNR == 1 { rel = FILENAME; if (substr(rel, 1, length(root)) == root) rel = substr(rel, length(root) + 1) }
        { line = $0
          while (match(line, /NODE-EP-[A-Za-z0-9_-]*[A-Za-z0-9]/)) {
            print substr(line, RSTART, RLENGTH) "\t" rel; line = substr(line, RSTART + RLENGTH) } }
      ' "${si_files[@]}" | LC_ALL=C sort -u > "$ep_hit" || {
        echo "ERROR: 入口ノードの参照の抽出（awk）が失敗しました" >&2; rm -rf "$tmpd"; return 2; }
      n_ep_ref=$(awk -F'\t' 'FILENAME == ARGV[1] { ref[$1] = 1; next } ($2 in ref) { n++ } END { print n + 0 }' "$ep_hit" "$ep_tsv") || {
        echo "ERROR: 入口ノードの参照の集計（awk）が失敗しました" >&2; rm -rf "$tmpd"; return 2; }
      # 表は先に描いて rc を見る（Markdown の組み立てブロックの中で落ちると、黙って表が途切れる）
      awk -F'\t' '
        FILENAME == ARGV[1] { sp[$1] = ($1 in sp) ? sp[$1] " / `" $2 "`" : "`" $2 "`"; next }
        { lab = $3
          printf "| %s | %s | %s |\n", $2, lab, (($2 in sp) ? sp[$2] : "（仕様から参照されていない）") }
      ' "$ep_hit" "$ep_tsv" > "$tmpd/ep.md" || {
        echo "ERROR: 入口の索引の組み立て（awk）が失敗しました" >&2; rm -rf "$tmpd"; return 2; }
    fi
  fi

  # (4) Markdown を組み立てる（並び順は sort に任せる＝awk の実装差に依存しない）
  local n_spec n_total n_internal n_unres n_indexed
  n_spec=$(grep -c . "$tmpd/specs.txt" || true)
  n_total=$(awk -F'\t' '$1=="S" && $2=="total" {print $3}' "$tmpd/agg.tsv")
  n_internal=$(awk -F'\t' '$1=="S" && $2=="internal" {print $3}' "$tmpd/agg.tsv")
  n_unres=$(awk -F'\t' '$1=="S" && $2=="unresolved" {print $3}' "$tmpd/agg.tsv")
  n_indexed=$(awk -F'\t' '$1=="S" && $2=="indexed" {print $3}' "$tmpd/agg.tsv")

  {
    echo '---'
    echo 'spec-id: SPEC-source-index'
    echo 'category: index'
    # 横断・索引文書は source-paths: [] が正当（全縦串から観測を集約する文書である）
    echo 'source-paths: []'
    echo 'coverage-status: generated'
    echo '---'
    echo '# 逆引き索引: ソース → それを引用する仕様'
    echo ''
    echo '<!-- 機械生成物。`bash spec-extraction/03-audit/gates.sh source-index` が生成する。手で編集しない。 -->'
    echo ''
    echo '**「解析対象のソースが変わったらどの仕様が陳腐化するか」に答えるための逆引き索引**'
    echo '（GP-4 の 2 段トレーサビリティの逆方向）。'
    echo ''
    echo '**索引の権威は front-matter の `source-paths` 宣言ではなく本文の `path:line` 引用である**'
    echo '——SB-1 により全記述は引用で裏取りされているので、引用こそが依存関係の実体である。'
    echo ''
    if [ "$resolve" = "0" ]; then
      echo "> ⚠️ **引用を実ファイルへ解決していない**（${srcnote}）。"
      echo '> 同じファイルが別の書き方で引用されていると**別の行に分かれる**。'
      echo '> `gate-config.env` に `SOURCE_PATH=<解析対象の絶対パス>` を足すと解決される。'
      echo ''
    fi
    echo '## 集計'
    echo ''
    echo '| 指標 | 値 |'
    echo '|---|--:|'
    echo "| 走査した仕様 | ${n_spec} |"
    echo "| 引用の総数 | ${n_total} |"
    echo "| 索引化したソースファイル | ${n_indexed} |"
    echo "| 仕様 → 仕様の参照（索引の対象外） | ${n_internal} |"
    echo "| 解決できなかった引用 | ${n_unres} |"
    [ "${si_excluded:-0}" -gt 0 ] && echo "| 解析対象から除外したファイル（SOURCE_EXCLUDE） | ${si_excluded} |"
    [ -n "$si_unclosed" ] && echo "| **front-matter が閉じていない仕様**（引用を拾えていない） | $(printf '%s' "$si_unclosed" | grep -c . || true) |"
    echo ''
    # 解決できない引用が多いのは、たいてい「同名の生成物コピーが分母に混ざっている」ためである。
    # **原因を書かずに件数だけ出すと直せない**（GP-6: 失敗行を出す）。
    if [ "$resolve" = "1" ] && [ "${n_total:-0}" -gt 0 ] \
       && [ $(( ${n_unres:-0} * 10 )) -gt "${n_total:-1}" ]; then
      echo "> **解決できない引用が全体の 10% を超えている。**"
      echo "> 多くは**同名のビルド生成物が解析対象に含まれている**ため（例: 生成先へのコピー）。"
      echo '> `gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）に生成物のパスを入れると解決される。'
      echo '> 何を除外するかは Playbook の `enumeration.md`「走査の落とし穴」が規定する。'
      echo ''
    fi
    echo '## モジュール別（どの領域をどの仕様が覆うか）'
    echo ''
    echo '| モジュール | 仕様数 | 引用数 |'
    echo '|---|--:|--:|'
    awk -F'\t' '$1=="H" { n=split($2,a,"/"); mod=(n>1)?a[1]:"(ルート直下)"; c[mod]+=$4; s[mod"\t"$3]=1 }
                END { for (k in s) { split(k,b,"\t"); ns[b[1]]++ }
                      for (m in c) printf "%d\t%d\t%s\n", c[m], ns[m], m }' "$tmpd/agg.tsv" \
      | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k3,3 \
      | awk -F'\t' '{ printf "| `%s` | %d | %d |\n", $3, $2, $1 }'
    echo ''
    echo '## ソースファイル別（引用数の多い順）'
    echo ''
    echo '**引用数が多いファイルは、変更したときに影響する仕様が多いファイルである。**'
    echo ''
    echo '| # | ソース | 引用元の仕様 | 仕様数 | 引用数 |'
    echo '|--:|---|---|--:|--:|'
    # 【awk の連想配列の走査順を出力に漏らさない】`for (k in arr)` の順序は POSIX で未規定であり、
    # **awk 実装が違うと同じ入力から違う並びが出る**。セル内部の並びを走査順で作ると、
    # macOS で生成した索引を GNU 環境で `--check` したときに内容が同じでも「陳腐化」と判定され、
    # **両環境で作業するとゲートが振動して運用不能になる**（実測: 走査順をシャッフルすると 540 行が変わった）。
    # → **連結の前に sort を通す**。セル内は (ソース, 仕様) で確定させる。
    awk -F'\t' '$1=="H" { print $2 "\t" $3 "\t" $4 }' "$tmpd/agg.tsv" \
      | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 \
      | awk -F'\t' '{ tot[$1]+=$3; ns[$1]++
                       cell[$1] = ($1 in cell) ? cell[$1] " / `" $2 "`(" $3 ")" : "`" $2 "`(" $3 ")"
                       if (!($1 in seen)) { seen[$1]=1; order[++n]=$1 } }
                     END { for (i = 1; i <= n; i++) { s = order[i]
                             printf "%d\t%d\t%s\t%s\n", tot[s], ns[s], s, cell[s] } }' \
      | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k3,3 \
      | awk -F'\t' '{ printf "| %d | `%s` | %s | %d | %d |\n", NR, $3, $4, $2, $1 }'
    if [ -f "$CODEGRAPH" ] && [ "${n_ep:-0}" -eq 0 ]; then
      echo ''
      echo '## 入口から引く'
      echo ''
      echo '> コードグラフに `NODE-EP-…` の入口ノードが無いので、入口の表を作れなかった（GP-14 ルール8）。'
    fi
    if [ "${n_ep:-0}" -gt 0 ]; then
      echo ''
      echo '## 入口から引く（コードグラフの入口ノード → その ID を書いた仕様）'
      echo ''
      echo "**仕様は機能単位で書き、入口からはこの表で引く**（GP-14 ルール8）。入口ノード ${n_ep} 件のうち ${n_ep_ref} 件が仕様から参照されている。"
      echo '参照されていない入口は、扱う仕様の節に `NODE-EP-…` の ID を書くと載る（範囲表記 `01〜05` は両端しか拾わない。1 つずつ書く）。'
      echo '**件数は「ID を書いた仕様がある」ことしか表さない**（その仕様が入口を十分に扱っているかは別）。'
      echo ''
      echo '| 入口ノード | エントリポイント | 仕様 |'
      echo '|---|---|---|'
      cat "$tmpd/ep.md"
    fi
    if [ "${n_unres:-0}" -gt 0 ]; then
      echo ''
      echo '## 解決できなかった引用'
      echo ''
      echo '**黙って落とさず列挙する。** 恒久解は仕様側でフルパスを書くこと。'
      echo ''
      echo '| 引用文字列 | 出現 | 引用している仕様 |'
      echo '|---|--:|---|'
      awk -F'\t' '$1=="U" { printf "%d\t%s\t%s\n", $3, $2, $4 }' "$tmpd/agg.tsv" \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 \
        | awk -F'\t' '{ printf "| `%s` | %d | %s |\n", $2, $1, $3 }'
    fi
  } > "$out"

  SI_TOTAL="$n_total"; SI_INDEXED="$n_indexed"; SI_UNRES="$n_unres"; SI_RESOLVE="$resolve"
  SI_NOTE="$srcnote"; SI_SRCFILES=$(grep -c . "$srclist" || true); SI_UNCLOSED="$si_unclosed"
  # 【0 になった原因を区別する】PASS の条件が「解決できない引用が 0」だけだと、
  # **引用が 1 件も無い空の索引**も合格になる。空索引は陳腐化索引より悪い——中身が無いのに
  # 「最新」と報告されるため。原因を分けて呼び出し側へ渡す。
  SI_DEGRADED=""
  if [ "$resolve" = "1" ] && [ "${SI_SRCFILES:-0}" -eq 0 ]; then
    SI_DEGRADED="SOURCE_PATH は設定されているのに解析対象のファイルが 0 件（パス誤り・権限・SOURCE_EXCLUDE の過剰一致）"
  elif [ "${n_total:-0}" -eq 0 ]; then
    SI_DEGRADED="仕様に path:line 引用が 1 件も無い（SB-1 により全記述は引用で裏取りされているはず）"
  elif [ "${n_indexed:-0}" -eq 0 ]; then
    SI_DEGRADED="引用はあるが索引化できたソースファイルが 0 件（すべて解決できていない）"
  fi

  if [ "$mode" = "--check" ]; then
    # 【改行コードで比較しない】Git for Windows の既定は `core.autocrlf=true` なので、
    # チェックアウトすると成果物が CRLF になる。生成器は LF を出すため、そのまま比較すると
    # **Windows 利用者は初回から「陳腐化」FAIL になり、指示どおり再生成すると改行だけの差分を
    # コミットして他環境と往復する**（実測）。比較前に CR を落とす。
    if [ -f "$SOURCE_INDEX_DOC" ] \
       && diff -q <(tr -d '\r' < "$SOURCE_INDEX_DOC") <(tr -d '\r' < "$out") >/dev/null 2>&1; then
      rm -rf "$tmpd"; return 0
    fi
    rm -rf "$tmpd"; return 1
  fi
  cp "$out" "$SOURCE_INDEX_DOC"
  rm -rf "$tmpd"
  echo "生成: ${SOURCE_INDEX_DOC#"$REPO_ROOT"/}"
  echo "引用 ${n_total} / 索引化 ${n_indexed} ファイル / 仕様間参照 ${n_internal} / 解決できず ${n_unres}"
  [ "$resolve" = "0" ] && echo "⚠️  引用を解決していない（${srcnote}）"
  return 0
}

# --- G-SOURCEINDEX: 逆引き索引が存在し、最新であること（GP-4 ルール7 / GP-19） ---
# 【なぜゲートにするか】機械生成物なので「書き忘れ」ではなく「再生成し忘れ」で腐る。
# **陳腐化した索引は無い索引より悪い**——存在するので確認したつもりになる。
# 冪等な生成器なので「再生成して差分が無いこと」で最新性を機械判定できる。
gate_source_index() {
  local specs_n; specs_n=$(spec_files | grep -c . || true)
  [ "${specs_n:-0}" -gt 0 ] || { report SKIP G-SOURCEINDEX "仕様ファイルが無い（未生成段階）"; return; }
  if [ ! -f "$SOURCE_INDEX_DOC" ]; then
    report INCOMPLETE G-SOURCEINDEX "逆引き索引が無い（ソース変更時にどの仕様が陳腐化するか分からない）" \
      "  bash spec-extraction/03-audit/gates.sh source-index  で生成する"
    return
  fi
  # 【rc 1 と rc 2 を混ぜない】rc 2 は「陳腐化」ではなく**構成不備**（正規表現の誤り・awk の異常終了・
  # mktemp 失敗）である。両方を「再生成せよ」と報告すると、指示どおり再生成しても同じ失敗を繰り返す。
  run_source_index --check; local si_rc=$?
  if [ "$si_rc" -ge 2 ]; then
    report FAIL G-SOURCEINDEX "逆引き索引を生成できない（構成不備。陳腐化ではない）" \
      "  上に出ている ERROR 行を直す（SOURCE_EXCLUDE の正規表現・SOURCE_PATH・一時ディレクトリ）"
    return
  fi
  if [ "$si_rc" -eq 1 ]; then
    report FAIL G-SOURCEINDEX "逆引き索引が陳腐化している（再生成すると差分が出る）" \
      "  bash spec-extraction/03-audit/gates.sh source-index  で再生成してからコミットする"
    return
  fi
  local note="引用 ${SI_TOTAL} / 索引化 ${SI_INDEXED} ファイル"
  # 【縮退を PASS にしない】索引が「最新」でも中身が空なら成果物として成立していない。
  if [ -n "${SI_DEGRADED:-}" ]; then
    report INCOMPLETE G-SOURCEINDEX "逆引き索引が空同然（${note}）" \
      "  原因: ${SI_DEGRADED}${SI_NOTE:+
  詳細: ${SI_NOTE}}"
    return
  fi
  if [ "${SI_RESOLVE}" = "0" ]; then
    # 解決していない索引は「使えるが精度が落ちている」——PASS で黙らせず WARN で残す。
    report WARN G-SOURCEINDEX "逆引き索引は最新だが引用を実ファイルへ解決していない（${note}）" \
      "  原因: ${SI_NOTE:-SOURCE_PATH が未設定}
  gate-config.env に SOURCE_PATH='<解析対象の絶対パス>' を設定すると解決される"
    return
  fi
  if [ -n "${SI_UNCLOSED:-}" ]; then
    report WARN G-SOURCEINDEX "front-matter が閉じていない仕様があり、その引用を拾えていない（${note}）" \
      "$(printf '%s\n' "$SI_UNCLOSED" | sed 's/^/  /')"
    return
  fi
  if [ "${SI_UNRES:-0}" -gt 0 ]; then
    report WARN G-SOURCEINDEX "逆引き索引は最新だが解決できない引用が ${SI_UNRES} 件（${note}）" \
      "  仕様側でフルパスを書くと解決する（索引の「解決できなかった引用」節に一覧）"
  else
    report PASS G-SOURCEINDEX "逆引き索引が最新（${note}）"
  fi
}

run_metrics() {
  local out="$AUDIT/metrics.tsv"
  local today
  today=$(date '+%Y-%m-%d')
  # ヘッダ（初回のみ）
  if [ ! -f "$out" ]; then
    printf 'date\tmetric\tcategory\tvalue\n' > "$out"
  fi
  local lines=""

  # 1) カテゴリ別ファイル数・平均行数（カテゴリ非対称の検出: SB-15/17）
  for c in modules api data behavior rebuild; do
    local files count total avg
    files=$(find "$SPECS/$c" -name '*.md' -not -name '_*' 2>/dev/null)
    count=$(echo "$files" | grep -c . || true)
    if [ "$count" -gt 0 ]; then
      total=$(echo "$files" | sum_lines)
      avg=$((total / count))
    else
      avg=0
    fi
    lines+="${today}\tfile_count\t${c}\t${count}\n"
    lines+="${today}\tavg_lines\t${c}\t${avg}\n"
  done

  # 1b) 断定型の密度（標本の重点配分に使う。GP-16 ルール10-(7)）
  # 「0 件 / 唯一 / すべて」型は**反例 1 件で完全に崩れ、しかも結論の向きが変わる**
  # （「対策不要」→「対策必要」）。件数型（「N 箇所ある」）は過小・過大に振れても近い値になりやすい。
  # 実運用の実測: ある層は行数では母集団の 20% なのに断定型の 54% を占め、
  # その層のサンプリング誤り率は 54.5% で全層最悪だった（他層 10〜42%）。
  # → **比例配分は「誤りが均等に散らばっている」前提に立つが成り立たない。**
  # 本指標は合否を持たない（測るだけ。判断は GP-16 ルール10 の標本設計で行う）。
  for c in modules api data behavior rebuild; do
    local cfiles absent unique universal claims
    cfiles=$(find "$SPECS/$c" -name '*.md' -not -name '_*' 2>/dev/null)
    if [ -z "$cfiles" ]; then
      lines+="${today}\tassertion_density_absent\t${c}\t0\n"
      lines+="${today}\tassertion_density_unique\t${c}\t0\n"
      lines+="${today}\tassertion_density_universal\t${c}\t0\n"
      continue
    fi
    # `path:line` を伴う行＝検証可能な主張の行だけを母集団にする（散文の前置きを数えない）。
    claims=$(echo "$cfiles" | nul_pack | xargs -0 -r grep -hE ':[0-9]+' 2>/dev/null || true)
    absent=$(echo    "$claims" | grep -cE "$CLAIM_ABSENT_RE" || true)
    unique=$(echo    "$claims" | grep -cE "$CLAIM_UNIQUE_RE" || true)
    universal=$(echo "$claims" | grep -cE "$CLAIM_UNIVERSAL_RE" || true)
    lines+="${today}\tassertion_density_absent\t${c}\t${absent}\n"
    lines+="${today}\tassertion_density_unique\t${c}\t${unique}\n"
    lines+="${today}\tassertion_density_universal\t${c}\t${universal}\n"
  done

  # 1c) ゲート運用のコスト（FB-12 の再発検知）。
  # 「ゲートを何回回し、そのたびにどれだけ出力したか」を残す。
  # FB-12 の切り分けでは**この値が残っていなかったため後から推定するしかなかった**。
  # 次の run と比較して「出力上限・phase2・INCOMPLETE 分離が効いたか」を実証で言えるようにする。
  if [ -f "$RUNS_TSV" ]; then
    local runs full shown supp p4runs
    runs=$(awk 'NR>1' "$RUNS_TSV" | grep -c . || true)
    full=$(awk -F'\t' 'NR>1 {s+=$8} END{print s+0}' "$RUNS_TSV")
    shown=$(awk -F'\t' 'NR>1 {s+=$9} END{print s+0}' "$RUNS_TSV")
    supp=$((full - shown))
    p4runs=$(awk -F'\t' 'NR>1 && $3=="phase4"' "$RUNS_TSV" | grep -c . || true)
    lines+="${today}\tgate_runs_total\tall\t${runs}\n"
    lines+="${today}\tgate_runs_phase4\tall\t${p4runs}\n"
    # 【`phase4` の回数だけでは「流用」を診断できない】手順書は「`phase4` が 10 回を超えたら
    # 完了ゲートを途中確認に流用している」と書いていたが、**Phase 4 の是正ループでは自然に超える**
    # （実測: 能力 1 つで 12 回。`phase2` の流用はしていなかった）。
    # 流用の徴候は「`phase4` が多い **かつ** `phase2` が使われていない」なので `phase2` も出す。
    local p2runs
    p2runs=$(awk -F'\t' 'NR>1 && $3=="phase2"' "$RUNS_TSV" | grep -c . || true)
    lines+="${today}\tgate_runs_phase2\tall\t${p2runs}\n"
    lines+="${today}\tgate_detail_lines_shown\tall\t${shown}\n"
    lines+="${today}\tgate_detail_lines_suppressed\tall\t${supp}\n"
    # 1 実行あたりの平均出力行数（上限が効いているかの直接指標）
    if [ "${runs:-0}" -gt 0 ]; then
      lines+="${today}\tgate_detail_lines_per_run\tall\t$((shown / runs))\n"
    fi
  fi

  # 1d) 同一引用が複数の密度ブロックに現れる度合い（[[GP-22]] ルール7 の観測。**測るだけ**）
  # 【なぜ合否を持たせないか】実走検証で「収束を妨げる主因は二重記述」と判明したが、
  # **同じ引用が 2 ブロック以上に現れるのは正常である**——実測で
  # 深掘りを進めた成果物 **465 / 5,434 件（8.6%）**、小規模で最深まで進めた成果物 **49 / 232 件（21%）**。
  # 合否にすると 465 件で落ちる（[[GP-103]] が禁じる型）。**同一引用 ≠ 同一事実**で、
  # **絶対数は引用の切り出し方で変わる**（同じデータで 4,798〜6,347 の幅が出た）。
  # 結論が乗っているのは**比率**（8〜10% と 21%）で、こちらは切り出し方に対して頑健だった。
  # 同じ行が別の主張を支えるのは普通である。⇒ **是正の方向は手順書の規律で縛り、ここでは量だけ残す。**
  # 【引用の定義は `G-BLOCK-SIZE` と同じものを使う】独自の式を書くと乖離する
  # （一度 `[A-Za-z0-9_./-]+` で書いたところ、**カンマ区切りの複数範囲**
  # （`X.java:46,67-71`）を取り逃して母集団が 76% になった）。**2 箇所で同じ式を書かない。**
  # 【3 ブロック以上は一覧も出す】件数だけでは「どれを直すか」に到達できない（FB-6 の型）。
  # 【fail-closed】awk が 1 ファイルでも開けないと END に到達せず、2 段目が `0 0 0` を出して
  # **「測った値」として 0 が残る**（`G-BLOCK-OUTSIDE` が明文化して直した罠）。
  # rc を見て、測れなければ**指標行を書かない**。
  # 【バッチ分割に耐える】1 段目は `引用<TAB>ブロック` を出し、2 段目で `sort -u` してから数える
  # ——単純合算だと**同じ引用が別バッチに跨ったとき合算されず過小になる**（`sum_lines` と同じ罠）。
  if [ -d "$SPECS" ]; then
    local dc_err dc_pairs dc_rc=0
    if ! dc_err="$(mktemp "${TMPDIR:-/tmp}/gm-dupcite.XXXXXX")" || [ -z "$dc_err" ]; then
      dc_err=""
    fi
    dc_pairs=$(spec_files | nul_pack | LC_ALL=C xargs -0 -r awk '
        FNR==1 { cur = "" }                      # ファイル境界で必ず閉じる（閉じ忘れの漏れを防ぐ）
        {
          line = $0; opened = 0
          if (match(line, /<!-- density-block:[^>]*DB-[0-9]+/)) {
            s = substr(line, RSTART, RLENGTH); sub(/.*DB-/, "DB-", s)
            cur = FILENAME "#" s; opened = 1       # ブロック ID はファイルで修飾する（別仕様の同名 ID を混ぜない）
          }
          # 開始と同一行に終了がある形（既知のマーカー異常）でも、その行の引用は数える
          if (cur != "" && line ~ /<!-- \/density-block/) { closes = 1 } else { closes = 0 }
          if (cur != "") {
            rest = line
            while (match(rest, /`[^`]+\.[A-Za-z0-9]+:[0-9]+[0-9,:-]*`/)) {
              c = substr(rest, RSTART + 1, RLENGTH - 2)
              print c "\t" cur
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
          if (closes) cur = ""
        }' 2>"${dc_err:-/dev/null}") || dc_rc=$?
    if [ "${dc_rc:-0}" -eq 0 ] && { [ -z "$dc_err" ] || [ ! -s "$dc_err" ]; }; then
      local dc_tot dc_2 dc_3 dc_list
      dc_tot=$(printf '%s\n' "$dc_pairs" | LC_ALL=C sort -u | LC_ALL=C awk -F'\t' 'NF==2 {n[$1]++} END {print length(n)+0}')
      dc_2=$(printf '%s\n' "$dc_pairs" | LC_ALL=C sort -u | LC_ALL=C awk -F'\t' 'NF==2 {n[$1]++} END {c=0; for (k in n) if (n[k]>=2) c++; print c+0}')
      dc_3=$(printf '%s\n' "$dc_pairs" | LC_ALL=C sort -u | LC_ALL=C awk -F'\t' 'NF==2 {n[$1]++} END {c=0; for (k in n) if (n[k]>=3) c++; print c+0}')
      # 【対象 0 件のときは書かない】「ブロック未着手」と「二重記述ゼロ」を区別する
      if [ "${dc_tot:-0}" -gt 0 ]; then
        lines+="${today}\tblock_citation_unique\tall\t${dc_tot}\n"
        lines+="${today}\tblock_citation_in_2plus\tall\t${dc_2}\n"
        lines+="${today}\tblock_citation_in_3plus\tall\t${dc_3}\n"
        # 3 ブロック以上に現れる引用の一覧（正本を 1 つにする候補。人が見る）
        dc_list=$(printf '%s\n' "$dc_pairs" | LC_ALL=C sort -u \
                  | LC_ALL=C awk -F'\t' 'NF==2 {n[$1]++} END {for (k in n) if (n[k]>=3) print n[k] "\t" k}' \
                  | LC_ALL=C sort -rn | head -40 || true)
        if [ -n "$dc_list" ]; then
          printf '=== 3 ブロック以上に現れる引用（正本を 1 つにする候補。GP-22 ルール7 (b)）===\n%s\n' \
            "$dc_list" >> "$DETAILS_FILE"
          echo "ℹ️  3 ブロック以上に現れる引用 ${dc_3} 件の一覧を 03-audit/gate-details.log に出しました（GP-22 ルール7 (b)）"
        fi
      fi
    else
      echo "⚠️  同一引用の集計ができませんでした（測定不能なので指標を書きません）: $( [ -n "$dc_err" ] && head -1 "$dc_err" )" >&2
    fi
    [ -n "$dc_err" ] && rm -f "$dc_err"
  fi

  # 1c) 能力をまたぐ突き合わせの候補（GP-15 ルール11。合否は持たない）
  # 同じ `path:line` を 3 つ以上の分析物ファイル（能力）が引く箇所を列挙する。実測で、能力ごとの自己検査が
  # すべて通ったのに、この候補の突合で能力間の矛盾が見つかった（1 件は完了ゲートも通過していた）。
  # **候補を出すだけ**——記述を比べて判断するのは人（または検証官）である。
  # 【網羅ではない】拾うのはバッククォートで囲んだ完全な `path:line` だけ（範囲・パスを省いた継続形は別の箇所として数えない）。
  #  実測で、手で数えた箇所の半分程度しか拾わなかった。**一覧が短いことを「突き合わせる箇所が少ない」の証拠にしない。**
  if [ -d "$WROOT/02-analysis" ]; then
    local xc_list xc_n
    xc_list=$(find "$WROOT/02-analysis" -type f -name '*.md' -not -name '_*' -print0 2>/dev/null \
              | LC_ALL=C xargs -0 -r awk '
                  { line = $0
                    while (match(line, /`[^`]+[.][A-Za-z0-9]+:[0-9]+[0-9,:-]*`/)) {
                      c = substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, RSTART + RLENGTH)
                      # 同じ箇所の書き方の揺れを寄せる: ファイル名だけ＋範囲の始点（`a/b/X.java:60-117` → `X.java:60`）
                      np = split(c, cp, "/"); c = cp[np]; sub(/[-,].*$/, "", c)
                      rel = FILENAME; sub(/^.*\/02-analysis\//, "", rel); print c "\t" rel } }' 2>/dev/null \
              | LC_ALL=C sort -u | LC_ALL=C awk -F'\t' '{ n[$1]++; f[$1] = ($1 in f) ? f[$1] " " $2 : $2 }
                  END { for (k in n) if (n[k] >= 3) printf "%d\t%s\t%s\n", n[k], k, f[k] }' \
              | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 || true)
    xc_n=$(printf '%s' "$xc_list" | grep -c . || true)
    lines+="${today}\tcross_capability_citations_3plus\tall\t${xc_n:-0}\n"
    if [ "${xc_n:-0}" -gt 0 ]; then
      printf '=== 3 つ以上の分析物（能力）が引く path:line（能力をまたぐ突き合わせの候補。GP-15 ルール11。全 %d 件中 先頭 %d 件）===\n%s\n' \
        "$xc_n" "$([ "$xc_n" -gt 200 ] && echo 200 || echo "$xc_n")" "$(printf '%s\n' "$xc_list" | head -200)" >> "$DETAILS_FILE"
      echo "ℹ️  能力をまたぐ突き合わせの候補 ${xc_n} 箇所の一覧を 03-audit/gate-details.log に出しました（GP-15 ルール11）"
    fi
  fi

  # 2) 必須節充足率（密度の床割れ: SB-18。G-DENSITY と同じ検査の集計版）
  #    検査対象仕様数に対する「違反ゼロの仕様数」の割合（%）
  local dens_out
  dens_out=$(DENSITY_METRICS_ONLY=1 metrics_density_fill_rate)
  # 【重要】`$(...)` は**末尾の改行を必ず落とす**。`lines` は最後に `printf '%b'` で展開されるため、
  # ここで改行を補わないと**次の追記が同じ行に連結され TSV の列数が壊れる**。
  # 実測（roller-spec）: `required_sections_fill_pct data 100` と `ledger_blocks all 101` が
  # 1 行に融合して **4 列であるべき行が 7 列**になり、metrics を回すたびに 1 行増えていた。
  # metrics.tsv は「プロジェクト横断で品質の揺れを宣言前に計測する」台帳なので、
  # 列数が壊れると指標の目的そのものが達成できない。
  # **コマンド置換の結果を `lines` へ足す箇所は必ず改行を補う**（他は文字列リテラルで `\n` を持つ）。
  [ -n "$dens_out" ] && lines+="$dens_out\n"

  # 3) Verify 済率・fabricated 検出率（検証の抜け: SB-21 / Extract 品質の代理指標）
  local ledger="$AUDIT/density-ledger.tsv"
  if [ -f "$ledger" ]; then
    local rows total verified fab_blocks rate_v rate_f
    rows=$(grep -v '^#' "$ledger" | grep -v '^block_id' | grep -v '^[[:space:]]*$' || true)
    total=$(echo "$rows" | grep -c . || true)
    if [ "$total" -gt 0 ]; then
      verified=$(echo "$rows" | awk -F'\t' '$5 == "verified" {n++} END {print n+0}')
      fab_blocks=$(echo "$rows" | awk -F'\t' '$6 ~ /^[0-9]+$/ && $6 > 0 {n++} END {print n+0}')
      rate_v=$((verified * 100 / total))
      # fabricated 検出率 = fabricated が 1 件以上出たブロック ÷ Verify 済みブロック（実測 35% との比較用）
      local verified_any
      verified_any=$(echo "$rows" | awk -F'\t' '$6 ~ /^[0-9]+$/ {n++} END {print n+0}')
      [ "$verified_any" -gt 0 ] && rate_f=$((fab_blocks * 100 / verified_any)) || rate_f=0
      lines+="${today}\tledger_blocks\tall\t${total}\n"
      lines+="${today}\tverified_rate_pct\tall\t${rate_v}\n"
      lines+="${today}\tfabricated_detect_rate_pct\tall\t${rate_f}\n"
      # 【層別の fabricated を出す（合否は持たない）】誤りは層に均等に散らばらない。
      # 独立した 3 成果物の実測で、本質層（`specs/rebuild/`）の 1 ブロックあたり fabricated は
      # 他層の 1.4〜11.8 倍だった（GP-16 ルール10-(7)）。**どの層に集まっているかを毎回見えるようにする**
      # ——閾値は置かない（層構成はプロジェクトごとに違い、完成品が落ちる要求にしない。GP-103）。
      local layer_out
      # 【`.md` を落とさない】落とした初版は、**平置きの `specs/rebuild.md` が
      # ディレクトリ層 `rebuild` と同じ名前に潰れ**、ゲート側（`specs/rebuild/` の前置一致）と
      # 対象がずれた。平置きファイルは `overview.md` のようにそのまま層名にする（区別できる）。
      # 【ヘッダ・注釈を自前で飛ばす】呼び出し側の前処理に暗黙に依存していた（他の台帳リーダは
      # awk 内で自前に落としている）。非対称を残すと前処理を外した人が黙って壊す。
      layer_out=$(printf '%s\n' "$rows" | LC_ALL=C awk -F'\t' -v D="$today" '
        function trim(v) { gsub(/\r/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); return v }
        {
          sf = trim($2); ff = trim($6)
          if (sf == "" || sf == "spec_file" || sf ~ /^#/) next
          # 【層名を正規化する】手順書は `spec_file` 列に `api/x.md`・`./specs/…` も認める。
          #  先頭の `./` と `specs/` を落としてから、ディレクトリ名か（平置きなら）ファイル名を層名にする。
          #  ファイル側の集計（主張行あたりの指標）と同じ規則で、結合が黙って外れないようにする。
          sub(/^\.\//, "", sf); sub(/^specs\//, "", sf)
          n = split(sf, q, "/"); layer = (n >= 2) ? q[1] : sf
          blk[layer]++
          if (ff ~ /^[0-9]+$/) fab[layer] += ff
        }
        END {
          for (l in blk) {
            printf "%s\tlayer_blocks\t%s\t%d\n", D, l, blk[l]
            printf "%s\tlayer_fabricated\t%s\t%d\n", D, l, fab[l]
            printf "%s\tlayer_fab_per_block_x100\t%s\t%d\n", D, l, (fab[l] * 100) / blk[l]
          }
        }' || true)
      [ -n "$layer_out" ] && lines+="$layer_out\n"
      # 【主張行あたりに正規化する（2026-10-01 追加）】ブロックの大きさは実行ごとに違う
      # （実測: 同じ対象の 2 回の完走試験で 1 ブロックあたりの主張行が約 1.7 倍違った）。
      # 「ブロックあたりの誤り」は実行間で比べられないので、**主張行 1,000 行あたり**も出す。
      # 主張行は `CLAIM_LINE_RE`（G-POPULATION 等と同じ述語）で数える。合否は持たない。
      # 【分母の範囲】主張行はブロックの外・HTML コメントの中も含む（fabricated は Verify 済みブロックの中だけ）。
      #  範囲が違うので絶対値ではなく、**同じ定義で測った実行どうしの比較**に使う。生成物の索引は数えない。
      local claim_out
      claim_out=$(content_spec_files | nul_pack | LC_ALL=C xargs -0 -r awk -v RE="$CLAIM_LINE_RE" -v S="$SPECS/" '
          FNR == 1 { rel = FILENAME; if (substr(rel, 1, length(S)) == S) rel = substr(rel, length(S) + 1)
                     n = split(rel, q, "/"); layer = (n >= 2) ? q[1] : rel; files[layer]++ }
          $0 ~ RE { cl[layer]++ }
          END { for (l in files) printf "C\t%s\t%d\t%d\n", l, cl[l] + 0, files[l] }' 2>/dev/null) || claim_out=""
      if [ -n "$claim_out" ]; then
        local per_claim
        per_claim=$( { printf '%s\n' "$layer_out"; printf '%s\n' "$claim_out"; } | LC_ALL=C awk -F'\t' -v D="$today" '
            $2 == "layer_fabricated" { fab[$3] = $4; next }
            $1 == "C" { printf "%s\tlayer_claim_lines\t%s\t%d\n", D, $2, $3
                        printf "%s\tlayer_spec_files\t%s\t%d\n", D, $2, $4
                        if ($3 > 0 && ($2 in fab)) printf "%s\tlayer_fab_per_1k_claims\t%s\t%d\n", D, $2, (fab[$2] * 1000) / $3 }' || true)
        [ -n "$per_claim" ] && lines+="$per_claim\n"
      fi
    fi
  fi

  # 4) UNKNOWN 内訳（未解決の質）
  # `undecidable` = 調べた結果として原典から決まらない（GP-5 ルール5/8）。
  # **3 タグ固定のままだと新タグが集計に現れず「記録したのに見えない」**状態になる。
  # `partial` = 一部だけ確認して完了した（GP-5 ルール10）。**件数は「どれだけ読み残したか」の観測**であり合否ではない。
  for tag in blocking deferred out-of-scope undecidable partial; do
    local n
    n=$(content_spec_files | nul_pack | xargs -0 -r grep -o "UNKNOWN\[${tag}\]" 2>/dev/null | wc -l | tr -d ' ')
    lines+="${today}\tunknown_${tag}\tall\t${n}\n"
  done
  # HOLD-9 の (B) で外した主張（範囲に `[[ADR-` を持つ partial）。完了の条件の件数の出所（手順書 Step 4-7）
  local n_hold9
  # 範囲の中（`確認した範囲:` から最初の `）` か `。` まで）が `[[ADR-` で始まる partial を、**出現ごと**に数える（解消済みは除く）
  n_hold9=$(content_spec_files | nul_pack | xargs -0 -r grep -h 'UNKNOWN\[partial\]' 2>/dev/null \
            | grep -v '~~.*~~ \*\*解消済' | awk '{
                rest = $0
                while ((i = index(rest, "UNKNOWN[partial]")) > 0) {
                  rest = substr(rest, i + length("UNKNOWN[partial]"))
                  j = index(rest, "確認した範囲"); if (j == 0) break
                  r = substr(rest, j + length("確認した範囲")); sub(/^[ *]+/, "", r)
                  if (index(r, ":") == 1) r = substr(r, 2); else if (index(r, "：") == 1) r = substr(r, length("：") + 1); else continue
                  sub(/^[ ]+/, "", r)
                  if (index(r, "[[ADR-") == 1) n++
                }
              } END { print n + 0 }' || true)
  # 【`|| echo 0` にしない】該当行が 0 件だと pipefail で前段の grep が rc=1 になり、awk の 0 に echo の 0 が足されて
  #  2 行になった（metrics.tsv の列が壊れた。実測）。awk は常に 1 行出すので、末尾の 1 行だけを採る。
  n_hold9=$(printf '%s\n' "$n_hold9" | tail -1)
  lines+="${today}\tunknown_partial_hold9\tall\t${n_hold9:-0}\n"

  # 5) ノード消化率（分母未消化: SB-11）
  # 【定義が変わった時点の段差に注意】`node_count` は `node_rows` の行数である。
  # `node_rows` は 2026-09 に**エッジ行をノード行と数えない**形に直したので、
  # それ以前に記録した値とは**同じ名前で意味が違う**（実測: ある成果物で 66 → 33）。
  # 値は正しくなったが、**時系列を見るときは定義変更の前後で比較しない**
  # （`metrics.tsv` は追記専用なので過去の行は残る。教訓 37: 成果物でなく測定器が変わる事故）。
  if [ -f "$CODEGRAPH" ]; then
    local nodes done_nodes rate_n
    nodes=$(node_rows | grep -c . || true)
    if [ "$nodes" -gt 0 ]; then
      done_nodes=$(node_rows | grep -c '仕様化済\|対象外' || true)
      rate_n=$((done_nodes * 100 / nodes))
      lines+="${today}\tnode_count\tall\t${nodes}\n"
      lines+="${today}\tnode_done_rate_pct\tall\t${rate_n}\n"
    fi
  fi

  printf '%b' "$lines" >> "$out"
  echo "=== metrics スナップショット（${today}） ==="
  printf '%b' "$lines" | column -t -s $'\t'
  echo ""
  echo "→ ${out#"$REPO_ROOT"/} に追記した（同一書式でプロジェクト横断比較・改善効果測定に使う）"
}

# 必須節充足率の算出（gate_density と同じ対応付けロジックの集計版）
metrics_density_fill_rate() {
  local today
  today=$(date '+%Y-%m-%d')
  while IFS= read -r tmpl; do
    local req_line
    req_line=$(grep -o 'required-sections: [^-]*' "$tmpl" | head -1 | sed 's/required-sections: //; s/ *-*$//')
    [ -z "$req_line" ] && continue
    local cat_dir tmpl_key cat_name targets
    cat_dir=$(dirname "$tmpl")
    cat_name=$(basename "$cat_dir")
    tmpl_key=$(grep -o 'artifact-key: [a-z0-9-]*' "$tmpl" | head -1 | sed 's/artifact-key: //')
    if [ -n "$tmpl_key" ]; then
      targets=$(grep -rlE "$(artifact_key_re "$tmpl_key")" "$SPECS" 2>/dev/null | grep -v '/_[^/]*$' || true)
      cat_name="$tmpl_key"
    else
      targets=$(find "$cat_dir" -name '*.md' -not -name '_*' 2>/dev/null \
                | nul_pack | xargs -0 -r grep -LE "$ARTIFACT_KEY_ANY_RE" 2>/dev/null || true)
    fi
    local n_specs=0 n_ok=0
    while IFS= read -r spec; do
      [ -z "$spec" ] && continue
      n_specs=$((n_specs + 1))
      local ok=1
      local IFS_OLD="$IFS"
      IFS=','
      for section in $req_line; do
        section=$(echo "$section" | sed 's/^ *//; s/ *$//')
        [ -z "$section" ] && continue
        local head_line
        # 【H1 は題名なので見ない（2026-10-01）】題名の中の語に先に当たり、本物の節の代わりに題名の直後を「空」と判定した。
        head_line=$(grep -n "^#\{2,4\} .*${section}" "$spec" | head -1 | cut -d: -f1)
        local head_lvl
        head_lvl=$(sed -n "${head_line:-0}p" "$spec" 2>/dev/null | sed 's/^\(#*\).*/\1/' | awk '{print length($0)}')
        [ -z "$head_line" ] && { ok=0; break; }
        local body
        # 【同じかより浅い見出しまでを本文とする（2026-10-01）】次の見出しで切っていたため、直後に `###` の小節が来ると
        #  その節は「空」と判定された（小節が中身なのに）。小節の**中身**を数え、見出し行そのものは数えない
        #  （空の小節の見出しだけで「非空」にしない）。
        body=$(awk -v start="$head_line" -v L="${head_lvl:-4}" 'NR > start { if (match($0, /^#+ /) && RLENGTH - 1 <= L) exit; print }' "$spec" \
               | strip_html_comments | grep -v '^[[:space:]]*$' | grep -v '^|[-| ]*|$' | grep -vE '^#+ ' || true)
        [ -z "$body" ] && { ok=0; break; }
      done
      IFS="$IFS_OLD"
      [ "$ok" -eq 1 ] && n_ok=$((n_ok + 1))
    done <<< "$targets"
    if [ "$n_specs" -gt 0 ]; then
      printf '%s\trequired_sections_fill_pct\t%s\t%s\n' "$today" "$cat_name" "$((n_ok * 100 / n_specs))"
    fi
  done < <(find "$SPECS" \( -name '_template.md' -o -name '_*-template.md' \) 2>/dev/null)
}

# ---- main ----
SUBCMD="${1:-}"
# 詳細の全件ログは実行ごとに作り直す（追記し続けると何回目の結果か分からなくなる）
: > "$DETAILS_FILE" 2>/dev/null || true
case "$SUBCMD" in
  phase1)  run_phase1 ;;
  phase2)  run_phase2 ;;
  phase3)  run_phase3 ;;
  phase4)  run_phase4 ;;
  all)     run_phase1; echo; run_phase3; echo; run_phase4 ;;
  density) run_density ;;
  # metrics / session は gate-results.md に書き込まず、末尾の共通判定も通さない。
  # 【注意】共通判定は ${FAIL_COUNT}（report 関数が加算）を見るため、
  # report を使わない session の戻り値が**上書きされて常に exit 0 になっていた**。
  # 自前の終了コードを返すには**ここで exit する**必要がある。
  metrics) run_metrics; exit 0 ;;
  session) run_session; exit $? ;;
  # source-baseline は解析対象の今の状態を記録する（gate-results.md には書かない。init.sh が呼ぶ）
  source-baseline) run_source_baseline; exit $? ;;
  # source-index は成果物を生成する（gate-results.md には書かない）。
  # 不在・陳腐化の判定は phase3/phase4 の G-SOURCEINDEX が行う。
  source-index) run_source_index "${2:-}"; exit $? ;;
  *)
    print_usage
    # 【ここも痕跡を残す】`main` 冒頭で詳細ログを空にしてから来るので、直前の実行の詳細は
    # 既に消えている。何も書かないと「空の詳細ログ」だけが残り、中断したことが分からない。
    { echo "# gates.sh: 不明なサブコマンド '${SUBCMD}' で中断（判定は 1 件も記録していない）"
      echo "# gate-results.md / gate-verdicts.tsv の内容は前回の実行のもの"; } > "$DETAILS_FILE" 2>/dev/null || true
    exit 2
    ;;
esac

# ---- 結果の記録（gate-results.md = 検証結果の正本） ----
if [ "${#REPORT_LINES[@]}" -gt 0 ]; then
  {
    echo ""
    echo "## 実行記録: $(date '+%Y-%m-%d %H:%M') — \`gates.sh ${SUBCMD}\`"
    echo ""
    echo "| ゲート | 判定 | 内容 |"
    echo "|--------|------|------|"
    printf '%s\n' "${REPORT_LINES[@]}"
    echo ""
    echo "**結果: FAIL ${FAIL_COUNT} / INCOMPLETE ${INCOMPLETE_COUNT} / WARN ${WARN_COUNT}**"
  } >> "$RESULTS"
  # 1 実行 1 行の実測値（FB-12 の再発検知。次の run と機械的に比較するため）
  [ -f "$RUNS_TSV" ] || printf 'date\ttime\tsubcmd\tpass\tfail\tincomplete\twarn\tdetail_lines_full\tdetail_lines_shown\tdetail_max\n' > "$RUNS_TSV"
  printf '%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' \
    "$(date '+%Y-%m-%d')" "$(date '+%H:%M')" "$SUBCMD" \
    "$PASS_COUNT" "$FAIL_COUNT" "$INCOMPLETE_COUNT" "$WARN_COUNT" \
    "$DETAIL_LINES_FULL" "$DETAIL_LINES_SHOWN" "$DETAIL_MAX" >> "$RUNS_TSV"
  # ゲート別の判定 ＋ gates.sh の指紋（G-REGRESS が次回の実行で前回と突合する）
  if [ "${#VERDICT_LINES[@]}" -gt 0 ]; then
    [ -f "$VERDICTS_TSV" ] || printf 'date\ttime\tsubcmd\tgate_id\tverdict\tgates_sha\n' > "$VERDICTS_TSV"
    # ここはトップレベル（関数の外）なので `local` は使えない
    _d=$(date '+%Y-%m-%d'); _t=$(date '+%H:%M')
    # 【同一 run で同じゲートが 2 回判定されたら 1 行に畳む（最も厳しい判定を採る）】
    # 複数の phase に登録されたゲート（`all` で 2 回走る）が 2 行残ると、
    # **`G-REGRESS` の「最新」と「1 つ前」が同一 run の 2 行になり、前回の FAIL が押し出される**
    # ——「ゲートを緩めて通した」ことを検出する唯一の仕掛けが無効になる（実測で再現した）。
    # 厳しさの順: FAIL > INCOMPLETE > WARN > PASS。
    printf '%s\n' "${VERDICT_LINES[@]}" \
      | LC_ALL=C awk -F'\t' '
          # 【語彙外は最強側に倒す】未知の判定を PASS より弱くすると**PASS で上書きされる**。
          # 「測っていない」を「通った」と読ませない（同ファイルの fail-closed 規約と揃える）。
          function rank(v) { return (v=="PASS")?1:((v=="WARN")?2:((v=="INCOMPLETE")?3:((v=="FAIL")?4:5))) }
          { if (!($1 in best) || rank($2) > rank(best[$1])) { if (!($1 in best)) order[++n]=$1; best[$1]=$2 } }
          END { for (i=1; i<=n; i++) print order[i] "\t" best[order[i]] }' \
      | while IFS=$'\t' read -r _g _v; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_d" "$_t" "$SUBCMD" "$_g" "$_v" "$GATES_SHA"
        done >> "$VERDICTS_TSV"
  fi
else
  # metrics 等、ゲート判定を伴わないサブコマンドは gate-results に追記しない
  exit 0
fi

echo ""
echo "--------------------------------------------------"
if [ $((FAIL_COUNT + INCOMPLETE_COUNT)) -eq 0 ]; then
  echo "✅ 全ゲート通過（WARN ${WARN_COUNT}）。結果を ${RESULTS#"$REPO_ROOT"/} に記録した。"
  exit 0
else
  # **欠陥（FAIL）と未完了（INCOMPLETE）を分けて出す。** 作業途中は後者が大半で、
  # 先に見るべきは前者である（実測: 途中の未達 10 件中 9 件が未完了だった）。
  echo "❌ 未達 $((FAIL_COUNT + INCOMPLETE_COUNT)) 件（**欠陥 ${FAIL_COUNT}** / 未完了 ${INCOMPLETE_COUNT}）/ WARN ${WARN_COUNT} 件。"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "   → まず ❌[FAIL]（欠陥）を直す。🚧[INCOMPLETE] は作業を進めれば解消する。"
  else
    echo "   → 欠陥は 0。🚧[INCOMPLETE] のみ＝作業を進めれば解消する（完了/レディ宣言はまだできない）。"
  fi
  echo "   完了/レディ宣言の条件は「未達 0」で変わらない。結果を ${RESULTS#"$REPO_ROOT"/} に記録した。"
  exit 1
fi
