#!/bin/bash
# =============================================================================
# claude-verify-check.sh — Claude Code の検証官が隔離されていたかを、セッション記録で確かめる（GP-16 ルール2 / SB-12）
# =============================================================================
#
# 使い方:  bash spec-extraction/03-audit/claude-verify-check.sh --since <UTC 時刻> --expect <起動した数> [--projects <dir>]
#   Claude Code のセッション記録（既定 ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<作業ディレクトリ>/*/subagents/）を読み、
#   --since 以降に起動した検証官（spec-verifier で起動したもの、または検証官の指示テンプレートで起動したもの）をすべて確かめる。
#   --expect には、その間に起動した検証官の数を渡す（PASS がこれに満たなければ rc=3。指示文を言い換えて汎用で起動した 1 体は
#   記録から見分けられないので、数で拾う）。
#   作業ディレクトリは仕様リポジトリのルートと spec-extraction/ の両方を探す。
#   --since は記録の timestamp（例 2026-11-03T13:01:10.880Z）と文字列で比べる（前方一致の短い形も使える）。
#
# 出力（標準出力・タブ区切り・検証官ごとに 1 行。最後に集計 1 行）:
#   <agent_id>  PASS  block_id=<ID|->  -
#   <agent_id>  FAIL  block_id=<ID|->  <C1〜C3>: <理由>
#   **採用してよいのは PASS の行の検証官の結果だけ**（台帳の verifier = subagent-isolated）。
#
# 終了コード: 0 = 対象の検証官がすべて PASS（1 体以上）
#            3 = 1 体でも FAIL、または PASS が --expect に満たない（その結果は集計にも台帳にも入れない）
#            2 = 前提を満たさない（記録・設定が見つからない・対象が 0 体）。何も確かめていない
#
# 【確かめること】
#   C1 検証官のテンプレートで起動したサブエージェントが spec-verifier である（汎用での代用を拾う）
#   C2 hook が実際に動いた: 記録の中に、verifier-guard が読み取りを拒否した結果がある
#      （信頼ダイアログ未承認で hook が動かない状態を拾う。定義は最初に AGENTS.md を読ませ、それが拒否される。
#      拒否されたパスは問わない——実測で、カナリアのパスを取り違えて別の場所の AGENTS.md を読もうとし、
#      hook に拒否されたのに guard-canary.tsv に行が残らなかった検証官がいた）
#   C3 読み取り（Read / Grep / Glob）が解析対象ソースの配下だけ、または hook に拒否されている。
#      それ以外のツール（Bash 等）を使っていない
#
# 【なぜ起動ごとの照合をやめたか】以前は「窓の中で起動した spec-verifier の数 ≤ guard-canary.tsv に増えた
#   agent_id の数」を起動のたびに確かめさせていた。並列のバッチを窓にまとめる手続きのために取りまとめ役の
#   サブエージェントが生まれ、サブエージェントの費用の約 4 割を占めた（約 5,200 行の対象での実測）。照合に失敗した巡は
#   丸ごとやり直しになった。記録は agent_id ごとに残るので、終わった後に 1 回まとめて確かめれば足りる。
#
# 【JSON を完全には解釈しない】依存を増やさない（bash と coreutils だけ）。記録は 1 行 1 イベントの
#   詰めた JSON で、決まったキーの値だけを取り出す。**想定した形が見つからなければ FAIL / rc=2 に倒す**
#   （形式が変わったのに黙って合格にしない）。記録はリポジトリの外にあるので gates.sh は読まない（GP-107 ルール4）。
# =============================================================================
set -u
export LC_ALL=C

# 検証官の指示テンプレートの 1 行目（skills/density-verify §2・spec-adversarial-audit 手順 3）
MARKER='あなたは仕様記述の敵対的検証官である'

die2() { echo "claude-verify-check: $*" >&2; exit 2; }

repo_arg=""; since=""; expect=""; projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
while [ $# -gt 0 ]; do
  case "$1" in
    --since)      [ $# -ge 2 ] || die2 "--since に値が無い"; since=$2; shift 2 ;;
    --since=*)    since=${1#--since=}; shift ;;
    --expect)     [ $# -ge 2 ] || die2 "--expect に値が無い"; expect=$2; shift 2 ;;
    --expect=*)   expect=${1#--expect=}; shift ;;
    --projects)   [ $# -ge 2 ] || die2 "--projects に値が無い"; projects=$2; shift 2 ;;
    --projects=*) projects=${1#--projects=}; shift ;;
    --repo)       [ $# -ge 2 ] || die2 "--repo に値が無い"; repo_arg=$2; shift 2 ;;   # 試験用（既定はこのスクリプトの位置から辿る）
    -h|--help)    sed -n '5,20p' "$0"; exit 0 ;;
    *)            die2 "不明な引数: $1" ;;
  esac
