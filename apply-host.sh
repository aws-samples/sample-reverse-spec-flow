#!/bin/bash
# =============================================================================
# apply-host.sh — 既存の仕様リポジトリに harness を後付けする／ホストを変える（GP-107）
# =============================================================================
#
# `init.sh` は**新規生成**のときだけ harness を置く。しかし
#   (a) harness 層の導入**前**に作られたリポジトリ（既定ホストの配置物しか無く、HOST.md が無い）
#   (b) 途中で別のホストに移るとき（Claude Code で始めて Kiro IDE に移る等）
# があるので、**生成物に触らずにホスト固有の配置だけをやり直す**経路を用意する。
#
# 使い方:
#   ./apply-host.sh <spec-repo-path> <host> [--force]
#     <spec-repo-path> : init.sh が作った仕様リポジトリ（spec-extraction/ と specs/ を持つ）
#     <host>           : hosts/ 配下の名前、または任意パス
#     --force          : 未コミットの変更があっても進める（既定は止まる）
#
# 例:
#   ./apply-host.sh ../legacy-order-system-spec kiro-ide
#
# 【設計の原則】（2026-10-26 に実装と一致する形へ書き直した。初版は「生成物に触らない・何も削除しない・冪等」と
#   書いていたが、harness の実行物を spec-extraction/03-audit/ に置き、同名ファイルを上書きし、履歴を毎回追記していた）
#   1. **成果物（specs/）と中間生成物（spec-extraction/ の 00〜03 の記録）を変更しない。** 置くのは harness の配置物だけ。
#      ただし harness の実行物（検証官の起動・確認スクリプト）は spec-extraction/03-audit/ に置く（gate-config.env を相対で読むため）。
#   2. **削除しない。上書きはする。** 前のホストの配置物は残す（消すのは人の判断。何が残っているかは最後に表示する）。
#      いまのホストの配置物と同名のファイル（例: 利用者が手で書いた入口ファイルや skill）は**上書きする**。
#      そのために未コミットの変更があると止まる——上書きされたものは `git diff` で見え、戻せる。上書きした一覧は最後に表示する。
#   3. **配置は冪等。履歴は追記。** 置かれるファイルの集合と内容は何度実行しても同じ。`HOST-APPLIED` だけは実行ごとに 1 行増える
#      （append-only の出自の記録。冪等の対象外）。
#   4. **コミットしない。** 他人のリポジトリを勝手に確定させない。
#      ただし**追跡されないと引き継がれない**ので、最後にコミットを促す。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS_DIR="$SCRIPT_DIR/hosts"

FORCE=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 <spec-repo-path> <host> [--force]"
      echo "  既存の仕様リポジトリに harness を後付けする／ホストを変える（GP-107）"
      echo "  specs/ の成果物と spec-extraction/ の中間生成物は変更しない。harness の配置物だけを置く（同名の既存ファイルは上書きし、一覧を報告する）。"
      echo "  削除しない（前のホストの配置物は残し、一覧を報告する）。配置は冪等（HOST-APPLIED の履歴だけ 1 行ずつ増える）。"
      echo "  --force : 未コミットの変更があっても進める（既定は止まる）"
      exit 0 ;;
    -*) echo "Error: 不明なオプション: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"
SPEC_REPO_ARG="${1:-}"
HOST_ARG="${2:-}"
if [ -z "$SPEC_REPO_ARG" ] || [ -z "$HOST_ARG" ]; then
  echo "Usage: $0 <spec-repo-path> <host> [--force]" >&2
  echo "  利用可能なホスト: $(find "$HOSTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '_template' \
    -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')" >&2
  exit 1
fi

# ---- 対象が「生成された仕様リポジトリ」であることを確かめる ----
# 【なぜ確かめるか】取り違えて別のリポジトリに置くと、ホスト固有のファイルが
# 無関係なプロジェクトに混ざる。**生成物に触らないことと、対象を間違えないことは別の話**である。
[ -d "$SPEC_REPO_ARG" ] || { echo "Error: ディレクトリがありません: $SPEC_REPO_ARG" >&2; exit 1; }
SPEC_REPO="$(cd "$SPEC_REPO_ARG" && pwd)"
WROOT="$SPEC_REPO/spec-extraction"
for _m in "$WROOT" "$SPEC_REPO/specs" "$SPEC_REPO/AGENTS.md"; do
  [ -e "$_m" ] || {
    echo "Error: init.sh が作った仕様リポジトリに見えません: $SPEC_REPO" >&2
    echo "  見つからない: ${_m#$SPEC_REPO/}" >&2
    echo "  （spec-extraction/ ・ specs/ ・ AGENTS.md を持つディレクトリを指定する）" >&2
    exit 1; }
