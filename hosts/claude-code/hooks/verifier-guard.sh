#!/bin/bash
# =============================================================================
# verifier-guard.sh — 検証官サブエージェント（.claude/agents/spec-verifier.md）の読み取りを
# 解析対象ソースの配下だけに制限する PreToolUse hook（GP-16 ルール2 のコンテキスト隔離を機械で強制する）
# =============================================================================
#
# 【何を守るか】検証官に渡してよいのは「生成ブロック本文」と「原典パス」だけである
# （skills/density-verify §2）。指示文で渡さなくても、検証官は Read / Grep / Glob で
# 仕様リポジトリの分析物（02-analysis/）や仕様本文を**自分で読みに行ける**。
# この hook はその経路を塞ぐ。
#
# 【許可リスト方式】`spec-extraction/00-ingestion/gate-config.env` の `SOURCE_PATH` の配下だけを通す。
# 仕様リポジトリを列挙して拒否する方式にしないのは、写し（~/tmp 等）や親ディレクトリからの
# 再帰検索で回り道できるため（実測: path 省略の Grep・親を path にした Grep が分析物に届いた）。
#
# 【fail-closed】Claude Code は exit 2 だけを「拒否」と扱い、それ以外の非 0 は**通してしまう**。
# 判定できない入力（設定が無い・JSON を解釈できない・パスを解決できない）はすべて exit 2 に倒す。
# 依存は bash と coreutils だけ（フレームワークは bash + Markdown のみで動く）。
#
# 【対になる定義: .claude/agents/spec-verifier.md】隔離を機械で強制するのは次の 3 点の組である。
# 定義の本文はそのまま検証官の system prompt になるので、保守者向けの説明はこちらに置く。
#   - tools: Read / Grep / Glob だけ。Bash を足すとこの hook のパス判定を `cat` で回り道できる（下の【限界】）
#   - omitClaudeMd: CLAUDE.md と、そこから @ で取り込まれる AGENTS.md（規範）を注入させない
#   - hooks: この hook で読み取りを解析対象ソースの配下だけに制限する
#   - model: inherit は意図の明示（検証の質がモデルで変わるため、呼び出し側と同じモデルで動かす）
# 検証の姿勢・検査項目・出力形式は定義に書かず、skill の指示テンプレートを正本にする（Kiro の
# kiro-verify.sh も同じテンプレートを使うので、ホスト間で食い違わせない）。
# 【fail-open に注意】プロジェクトの定義に書いた hooks は、ワークスペースの信頼ダイアログを承認するまで
# 動かない（`claude -p` も承認扱いにならない）。tools と omitClaudeMd は効くので表面上は動いて見える。
# 検証官の自己申告（isolation_check）は補助で、呼び出し側は下のカナリアの記録で確かめる。
#
# 【カナリアの記録】仕様リポジトリの AGENTS.md（ルート・spec-extraction/・specs/）への読み取りを拒否したときは
# `spec-extraction/03-audit/verify-log/guard-canary.tsv` に 1 行追記する。検証官の「拒否された」という
# 自己申告ではなく、**hook が実際に動いて拒否したこと**を呼び出し側（skill）が確かめるための記録である。
#
# 【限界】
# - Bash ツールのコマンド文字列は判定しない（`cat` や `find /` で回り道できる）。
#   このため検証官の tools に Bash を入れてはいけない（spec-verifier.md の tools と対で守る）。
# - Grep / Glob は**起点の path だけ**を判定する。解析対象ソースの中に外を指すシンボリックリンクの
#   ディレクトリがあると、再帰検索がリンク先へ入りうる（ホストの走査がリンクを辿るかは未実測）。
# =============================================================================
set -u
# 想定外の終了（unbound 変数・コマンド失敗など）を「通す」側に落とさない: 0 以外はすべて exit 2 にする
trap '_rc=$?; [ "$_rc" -eq 0 ] || exit 2' EXIT

deny() { echo "verifier-guard: $1" >&2; exit 2; }