done

case "$expect" in ''|*[!0-9]*) [ -z "$expect" ] || die2 "--expect は数で渡す: ${expect}" ;; esac
if [ -n "$repo_arg" ]; then here="$repo_arg/spec-extraction/03-audit"
else here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); fi
# Claude Code は論理パス（シンボリックリンクを辿る前）で記録の場所を決めるので、論理パスも控える
if [ -n "$repo_arg" ]; then here_l=$(cd "$repo_arg/spec-extraction/03-audit" && pwd -L) || here_l=$here
else here_l=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -L) || here_l=$here; fi
spec_root=$(cd "$here/../.." && pwd -P) || die2 "仕様リポジトリを解決できない: ${here}"
conf="$spec_root/spec-extraction/00-ingestion/gate-config.env"
[ -f "$conf" ] || die2 "設定が無い: ${conf}"
# verifier-guard.sh と同じ寛容さで SOURCE_PATH を読む（最後の代入が勝つ・引用の形を問わない）
src_line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?SOURCE_PATH=" "$conf" | tail -n 1)
[ -n "$src_line" ] || die2 "SOURCE_PATH の行が ${conf} に無い"
src=${src_line#*SOURCE_PATH=}; src=${src%$'\r'}
case "$src" in
  \'*) src=${src#\'}; src=${src%%\'*} ;;
  \"*) src=${src#\"}; src=${src%%\"*} ;;
  *)   src=${src%%[[:space:]]#*}; src=${src%"${src##*[![:space:]]}"} ;;
esac
[ -n "$src" ] && [ -d "$src" ] || die2 "SOURCE_PATH が存在しない: ${src}"
src_p=$(cd -P "$src" && pwd -P)
src_l=${src%/}
[ -d "$projects" ] || die2 "セッション記録の場所が無い: ${projects}"

# Claude Code は作業ディレクトリの英数字以外を - にした名前で記録を置く。
# 論理パスと実体パス（macOS の /private/var 等）の両方、ルートと spec-extraction/ の両方を候補にする。
enc() { printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g'; }
cands=""
for r in "$spec_root" "$(cd "$here_l/../.." && pwd -L)"; do
  for d in "$r" "$r/spec-extraction"; do
    w=$d
    command -v cygpath >/dev/null 2>&1 && w=$(cygpath -w "$d" 2>/dev/null || printf '%s' "$d")
    c="$projects/$(enc "$w")"
    [ -d "$c" ] && case " $cands " in *" $c "*) ;; *) cands="$cands $c" ;; esac
  done
done
[ -n "$cands" ] || die2 "このリポジトリのセッション記録が見つからない（${projects} の下。作業ディレクトリが違う場合は --projects で親を渡す）"