done

# ---- 未コミットの変更があれば止まる ----
# 【なぜ止めるか】作業中の生成物とホスト配置の変更が混ざると、**差分を見て判断できなくなる**。
# ホストを変える操作は後戻りが要る種類なので、きれいな状態から始める（GP-100 の dirty 分類と同じ趣旨）。
# 【`.git` はディレクトリとは限らない】worktree では `.git` がファイルになる。`git rev-parse` で判定する。
# 【仕様リポジトリ自身がルートであること】親リポジトリの一部ディレクトリだと `git status` のパスがルート相対になり、
# dirty 判定が親全体に広がり、上書きの報告（HOST.md の除外）も合わなくなる。その場合は git の判定を使わず注意を出す
_in_git=0
_top="$( cd "$SPEC_REPO" && git rev-parse --show-toplevel 2>/dev/null || true )"
if [ -n "$_top" ]; then
  # 論理パスと物理パスの差（/tmp と /private/tmp 等）で誤判定しないよう両方を物理で比べる
  if [ "$( cd "$_top" && pwd -P )" = "$( cd "$SPEC_REPO" && pwd -P )" ]; then _in_git=1
  else echo "  ⚠ ${SPEC_REPO} は git リポジトリのルートではない（ルート: ${_top}）。未コミットの変更の検査と上書きの報告は行わない。" >&2; fi
