#!/bin/bash
# =============================================================================
# next-id.sh — 新しい GP/SB/FB の採番を機械化する
# =============================================================================
#
# 「採番の前に実測する」を人手の手順にしていたら 2 回連続で衝突した:
#   - Phase G: GP-23 を採ろうとした → fineract が既に使用（記憶で判断した）
#   - Phase H: SB-32 を採った       → fineract が同日中に SB-32/33 を追加していた
#                                     （1 時間前の実測値を使った＝測定の鮮度が足りない）
# 人が「測って・読んで・書き写す」工程が残る限り同じ失敗が起きる。**採番そのものを実行物にする。**
#
# 使い方:
#   ./next-id.sh          全系列の次番号を表示
#   ./next-id.sh GP       GP の次番号だけを数値で出力（スクリプトから使える）
#   ./next-id.sh --check  フレームワーク本体の番号が他リポジトリと衝突していないか検査（exit 1 で衝突）
#
# 走査対象: 本リポジトリの pipeline.md / playbook.md ＋ 同階層の全 *-spec リポジトリのコピー。
# **git のコミット状態を見ない**（未コミットの追記も占有として数える。実際に fineract の
# SB-32/33 は未コミットだった）。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACES="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# 【重要】採番は「番号帯」で分離する（3 回続けて衝突したため方式を変えた）
# =============================================================================
# 衝突の履歴——いずれも**同じ構造**の失敗:
#   Phase G: GP-23 を記憶で判断して衝突
#   Phase H: SB-32 を 1 時間前の実測値で採り衝突（その間に追加されていた）
#   Phase J: SB-34 を実測直後に採ったが衝突（並行して追加された）
#
# 根本原因は **単一の連番空間を 2 者（フレームワーク本体・稼働中のプロジェクト）が
# 同時に消費していること**。「測ってから採る」方式は、測定と採番の間に隙間がある限り
# 必ず破れる（TOCTOU）。プロジェクトは並行して作業を続けており、隙間はゼロにできない。
#
# また Phase F で名前空間分離（`GP-<spec-name>-N`）を導入したが、**それ以前に生成された
# プロジェクト**（宣言のないコピーを持つ）は無印を採り続ける。既存プロジェクトを
# 遡って直すことはできない。
#
# → **フレームワーク本体は 100 番以降を使う。** プロジェクトが自然に使う 1〜99 と
#   構造的に衝突しない（プロジェクトが 100 件の知見を独自採番するまで安全）。
#   1〜99 の既存エントリは維持し、新規のみ 100 番以降を採る。
FRAMEWORK_BASE=100

