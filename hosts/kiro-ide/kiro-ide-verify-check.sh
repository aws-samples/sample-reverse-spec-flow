#!/bin/bash
# =============================================================================
# kiro-ide-verify-check.sh — Kiro IDE の検証官が隔離されていたかを、セッション記録で確かめる（GP-16 ルール2 / SB-12）
# =============================================================================
#
# 使い方:  bash spec-extraction/03-audit/kiro-ide-verify-check.sh [--since <UTC 時刻>] [--session <ID か記録のディレクトリ>]
#   既定では環境変数 KIRO_SESSION_ID（IDE のシェルに出ている）のセッション記録
#   ~/.kiro/sessions/<ハッシュ>/<セッション ID>/ を読み、--since 以降に起動した spec-verifier のすべてを確かめる。
#   --since は sub_agent_start の timestamp（例 2026-10-22T07:39:50.192Z）と文字列で比べる（前方一致の短い形も使える）。
#   Windows: init.sh を走らせたのと同じ bash（ふつうは WSL）で走らせる（gate-config.env の SOURCE_PATH がその bash の形のため）。
#   WSL には Windows のホームも KIRO_SESSION_ID も届かないので、記録の場所とセッション ID を渡す:
#     KIRO_SESSIONS_ROOT=/mnt/<ドライブ>/Users/<ユーザー>/.kiro/sessions bash … --session <セッション ID>
#   （セッション ID は PowerShell の $env:KIRO_SESSION_ID）。
#
# 出力（標準出力・タブ区切り・検証官ごとに 1 行）:
#   <subSessionId>  PASS  block_id=<ID|->  -
#   <subSessionId>  FAIL  block_id=<ID|->  <C1〜C5>: <理由>
#   <subSessionId>  SKIP  name=<名前>      spec-verifier でない（この確かめの対象外。機械の隔離は無い）
#   **採用してよいのは PASS の行の検証官の結果だけ**（台帳の verifier = subagent-isolated）。
#
# 終了コード: 0 = 対象の検証官がすべて PASS
#            3 = 1 体でも FAIL（その結果は集計にも台帳にも入れない）
#            2 = 前提を満たさない（記録・設定・定義が見つからない）。何も確かめていない
#
# 【確かめること】設計は reverse-spec-flow/dev/kiro-ide-verifier-isolation.md §2。
#   C1 検証官のテンプレートで起動したサブエージェントが spec-verifier である
#   C2 検証官に、ルートの AGENTS.md 以外の仕様リポジトリの文書が注入されていない（steering_inclusion）
#   C3 検証官が実際に読んだのは解析対象ソースの配下だけ（承認されたツール呼び出しのパス）
#   C4 最初のファイル操作が、ルートの AGENTS.md への読み取りで、エージェント定義の deny で拒否された（カナリア）
#   C5 記録が想定した形をしている（起動時の注入にルートの AGENTS.md がある・完了の記録がある）
#
# 【JSON を完全には解釈しない】依存を増やさない（bash と coreutils だけ）。記録は 1 行 1 イベントの
# 詰めた JSON で、構造上のキー（"key":"）は文字列の中では必ずエスケープされる（\"key\":\"）ので、
# 決まったキーの値だけを取り出せる。**想定した形が見つからなければ FAIL / rc=2 に倒す**（形式が変わったのに
# 黙って合格にしない）。記録はリポジトリの外にあるので gates.sh は読まない（GP-107 ルール4）。
# =============================================================================
set -u
export LC_ALL=C

# 検証官の指示テンプレートの 1 行目（skills/density-verify §2）。これで起動したのに spec-verifier でなければ C1 で落とす
MARKER='あなたは仕様記述の敵対的検証官である'

die2() { echo "kiro-ide-verify-check: $*" >&2; exit 2; }