fi
if [ "$_in_git" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  if [ -n "$(cd "$SPEC_REPO" && git status --porcelain 2>/dev/null)" ]; then
    echo "Error: 未コミットの変更があります: $SPEC_REPO" >&2
    echo "  ホストの配置と作業中の変更が混ざると差分で判断できなくなります。" >&2
    echo "  コミットするか退避してから再実行してください（どうしても進めるなら --force）。" >&2
    exit 1
  fi
fi

# ---- ホストの解決（正本は hosts/_resolve.sh。init.sh と共有する） ----
# shellcheck source=hosts/_resolve.sh
. "$HOSTS_DIR/_resolve.sh"

echo "=== harness の適用 (apply-host.sh) ==="
echo "  spec repo: $SPEC_REPO"
echo "  host     : ${HOST_NAME}（対応レベル: ${HOST_LEVEL:-不明}）"
if [ "${HOST_LEVEL:-placed-unverified}" = "placed-unverified" ]; then  # 宣言が無いものも未検証として扱う
  echo ""
  echo "  ⚠ このホストは **未検証** である。${HOST_DIR}/MEASURED.md を読むこと。"
fi
echo ""

# ---- 適用済みの履歴を読む（前のホストが何かを知る） ----
APPLIED_LOG="$WROOT/docs/knowledge/HOST-APPLIED"
PREV_HOSTS=""
if [ -f "$APPLIED_LOG" ]; then
  PREV_HOSTS="$(grep -oE '^[0-9-]+[[:space:]]+[A-Za-z0-9._-]+' "$APPLIED_LOG" 2>/dev/null \
    | awk '{print $2}' | sort -u | grep -v "^${HOST_NAME}$" | tr '\n' ' ' || true)"
fi

# ---- ホスト固有の配置を委譲する（init.sh と同じ契約） ----
export FW_DIR="$SCRIPT_DIR"
export HOST_DIR
export SPEC_REPO
export WROOT
export SKILLS_SRC="$SCRIPT_DIR/skills"
# shellcheck source=/dev/null
( . "$HOST_DIR/placement.sh" )
# 【ホストを知らずに行える配置（HOST.md・HOST-SETUP.md・残置物の報告）】正本は hosts/_place-common.sh（init.sh と共有）
# shellcheck source=hosts/_place-common.sh
. "$HOSTS_DIR/_place-common.sh"

# ---- 適用の記録（append-only） ----
# 【なぜ残すか】「このリポジトリはどのホスト向けに配置されているか」が分からないと、
# 次に開く人が前提を再現できない。`FRAMEWORK-VERSION`（生成元の版）と同じ趣旨の出自の記録である。
# 【gate-config.env に書かない】ゲートがホスト設定を読むと合否がホストで変わる（GP-107 ルール4）。
mkdir -p "$(dirname "$APPLIED_LOG")"
if [ ! -f "$APPLIED_LOG" ]; then
  cat > "$APPLIED_LOG" << 'EOF'
# 適用した harness の履歴（GP-107）。append-only。
# 「このリポジトリがどのホスト向けに配置されているか」の記録で、ゲートは読まない。
# 書式: <日付> <ホスト> <対応レベル> <適用時のフレームワーク版>
EOF
fi
FW_VER="$(head -1 "$WROOT/docs/knowledge/FRAMEWORK-VERSION" 2>/dev/null | tr -d '\r' || true)"
printf '%s %s %s %s\n' "$(date +%Y-%m-%d)" "$HOST_NAME" "${HOST_LEVEL:-unknown}" "${FW_VER:-unknown}" \
  >> "$APPLIED_LOG"
echo "  recorded : spec-extraction/docs/knowledge/HOST-APPLIED"

# ---- 前のホストの残りを報告する（削除はしない） ----
if [ -n "${PREV_HOSTS// /}" ]; then
  echo ""
  echo "  ⚠ 以前に適用したホストがある: ${PREV_HOSTS}"
  echo "    **このスクリプトは何も削除しない。** 残った配置物は多くの場合そのホスト以外では"
  echo "    黙って無視されるので無害だが、紛らわしいと感じるなら手で消す。"
  echo "    残っているもの（各 harness の profile.env の PLACED_PATHS と突合。外部パスの harness は走査に入らない）:"
  # shellcheck disable=SC2086  # PREV_HOSTS は空白区切りの一覧（語分割が目的）
  _lo="$(host_leftovers "$SPEC_REPO" "$HOST_NAME" $PREV_HOSTS)"
  if [ -n "$_lo" ]; then printf '%s\n' "$_lo"; else echo "      - （該当なし）"; fi
fi

# ---- 上書きしたファイルを報告する（原則 2） ----
# 配置前はクリーン（--force でなければ）なので、変更（M）として見えるものは「存在していたものを上書きした」である。
# --force のときは配置前からの変更が混ざるので、そう書く。
if [ "$_in_git" -eq 1 ]; then
  # HOST.md（置き直す）と HOST-APPLIED（追記する）は設計どおりの変更なので除く
  _ow="$( (cd "$SPEC_REPO" && git status --porcelain 2>/dev/null) | awk '$1 ~ /M/ && $2 != "HOST.md" && $2 !~ /HOST-APPLIED$/ {print "      - " $2}')"
  if [ -n "$_ow" ]; then
    echo ""
    if [ "$FORCE" -eq 1 ]; then echo "  ⚠ 変更されているファイル（--force のため配置前からの変更を含む。内容は git diff で見える）:"
    else echo "  ⚠ 既存のファイルを上書きした（内容は git diff で見える。手書きの内容があったなら戻してから取り込む）:"; fi
    printf '%s\n' "$_ow"
  fi
fi
# 【古い生成先の入口が HOST.md を指していない】harness 層より前に作ったリポジトリでは、ルートの AGENTS.md と手順書が
# HOST.md を知らない。手順書だけで進める実施者は HOST.md の「検証官の隔離」を読まない（独立レビュー）。生成物は書き換えず、知らせる
for _entry in AGENTS.md spec-extraction/pipeline-procedure.md; do
  if [ -f "$SPEC_REPO/$_entry" ] && ! grep -q 'HOST.md' "$SPEC_REPO/$_entry" 2>/dev/null; then
    echo ""
    echo "  ⚠ ${_entry} が HOST.md を指していない（harness 層より前に作ったリポジトリ）。"
    echo "    先頭に「ホスト固有の規則（ツール名・禁止事項・検証官の隔離）はルートの HOST.md に従う」の 1 行を足すこと。"
  fi
done
unset _entry

# ---- 完了 ----
echo ""
echo "=== 完了 ==="
# 【言い過ぎない】HOST-APPLIED は spec-extraction/ の下にあるので「spec-extraction/ を変更していない」は
# 正しくない。**変更していないのは成果物と中間生成物**で、追記したのは記録 1 件である。
echo "  変更していないもの: specs/ の成果物と spec-extraction/ の中間生成物（追記したのは HOST-APPLIED 1 件。harness が置く実行物と HOST.md は置き直した）。"
if [ "${HOST_SETUP_PLACED:-0}" = 1 ]; then
  echo "  ★ セッションを開く前に ${SPEC_REPO}/HOST-SETUP.md を読むこと。"
fi
echo ""
echo "  次にやること: 差分を確認してコミットする。"
echo "    cd $SPEC_REPO && git status --short"
echo "  **追跡されないと引き継がれない**（実運用で、無視された入口文書が引き継がれず入口が死んだ）。"