# ---- 解析対象ソースのパス（hook 自身の位置から仕様リポジトリを辿る。cwd に依存しない） ----
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || deny "hook の位置を解決できない"
spec_root=$(cd "$here/../.." 2>/dev/null && pwd -P) || deny "仕様リポジトリを解決できない"
conf="${spec_root}/spec-extraction/00-ingestion/gate-config.env"
[ -f "${conf}" ] || deny "設定が無い: ${conf}"
# source しない（設定ファイルを実行しない）。SOURCE_PATH= の 1 行だけを読む。
# gates.sh は source で読むので引用の形を問わない。ここも同じ寛容さで読む（単引用符・二重引用符・引用なし・export 付き・CR）。
# 初版は SOURCE_PATH='...' だけを受けており、旧リポジトリ（gates.sh の案内は引用なしの形）に後付けすると
# 「SOURCE_PATH が無い」と誤報して全拒否になっていた（fail-closed だが利用者が直せない文言だった）。
# source と同じく**最後の代入が勝つ**（旧リポジトリでは空の行の後に正しい行が追記されている形がある）
src_line=$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+)?SOURCE_PATH=" "${conf}" | tail -n 1)
[ -n "${src_line}" ] || deny "SOURCE_PATH の行が ${conf} に無い"
src=${src_line#*SOURCE_PATH=}; src=${src%$'\r'}
case "${src}" in
  \'*) src=${src#\'}; src=${src%%\'*} ;;
  \"*) src=${src#\"}; src=${src%%\"*} ;;
  *)   src=${src%%[[:space:]]#*}; src=${src%"${src##*[![:space:]]}"} ;;
esac
case "${src}" in *'$'*) deny "SOURCE_PATH に変数展開は使えない（実パスを書く）: ${src}";; esac
[ -n "${src}" ] && [ -d "${src}" ] || deny "SOURCE_PATH が存在しない: ${src}"
src=$(cd -P "${src}" && pwd -P) || deny "SOURCE_PATH を解決できない"
[ "${src}" != "/" ] || deny "SOURCE_PATH が / である（許可リストがファイルシステム全体になる）"
case "${spec_root}/" in "${src}"/*) deny "仕様リポジトリが解析対象ソースの中にある（隔離できない配置）";; esac
# 【逆向きも拒む（2026-11-11。脅威モデル T6）】SOURCE_PATH が仕様リポジトリの中（例: spec-extraction/02-analysis）を
# 指すと、許可リストが分析物そのものになる。kiro-verify.sh と同じく両方の向きを検査する
case "${src}/" in "${spec_root}"/*) deny "解析対象ソースが仕様リポジトリの中にある（隔離できない配置）";; esac

# ---- 入力 JSON から値を取り出す（jq に依存しない） ----
input=$(cat) || deny "入力を読めない"
# json_str <key>: "key": "value" の value を標準出力に返す。
#   rc=0 取れた / rc=1 キーが無い / rc=2 解釈できない（\\ と \/ 以外のエスケープ（\" \u 等）を含む）
# 「無い」と「解釈できない」を分けるのは、後者を「無い」に落とすと任意項目の検査が素通りするため。
json_str() {
  local raw n
  raw=$(printf '%s' "$input" | LC_ALL=C grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"")
  [ -n "$raw" ] || return 1
  # 同じキーが 2 回以上現れたら、構造を解釈しない限りどれを判定すべきか決められないので拒否する
  n=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
  [ "$n" -eq 1 ] || return 2
  raw=${raw#*:}; raw=${raw#"${raw%%[![:space:]]*}"}; raw=${raw#\"}; raw=${raw%\"}
  local probe=${raw//\\\\/}; probe=${probe//\\\//}
  case "$probe" in *\\*) return 2;; esac
  raw=${raw//\\\//\/}; raw=${raw//\\\\/\\}
  printf '%s' "$raw"
}
# get <var> <key> <必須なら1>: 解釈できない値は常に拒否、無い値は必須のときだけ拒否する
get() {
  local v rc
  v=$(json_str "$2"); rc=$?
  [ "$rc" -eq 2 ] && deny "解釈できない値（エスケープ・キーの重複）: ${2}"
  [ "$rc" -eq 1 ] && [ "$3" = 1 ] && return 1
  printf -v "$1" '%s' "$v"
}

get tool tool_name 1 || deny "tool_name が無い"
get cwd cwd 0; [ -n "${cwd}" ] || cwd=$(pwd -P)
case "${tool}" in
  Read)      get p file_path 1 || deny "Read の file_path が無い" ;;
  Grep|Glob) get p path 1 || deny "${tool} には解析対象ソース配下の path を明示すること（省略すると作業ディレクトリから再帰検索になる）" ;;
  *)         deny "想定外のツール: ${tool}（検証官に許すのは Read / Grep / Glob だけ）" ;;
esac
[ -n "${p}" ] || deny "${tool} のパスが空"

# Glob の pattern / Grep の glob が絶対パスや .. を含むと path の外へ出られるので拒否する
pat=""
if [ "${tool}" = Glob ]; then get pat pattern 0; elif [ "${tool}" = Grep ]; then get pat glob 0; fi
case "${pat}" in /*|"~"*|*..*|[A-Za-z]:*|*"{/"*|*",/"*|*"{~"*|*",~"*|*", /"*|*", ~"*|*"{ /"*|*"{ ~"*) deny "${tool} のパターンに絶対パス・~・.. は使えない: ${pat}";; esac

# ---- パスを実体へ解決する（シンボリックリンク・.. を辿った先で判定する） ----
# Windows（Git Bash）の C:\... は cygpath で POSIX 形式にする。無ければ拒否する。
case "${p}" in [A-Za-z]:\\*|[A-Za-z]:/*)
  command -v cygpath >/dev/null 2>&1 || deny "Windows 形式のパスを解決できない: ${p}"
  p=$(cygpath -u "${p}") ;;
esac
case "${cwd}" in [A-Za-z]:\\*|[A-Za-z]:/*)
  command -v cygpath >/dev/null 2>&1 && cwd=$(cygpath -u "${cwd}") ;;
esac
case "${p}" in "~"|"~/"*) p="$HOME${p#\~}";; esac
case "${p}" in /*) ;; *) p="${cwd}/${p}";; esac

resolve() { # 実在する最も深い祖先まで pwd -P で解決し、残りを付け足す（残りに .. があれば拒否）
  local path=$1 rest="" base
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    base=${path##*/}; [ -n "$base" ] || deny "パスを解決できない: $1"
    case "$base" in ..) deny "実在しない場所を経由する .. は解決できない: $1";; esac
    rest="/$base$rest"; path=${path%/*}; [ -n "$path" ] || path=/
  done
  if [ -d "$path" ]; then
    path=$(cd -P "$path" && pwd -P) || deny "パスを解決できない: $1"
  else
    local dir=${path%/*} name=${path##*/}
    [ -n "$dir" ] || dir=/
    dir=$(cd -P "$dir" && pwd -P) || deny "パスを解決できない: $1"
    path="$dir/$name"
    if [ -L "$path" ]; then # リンク先で判定する（realpath が無い環境ではリンクを拒否する）
      command -v realpath >/dev/null 2>&1 || deny "シンボリックリンクを解決できない: $1"
      path=$(realpath "$path" 2>/dev/null) || deny "シンボリックリンクを解決できない: $1"
    fi
  fi
  printf '%s%s' "${path%/}" "$rest"
}
target=$(resolve "${p}") || exit 2
[ -n "${target}" ] || target=/

case "${target}/" in
  "${src}"/*) exit 0 ;;
  "${spec_root}/AGENTS.md/"|"${spec_root}/spec-extraction/AGENTS.md/"|"${spec_root}/specs/AGENTS.md/")
    get agent agent_id 0
    _log="${spec_root}/spec-extraction/03-audit/verify-log"
    mkdir -p "$_log" 2>/dev/null && printf '%s\t%s\t%s\n' "$(date +%s)" "${agent:-unknown}" "${target}" >> "$_log/guard-canary.tsv" 2>/dev/null
    deny "解析対象ソースの外は読めない: ${target}（カナリア。拒否を記録した）" ;;
  *) deny "解析対象ソースの外は読めない: ${target}（許可: ${src}）" ;;
esac