# series_max <GP|SB> → 全リポジトリを走査した最大番号
series_max() {
  local series="$1" file
  case "$series" in
    GP) file="pipeline.md" ;;
    SB) file="playbook.md" ;;
    *)  echo "0"; return ;;
  esac
  # 【本体の台帳が読めなければ採番しない（fail-closed）】下の `echo 0` は
  # 「他リポジトリが 0 件でも動く」ための床だが、**本体の台帳も読めないときに 0 に落ちる**。
  # その結果 `next_in_band 0` が `FRAMEWORK_BASE`（=100）を返し、**既に使われている番号**を
  # 「次の空き」として提示する（実測: `chmod 000 pipeline.md` で 107 → 100 になった）。
  # この道具は「測ってから採る方式は隙間がある限り破れる」という 3 回の衝突への対策なのに、
  # **壊れた瞬間に確定衝突する番号を返していた**。読めないなら答えを出さずに落ちる。
  # 【`exit` はここでは効かない】`series_max` は `$( )` の中で呼ばれるのでサブシェルであり、
  # `exit 2` はサブシェルを抜けるだけで**外側は rc=0 のまま続行する**（実測で踏んだ）。
  # ⇒ **番号ではありえない値（-1）を返し、呼び出し側（`next_in_band`）で落とす。**
  if [ ! -r "$SCRIPT_DIR/$file" ]; then
    echo "-1"; return
  fi
  {
    grep -oE "^## ${series}-[0-9]+" "$SCRIPT_DIR/$file" | grep -oE '[0-9]+'
    for r in "$WORKSPACES"/*-spec; do
      [ -f "$r/spec-extraction/docs/knowledge/$file" ] || continue
      grep -oE "^## ${series}-[0-9]+" "$r/spec-extraction/docs/knowledge/$file" 2>/dev/null | grep -oE '[0-9]+'
    done
    echo 0
  } | sort -n | tail -1
}

# FB は playbook.md の実運用フィードバック表（| FB-N |）で管理する
fb_max() {
  {
    grep -oE '^\| FB-[0-9]+' "$SCRIPT_DIR/playbook.md" 2>/dev/null | grep -oE '[0-9]+'
    for r in "$WORKSPACES"/*-spec; do
      [ -f "$r/spec-extraction/docs/knowledge/playbook.md" ] || continue
      grep -oE '^\| FB-[0-9]+' "$r/spec-extraction/docs/knowledge/playbook.md" 2>/dev/null | grep -oE '[0-9]+'
    done
    echo 0
  } | sort -n | tail -1
}

# 本体が定義している番号のうち、他リポジトリでも定義されているもの（＝意味の衝突）
collisions() {
  local series="$1" file="$2" own other
  own=$(grep -oE "^## ${series}-[0-9]+" "$SCRIPT_DIR/$file" 2>/dev/null | grep -oE '[0-9]+' | sort -u)
  for r in "$WORKSPACES"/*-spec; do
    local f="$r/spec-extraction/docs/knowledge/$file"
    [ -f "$f" ] || continue
    other=$(grep -oE "^## ${series}-[0-9]+" "$f" 2>/dev/null | grep -oE '[0-9]+' | sort -u)
    # 本体のコピーとして配布された番号は衝突ではない。「本体に無い番号」を独自採番と見なし、
    # そのうち本体が後から使ってしまった番号を衝突として報告する。
    comm -12 <(echo "$own") <(echo "$other") | while read -r n; do
      local a b
      a=$(grep -m1 "^## ${series}-${n}:" "$SCRIPT_DIR/$file")
      b=$(grep -m1 "^## ${series}-${n}:" "$f")
      # 本体が「欠番」スタブなら、それは衝突を回避した記録そのものなので報告しない
      case "$a" in *欠番*) continue ;; esac
      # 見出しの先頭 24 文字（タイトルの主部）が一致すれば同一エントリの版差＝衝突ではない
      # （コピー配布後に本体側でタイトルを補筆した場合を誤検出しないため）
      [ "${a:0:24}" = "${b:0:24}" ] && continue
      echo "  ${series}-${n}: 本体「$(echo "$a" | cut -c1-56)」 vs $(basename "$r")「$(echo "$b" | cut -c1-56)」"
    done
  done
}

# next_in_band <現在の最大> → フレームワーク帯（100 番以降）の次番号
next_in_band() {
  local max="$1"
  # 【読めなかったことを 0 件と混ぜない】`series_max` が `-1` を返したら答えを出さずに落ちる。
  if [ "$max" -lt 0 ]; then
    echo "ERROR: 本体の台帳を読めないため採番できません（読めると 0 件は区別する）。" >&2
    echo "       この状態で採番すると既に使われている番号を「次の空き」として返し、確定で衝突します。" >&2
    exit 2
  fi
  if [ "$max" -lt "$FRAMEWORK_BASE" ]; then
    echo "$FRAMEWORK_BASE"
  else
    echo $(( max + 1 ))
  fi
}

case "${1:-}" in
  GP) next_in_band "$(series_max GP)" ;;
  SB) next_in_band "$(series_max SB)" ;;
  # FB（実運用フィードバック）は本体のみが採番する系列（プロジェクトは一度も採番していない）。
  # 帯を適用すると FB-100 になり不合理なので、FB は通常の連番のままにする。
  FB) echo $(( $(fb_max) + 1 )) ;;
  --check)
    found=""
    for pair in "GP pipeline.md" "SB playbook.md"; do
      set -- $pair
      c=$(collisions "$1" "$2")
      [ -n "$c" ] && found+="$c"$'\n'
    done
    if [ -n "$found" ]; then
      echo "❌ ID の意味が衝突している（GP-9 違反。改番が必要）:"
      echo "$found"
      exit 1
    fi
    echo "✅ ID の衝突なし（本体の番号が他リポジトリで別の意味に使われていない）"
    ;;
  "")
    echo "=== 次に採るべき番号（フレームワーク帯 = ${FRAMEWORK_BASE} 番以降） ==="
    printf '  GP-%s / SB-%s / FB-%s\n' \
      "$(next_in_band "$(series_max GP)")" "$(next_in_band "$(series_max SB)")" "$(( $(fb_max) + 1 ))"
    echo ""
    echo "  ※ 単一連番を本体とプロジェクトが同時に消費すると必ず衝突する（3 回発生）。"
    echo "     本体は ${FRAMEWORK_BASE} 番以降を使い、プロジェクトが使う 1〜99 と構造的に分離する。"
    echo "     FB は本体のみが採番する系列なので帯を適用しない（通常の連番）。"
    echo ""
    echo "=== 占有状況 ==="
    printf '  %-28s GP最大=%s SB最大=%s\n' "reverse-spec-flow（本体）" \
      "$(grep -oE '^## GP-[0-9]+' "$SCRIPT_DIR/pipeline.md" | grep -oE '[0-9]+' | sort -n | tail -1)" \
      "$(grep -oE '^## SB-[0-9]+' "$SCRIPT_DIR/playbook.md" | grep -oE '[0-9]+' | sort -n | tail -1)"
    for r in "$WORKSPACES"/*-spec; do
      p="$r/spec-extraction/docs/knowledge"
      [ -f "$p/pipeline.md" ] || continue
      printf '  %-28s GP最大=%s SB最大=%s\n' "$(basename "$r")" \
        "$(grep -oE '^## GP-[0-9]+' "$p/pipeline.md" | grep -oE '[0-9]+' | sort -n | tail -1)" \
        "$(grep -oE '^## SB-[0-9]+' "$p/playbook.md" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
    done
    echo ""
    echo "※ 実測値を文書に書き写さない（書き写した瞬間に古くなる）。採番の直前に本コマンドを実行する。"
    ;;
  *)
    echo "Usage: $0 [GP|SB|FB|--check]" >&2
    exit 2 ;;
esac