# 【Windows の形のパスを、このシェルのパスに直す】Windows 版の Kiro IDE は記録にパスを Windows の形で書く
# （1.4.86 の実測: workspacePaths は `d:\\Users\\…`、ツール呼び出しは `D:\\Users\\…`、注入は `file:///d%3A/Users/…`）。
# 直さないと、ワークスペースが読めず rc=2 で止まり、原典の読み取りもすべて解決できなかった。
# WSL なら /mnt/<ドライブ>/…、Git Bash なら /<ドライブ>/… にする。Windows の形でないパス・ドライブが見当たらないパスはそのまま返す
# （macOS / Linux の挙動を変えない）。
# 【`\\` 以外のエスケープが残る値は直さない】`\u005c` などを `/` に化けさせると、隠れた `..` が消えて原典の外の読み取りが
# 原典の中に見える（独立レビューで再現）。そのまま返し、resolve が `\` を見て不合格にする。
# 【置換は sed / tr で行う】`${p//…}` の `\` の扱いは bash の版で違う（macOS の bash 3.2）。
topath() {
  local p=$1 dl pre
  case "$p" in *\\*)
    case "$(printf '%s' "$p" | sed 's/\\\\//g')" in *\\*) printf '%s' "$1"; return ;; esac
    p=$(printf '%s' "$p" | sed 's/\\\\/\\/g') ;;                 # JSON の `\\` を `\` に戻す
  esac
  case "$p" in /[A-Za-z]:[/\\]*) p=${p#/} ;; esac                # URI をほどいた `/d:/…` の先頭の / を外す
  case "$p" in
    [A-Za-z]:[/\\]*)
      dl=$(printf '%s' "${p%%:*}" | tr 'A-Z' 'a-z')
      if [ -d "/mnt/$dl" ]; then pre="/mnt/$dl"; elif [ -d "/$dl" ]; then pre="/$dl"; else printf '%s' "$1"; return; fi
      p="$pre$(printf '%s' "${p:2}" | tr '\\' '/')" ;;
  esac
  printf '%s' "$p"
}

since=""; sess_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since)     [ $# -ge 2 ] || die2 "--since に値が無い"; since=$2; shift 2 ;;
    --since=*)   since=${1#--since=}; shift ;;
    --session)   [ $# -ge 2 ] || die2 "--session に値が無い"; sess_arg=$2; shift 2 ;;
    --session=*) sess_arg=${1#--session=}; shift ;;
    -h|--help)   sed -n '5,24p' "$0"; exit 0 ;;
    *)           die2 "不明な引数: $1" ;;
  esac
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
spec_root=$(cd "$here/../.." && pwd -P)
conf="$spec_root/spec-extraction/00-ingestion/gate-config.env"
[ -f "$conf" ] || die2 "設定が無い: ${conf}"
src_line=$(grep -m1 "^SOURCE_PATH='" "$conf") || die2 "SOURCE_PATH が ${conf} に無い"
src=${src_line#SOURCE_PATH=\'}; src=${src%\'*}
[ -d "$src" ] || die2 "SOURCE_PATH が存在しない: ${src}"
src=$(cd "$src" && pwd -P)
case "$spec_root/" in "$src"/*) die2 "仕様リポジトリが解析対象ソースの中にある（隔離を判定できない配置）";; esac
case "$src/" in "$spec_root"/*) die2 "解析対象ソースが仕様リポジトリの中にある（隔離を判定できない配置）";; esac

agent_def="$spec_root/.kiro/agents/spec-verifier.md"
[ -f "$agent_def" ] || die2 "検証官の定義が無い: ${agent_def}（apply-host.sh で kiro-ide を置き直す）"

# ---- セッション記録を探す ----
sroot="${KIRO_SESSIONS_ROOT:-$HOME/.kiro/sessions}"
if [ -n "$sess_arg" ] && [ -d "$sess_arg" ]; then
  sdir=$(cd "$sess_arg" && pwd -P)
else
  sid=${sess_arg:-${KIRO_SESSION_ID:-}}
  [ -n "$sid" ] || die2 "KIRO_SESSION_ID が無い（Kiro IDE のシェルで実行するか --session を付ける。WSL には届かないので --session で渡す）"
  case "$sid" in */*|*..*) die2 "セッション ID の形が不正: ${sid}";; esac
  sdir=""; n=0
  for d in "$sroot"/*/"$sid"; do [ -d "$d" ] && { sdir=$d; n=$((n+1)); }; done
  [ "$n" -eq 1 ] || die2 "セッション記録が ${n} 件見つかった（1 件のはず）: ${sroot}/*/${sid}"
