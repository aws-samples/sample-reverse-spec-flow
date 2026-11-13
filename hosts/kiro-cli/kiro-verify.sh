#!/bin/bash
# =============================================================================
# kiro-verify.sh — Kiro CLI（V3）で検証官を隔離して起動する（GP-16 ルール2 / SB-12）
# =============================================================================
#
# 使い方:  bash spec-extraction/03-audit/kiro-verify.sh <指示文ファイル>
#   指示文ファイル = skills/density-verify §2 の指示テンプレートに「生成ブロック本文」と「原典パス」を
#   埋めたもの（それ以外を入れない）。検証官の出力（JSON）を標準出力に出す。
#
# 終了コード: 0 = 隔離を確認して検証結果を得た
#            2 = 前提を満たさない（設定・配置・kiro-cli・陽性対照に使える原典ファイルが無い）。検証していない
#            3 = 隔離を確認できない（探針で外の値が読めた・kiro-cli が拒否を報告しない・原典を読めない）。検証しない
#            4 = 解析対象ソースが変更された（SB-5 違反の疑い）。結果を使わない
#            5 = kiro-cli が異常終了した
#            6 = 検証本体で拒否された操作がある（検証官が read 以外を試みた）。結果を使わない
#            7 = 検証本体で原典を読んでいない（呼び出し 0 件、または渡したパス数より少ない＝全部は読んでいない）。結果を使わない
#
# 【隔離の仕組み（実測で決めた）】Kiro V3 は次の 3 経路で仕様リポジトリの内容を
# 検証官に入れうる: (1) ワークスペースの .kiro/steering、(2) アクセスしたディレクトリの入れ子 AGENTS.md
# （読み取りが deny で拒否されても注入される）、(3) 検証官が自分で読みに行くファイル。
# カスタムエージェントの permissions は**ワークスペースの中にしか効かない**（外への deny は無視された）。
# そこで**解析対象ソースをワークスペースにして起動し、仕様リポジトリをワークスペースの外に置く**:
#   - (1)(2) 仕様リポジトリの steering・AGENTS.md はワークスペースの外なので読み込まれない
#   - (3) ワークスペースの外へのアクセスは「確認待ち」になり、--no-interactive では拒否される
#        （--trust-all-tools と、read のツール ID を --trust-tools に書くことは、これを承認してしまうので**しない**）
# 解析対象ソース自身の AGENTS.md・steering は読み込まれる（解析対象の規範であって生成物ではない）。
#
# 【この検証官は read しかできない（2.33.0 / 2.34.0 の V3 で実測。MEASURED.md 追補 V3-1）】
# V3 エンジンに `grep` / `glob`（公式ドキュメントの ID では `grep_search` / `file_search`）というツールは**存在せず**、
# 検索の要求は**シェル**（`rg` / `**` 展開）に落ちる。シェルは既定で確認待ち＝非対話では拒否される。
# 読めるのは Kiro の既定の許可で通る**ワークスペースの中の read だけ**で、検証官は**指示文で渡されたパスの読み取りだけ**で判定する
# （検査項目 1〜5 は成立する。原典を横断して反例を探す検査はできない。entry.md §5）。
# 初版は `--trust-tools=read,grep,glob` と書いていたが、3 つとも存在しないツール ID で、何も信頼していなかった（結果として安全側だった）。
#
# 【fail-closed の 3 点】隔離は「外を読めない」だけでは確かめたことにならない。
#   (a) 探針で、外の値（カナリア）が読めないこと          → rc=3
#   (b) 同じ探針で、原典の既知ファイルの 1 行目が読めること → rc=3（read の信頼が効いていなければ検証官は何も読めず、
#       読まずに判定した結果が「隔離できた検証」に化ける。陽性対照）
#   (c) 検証本体で kiro-cli が拒否を報告していないこと    → rc=6（検証官が検索やシェルを試みた＝渡されたパスだけで
#       判定していない。初版はこの拒否行を出力から**除いて rc=0 で返していた**）
#   (d) 検証本体でツール呼び出し（read）が【原典パス】の件数以上あること → rc=7（(b) は「読める」ことしか確かめない。
#       実際に読んだか、渡した候補を**全部**読んだかはここで見る。全部読まなければ唯一型・全称型の判定は成立しない）
# =============================================================================
set -u