under_src() { # $1=記録のパス（JSON のまま）。解析対象ソースの配下か（論理・実体どちらの表記も受ける）。.. を含むものは配下と見なさない
  local q=$1
  case "$q" in [A-Za-z]:\\*|[A-Za-z]:/*) # Windows（Git Bash）: 記録は C:\\... の形。エスケープを戻して POSIX 形式にする（未実測）
    command -v cygpath >/dev/null 2>&1 || return 1
    q=${q//\\\\/\\}; q=$(cygpath -u "$q" 2>/dev/null) || return 1 ;;
  esac
  case "$q" in *'/../'*|*'/..'|*'\..'*) return 1 ;; esac
  case "$q/" in "$src_l"/*|"$src_p"/*) return 0 ;; esac
  return 1
}

n_pass=0; n_fail=0
tmp_list=$(mktemp "${TMPDIR:-/tmp}/cvc.XXXXXX") || die2 "一時ファイルを作れない"
trap 'rm -f "$tmp_list"' EXIT
for c in $cands; do
  for f in "$c"/*/subagents/agent-*.jsonl; do
    [ -f "$f" ] || continue
    # 対象: spec-verifier で起動したもの（指示文を問わない）と、検証官の指示テンプレートで起動したもの（汎用での代用を C1 で落とす）
    head -n 1 "$f" | grep -qF "$MARKER" || grep -qE '"agentType":"spec-verifier"' "${f%.jsonl}.meta.json" 2>/dev/null || continue
    if [ -n "$since" ]; then
      ts=$(head -n 1 "$f" | grep -oE '"timestamp":"[^"]*"' | head -n 1 | sed 's/.*:"//; s/"$//')
      [ -n "$ts" ] || { printf '%s\n' "$f" >> "$tmp_list"; continue; }   # 時刻が読めないものは対象に含める（落とさない）
      [ "$ts" \< "$since" ] && continue
    fi
    printf '%s\n' "$f" >> "$tmp_list"
  done
done
[ -s "$tmp_list" ] || die2 "対象の検証官が 0 体（--since・作業ディレクトリを確かめる）。何も確かめていない"

while IFS= read -r f; do
  id=${f##*/agent-}; id=${id%.jsonl}
  meta=${f%.jsonl}.meta.json
  blk=$(grep -oE 'block_id\\+": *\\+"[^"\\]*' "$f" | tail -n 1 | sed 's/.*"//')
  [ -n "$blk" ] || blk=-
  why=""
  # C1
  if [ ! -f "$meta" ]; then why="C1: 記録の meta が無い（${meta##*/}）"
  elif ! grep -qE '"agentType":"spec-verifier"' "$meta"; then
    why="C1: spec-verifier でない（$(grep -oE '"agentType":"[^"]*"' "$meta" | sed 's/.*:"//; s/"$//')）。汎用のサブエージェントでの代用は隔離にならない"
  fi
  # 拒否された呼び出しの ID: hook の拒否として記録された結果（`"content":"PreToolUse:` で始まり `"is_error":true`、
  # 本文に verifier-guard の文言）で、ID が 1 つだけの行。2 つ以上なら決めずに拒否扱いしない。
  # 【文言だけで判定しない】仕様リポジトリには verifier-guard の文言を含むファイル（定義・hook・このスクリプト）があり、
  # それを**読めた**結果の行も文言を含む。hook が動いていないのに「拒否された」と数える fail-open になる（独立レビュー）
  denied=$(grep -F '"content":"PreToolUse:' "$f" | grep -F '"is_error":true' | grep -F 'verifier-guard:' | awk '{ n=gsub(/"tool_use_id":"/,"&"); if (n==1 && match($0,/"tool_use_id":"[^"]*"/)) print substr($0,RSTART+15,RLENGTH-16) }')
  # C2: verifier-guard が 1 回以上拒否している＝ hook が動いていた（定義は最初に AGENTS.md を読ませ、それが拒否される）
  if [ -z "$why" ] && [ -z "$denied" ]; then
    why="C2: verifier-guard が拒否した記録が無い（hook が動いていない。信頼ダイアログの承認を確かめる）"
  fi
  # C3: ツール呼び出しを 1 件ずつ取り出す（ID・ツール名・パス）。同じ行に並列の呼び出しがあっても分ける
  if [ -z "$why" ]; then
    uses=$(awk -v Q='"' '{ n=split($0, a, "{" Q "type" Q ":" Q "tool_use" Q "," Q "id" Q ":" Q)
      for (i=2; i<=n; i++) { c=a[i]; id=substr(c,1,index(c,Q)-1); nm=""; pth=""
        if (match(c,/"name":"[^"]*"/)) nm=substr(c,RSTART+8,RLENGTH-9)
        if (match(c,/"(file_path|path)":"[^"]*"/)) { pth=substr(c,RSTART,RLENGTH); sub(/^"[a-z_]*":"/,"",pth); sub(/"$/,"",pth) }
        print id "\t" nm "\t" pth } }' "$f")
    [ -n "$uses" ] || why="C3: ツール呼び出しの記録が想定した形で見つからない"
    while IFS=$'\t' read -r uid name p; do
      [ -n "$uid" ] && [ -z "$why" ] || continue
      case "$name" in
        Read|Grep|Glob)
          if [ -n "$p" ] && under_src "$p"; then :
          elif printf '%s\n' "$denied" | grep -qxF "$uid"; then :   # hook が拒否した（読めていない）
          else why="C3: 解析対象ソースの外を読めている（または拒否が確かめられない）: ${name} ${p:-（パス省略）}"; fi ;;
        SubagentHandback|StructuredOutput) ;;
        *) why="C3: 検証官に許していないツールを使った: ${name:-（名前なし）}" ;;
      esac
    done <<USES
$uses
USES
  fi
  if [ -z "$why" ]; then printf '%s\tPASS\tblock_id=%s\t-\n' "$id" "$blk"; n_pass=$((n_pass+1))
  else printf '%s\tFAIL\tblock_id=%s\t%s\n' "$id" "$blk" "$why"; n_fail=$((n_fail+1)); fi
done < "$tmp_list"

printf 'SUMMARY\tPASS=%s\tFAIL=%s\tsince=%s\texpect=%s\n' "$n_pass" "$n_fail" "${since:--}" "${expect:--}"
[ "$n_fail" -eq 0 ] || exit 3
if [ -n "$expect" ] && [ "$n_pass" -lt "$expect" ]; then
  echo "claude-verify-check: PASS が ${n_pass} 体で、起動した ${expect} 体に満たない（記録に現れない検証官がいる＝指示文を変えて汎用で起動した等。その巡の結果は採用しない）" >&2
  exit 3
fi
exit 0