fi
msgs="$sdir/messages.jsonl"; sj="$sdir/session.json"
[ -f "$msgs" ] && [ -f "$sj" ] || die2 "記録の形が想定と違う（messages.jsonl / session.json が無い）: ${sdir}"

# ワークスペース（相対パスの基点）。複数ルートは基点が決まらないので扱わない
wsarr=$(tr -d '\n' < "$sj" | grep -o '"workspacePaths": *\[[^]]*\]' | head -1)
[ -n "$wsarr" ] || die2 "session.json に workspacePaths が無い（記録の形が変わった疑い）"
nws=$(printf '%s' "$wsarr" | grep -o '"[^"]*"' | grep -vc '^"workspacePaths"$')
[ "$nws" -eq 1 ] || die2 "ワークスペースが ${nws} 個ある（1 個のときだけ判定できる）"
ws=$(printf '%s' "$wsarr" | grep -oE '"([^"\\]|\\.)*"' | sed -n '2p' | tr -d '"')
ws=$(topath "$ws")
[ -n "$ws" ] && [ -d "$ws" ] || die2 "ワークスペースのパスを読めない（値: ${ws}）"
[ "$(cd "$ws" && pwd -P)" = "$spec_root" ] \
  || die2 "このセッションのワークスペース（${ws}）がこの仕様リポジトリ（${spec_root}）でない"
# 定義の deny はワークスペース基点の相対パスで書く（マシンのパスを持たない＝コピーしても働く）。
# 効いていたかは C4（カナリアの拒否の記録）で確かめる。ここでは定義が壊れていないことだけを見る
grep -qF '"specs/**"' "$agent_def" && grep -qF '"spec-extraction/**"' "$agent_def" \
  || die2 "検証官の定義に specs/** と spec-extraction/** の deny が無い（apply-host.sh で kiro-ide を置き直す）"

# ---- 下請け ----
# 最初に現れる "key":"値"（値はエスケープを含んでよい。ほどかずに返す——パスは resolve が topath でほどく）
jfield() { printf '%s' "$2" | grep -oE "\"$1\":\"([^\"\\\\]|\\\\.)*\"" | head -1 | sed "s/^\"$1\":\"//; s/\"\$//"; }