prompt_file="${1:-}"
[ -n "$prompt_file" ] && [ -f "$prompt_file" ] || { echo "使い方: $0 <指示文ファイル>" >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
spec_root=$(cd "$here/../.." && pwd -P)
conf="$spec_root/spec-extraction/00-ingestion/gate-config.env"
[ -f "$conf" ] || { echo "kiro-verify: 設定が無い: ${conf}" >&2; exit 2; }
# gates.sh は source で読むので引用の形を問わないが、ここは設定ファイルを実行しない（SOURCE_PATH='...' の 1 行だけを読む）。
# 単引用符以外の形（"..." / 引用なし / export 付き）も受け付け、CR は落とす。
# source と同じく**最後の代入が勝つ**（旧リポジトリでは空の行の後に正しい行が追記されている形がある）
src_line=$(LC_ALL=C grep -E "^[[:space:]]*(export[[:space:]]+)?SOURCE_PATH=" "$conf" | tail -n 1)
[ -n "$src_line" ] || { echo "kiro-verify: SOURCE_PATH の行が ${conf} に無い" >&2; exit 2; }
src=${src_line#*SOURCE_PATH=}; src=${src%$'\r'}
case "$src" in
  \'*) src=${src#\'}; src=${src%%\'*} ;;
  \"*) src=${src#\"}; src=${src%%\"*} ;;
  *)   src=${src%%[[:space:]]#*}; src=${src%"${src##*[![:space:]]}"} ;;
esac
case "$src" in *'$'*) echo "kiro-verify: SOURCE_PATH に変数展開は使えない（実パスを書く）: ${src}" >&2; exit 2;; esac
[ -n "$src" ] && [ -d "$src" ] || { echo "kiro-verify: SOURCE_PATH が存在しない: ${src}" >&2; exit 2; }
src=$(cd "$src" && pwd -P)
[ "$src" != "/" ] || { echo "kiro-verify: SOURCE_PATH が / である（ワークスペースの境界が無い）" >&2; exit 2; }

# 仕様リポジトリとソースが入れ子だと、ワークスペースの境界が隔離にならない
case "$spec_root/" in "$src"/*) echo "kiro-verify: 仕様リポジトリが解析対象ソースの中にある（隔離できない配置）" >&2; exit 2;; esac
case "$src/" in "$spec_root"/*) echo "kiro-verify: 解析対象ソースが仕様リポジトリの中にある（隔離できない配置）" >&2; exit 2;; esac

KIRO="${KIRO_CLI:-kiro-cli}"
command -v "$KIRO" >/dev/null 2>&1 || { echo "kiro-verify: ${KIRO} が見つからない" >&2; exit 2; }
"$KIRO" chat --help 2>/dev/null | LC_ALL=C grep -q -- '--v3' \
  || { echo "kiro-verify: ${KIRO} が V3 エンジン（--v3）に対応していない" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/kiro-verify.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
work=$(cd "$work" && pwd -P)
case "$work/" in "$src"/*|"$spec_root"/*) echo "kiro-verify: 一時ディレクトリ（${work}）がソースか仕様リポジトリの中にある（TMPDIR を変える）" >&2; exit 2;; esac

# 【何も信頼しない（`--trust-tools=`）】ワークスペースの中の読み取りは Kiro の**既定の許可**（`fs_read` は `./**` を自動許可。
# 公式ドキュメント permissions「Default behavior」）で通り、外への読み取りは「確認待ち」＝非対話では拒否される。
# **`--trust-tools=read_file` と書いてはいけない**: ツール ID を信頼すると境界を問わず承認され、ワークスペースの**外も読める**
# （2.34.0 で実測。カナリアが読めて rc=3 になる。追補 V3-1 #9）。初版の `read,grep,glob` は**どれも実在しないツール ID**で、
# 読めていたのは既定の許可のおかげだった（信頼していたからではない）。効いているかは探針の陽性対照（下の (b)）が確かめる。
KFLAGS=(chat --v3 --no-interactive --trust-tools=)
ESC=$(printf '\033')
denied_re="^[[:space:]]*(${ESC}\[[0-9;]*m)*\[denied\]"
count_denied() { LC_ALL=C grep -cE "$denied_re" "$@" 2>/dev/null | awk -F: '{n+=$NF} END{print n+0}'; }

# ---- 0. 陽性対照に使う原典ファイルを選ぶ（書き込まない。SB-5） ----
# 原典の先頭 200 件から、先頭 512 バイトが印字可能 ASCII だけのテキストで、1 行目の空白を除いた長さが 12〜200 文字の
# ファイルを探す。（多バイトや長い行は表示の揺れで誤判定になる。短い行は偶然一致する。**1 行目がそのファイルのパスや
# カナリアのパスに含まれる**（README の 1 行目がプロジェクト名、等）と、読めなくても一致するので除く。見つからなければ検証しない）
pos_file=""; pos_line=""; pos_key=""
while IFS= read -r _f; do
  LC_ALL=C head -c 512 "$_f" 2>/dev/null | LC_ALL=C grep -q '[^[:print:][:space:]]' && continue   # バイナリ・多バイト
  _l=$(LC_ALL=C head -n 1 "$_f" 2>/dev/null | tr -d '\r')
  _k=$(printf '%s' "$_l" | LC_ALL=C tr -d ' \t')
  printf '%s' "$_k" | LC_ALL=C grep -qE '^[[:print:]]{12,200}$' || continue
  case "$(printf '%s%s' "$_f" "$work" | LC_ALL=C tr -d ' \t')" in *"$_k"*) continue ;; esac
  pos_file="$_f"; pos_line="$_l"; pos_key="$_k"; break
done < <(find "$src" -path "$src/.git" -prune -o -type f -size +0 -print 2>/dev/null | LC_ALL=C sort | head -200)
[ -n "$pos_file" ] || { echo "kiro-verify: 陽性対照に使える原典ファイルが無い（1 行目が印字可能 ASCII 12 文字以上のテキストが先頭 200 件に無い）" >&2; exit 2; }

# ---- 1. 探針（検証の前に、同じ起動条件で境界と読み取りの両方が働くことを機械で確かめる） ----
# 推測できない値を**ソースの外の一時ディレクトリ**に置き、「読めたらそのまま表示せよ」と指示する。
# 同じセッションで原典の既知ファイルの 1 行目も表示させる（陽性対照）。合否は自己申告で決めない:
#   (a) カナリアの値が出力に現れない (b) kiro-cli が拒否を報告した（[denied] 行）(c) 原典の 1 行目が出力に現れる。
# 探針を検証本体と分けるのは、本体に [denied] が混ざると「外を読もうとした」のか「検索を試みた」のか
# 区別できないため（本体の [denied] は別に数えて rc=6 にする）。
# 仕様リポジトリの中を指さないのは、Kiro V3 がアクセスしたディレクトリの AGENTS.md を
# 拒否されても注入するため（カナリア自身が注入の入口になる）。
nonce=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -n "$nonce" ] || nonce="$(date +%s)$$${RANDOM}${RANDOM}"
nonce="KVCANARY-${nonce}"
canary="$work/canary.txt"
printf '%s\n' "$nonce" > "$canary"
probe="次の 2 つを順に行い、他のことはしない。
(1) ${canary} を Read し、読めた内容を一字一句そのまま表示せよ。読めなければ CANARY_DENIED とだけ表示せよ。
(2) ${pos_file} を Read し、その 1 行目を一字一句そのまま表示せよ。読めなければ INSIDE_DENIED とだけ表示せよ。
シェルや検索ツールは使わない。"

: > "$work/marker"
sleep 1   # 変更検出（find -newer）の秒精度に対して、起動前の書き込みと区別する

( cd "$src" && "$KIRO" "${KFLAGS[@]}" "$probe" ) > "$work/probe.out" 2> "$work/probe.err"
prc=$?
[ "$prc" -eq 0 ] || { echo "kiro-verify: 探針で ${KIRO} が rc=${prc} で終了した" >&2; tail -20 "$work/probe.err" >&2; exit 5; }
if LC_ALL=C tr -d ' \t\r\n' < "$work/probe.out" | LC_ALL=C grep -qF -- "$nonce" \
   || LC_ALL=C tr -d ' \t\r\n' < "$work/probe.err" | LC_ALL=C grep -qF -- "$nonce"; then
  echo "kiro-verify: カナリアを読めた（ワークスペースの外への読み取りが拒否されていない）。検証しない" >&2; exit 3
fi
if [ "$(count_denied "$work/probe.out" "$work/probe.err")" -lt 1 ]; then
  echo "kiro-verify: 探針で kiro-cli が拒否を報告していない（[denied] 行が無い）。検証しない" >&2; exit 3
fi
if ! LC_ALL=C tr -d ' \t\r\n' < "$work/probe.out" | LC_ALL=C grep -qF -- "$pos_key"; then   # -- : 1 行目が - で始まることがある
  echo "kiro-verify: 探針で原典の既知ファイルを読めなかった（read の信頼が効いていない。検証官は何も読めない）。検証しない" >&2
  echo "  対照: ${pos_file} の 1 行目" >&2; exit 3
fi

# ---- 2. 検証本体（探針と同じ起動条件） ----
# 指示文の前に、このホストでできることを 1 段だけ足す（harness が知ってよいホスト固有の制約。GP-107 ルール1）。
# 検索やシェルを試みると拒否され、その拒否は下で数えて rc=6 になる。
preamble="【このホストの制約】使えるツールは Read だけである。シェル・検索（grep / glob）・ディレクトリの列挙は使えない。
【原典パス】に挙げられた**ファイル**だけを Read して判定せよ（ディレクトリは列挙できない。挙げられていないファイルを探しに行かない）。
原典を横断して反例を探す検査は行わず、渡されたファイルの中で判定できないことは判定しない。"
( cd "$src" && "$KIRO" "${KFLAGS[@]}" "${preamble}

$(cat "$prompt_file")" ) > "$work/out" 2> "$work/err"
krc=$?

# 解析対象ソースの変更を検出する（.git の中は Kiro 以外も触るので除く）
changed=$(find "$src" -path "$src/.git" -prune -o -newer "$work/marker" -print 2>/dev/null | head -5)
if [ -n "$changed" ]; then
  echo "kiro-verify: 解析対象ソースが変更された（SB-5）:" >&2; echo "$changed" >&2; exit 4
fi
[ "$krc" -eq 0 ] || { echo "kiro-verify: ${KIRO} が rc=${krc} で終了した" >&2; tail -20 "$work/err" >&2; exit 5; }

# 検証本体の拒否は結果を無効にする（渡されたパスの read 以外を試みた）。何を試みたかは直前の [tool] 行に出る
nd=$(count_denied "$work/out" "$work/err")
if [ "$nd" -ge 1 ]; then
  echo "kiro-verify: 検証本体で ${nd} 件の操作が拒否された（検証官が read 以外を試みた）。結果を使わない" >&2
  LC_ALL=C grep -E -B1 "$denied_re" "$work/out" "$work/err" 2>/dev/null | LC_ALL=C grep -E '\[(tool|denied)\]' | head -10 >&2
  exit 6
fi
# 1 件も読んでいなければ結果を無効にする（探針は「読める」ことしか確かめていない。実際に読んだかはここで見る）。
# kiro-cli はツール呼び出しごとに「[tool] <題名>」を 1 行、進捗を「[tool] status: …」で出す（2.33.0 で実測）。題名の行だけを数える
ncall=$(LC_ALL=C grep -E "^[[:space:]]*(${ESC}\[[0-9;]*m)*\[tool\] " "$work/out" "$work/err" 2>/dev/null | LC_ALL=C grep -vE '\[tool\] status:' | wc -l | tr -d ' ')
if [ "${ncall:-0}" -lt 1 ]; then
  echo "kiro-verify: 検証本体でツール呼び出しが 0 件（原典を読まずに判定している）。結果を使わない" >&2; exit 7
fi
# 渡されたパスを全部読んだか（唯一型・全称型の検証は「候補を全部渡して全部読む」ことで成立する。entry.md §5）。
# 指示文の【原典パス】節（次の【…】見出しか末尾まで）の、`/` を含む行を 1 パスと数える。Read の呼び出し数がそれ未満なら、
# 読まなかった候補が反例を持ちうる＝唯一・全称の判定は成立しない。節が無い（テンプレートに従っていない）なら 0 件として扱い、この検査は効かない
npaths=$(awk '/^【原典パス】/{f=1;next} f&&/^【/{f=0} f&&/\//{n++} END{print n+0}' "$prompt_file")
if [ "${npaths:-0}" -gt 0 ] && [ "$ncall" -lt "$npaths" ]; then
  echo "kiro-verify: 原典パス ${npaths} 件のうち Read の呼び出しは ${ncall} 件（全部は読んでいない。唯一型・全称型の判定は成立しない）。結果を使わない" >&2; exit 7
fi

# 進捗・ログ行を除いた応答本文
LC_ALL=C grep -v -E "^[[:space:]]*(${ESC}\[[0-9;]*m)*\[(INFO|DEBUG|WARN|ERROR|tool)\]|ExperimentalWarning|trace-warnings" "$work/out" > "$work/answer"
cat "$work/answer"