# パスを実体に解決する（相対はワークスペース基点。リンクを辿る）。解決できなければ 1
resolve() {
  local p d rest="" t n=0
  p=$(topath "$1")
  # 【%xx は正しい 16 進の組だけをほどく・バックスラッシュを含むパスは解決しない】以前は `printf %b` に丸ごと渡しており、
  # `%zz` を誤ってほどき、パスの中の `\n` などまで解釈していた（独立レビュー）。解決できないものは 1（＝不合格）に倒す
  # （Windows の形の `\` は上の topath で `/` に直してある。残っている `\` は解釈できないエスケープである）
  case "$p" in *\\*) return 1 ;; esac
  # 左から 1 回だけほどく（`%2541` を `%41` → `A` と二重にほどかない）
  local out="" left=$p
  while [[ "$left" =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}$(printf "\\x${BASH_REMATCH[2]}")"; left=${BASH_REMATCH[3]}
  done
  p="$out$left"
  p=$(topath "$p")                       # `file:///d%3A/…` はほどいた後で Windows の形になる（その中の `%5C` は区切りとして `/` になる）
  case "$p" in *\\*) return 1 ;; esac    # Windows の形でないパスで `%5C` をほどいて生まれた `\` は解決しない
  case "$p" in /*) ;; "~/"*) p="$HOME/${p#\~/}" ;; *) p="$ws/$p" ;; esac
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t=$(readlink "$p") || return 1
    case "$t" in /*) p=$t ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n+1))
  done
  [ -L "$p" ] && return 1
  d=$p
  while [ ! -d "$d" ]; do rest="/$(basename "$d")$rest"; d=$(dirname "$d"); done
  case "$rest/" in */../*|*/./*) return 1 ;; esac
  d=$(cd -P "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "${d%/}" "$rest"
}
under() { case "$1/" in "$2"/*) return 0 ;; esac; return 1; }
rel() { case "$1" in "$spec_root"/*) printf '%s' "${1#"$spec_root"/}" ;; *) printf '%s' "$1" ;; esac; }

reason=""
check_sub() { # check_sub <subSessionId>（不合格なら reason を書いて 1）
  local id=$1 f line x p r tn st canary=0 inc_first
  f="$sdir/sub-executions/$id.jsonl"
  [ -f "$f" ] || { reason="C5: 検証官の記録が無い（sub-executions/${id}.jsonl）"; return 1; }
  grep '"type":"sub_agent_complete"' "$msgs" | grep -qF "\"subSessionId\":\"$id\"" \
    || { reason="C5: 検証官が完了した記録が無い（拒否・中断・記録の欠け）"; return 1; }
  inc_first=$(grep -m1 '"type":"steering_inclusion"' "$f")
  [ -n "$inc_first" ] || { reason="C5: 注入の記録（steering_inclusion）が無い（記録の形が変わった疑い）"; return 1; }
  # 【文字列ではなく解決したパスで比べる】Windows では注入が `file:///d%3A/…` の形で書かれ、文字列では一致しない
  local inc_root=0
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    p=${x#\"file://}; p=${p%\"}
    r=$(resolve "$p") || continue
    [ "$r" = "$spec_root/AGENTS.md" ] && { inc_root=1; break; }
  done < <(printf '%s' "$inc_first" | sed -E 's/"content":"([^"\\]|\\.)*"/"content":""/g' | grep -o '"file://[^"]*"')
  [ "$inc_root" -eq 1 ] \
    || { reason="C5: 起動時の注入にルートの AGENTS.md が無い（記録の形が変わった・別のワークスペースで起動した疑い）"; return 1; }

  # C2: 注入された文書。中身（"content":"…"）を先に消し、中身の中の file:// を拾わない
  while IFS= read -r line; do
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      p=${x#\"file://}; p=${p%\"}
      r=$(resolve "$p") || { reason="C2: 注入された文書のパスを解決できない（${p}）"; return 1; }
      if under "$r" "$spec_root" && [ "$r" != "$spec_root/AGENTS.md" ]; then
        reason="C2: 仕様リポジトリの文書が検証官に注入された（$(rel "$r")）"; return 1
      fi
    done < <(printf '%s' "$line" | sed -E 's/"content":"([^"\\]|\\.)*"/"content":""/g' | grep -o '"file://[^"]*"')
  done < <(grep '"type":"steering_inclusion"' "$f")

  # C3・C4: ツール呼び出しを順に見る
  while IFS= read -r line; do
    tn=$(jfield toolName "$line"); st=$(jfield status "$line")
    case "$tn" in subagent_response|report_progress) continue ;; esac
    if [ "$canary" -eq 0 ]; then
      p=$(jfield path "$line")
      r=""; [ -n "$p" ] && r=$(resolve "$p")
      if [ "$tn" != read_file ] || [ "$r" != "$spec_root/AGENTS.md" ]; then
        reason="C4: 最初のファイル操作がカナリア（ルートの AGENTS.md の読み取り）でない（${tn:-?} ${p:-}）"; return 1
      fi
      [ "$st" = denied ] || { reason="C4: カナリアが拒否されていない（status=${st:-?}。deny が効いていない）"; return 1; }
      printf '%s' "$line" | grep -qF '"source":"subagent-profile"' \
        || { reason="C4: カナリアの拒否がエージェント定義の deny によるものでない（policyDenial の source が subagent-profile でない）"; return 1; }
      canary=1; continue
    fi
    [ "$st" = denied ] && continue   # 読めていない（注入は C2 で見た）
    case "$tn" in
      read_file|read_code|list_directory)
        p=$(jfield path "$line")
        [ -n "$p" ] || { reason="C3: ${tn} のパスを記録から読めない"; return 1; }
        r=$(resolve "$p") || { reason="C3: ${tn} のパスを解決できない（${p}）"; return 1; }
        under "$r" "$src" || { reason="C3: 解析対象ソースの外を読んだ（${tn} $(rel "$r")）"; return 1; } ;;
      grep_search|file_search)
        reason="C3: ${tn} でワークスペース（仕様リポジトリ）を検索した"; return 1 ;;
      *)
        reason="C3: 想定外のツールを使った（${tn:-?}）"; return 1 ;;
    esac
  done < <(grep '"type":"tool_call"' "$f")
  [ "$canary" -eq 1 ] || { reason="C4: カナリア（ルートの AGENTS.md の読み取り）の記録が無い"; return 1; }
  return 0
}

block_of() { # 完了の記録の応答から block_id を拾う（無ければ -）
  local b
  b=$(grep '"type":"sub_agent_complete"' "$msgs" | grep -F "\"subSessionId\":\"$1\"" | head -1 \
      | grep -o '\\"block_id\\": *\\"[^\\"]*' | head -1 | sed 's/.*\\"//')
  printf '%s' "${b:--}"
}

# ---- 起動した検証官を順に確かめる ----
npass=0; nfail=0; nskip=0
while IFS= read -r line; do
  id=$(jfield subSessionId "$line"); name=$(jfield subAgentName "$line"); ts=$(jfield timestamp "$line")
  [ -n "$id" ] || die2 "sub_agent_start に subSessionId が無い（記録の形が変わった疑い）"
  # 【時刻が無い行を黙って除外しない】`[[ "" < since ]]` は真になるので、以前は対象外として消えていた（独立レビュー）
  if [ -n "$since" ] && [ -z "$ts" ]; then
    if [ "$name" = spec-verifier ] || printf '%s' "$line" | grep -qF "$MARKER"; then
      printf '%s\tFAIL\tblock_id=%s\tC5: sub_agent_start に timestamp が無く、--since で絞れない（記録の形が変わった疑い）\n' "$id" "$(block_of "$id")"
      nfail=$((nfail+1))
    else
      printf '%s\tSKIP\tname=%s\tspec-verifier でない（この確かめの対象外）\n' "$id" "${name:-?}"; nskip=$((nskip+1))
    fi
    continue
  fi
  [ -n "$since" ] && [[ "$ts" < "$since" ]] && continue
  if [ "$name" != spec-verifier ]; then
    if printf '%s' "$line" | grep -qF "$MARKER"; then
      printf '%s\tFAIL\tblock_id=%s\tC1: 検証官のテンプレートで起動したのに spec-verifier でない（%s）\n' "$id" "$(block_of "$id")" "${name:-?}"
      nfail=$((nfail+1))
    else
      printf '%s\tSKIP\tname=%s\tspec-verifier でない（この確かめの対象外）\n' "$id" "${name:-?}"
      nskip=$((nskip+1))
    fi
    continue
  fi
  if check_sub "$id"; then
    printf '%s\tPASS\tblock_id=%s\t-\n' "$id" "$(block_of "$id")"; npass=$((npass+1))
  else
    printf '%s\tFAIL\tblock_id=%s\t%s\n' "$id" "$(block_of "$id")" "$reason"; nfail=$((nfail+1))
  fi
done < <(grep '"type":"sub_agent_start"' "$msgs")

echo "# 合格 ${npass} / 不合格 ${nfail} / 対象外 ${nskip}（セッション: $(basename "$sdir")${since:+ / --since ${since}}）"
[ $((npass + nfail)) -gt 0 ] || die2 "確かめる検証官が見つからない（spec-verifier で起動したか、 --since の時刻を確かめる）"
[ "$nfail" -eq 0 ] || exit 3
exit 0
