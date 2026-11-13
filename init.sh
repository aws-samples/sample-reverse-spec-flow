#!/bin/bash
# =============================================================================
# 仕様書生成 初期化スクリプト（軽量 init / reverse-spec-flow）
# =============================================================================
#
# 既存ソースコードを解析して仕様書を生成するための作業リポジトリを初期化する。
# 解析対象ソースは変更もコピーもしない（参照専用）。仕様書の出力先として、
# <source>-spec という独立した新規 git リポジトリを作り、作業アセットを配置する。
#
# 結果（解析対象はそのまま。新規に 1 フォルダを作る）:
#   <source>/                         解析対象ソース（参照専用。触らない）
#   <source>-spec/                    ★仕様書の出力先（独立 git リポジトリ, branch=spec/<spec-name>）
#     ├── specs/                      生成する仕様書（成果物）
#     └── spec-extraction/            作業アセット（生成パイプラインの各段: 取り込み・コードグラフ・分析・監査・worklog）
#
# 使い方:
#   ./init.sh <source-path> <spec-name> [purpose] [--playbook <name|path>] [--host <name|path>]
#     <source-path> : 解析対象ソースのパス
#     <spec-name>   : ブランチ名サフィックス / 出力の識別子
#                     例: order-system → ブランチ spec/order-system
#     [purpose]     : 仕様抽出の目的（GP-13 適用条件・目標密度 SB-18/GP-21 を決める）
#                     maintenance = 保守理解のみ（rebuild 層なし・密度は警告のみ）
#                     evaluation  = 再構築の評価/見積り（rebuild 骨子・密度 warn）
#                     rebuild     = 再構築の実装完走（rebuild フル・密度 on・**全数 Verify が必須**）
#                     ※ どの目的でも可読性の床（責務）は必須（G-READABLE）
#                     省略時は対話プロンプトで選択（デフォルト: rebuild）
#     --playbook    : ドメイン固有知識の Playbook（GP-105）。繰り返すと併用（先に書いた方が主）
#     --host        : ホストアダプタ（GP-107）。省略時は claude-code
#
# 例:
#   ./init.sh /Users/me/workspaces/legacy-order-system order-system rebuild
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYBOOKS_DIR="$SCRIPT_DIR/playbooks"
HOSTS_DIR="$SCRIPT_DIR/hosts"

# ---- 引数解析（位置引数 3 つ ＋ オプション --playbook / --host。--playbook は繰り返せる＝併用。GP-105 ルール11） ----
PLAYBOOK_ARGS=()
HOST_ARG=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --playbook)
      [ -n "${2:-}" ] || { echo "Error: --playbook に値がありません" >&2; exit 1; }
      PLAYBOOK_ARGS+=("$2"); shift 2 ;;
    --playbook=*)
      [ -n "${1#--playbook=}" ] || { echo "Error: --playbook に値がありません" >&2; exit 1; }
      PLAYBOOK_ARGS+=("${1#--playbook=}"); shift ;;
    --host)
      HOST_ARG="${2:-}"
      [ -n "$HOST_ARG" ] || { echo "Error: --host に値がありません" >&2; exit 1; }
      shift 2 ;;
    --host=*)
      HOST_ARG="${1#--host=}"; shift ;;
    --list-hosts)
      echo "利用可能なホスト（hosts/ 配下。GP-107）:"
      for d in "$HOSTS_DIR"/*/; do
        n="$(basename "$d")"
        [ "$n" = "_template" ] && continue
        # profile.env の SUPPORT_LEVEL を出す（未検証を隠して名乗らせない。SB-12 と同型）
        lvl="$(grep -E '^SUPPORT_LEVEL=' "$d/profile.env" 2>/dev/null | head -1 | cut -d= -f2 | awk '{print $1}' || true)"
        printf '  %-16s %s\n' "$n" "${lvl:-（profile.env なし）}"
      done
      echo ""
      echo "  対応レベルの意味と各ホストの実測は hosts/README.md を参照する。"
      exit 0 ;;
    --list-playbooks)
      echo "利用可能な Playbook（playbooks/ 配下）:"
      for d in "$PLAYBOOKS_DIR"/*/; do
        n="$(basename "$d")"
        [ "$n" = "_template" ] && continue
        # README の 1 行サマリ（H1 直下の説明文の 1 行目）を表示する
        printf '  %-24s %s\n' "$n" "$(awk '/^# Playbook:/{getline; getline; print; exit}' "$d/README.md" 2>/dev/null | cut -c1-72)"
      done
      exit 0 ;;
    -h|--help)
      echo "Usage: $0 <source-path> <spec-name> [purpose] [--playbook <name|path>] [--host <name|path>]"
      echo "  purpose （完了条件が変わる。省略時は対話選択・既定 rebuild）:"
      echo "    maintenance  保守理解のみ    / rebuild 層なし / 密度は警告のみ"
      echo "    evaluation   評価・見積り    / rebuild 骨子   / 密度は警告のみ"
      echo "    rebuild      実装完走        / rebuild フル   / 密度は未達で停止 / 全数 Verify が必須"
      echo "  ※ どの目的でも可読性の床（責務＝何のためにあるか / 業務動線 / 利用者）は必須"
      echo "  --playbook       ドメイン固有知識の Playbook（GP-105）。省略時は列挙手順を自分で埋める"
      echo "                   繰り返すと併用する（アプリ側 ＋ DB 側の PL/SQL 等）。先に書いた方が主になる"
      echo "  --list-playbooks 利用可能な Playbook を表示して終了"
      echo "  --host           ホストアダプタ（GP-107）。省略時は claude-code（既定＝従来の挙動）"
      echo "  --list-hosts     利用可能なホストと対応レベルを表示して終了"
      exit 0 ;;
    -*)
      echo "Error: 不明なオプション: $1" >&2; exit 1 ;;
    *)
      POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

SRC="${1:-}"
SPEC_NAME="${2:-}"
PURPOSE="${3:-}"

if [ -z "$SRC" ] || [ -z "$SPEC_NAME" ]; then
  echo "Usage: $0 <source-path> <spec-name> [purpose: maintenance|evaluation|rebuild] [--playbook <name|path>] [--host <name|path>]"
  echo "  例: $0 /path/to/legacy-order-system order-system rebuild --playbook java-jaxrs-jpa"
  echo "  --list-playbooks で利用可能な Playbook を、--list-hosts で利用可能なホストを確認できます"
  echo "  併用: --playbook <アプリ側> --playbook <DB 側>（例: --playbook csharp-winforms-adonet --playbook oracle-plsql）"
  exit 1
fi
# spec-name は 3 箇所で使われるため文字種を制限する:
#   (1) git ブランチ名 spec/<spec-name>  (2) sed の置換文（& や # で壊れる）
#   (3) 知見の採番名前空間 GP-<spec-name>-N（GP-9 の安定キー）
# 制限しないと & で置換が静かに壊れ（AGENTS.md と FRAMEWORK-VERSION が別の名前空間を指す）、
# # では sed がエラーになり git init 前に中断して壊れたディレクトリが残る。
case "$SPEC_NAME" in
  *[^A-Za-z0-9._-]*)
    echo "Error: spec-name には英数字と . _ - のみ使えます: $SPEC_NAME" >&2
    echo "  （git ブランチ名・sed の置換文・知見の採番 ID に使うため）" >&2
    exit 1 ;;
  -*|.*)
    echo "Error: spec-name は英数字で始めてください: $SPEC_NAME" >&2
    exit 1 ;;
esac
if [ ! -d "$SRC" ]; then
  echo "Error: source not found: $SRC"
  exit 1
fi

# 【CRLF が混ざった配布元では生成させない（2026-09-14）】実測: Windows で v1.22 より前に
# clone した本体を `git pull` で更新すると、**この更新で変更されなかったファイル**（`playbook.md` 等）
# は CRLF のまま残り、そのまま生成先へコピーされる。生成先に `.gitattributes` が入っていても
# **中身は直らない**ので、生成直後から `G-REPAIR` などが誤って FAIL になる（判定は厳しい側にしか
# 動かないが、出力が CR に言及しないので受け取った人は直せない）。**生成前に止める。**
# 【対話より前に呼ぶ】purpose を答えさせてから中断するのは無駄な往復。
# 【バイナリ除外の実体は `-I` ではない（2026-09-23）】BSD grep では `-U` が `-I` を無効化するので、
# **バイナリを落としているのは下の (2a) のバイト比較**である（`-I` は候補を減らす最適化に過ぎない）。
# なお**走査対象には既にバイナリが有る**——実測で `playbooks/.DS_Store` と `skills/.DS_Store` が
# NUL を含む（`.gitignore` 済みだが、このガードはファイルシステムを見る）。
# つまり (2a) は「将来増えたとき」ではなく**日常的に通る経路**である。
#
# 【grep に CR の判定を任せない（2026-09-23 是正）】実測（Windows / Git for Windows・
# GNU grep 3.0・gawk 5.4.0）: **grep と awk が CR を剥がすため、CR を含むファイルに対して
# `grep -q $CR` が一致しない**（`-F` / `-P` / `LC_ALL=C` / binary マウントでも同じ）。
# つまり**このガードは Windows で恒久的に無反応**だった——守るべき唯一のプラットフォームで死んでいた。
# `-U`（--binary）だけが Windows で機能するが、**BSD grep（macOS）では `-U` が `-I` の
# バイナリ除外を壊す**（NUL を含むファイルが CRLF として検出される。実測）。
# ⇒ **2 段構成にする**: (1) grep で候補を広く拾う（`-U` 有無の和集合。取りこぼさないことだけを担う）
#    (2) **バイト比較で確定する**（`tr` / `wc -c` は両環境で CR を保つ。実測済み）。
# 候補は通常 0 件なので、(2) のプロセス起動コストは実質かからない
# （Windows はプロセス起動が約 0.2 秒なので、全ファイルを回す形にはしない）。
crlf_guard() { # crlf_guard <対象パス...>
  local hits cand f
  # (1) 候補の収集: `-U` 有無の和集合。どちらかが効けば拾える
  cand=$( { LC_ALL=C grep -rlIU "$(printf '\r')" "$@" 2>/dev/null || true
            LC_ALL=C grep -rlI  "$(printf '\r')" "$@" 2>/dev/null || true; } | sort -u )
  hits=""; local n=0 unresolved=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # 【解決できない候補だけを数える】バイナリや CR 無しで落ちるのは**正当な除外**なので数えない
    # （当初 `[ -n "$f" ]` を通った全件を数えて fail-closed にしたところ、CR を含むバイナリが
    #  候補に上がるだけで誤って中断した。既存の探針がこれを捕まえた）。
    # ここに来るのは「grep が列挙したのにファイルとして開けない」= パスが 1 行に収まっていない印。
    [ -f "$f" ] || { unresolved=$((unresolved + 1)); continue; }
    # (2a) バイナリを除く: NUL を含むファイルは「テキストの CRLF」ではない
    #      （`-U` が `-I` を壊す BSD grep で出る誤検出をここで落とす）
    LC_ALL=C tr -d '\000' < "$f" 2>/dev/null | cmp -s - "$f" 2>/dev/null || continue
    # (2b) CR の有無はバイト数差で確定する（grep / awk の CR 剥がしに依存しない）
    [ "$(LC_ALL=C wc -c < "$f" | tr -d ' ')" = "$(LC_ALL=C tr -d '\r' < "$f" | LC_ALL=C wc -c | tr -d ' ')" ] && continue
    hits="${hits}${f}
"
    # 【3 件で打ち切る（2026-09-23）】出力は 3 件までなので、それ以上調べる必要がない。
    # 当初は全件調べてから `head -3` していたが、2 つの問題があった:
    #  (a) `set -euo pipefail` の下で `printf … | head -3` が **SIGPIPE で rc=141** になり、
    #      **ガードが喋るべき瞬間にスクリプトが無言死する**（実測: 入力 487KB で rc=141）。
    #      発火するのは「CRLF が大量に混ざっている」まさに守りたい状況である。
    #  (b) 候補が多いと 1 件あたり 5 プロセス起動する（実測: 候補 200 件で 8.4 秒）。
    #      発火するのは autocrlf で clone した Windows で、そこでは配布物が**全部**候補になる
    #      （プロセス起動 0.2 秒なら数十秒）。**「全ファイルを回さない」は発火時こそ守るべき。**
    n=$((n + 1))
    [ "$n" -ge 3 ] && break
  done <<EOF
$cand
EOF
  if [ -z "$hits" ]; then
    # 【候補はあったのに確定 0 件＝判定不能（fail-closed）】ファイル名に改行が含まれると
    # 1 行 1 パスの前提が崩れて取りこぼす（実測: `new<LF>line.md` で旧実装は発火・新実装は無反応）。
    # **黙って通さず「判定できなかった」と言う**（CR の混入を見逃す方が高くつく）。
    if [ "$unresolved" -gt 0 ]; then
      echo "Error: CRLF の判定ができませんでした（候補 ${unresolved} 件のパスを解決できない。ファイル名に改行が含まれる可能性）" >&2
      echo "  対処: 対象ディレクトリのファイル名を確認してください（改行を含む名前は扱えません）。" >&2
      exit 1
    fi
    return 0
  fi
  echo "Error: 配布元のファイルに CRLF が混ざっています（このまま生成すると生成先の点検が誤って未達を出します）" >&2
  printf '%s\n' "$hits" | sed "s|^$SCRIPT_DIR/|  |" >&2
  echo "  対処: 本体を取得し直してください（.gitattributes が入っているので LF になります）。" >&2
  echo "  取得し直せない場合の手順は docs/release-notes.md（未コミットの変更を失う操作を含むため、手順を読んでから実行してください）" >&2
  exit 1
}
crlf_guard "$SCRIPT_DIR/templates" "$SCRIPT_DIR/playbooks" "$SCRIPT_DIR/skills" \
           "$SCRIPT_DIR/pipeline.md" "$SCRIPT_DIR/playbook.md" "$SCRIPT_DIR/AGENTS.md.template"

# 【Playbook の解決は対話より前に置く】`--playbook <外部パス>` の CRLF 検査が purpose の対話の
# **後**にあったため、CRLF の外部 Playbook を渡すと purpose を答えさせてから止まっていた（実測）。
# 「検査は対話より前」という本体の原則を、外部入力にも同じく適用する。
# ---- Playbook の解決（GP-105。名前 / 任意パス / 省略） ----
# 「分母の数え方」はスタック依存であり、汎用手順書に書くと別スタックで計算不能になる
# （実測: roller は @Path も @Table も 0 件で、分母突合の等式が成立しなかった）。
# 【併用（GP-105 ルール11）】`--playbook` を繰り返すと、1 つ目が主（従来と同じ配置先）、2 つ目以降が従になる。
#   従の Playbook は名前つきのファイル（enumeration-<名前>.md / gate-snippets-<名前>.sh / practices-<名前>.md）に置き、
#   G-ENUM-SOURCE が enumeration*.md をすべて検査する。ノード種別は増やさず、種別ごとの 2 経路突合を Playbook ごとに持つ。
PLAYBOOK_DIRS=()
PLAYBOOK_NAMES=()
for _pa in "${PLAYBOOK_ARGS[@]+"${PLAYBOOK_ARGS[@]}"}"; do
  if [ -d "$PLAYBOOKS_DIR/$_pa" ]; then
    _pd="$PLAYBOOKS_DIR/$_pa"
  elif [ -d "$_pa" ]; then
    _pd="$(cd "$_pa" && pwd)"   # リポジトリ外のプライベート Playbook も許可
  else
    echo "Error: Playbook が見つかりません: $_pa" >&2
    echo "  利用可能: $(ls "$PLAYBOOKS_DIR" 2>/dev/null | grep -v '^_template$' | tr '\n' ' ')" >&2
    exit 1
  fi
  _pn="$(basename "$_pd")"
  [ "$_pn" != "_template" ] || { echo "Error: _template は Playbook として指定できません（雛形は --playbook の省略時に配置される）" >&2; exit 1; }
  # 【名前の重複を拒む】同じ名前を 2 度渡すと、従のファイル名が主と区別できず分母が二重になる
  # （別のパスでも basename が同じなら同じ置き場になるので拒む）
  for _x in "${PLAYBOOK_NAMES[@]+"${PLAYBOOK_NAMES[@]}"}"; do
    [ "$_x" != "$_pn" ] || { echo "Error: Playbook の名前（ディレクトリ名）が重複している: ${_pn}（同じ置き場になるため併用できない）" >&2; exit 1; }
  done
  # 【従の名前だけ文字種を制限する】従の名前はファイル名・sed の置換・gate-config.env の
  # 空白区切りの値に入る。主は従来どおり（空白を含む外部パスも受ける。下の PLAYBOOK= の引用を参照）
  if [ "${#PLAYBOOK_NAMES[@]}" -ge 1 ]; then
    case "$_pn" in *[!A-Za-z0-9._-]*) echo "Error: 併用する Playbook の名前に使えない文字がある（英数字と . _ - のみ）: $_pn" >&2; exit 1 ;; esac
  fi
  # 【外部 Playbook も CRLF を見る】`--playbook <外部パス>` は本体の走査対象外なので、
  # ここで同じ検査にかける（実測: CRLF の enumeration.md がそのまま生成先へ入っていた）。
  crlf_guard "$_pd"
  # 必須ファイルの検査（欠けたまま進むと列挙の分母が定義されない）
  [ -f "$_pd/enumeration.md" ] || {
    echo "Error: Playbook に enumeration.md がありません: $_pd" >&2
    echo "  enumeration.md は分母の定義（GP-105 の中核）で省略できません" >&2
    exit 1; }
  PLAYBOOK_DIRS+=("$_pd"); PLAYBOOK_NAMES+=("$_pn")
done
PLAYBOOK_DIR="${PLAYBOOK_DIRS[0]:-}"
PLAYBOOK_NAME="${PLAYBOOK_NAMES[0]:-}"
PLAYBOOKS_ALL="${PLAYBOOK_NAMES[*]+"${PLAYBOOK_NAMES[*]}"}"
# ---- ホストアダプタの解決（GP-107。名前 / 任意パス / 省略） ----
# ホスト固有の配置・語彙は `hosts/<surface>/` に閉じる。本スクリプトはホスト名を知らず、
# **配置は `placement.sh` に委譲する**（ホストを知ってよい唯一のコード。GP-107 ルール1）。
# 解決そのものは `hosts/_resolve.sh` が正本（`apply-host.sh` と共有する。2 箇所に書くとずれる）。
# shellcheck source=hosts/_resolve.sh
. "$HOSTS_DIR/_resolve.sh"

# ---- gate-config.env に単引用符で埋め込む値の検査（2026-11-11。脅威モデル T8） ----
# SOURCE_PATH='…'・PLAYBOOK='…'・PLAYBOOKS='…' は gates.sh が source で読む。値に ' が入ると引用が閉じ、
# 残りがコマンドとして実行される（他者から受け取ったアーカイブのディレクトリ名でも起こりうる）。
# 検査は対話より前に置く（purpose を答えさせてから止めない）。
_q_src_l="$(cd "$SRC" && pwd)"; _q_src_p="$(cd "$SRC" && pwd -P)"
case "${_q_src_l}${_q_src_p}${PLAYBOOKS_ALL}" in
  *\'*)
    echo "Error: 解析対象のパスと Playbook の名前に ' （単引用符）は使えません" >&2
    echo "  解析対象: ${_q_src_p}" >&2
    echo "  Playbook: ${PLAYBOOKS_ALL}" >&2
    echo "  （gate-config.env に引用して書き込み、gates.sh が source で読むため。ディレクトリ名を変えてください）" >&2
    exit 1 ;;
esac
unset _q_src_l _q_src_p

# ---- purpose の確定（引数 or 対話。目標密度の再導出を毎回 AI にさせない: SB-18/GP-21） ----
if [ -z "$PURPOSE" ]; then
  echo ""
  echo "仕様抽出の目的を選択してください（目標密度・rebuild 層の要否・**完了条件**が決まる: GP-13, SB-18, GP-21）:"
  echo "  1) maintenance = 保守理解のみ"
  echo "       rebuild 層: なし / 密度: 警告のみ"
  echo "  2) evaluation  = 再構築の評価・見積り"
  echo "       rebuild 層: 骨子 / 密度: 警告のみ"
  echo "  3) rebuild     = 再構築の実装完走 [デフォルト]"
  echo "       rebuild 層: フル / 密度: 未達で停止 / **全数 Verify が必須**（範囲は ADR で限定可）"
  echo ""
  echo "  ※ どの目的でも「可読性の床」（責務＝何のためにあるか / 業務動線 / 利用者）は必須です。"
  echo "  ※ purpose は最終目標なので途中で下げません（変更は要停止）。"
  printf "選択 [1-3] (default: 3): "
  read -r choice || choice=""   # 非対話（パイプ/CI）では EOF → デフォルトに倒す
  case "${choice:-3}" in
    1) PURPOSE="maintenance" ;;
    2) PURPOSE="evaluation" ;;
    *) PURPOSE="rebuild" ;;
  esac
fi
case "$PURPOSE" in
  maintenance|evaluation|rebuild) : ;;
  *) echo "Error: purpose は maintenance|evaluation|rebuild のいずれか: $PURPOSE"; exit 1 ;;
esac


SRC="$(cd "$SRC" && pwd)"                  # 絶対パス化（配置先の決定に使う論理パス）
# 【走査に渡すパスは物理パスにする（2026-09-24 の実測。FO-1）】
# 解析対象をシンボリックリンクで指すと**走査が黙って 0 件になる**——`find <link>` と
# `find <link> | xargs grep` は **rc=0 で 0 件**（無警告）、`grep -rl`/`-Rl` は rc=1 で 0 件。
# **`-R` を付けても追わない**（macOS / BSD grep 2.6.0-FreeBSD で実測）。
# `pwd -P` で物理パスにすれば**裸の `find` でも正しい件数になる**ので、
# 走査形を 1 つずつ直すのではなく**値を渡す時点で 1 回正規化する**。
# 【配置先は論理パスのまま】`PARENT` を物理パスにすると**仕様リポジトリの作られる場所が変わる**
# ——リンク経由で解析対象を指す運用（測定用の作業ディレクトリ等）では、
# リンクの隣ではなく実体の隣に作られてしまう。**分けて持つ**。
SRC_SCAN="$(cd "$SRC" && pwd -P)"
PARENT="$(dirname "$SRC")"
NAME="$(basename "$SRC")"
SPEC_REPO="${PARENT}/${NAME}-spec"
BRANCH="spec/${SPEC_NAME}"
WROOT="${SPEC_REPO}/spec-extraction"       # 作業アセットの置き場所

if [ -e "$SPEC_REPO" ]; then
  echo "Error: target already exists: $SPEC_REPO"
  exit 1
fi

echo "=== 仕様書生成 初期化 (reverse-spec-flow) ==="
echo "  source   : $SRC  (解析対象。参照専用・変更しない)"
echo "  spec repo: $SPEC_REPO  (独立 git リポジトリ, branch=$BRANCH)"
echo "  assets   : $WROOT/"
echo "  host     : ${HOST_NAME}（対応レベル: ${HOST_LEVEL:-不明}。詳細は hosts/README.md）"

# ---- 1. 仕様書リポジトリのディレクトリ構造を作成 ----
# フェーズは生成パイプライン（取り込み→コードグラフ→分析→生成→監査）の各段に対応する（pipeline.md / GP-N）
mkdir -p "$SPEC_REPO"/specs/{modules,api,data,behavior}
# rebuild/ = 技術非依存の本質仕様層（再構築が目的のときのみ使う: GP-13）
mkdir -p "$SPEC_REPO"/specs/rebuild
mkdir -p "$WROOT"/{00-ingestion,01-code-graph,02-analysis,03-audit,worklog}
mkdir -p "$WROOT"/worklog/investigation-notes   # 着手時に開く受け皿（GP-28。git 管理外）
mkdir -p "$WROOT"/docs/{knowledge,decisions}

# ---- 2. 作業アセット（テンプレート）を配置 ----
cp "$SCRIPT_DIR/AGENTS.md.template"                       "$WROOT/AGENTS.md"
# ルートの入口（AGENTS.md）。**ベンダ中立な唯一の入口**で、全ホストに共通して置く。
# ホスト固有の入口ファイル（ベンダ名のついた導線など）が必要かはホストによって違うので、
# **その配置は `hosts/<surface>/placement.sh` が行う**（GP-107 ルール1。本スクリプトはホスト名を知らない）。
# **入れ子の AGENTS.md を自動で読むかもホストによって違う**ので、入口は
# 「目的別の規範を自分で読め」と指示する設計にしてある（自動読込に依存しない）。
cp "$SCRIPT_DIR/templates/root-AGENTS.md.template"        "$SPEC_REPO/AGENTS.md"
# 消費側（specs/ を読んで主張するとき）の規範。入れ子は自動読込されないので
# ルートの AGENTS.md が目的別に指す（そこが唯一の導線）。
cp "$SCRIPT_DIR/templates/specs-AGENTS.md.template"       "$SPEC_REPO/specs/AGENTS.md"
cp "$SCRIPT_DIR/templates/pipeline-procedure.md.template" "$WROOT/pipeline-procedure.md"
cp "$SCRIPT_DIR/templates/cross-cutting.md.template"       "$SPEC_REPO/specs/cross-cutting.md"
cp "$SCRIPT_DIR/templates/references.md.template"          "$WROOT/00-ingestion/references.md"
cp "$SCRIPT_DIR/templates/code-graph.md.template"          "$WROOT/01-code-graph/code-graph.md"
cp "$SCRIPT_DIR/templates/work-plan.md.template"           "$WROOT/01-code-graph/work-plan.md"
cp "$SCRIPT_DIR/templates/roadmap.md.template"             "$WROOT/01-code-graph/roadmap.md"
cp "$SCRIPT_DIR/templates/analysis.md.template"            "$WROOT/02-analysis/_template.md"
cp "$SCRIPT_DIR/templates/session-context.md.template"    "$WROOT/worklog/session-context.md"
cp "$SCRIPT_DIR/templates/investigation.md.template"      "$WROOT/worklog/investigation-notes/_template.md"
cp "$SCRIPT_DIR/templates/subtask-plan.md.template"       "$WROOT/worklog/_subtask-plan-template.md"
cp "$SCRIPT_DIR/templates/traceability.md.template"       "$WROOT/03-audit/traceability.md"
cp "$SCRIPT_DIR/templates/rebuild-readiness.md.template"  "$WROOT/03-audit/rebuild-readiness.md"
cp "$SCRIPT_DIR/templates/observed-anomalies.md.template" "$WROOT/03-audit/observed-anomalies.md"
cp "$SCRIPT_DIR/templates/gates.sh"                       "$WROOT/03-audit/gates.sh"
chmod +x "$WROOT/03-audit/gates.sh"
cp "$SCRIPT_DIR/templates/density-ledger.tsv"             "$WROOT/03-audit/density-ledger.tsv"

# ---- ホスト固有の配置を委譲する（GP-107 ルール1） ----
# 【ここがホスト分岐の唯一の場所】入口ファイル・skill の配置先・セットアップ手順など、
# ホストで違うものはすべて `placement.sh` が置く。**本スクリプトにホスト名で分岐を書かない**
# ——書くと 3 つ目のホストで破綻し、しかも汎用側がホストを知る状態が固定化する。
# 【git add より前に呼ぶ】置いたものが初期コミットに入らないと引き継がれない
# （実運用で、無視された入口文書が引き継がれず入口が死んだ）。
export FW_DIR="$SCRIPT_DIR"
export HOST_DIR
export SPEC_REPO
export WROOT
export SKILLS_SRC="$SCRIPT_DIR/skills"
# shellcheck source=/dev/null
( . "$HOST_DIR/placement.sh" )
# 【ホストを知らずに行える配置（HOST.md・HOST-SETUP.md）】正本は hosts/_place-common.sh（apply-host.sh と共有。2 箇所に書くとずれる）
# shellcheck source=hosts/_place-common.sh
. "$HOSTS_DIR/_place-common.sh"
# ---- Playbook 層の配置（GP-105。固定ファイル名が契約） ----
# enumeration.md は「分母の定義」であり必須。Playbook 未指定なら雛形を置いて
# Phase 1 Step 1-2 の最初の作業として埋めさせる（空のままだと G-ENUM-SOURCE が FAIL する）。
# 「独立ソースが分からない」を「突合しない」に落とさないための構造（GP-6 設計原則と同型）。
if [ -n "$PLAYBOOK_DIR" ]; then
  # 主の Playbook（従来どおりの固定ファイル名）
  cp "$PLAYBOOK_DIR/enumeration.md" "$WROOT/01-code-graph/enumeration.md"
  [ -f "$PLAYBOOK_DIR/practices.md" ] && \
    cp "$PLAYBOOK_DIR/practices.md" "$WROOT/docs/knowledge/practices.md"
  [ -f "$PLAYBOOK_DIR/spec-appendix.md" ] && \
    cp "$PLAYBOOK_DIR/spec-appendix.md" "$SPEC_REPO/specs/_appendix-${PLAYBOOK_NAME}.md"
  [ -f "$PLAYBOOK_DIR/gate-snippets.sh" ] && {
    cp "$PLAYBOOK_DIR/gate-snippets.sh" "$WROOT/03-audit/gate-snippets.sh"
    chmod +x "$WROOT/03-audit/gate-snippets.sh"; }
  [ -f "$PLAYBOOK_DIR/README.md" ] && \
    cp "$PLAYBOOK_DIR/README.md" "$WROOT/docs/knowledge/playbook-${PLAYBOOK_NAME}.md"
  echo "  playbook : ${PLAYBOOK_NAME}（enumeration.md ＝ 分母の定義を配置）"
  # 従の Playbook（名前つきのファイル。GP-105 ルール11）
  # 【文書の中の置き場も書き換える】Playbook の文書は自分の置き場を `03-audit/gate-snippets.sh` /
  # `01-code-graph/enumeration.md` と書いている。そのまま写すと、従の文書のコマンドが**主の走査器**を
  # 呼び、もっともらしい別の件数を返す（反証レビューの実測: 主の `idents-table` が PL/SQL の木から表を返した）。
  # 識別子の保存先も `identifiers/<名前>-<種別>.txt` に分ける（主と同じ `table.txt` を上書きしない）。
  _i=1
  while [ "$_i" -lt "${#PLAYBOOK_DIRS[@]}" ]; do
    _pd="${PLAYBOOK_DIRS[$_i]}"; _pn="${PLAYBOOK_NAMES[$_i]}"
    _sedx="s#03-audit/gate-snippets\.sh#03-audit/gate-snippets-${_pn}.sh#g"
    _sedx="${_sedx};s#01-code-graph/enumeration\.md#01-code-graph/enumeration-${_pn}.md#g"
    _sedx="${_sedx};s#identifiers/<種別>#identifiers/${_pn}-<種別>#g"
    _sedx="${_sedx};s#\`gate-snippets\.sh\`#\`gate-snippets-${_pn}.sh\`#g"
    sed "$_sedx" "$_pd/enumeration.md" > "$WROOT/01-code-graph/enumeration-${_pn}.md"
    [ -f "$_pd/practices.md" ] && \
      sed "$_sedx" "$_pd/practices.md" > "$WROOT/docs/knowledge/practices-${_pn}.md"
    [ -f "$_pd/spec-appendix.md" ] && \
      sed "$_sedx" "$_pd/spec-appendix.md" > "$SPEC_REPO/specs/_appendix-${_pn}.md"
    [ -f "$_pd/gate-snippets.sh" ] && {
      cp "$_pd/gate-snippets.sh" "$WROOT/03-audit/gate-snippets-${_pn}.sh"
      chmod +x "$WROOT/03-audit/gate-snippets-${_pn}.sh"; }
    [ -f "$_pd/README.md" ] && \
      sed "$_sedx" "$_pd/README.md" > "$WROOT/docs/knowledge/playbook-${_pn}.md"
    echo "  playbook : ${_pn}（併用。enumeration-${_pn}.md / gate-snippets-${_pn}.sh を配置）"
    _i=$((_i + 1))
  done
else
  cp "$PLAYBOOKS_DIR/_template/enumeration.md" "$WROOT/01-code-graph/enumeration.md"
  cp "$PLAYBOOKS_DIR/_template/gate-snippets.sh" "$WROOT/03-audit/gate-snippets.sh"
  chmod +x "$WROOT/03-audit/gate-snippets.sh"
  echo "  playbook : 未指定（enumeration.md の雛形を配置。Step 1-2 の最初に自分で埋めること）"
fi

cp "$SCRIPT_DIR/templates/lessons-learned.md.template"    "$WROOT/docs/knowledge/lessons-learned.md"
cp "$SCRIPT_DIR/templates/decisions.md.template"          "$WROOT/docs/decisions/decisions.md"
cp "$SCRIPT_DIR/playbook.md"                              "$WROOT/docs/knowledge/playbook.md"
cp "$SCRIPT_DIR/pipeline.md"                              "$WROOT/docs/knowledge/pipeline.md"

# 知見文書のコピーに採番の名前空間宣言を注入する（GP-9 の永続 ID 原則を運用でも守るため）。
# 実運用で複数プロジェクトが独立に GP-105 等を採番し、正本と意味が衝突した（この対策）。
for kf in playbook pipeline; do
  case "$kf" in
    playbook) _ns="SB" ;;
    pipeline) _ns="GP" ;;
  esac
  _tmp="$WROOT/docs/knowledge/.${kf}.tmp"
  {
    echo "<!-- ============================================================================="
    echo "     このファイルはフレームワーク正本のコピー（参照専用の知見台帳）である。"
    echo "     生成元: reverse-spec-flow / spec-name=${SPEC_NAME} / $(date '+%Y-%m-%d')"
    echo ""
    echo "     【採番の名前空間】無印の ${_ns}-N を新規採番してはいけない。"
    echo "     正本側で別の意味に使われ ID が衝突する（GP-9: 永続 ID・再利用禁止）。"
    echo "     このプロジェクトで得た汎用知見は ${_ns}-${SPEC_NAME}-N の名前空間で追記する。"
    echo "     プロジェクト完了時、フレームワークへ還元する際に正本側で改めて採番される。"
    echo "     ============================================================================= -->"
    echo ""
    cat "$WROOT/docs/knowledge/${kf}.md"
  } > "$_tmp"
  mv "$_tmp" "$WROOT/docs/knowledge/${kf}.md"
done
unset _ns _tmp

# 解析対象パスと spec 名を AGENTS.md に埋め込む
#   <SOURCE_PATH> → 解析対象の実パス
#   <SPEC_NAME>   → 知見の採番名前空間（GP-<SPEC_NAME>-N。正本の GP-N との衝突を防ぐ: GP-9）
if grep -q '<SOURCE_PATH>' "$WROOT/AGENTS.md"; then
  LC_ALL=C sed -i.bak "s#<SOURCE_PATH>#${SRC_SCAN}#g" "$WROOT/AGENTS.md"
  rm -f "$WROOT/AGENTS.md.bak"
fi
if grep -q '<SPEC_NAME>' "$WROOT/AGENTS.md"; then
  LC_ALL=C sed -i.bak "s#<SPEC_NAME>#${SPEC_NAME}#g" "$WROOT/AGENTS.md"
  rm -f "$WROOT/AGENTS.md.bak"
fi

# ---- 3. 初期ファイル作成 ----
cat > "$WROOT/worklog/worklog.md" << 'EOF'
# 作業ログ

<!-- 時系列で追記する。各エントリは日時(YYYY-MM-DD HH:MM)・Phase・内容を含めること -->
EOF

# gate-config.env: 目的プリセット（gates.sh が source する。SB-18/GP-21 の目標密度宣言の実体）
# 「Phase 0 で目標密度を宣言」を AI の毎回の再導出から init 時の一択に変える（揺れの発生源を断つ）。
case "$PURPOSE" in
  # maintenance も密度を **warn** で見せる（実運用の指摘に基づく変更。2026-09-07）。
  # off だと「浅い」ことに気づけないまま完了できてしまう。warn なら**作業は止めずに不足が見える**
  # ——保守目的では「ここは浅いので必要ならコードを見る」という判断ができれば足りる。
  maintenance) DENSITY_GATES="warn"; REBUILD_LAYER="off" ;;
  evaluation)  DENSITY_GATES="warn"; REBUILD_LAYER="skeleton" ;;
  rebuild)     DENSITY_GATES="on";   REBUILD_LAYER="full" ;;
esac
cat > "$WROOT/00-ingestion/gate-config.env" << EOF
# ゲート設定（init.sh が purpose=$PURPOSE から生成。gates.sh が source する）
# 変更する場合は ADR に理由を記録すること（スコープ/目的の変更に相当: GP-7, SB-11）。
# 【値は大文字小文字を区別する】各キーのコメントに列挙した値以外を書くと gates.sh は rc=2 で中断する
# （実測: 綴り違い 1 文字で検査が黙って消える事故が 4 件あったため。緑にも赤にもせず止める）。
# 目的: rebuild / maintenance / evaluation（unknown はキー自体が無い旧リポジトリの既定値）
PURPOSE=$PURPOSE
# 【生成時の目的（変更しない記録）】\`PURPOSE\` を下げると密度・本質層の要求がまとめて消えるので、
# **変更を検出できるように生成時の値を別キーで残す**。変更するなら PURPOSE の行に根拠 ADR の番号を書く:
#   PURPOSE=maintenance  # ADR-12
# この行自体は書き換えない（書き換えたら検出できなくなる。ADR で理由を残すこと）。
PURPOSE_INITIAL=$PURPOSE
# 密度ゲート: on=FAIL 判定 / warn=警告のみ / off=スキップ（SB-18, GP-20/21）
DENSITY_GATES=$DENSITY_GATES
# rebuild 層: full=全能力フル密度 / skeleton=骨子まで / off=作らない（GP-13 適用条件）
REBUILD_LAYER=$REBUILD_LAYER
# 統合俯瞰ビューの置き場所（能力別分割時。G-VIEW が参照）
INTEGRATED_VIEW_DOC=
# Playbook（GP-105。ドメイン固有の列挙手順。空 = 未指定＝ enumeration.md を自分で埋める）
# 【値を引用する】空白を含む Playbook 名/パスだと gate-config.env が bash の構文エラーになり、
# 生成直後から全ゲートが rc=2 で止まる（実測。SOURCE_PATH は同じ理由で引用している）。
PLAYBOOK='$PLAYBOOK_NAME'
# 併用した Playbook の全部（空白区切り。1 つ目が PLAYBOOK と同じ主。GP-105 ルール11）。
# gates.sh は 2 つ目以降の名前ごとに 01-code-graph/enumeration-<名前>.md の存在と記入を検査する
PLAYBOOKS='$PLAYBOOKS_ALL'
# 解析対象ソースのルート（GP-4 ルール7 の逆引き索引が引用を実ファイルへ解決するのに使う）。
# 【なぜ config に持つか】従来この情報は AGENTS.md にしか無く、gates.sh は解析対象の
# ファイル一覧を得られなかった。**移動した場合はここを直す**（絶対パス）。
# 空・存在しない場合、G-SOURCEINDEX は索引を作らないのではなく
# 「引用文字列のまま索引化し、解決していないことを明示する」に縮退する（黙って劣化させない）。
# **値は引用符で囲む**（空白入りのパスで config が bash の構文エラーになる。実測で踏んだ）
SOURCE_PATH='$SRC_SCAN'
# 解析対象からの除外（POSIX ERE。逆引き索引の分母＝引用の解決先から外す）。
# 【なぜ設定にするか】ビルド生成物のディレクトリ名はスタック固有であり（\`target/\` \`build/\`
# \`node_modules/\` \`dist/\` …）、**汎用ゲートに決め打ちを書くと別スタックで無意味になる**（GP-105）。
# 何を除外するかは Playbook の \`enumeration.md\`「走査の落とし穴」が規定する。Phase 0 で埋める。
# **値は必ず引用符で囲む**（\`SOURCE_EXCLUDE='(^|/)target/'\`）——囲まないと bash の構文エラーになり、
# gates.sh が中断する（囲み忘れを黙って「除外なし」で走らせない）。
# 空のままでも動くが、生成物のコピーが分母に混ざると同名複数で引用が解決できなくなる
# （実測: Apache Roller で引用の 23% が解決不能。\`target/\` を除外して 0.9% に下がった）。
SOURCE_EXCLUDE=''
EOF


# ---- 手順書の付録（状況限定部分。GP-102） ----
# 適用条件が gate-config.env の値で機械判定できるものだけを付録に分ける
# （「大規模時」「宣言時」等は AI 判断になるため付録化しない）。
# 読まれない文書を置かないことが最も確実な減量であり、条件は設定値で決まるため裁量が入らない。
# 【重要】この配置は上の purpose プリセット解決より後でなければならない
# （REBUILD_LAYER / DENSITY_GATES がまだ未定義なら set -u で中断する）。
# 両方が off のときだけ配置しない——片方でも生きているなら、
# 【現行のプリセットでは両方 off にならない】rebuild=on/full・maintenance=warn/off・
# evaluation=warn/skeleton なので、**この else 分岐はプリセット表を書き換えたときだけ効く**
# （`GP-102` の「条件が偽なら配置しない」は実例ゼロ。`dev/developing-the-framework.md` に起票済み）。
# 手順書の参照先が存在しない状態（宙に浮いた参照）を作ってはならない。
if [ "$REBUILD_LAYER" != "off" ] || [ "$DENSITY_GATES" != "off" ]; then
  mkdir -p "$WROOT/procedures"
  cp "$SCRIPT_DIR/templates/procedures/rebuild-layer.md" "$WROOT/procedures/rebuild-layer.md"
  echo "  appendix : procedures/rebuild-layer.md（REBUILD_LAYER=${REBUILD_LAYER} / DENSITY_GATES=${DENSITY_GATES}）"
else
  echo "  appendix : rebuild-layer.md は配置しない（REBUILD_LAYER=off かつ DENSITY_GATES=off）"
fi

# FRAMEWORK-VERSION: どの版のフレームワークで生成したかを固定する。
# 知見の還元レビュー時に「どの版を基準に得た知見か」を判定するために必要（dev/backport-procedure.md）。
_FW_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
_FW_DIRTY=""
if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
  _FW_DIRTY=" (uncommitted changes present at generation time)"
fi
cat > "$WROOT/docs/knowledge/FRAMEWORK-VERSION" << EOF
# 生成元フレームワークの版（知見還元時の基準。手書きで編集しない）
framework=reverse-spec-flow
framework_commit=${_FW_COMMIT}${_FW_DIRTY}
generated_at=$(date '+%Y-%m-%d %H:%M %Z')
spec_name=${SPEC_NAME}
purpose=${PURPOSE}
# 知見の採番名前空間（このプロジェクトが使う接頭辞。無印 GP-N/SB-N は正本専用）
knowledge_namespace=GP-${SPEC_NAME}-N / SB-${SPEC_NAME}-N
EOF

# HOST-APPLIED: 適用した harness の履歴（GP-107）。
# 【なぜ残すか】`apply-host.sh` で後からホストを変えるとき、**前のホストが何だったか**が
# 分からないと残った配置物の説明がつかない。FRAMEWORK-VERSION と同じ趣旨の出自の記録である。
# 【gate-config.env に書かない】ゲートがホスト設定を読むと合否がホストで変わる（GP-107 ルール4）。
cat > "$WROOT/docs/knowledge/HOST-APPLIED" << 'EOF'
# 適用した harness の履歴（GP-107）。append-only。
# 「このリポジトリがどのホスト向けに配置されているか」の記録で、ゲートは読まない。
# 書式: <日付> <ホスト> <対応レベル> <適用時のフレームワーク版>
EOF
printf '%s %s %s %s\n' "$(date +%Y-%m-%d)" "$HOST_NAME" "${HOST_LEVEL:-unknown}" "${_FW_COMMIT}" \
  >> "$WROOT/docs/knowledge/HOST-APPLIED"
unset _FW_COMMIT _FW_DIRTY

cat > "$WROOT/03-audit/gate-results.md" << 'EOF'
# ゲート実行結果（検証結果の正本）

<!--
このファイルは `03-audit/gates.sh` が自動追記する。手書きで編集しない。
traceability.md のチェックリストはこのファイルの最終実行結果を正本として参照する
（手書き転記＝自己申告の残存ベクターを廃止。GP-6 ルール7）。
完了/レディ宣言の前提: `gates.sh phase4` の最終実行が FAIL 0 であること。
-->
EOF

cat > "$WROOT/00-ingestion/scope.md" << EOF
# 取り込み・スコープ確定（Phase 0）

<!-- Phase 0 で作成。解析対象の断面を固定し、分析スコープと除外を明示する（pipeline.md / GP-1, GP-7, SB-5） -->

## 仕様の目的（init.sh の purpose プリセット。GP-13 適用条件・SB-18 目標密度の宣言）

| 項目 | 値 |
|------|---|
| purpose | **${PURPOSE}** （maintenance=保守理解 / evaluation=評価・見積り / rebuild=実装完走） |
| 密度ゲート | ${DENSITY_GATES}（gate-config.env。目標密度＝各カテゴリテンプレの required-sections） |
| rebuild 層 | ${REBUILD_LAYER} |

<!-- purpose の選択自体を Phase 0 の ADR に記録する（「なぜこの目的か」）。プリセットの中身
     （必須節・密度単位）はフレームワーク側で確定済みのため、ここで再導出しない（GP-21, SB-18）。
     途中で purpose を変える場合は gate-config.env を更新し、変更理由を ADR に残す。 -->

## 解析断面

| 項目 | 値 |
|------|---|
| 解析対象パス | <SOURCE_PATH> |
| コミットハッシュ（あれば） | |
| 取得日時 | YYYY-MM-DD HH:MM |

## 分析スコープ

- 対象: <全体 / 特定モジュール>
- 除外対象（サードパーティ・自動生成・非推奨等。理由は ADR に記録: GP-7, SB-2）:
  | 除外対象 | 理由 | ADR |
  |---------|------|-----|
  | | | ADR-N |

## 固有文脈（ステアリング相当: GP-7）

<!-- 対象システム固有の用語定義・命名規約・ドメイン略語。全フェーズで一貫参照する -->
EOF

cat > "$SPEC_REPO/specs/overview.md" << 'EOF'
---
spec-id: SPEC-overview-01
verification: unverified
category: overview
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# システム概要仕様（ISO/IEC/IEEE 29148:2018 SRS §1 Introduction + §2 Overall Description）

<!-- Phase 3（仕様生成）で作成。29148 準拠の章立てをリバース用途に調整（pipeline.md / GP-8）。
     各記述に分析物 ID を [[...]] で引用する（GP-4）。コードから確定できない意図依存の節は 🔍 UNKNOWN か省略（GP-5, SB-4） -->

## 対象システム

| 項目 | 値 |
|------|---|
| システム名 | <PRODUCT_NAME> |
| 解析対象パス | <SOURCE_PATH> |
| 主要技術スタック | |
| 仕様書の目的・読者 | |
| 作成開始日 | YYYY-MM-DD |

## 1. Purpose（目的）

<!-- この仕様書が扱う対象と目的。<SPEC_PURPOSE> と一致させる -->

## 2. Scope（スコープ）

<!-- 仕様化の対象範囲・対象外。00-ingestion/scope.md と一致させる（GP-7） -->

**能力の境界は抽出の便宜である。** 再構築の作業分割・見積もりの単位は再構築側が決める（GP-14 ルール8）。
仕様ファイルの単位: modules はコンポーネント単位、api・behavior は機能単位。入口（URL・アクション）からは `specs/source-index.md` の「入口から引く」表で引く。

## 3. Definitions / 略語

<!-- ドメイン用語・略語の定義（GP-7 の固有文脈） -->

## 4. System Overview（全体像）

<!-- システムの全体像・主要コンポーネント・技術スタック。ARCH 分析物を引用。
     コンポーネント関係・外部境界は mermaid 等の図で可視化する（GP-14）。図要素は仕様 ID／分析物 ID に紐づけ、
     新たな根拠を作らない。画像バイナリは一次仕様にしない（REF に留める）。 -->

## 5. Product Perspective（外部システムとの関係）

<!-- 依存する/依存される外部システム・外部境界の一覧（SB-7）。境界の詳細は specs/api, specs/data へ -->

## 6. Constraints / Assumptions（制約・前提）

<!-- コードから観測される制約。意図・要求根拠に依存する前提は 🔍 UNKNOWN で明示（GP-5） -->

## 7. Nonfunctional Attributes（System Qualities）

<!-- 品質特性の観点リストで網羅（ISO/IEC 25010 ベース、GP-3 の NFR 観点）。コードから観測できる範囲で記述し、
     定量目標（SLA 等、現行に無い）は 🔍 UNKNOWN[deferred]。観測→要件は推定として区別（GP-13 ルール4, SB-4）。 -->

- **性能効率性**: <キャッシュ・インデックス・非同期化など観測できる機構＋推定される性能要件>
- **信頼性**: <リトライ・タイムアウト・トランザクション境界・冗長化など>
- **セキュリティ**: <認証・認可・暗号化・CSRF・レート制限・監査ログ>
- **保守性**: <レイヤ構造・設定外出し・テスト・ログ>
- **互換性**: <外部 I/F・データ形式・対外契約（SB-7 と連携）>
- **使用性 / 移植性**: <i18n・アクセシビリティ・環境依存・DB 抽象>
- 🔍 UNKNOWN[deferred]: <定量目標（応答時間 SLA・可用性目標・スループット）は現行コードに無い＝再構築時に定義>

## 8. 利用/運用視点ビュー（投影、GP-14）

<!-- 「実際にどう使われ、どう運用されるか」の視点で束ねたビュー。新たな根拠を作らず、既存仕様への [[...]] 参照の
     再構成に徹する（single source of truth を崩さない。既存仕様のコピー＝二重管理はしない）。大規模なら
     specs/usage-operations.md として独立させてよい。 -->

- **利用視点**: <主要ユースケースを利用者の一連の操作（E2E 業務フロー）として束ねる。specs/behavior/・
  specs/rebuild/ の相互作用・画面遷移を [[SPEC-...]] で横断参照。E2E フローが最低 1 本つながること（GP-11 (C)）>
- **運用視点**: <定常運用・バッチ実行・障害時。specs/rebuild/ のジョブ実行・NFR（信頼性/可用性）・監視/ログを [[...]] で横断参照>

## 9. 統合俯瞰ビュー（能力別に分割した場合は必須、GP-14 ルール6）

<!-- 能力別（縦串別）に分割すると全体一覧性が失われる。「実体を持つ図」を描いた上で詳細へリンクする
     （「詳細は X を参照」のポインタ一文で終わらせない）。全体関係は統合ビュー固有＝二重管理でない
     （属性・条件の詳細は各仕様が正でリンク、図は関係の全体像のみ）。大規模なら specs/usage-operations.md
     または specs/rebuild/README.md に分離してよい。完了条件は機械検証（下記）。 -->

<!-- 統合論理データモデル（全能力横断 ER）: 全ドメイン能力のエンティティを 1 枚の erDiagram に。関連（カーディナリティ）のみ・
     属性は描かない。各エンティティに [[SPEC-data-...]] で属性表の所在を併記。部分 ER は不可（全 specs/data/* が登場すること）。
     例:
     ```mermaid
     erDiagram
       USER ||--o{ ARTICLE : authors
       ARTICLE ||--o{ COMMENT : has
     ```
     統合画面遷移グラフ: 全画面（SCR-*）を貫く遷移を 1 枚の flowchart に。エッジにトリガー/条件、各ノードに [[SPEC-...]]。
     能力↔仕様 索引 ＋ 能力依存グラフ: (A)/(B) 早見表 ＋ 能力依存グラフをレイヤ別 subgraph で描き位相順（実装着手順）を列挙。
     機械検証: 統合 ER のエンティティ数 ≥ specs/data/* 総数 / 統合画面遷移図のノード数 = SCR 総数 / 能力依存グラフのノード数 = rebuild 能力数。 -->

## 10. 到達点と限界（この節を消さない。GP-13 / FB-14）

<!--
**本質層（`specs/rebuild/`）の成果物では必須の節である。** 読者が「これで何を判断してよいか」を誤らないために、
担保していることと担保していないことを分けて書く。

【担保されていないことには「埋める費用」を併記する（FB-14）】
実測で、限界を列挙した成果物が**その限界を埋める費用を書かなかった**ため、
「あと少しで終わる」ように見えて実際は密度ブロック 709 件・Verify 証跡 905 件の作業が残っていた。
**限界の列挙だけでは意思決定に使えない**——各項目に量（`work-plan.md` (C) の残量と整合させる）を書く。

【少なくとも次を書く】
  担保: 分母の割当（未割当 N 件）／目印の系統数とヒット数／少数ヒットの精読で見つけた中間層
  担保しない: 深さ（`verification: unverified`）／不変条件が実際に強制されているか（**最多の欠落型**）／
              未確定 N 件（**このリストが短いことを網羅の証拠にしない**）／実装層の不在
  費用: 上記を埋めるのに必要な量（ブロック数 × Verify ラウンド・読む経路数 等）
-->

**担保されていること:**

- `<軸>`: `<何をどう確認したか。機械検証ならゲート名>`

**担保されていないこと（＋埋める費用）:**

| 担保しないこと | なぜ | 埋める費用（量。`work-plan.md` (C) と整合） |
|--------------|------|----------------------------------|
| <例: 各記述の深さ> | <verification: unverified。独立 Verify 未実施> | <例: 密度ブロック N 件 × 1〜7 ラウンド> |

> **この成果物で判断してよいこと / いけないこと**: `<明示する>`
EOF

# specs 各カテゴリに 29148 準拠の章立てスケルトンを配置（GP-8）。
# 各仕様項目に「検証（Verification）」を対で持たせるのが 29148 の要（GP-8 ルール 2）。
cat > "$SPEC_REPO/specs/modules/_template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: module
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# モジュール仕様: <component>（ISO/IEC/IEEE 29148 §3 System Requirements / コンポーネント単位）

<!-- 1 コンポーネント 1 ファイル（ソースツリーで 1 つの部品と認識するまとまり。ノード 1 つに 1 ファイルにしない。GP-14 ルール8） -->

<!-- required-sections: 責務, 機能要件, 処理フロー, 依存, Verification -->
<!-- readable-sections: 責務 -->
<!-- ↑**可読性の床**（`G-READABLE`）。密度ゲートとは別に、**purpose に関係なく FAIL 判定**で守る。
     【なぜ分けたか】`責務` を `required-sections`（密度）で実装したため、
     `DENSITY_GATES=off` だと一緒に無効化され、**人間の理解が目的の purpose=maintenance でだけ
     「読んで分かるか」の検査が切れていた**（実運用で判明した設計の誤り。逆である）。
     密度＝実装できる深さ／可読性＝何のためにあるかが書かれているか。要求が別なので分ける。
     複製した実成果物でもこの行を残す（消すと検査対象から外れる）。 -->
<!-- ↑密度ゲート（G-DENSITY, SB-18/GP-21）の検査対象。この見出しが存在し非空（コメント以外の実データ行 ≥1）
     であることが密度の床。複製した実成果物でもこの行を残す（消すと検査できない）。
     【なぜ 責務 / 処理フロー / 依存 を床に入れたか（実測に基づく還元）】
     初版は `機能要件, Verification` の 2 節だけで、**`責務` / `処理フロー` / `依存` は節ごと
     消えても PASS した**。4 プロジェクトの実測（2026-08-31）で、**2 プロジェクトがほぼ全モジュールで
     `責務` を欠落**させていた（残る 2 つは維持）。**普遍ではなく条件付きの症状**である
     ——落ちるのは機械生成と大規模反復。
     **密度は高いのに「何のためにあるか」が 1 行も無い**状態が機械検出されずに成立していた。
     FB-11 と同型（規約はあるが機械検査されていないので実運用で消える）。 -->

<!-- ファイル名は <component>.md。各記述に分析物 ID を [[...]] で引用（GP-4） -->

## 責務

<!-- このモジュールの責務（観測された挙動として記述）。ARCH/REQ 分析物を引用。
     【3 点を書く】再構築の意思決定には「実装が何をするか」だけでは足りない:
       (a) **何のためにあるか**（この単位が成立させている業務上の結果）
       (b) **業務動線のどこに位置するか**（前後の画面・処理。`specs/rebuild/screen-map.md` 等への上位リンク）
       (c) **誰が使うか**（アクター）
     実測で (a)(b)(c) の材料はいずれも**機械抽出可能**だった——画面の題名・能力名（`work-plan.md`）・
     許可遷移の行列・系統を示す識別子。**上位文脈への逆リンクが無いことが原因**で、
     screen-map → module のリンクはあっても module → 上位が無かった。 -->

## 機能要件

<!-- 提供する機能。単一責務・検証可能・曖昧表現を避ける（29148）。「shall」でなく観測挙動として（SB-4, GP-5）。
     実装完走が目的なら散文の「観測された挙動」で止めず、検証可能な受入基準（acceptanceCriteria）まで書く（SB-18, GP-21）。
     密度の測定単位は「機能」でなく「検証可能な must/must not 条件」（GP-20）。
     例: | REQ ID | 観測された挙動 | acceptanceCriteria（検証可能な must/must not） | 検証（根拠 path:line） | 分析物 |
         |--------|--------------|-----------------------------------------------|----------------------|--------|
         | SPEC-mod-<module>-01 | | must: <条件> / must not: <条件> | | [[REQ-01]] | -->

## 処理フロー

<!-- 主要な処理の流れ。詳細な業務フローは specs/behavior へ -->

## 依存

<!-- 呼び出す先 / 呼ばれる元。コードグラフのエッジと対応（GP-2） -->

## Verification（検証）

<!-- 29148 の要（GP-8）。上記の各機能要件を、どのコード位置・どの手段で確認したかを対で示す。
     実体は GP-4 の 2 段トレーサビリティ（分析物 ID → path:line）と GP-6 の監査結果。
     検証手段は 29148 の 4 分類を明示: Inspection（精読）/ Analysis（静的追跡）/ Test（実行観測）/ Demonstration（動作提示）。
     リバースは大半 Inspection/Analysis。動的挙動・設定駆動（SB-6）は Test/Demonstration が要る（未実施なら TODO と明示）。 -->
EOF

cat > "$SPEC_REPO/specs/api/_template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: api
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# API 仕様: <function>（ISO/IEC/IEEE 29148 External Interface Requirements / SB-7）

<!-- required-sections: parameters, response, errorHandling, examples, Verification -->
<!-- ↑密度ゲート（G-DENSITY, SB-18/GP-21）の検査対象。見出しの存在＋非空が密度の床。複製先でもこの行を残す。 -->

<!-- 1 機能 1 ファイル（既定は能力と同じ境界。入口 1 つに 1 ファイルにしない。GP-14 ルール8）。
     入口ごとに小見出しを立て、その下に parameters / response / errorHandling を書く（必須節の検査はファイルに 1 つあるかしか見ない）。
     扱う入口の NODE-EP-… を小見出しに 1 つずつ書くと gates.sh source-index が入口の索引に載せる。
     各記述に分析物 ID を [[...]] で引用（GP-4） -->

## 概要

<!-- この外部 I/F の役割・種別（HTTP/RPC/公開ライブラリ API 等） -->

## 契約

<!-- 実装完走が目的なら「パス＋?command= 名の目録」で止めない（＝地図。実装できない）。目標密度＝この記述だけで実装できること（SB-18, GP-21）。
     密度の測定単位は「操作」でなく「request/response の各フィールド」（GP-20）。外部サンプル（例: SpecStudio）の必須項目に照合する（GP-21）。 -->

- **signature**: <メソッド＋パス（CQRS なら `?command=` 分岐も）。1 操作 1 行> [[API-NN]]

### parameters（全項目: 名前 / 型 / required / 説明 / 制約）

| パラメータ | 型 | required | 説明 | 制約（長さ/範囲/enum 等） | 根拠 path:line |
|-----------|----|----|------|------------------------|----------------|
| | | | | | |

### response（returnValue: 成功スキーマ・ステータス）

| フィールド | 型 | 説明 | 根拠 path:line |
|-----------|----|------|----------------|
| | | | |

### errorHandling（例外 → HTTP／エラーコード）

| 条件 | 例外/エラー | HTTP ステータス | 根拠 path:line |
|------|------------|----------------|----------------|
| | | | |

### examples（リクエスト/レスポンス実例）

<!-- 最低 1 組。実際の値で。 -->

### 前提条件 / 副作用

<!-- 認可・冪等性・トランザクション境界・書き込み先など -->

## Verification（検証）

<!-- 29148 の要（GP-8）。上記契約の各項目の根拠 path:line と確認手段を対で示す（GP-4, GP-6）。
     検証手段は 29148 の 4 分類を明示: Inspection（精読）/ Analysis（静的追跡）/ Test（実行観測）/ Demonstration（動作提示）。
     リバースは大半 Inspection/Analysis。動的挙動・設定駆動（SB-6）は Test/Demonstration が要る（未実施なら TODO と明示）。 -->
EOF

cat > "$SPEC_REPO/specs/data/_template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: data
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# データモデル仕様: <entity>（ISO/IEC/IEEE 29148 データ要件 / データディクショナリ / SB-7）

<!-- required-sections: スキーマ, データ制約・不変条件, Verification -->
<!-- ↑密度ゲート（G-DENSITY, SB-18/GP-21）の検査対象。見出しの存在＋非空が密度の床。複製先でもこの行を残す。 -->

<!-- 1 データ境界（テーブル/スキーマ/ファイル形式）1 ファイル。各記述に分析物 ID を [[...]] で引用（GP-4） -->

## 概要

<!-- このデータ境界の役割・永続化先（DB テーブル/外部ストア/ファイル等） -->

## スキーマ

<!-- 実装完走が目的なら「テーブル名＋主要列だけ」で止めない（＝地図。DDL が書けない）。密度の測定単位は「テーブル」でなく「列」（GP-20, SB-9 強化）。
     1 テーブル 1 表で全列を書く（複数テーブルをまとめて中核だけ、にしない）。ORM(@Column)↔DDL(Liquibase 等) の乖離も明記。 -->

| 列 | 型 | NULL 可否 | 長さ/precision | default | PK/FK（参照先） | unique/index | 説明 | 根拠 (path:line) |
|----|----|----|----|----|----|----|------|------------------|
| | | | | | | | | |

## データ制約・不変条件

<!-- コードから観測される制約（一意性・参照整合・バリデーション等） -->

## Verification（検証）

<!-- 29148 の要（GP-8）。スキーマ・制約の根拠 path:line と確認手段を対で示す（GP-4, GP-6）。
     検証手段は 29148 の 4 分類を明示: Inspection（精読）/ Analysis（静的追跡）/ Test（実行観測）/ Demonstration（動作提示）。
     リバースは大半 Inspection/Analysis。動的挙動・設定駆動（SB-6）は Test/Demonstration が要る（未実施なら TODO と明示）。 -->
EOF

cat > "$SPEC_REPO/specs/behavior/_template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: behavior
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 振る舞い仕様: <function>（ISO/IEC/IEEE 29148 振る舞い・状態・シーケンス）

<!-- required-sections: トリガーと前提, フロー / 状態遷移, 副作用・結果, Verification -->
<!-- ↑密度ゲート（G-DENSITY, SB-18/GP-21）の検査対象。見出しの存在＋非空が密度の床。複製先でもこの行を残す。 -->

<!-- 1 機能 1 ファイル（api と同じ境界。機能の中の業務フローは節で分ける。GP-14 ルール8）。各記述に分析物 ID を [[...]] で引用（GP-4） -->

## 概要

<!-- この業務フロー/ユースケースの目的（観測された挙動として） -->

## トリガーと前提

<!-- 開始契機（エントリポイント）・前提条件。コードグラフのノードと対応（GP-2） -->

## フロー / 状態遷移

<!-- ステップまたは状態遷移。分岐条件は観測された挙動として記述（SB-4）。
     フロー・状態遷移は mermaid 等の標準記法の図で可視化する（GP-14）。図の各ノード/エッジ/状態は対応する
     仕様 ID／分析物 ID に紐づけ、新たな根拠を作らない（図にだけの裏取りなし主張を禁止）。未確定は図中でも 🔍 UNKNOWN[...]。
     例:
     ```mermaid
     stateDiagram-v2
       Draft --> Published: publish [[REQ-01]]
       Published --> Draft: unpublish [[REQ-02]]
     ``` -->

## 副作用・結果

<!-- 外部境界への副作用（DB 書き込み・メッセージ送信・ファイル出力等） -->

## Verification（検証）

<!-- 29148 の要（GP-8）。各ステップ・分岐・副作用の根拠 path:line と確認手段を対で示す（GP-4, GP-6）。
     検証手段は 29148 の 4 分類を明示: Inspection（精読）/ Analysis（静的追跡）/ Test（実行観測）/ Demonstration（動作提示）。
     リバースは大半 Inspection/Analysis。動的挙動・設定駆動（SB-6）は Test/Demonstration が要る（未実施なら TODO と明示）。 -->
EOF

# rebuild/ = 技術非依存の本質仕様層（再構築が目的のときのみ: GP-13）
# 能力仕様の雛形（`G-REBUILD` が本質層の実体として数える形）。
# 【雛形の名前から tier を外した（段階配達の撤去。2026-09-16）】撤去された規約とともに導入された名前で、
# 意味を失う。中身（能力仕様の雛形）は `G-REBUILD` が使うので残る。
cp "$SCRIPT_DIR/templates/capability-spec.md.template" "$SPEC_REPO/specs/rebuild/_capability-template.md"

cat > "$SPEC_REPO/specs/rebuild/_template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: rebuild
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 再構築仕様（技術非依存）: <capability ドメイン能力名>

<!-- required-sections: ユースケース / アクター, 論理データモデル, ビジネスルール / バリデーション, 対外契約（互換性要件）, 実装事実へのトレース -->
<!-- ↑密度ゲート（G-DENSITY, SB-18/GP-21）の検査対象。見出しの存在＋非空が密度の床。複製先でもこの行を残す。 -->

<!--
再構築（forward engineering）が目的のときに作る、技術非依存の本質仕様層（GP-13）。
判断規準: 「再構築先スタックが何であっても必要か / 現スタックだから必要なだけか」。再構築先を前提にして取捨しない。
現スタック固有語彙（サービスクラス構造/ORM/特定 Web フレームワーク/テンプレート機構/DI 等）を持ち込まない。
実装事実（specs/modules 等の (A) 層）に [[SPEC-...]] と path:line で必ず紐づける（想像で書かない）。
-->

## ドメイン能力の概要
<!-- 実装クラス単位でなく、技術非依存のドメイン能力（例: 記事管理）として何を実現するか -->

## ユースケース / アクター
<!-- 誰が何をするか。技術非依存 -->

## 論理データモデル
<!-- エンティティ・属性・関係・不変条件・キー。論理型（文字列/整数/日時/列挙）で。ORM 型・DDL 方言は書かない（(A) 層参照） -->

## ユーザーとの相互作用（ユースケース・操作フロー・状態遷移）
<!-- 「誰が何をして系がどう応答するか」。再構築先が UI/CLI/API どれでも必要な対話フロー。特定 UI 形態を前提にしない。
     既存 UI の画面・遷移は現状の相互作用の実例として記録（実装機構は排する）。参考: 画面マニュアル REF（GP-12） -->

## ビジネスルール / バリデーション
<!-- 守るべき規則（例: タイトル必須、未来公開は予約扱い）。実装機構でなくルールを -->

## 非機能要件
<!-- 性能・可用性・セキュリティ方針など、観測できる範囲 -->

## 対外契約（互換性要件）
<!-- 再構築後も保持すべき外部契約（既存 URL・フィード形式・既存データ）。「保持必須/変更可」を明記 -->

## 実装事実へのトレース（(A) 層 / 根拠）
<!-- 本質の抽出根拠。[[SPEC-mod-...]] 等と path:line -->
EOF

# specs/rebuild の画面マップ雛形（画面構成を (B) 本質層に取り込む: GP-13 ルール11。再構築目的のときのみ）
cat > "$SPEC_REPO/specs/rebuild/_screen-map-template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: rebuild
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 再構築仕様（技術非依存）: 画面マップ（情報アーキテクチャ＋遷移）

<!-- artifact-key: screen-map -->
<!-- ↑成果物形態ゲート（GP-19/SB-16）の突合キー。このテンプレを複製した実成果物にも同じ
     「artifact-key: screen-map」行を残すこと。非該当と判断した場合は ADR に同キーを含めて記録する。 -->

<!--
GP-13 ルール11。画面構成の「本質」だけを (B) に取り込む（再構築先の UI 形態に依存させない）。
(B) に入れる: 画面インベントリ・各画面の役割・情報構造（項目/操作/データ）・画面間遷移・入口↔画面の対応。
(B) に入れない: 具体レイアウト/ピクセル/ウィジェット/配色/ナビ様式 → 参考情報 REF（スクショ・画面設計書、GP-12）に留める。
一次情報はコード（ルーティング・遷移定義・テンプレート）。スクショ/設計書は補完し、必ずコードで裏取り（doc↔code ドリフト検出）。
-->

## 画面インベントリ
<!-- 存在する画面（ビュー/対話単位）と役割（一覧/詳細/編集/ダッシュボード/ウィザード等）。各画面を (A) の path に紐づける。 -->

| 画面ID | 画面名 | 役割(パターン) | 入口(URL/ルート/アクション) | 情報構造(主な項目/操作/表示データ) | (A) 根拠(path) | REF(スクショ/設計書) |
|--------|--------|---------------|----------------------------|-----------------------------------|----------------|---------------------|
| SCR-01 | | | | | | [[REF-n]] |

## 画面間ナビゲーション / 遷移グラフ
<!-- どの画面から どの画面へ、どの操作・条件で遷移するか。ルール3 の操作フローを画面ノードで結ぶ。 -->

| From | To | トリガー操作 | 条件 | (A) 根拠(path) |
|------|----|-------------|------|----------------|
| SCR-01 | SCR-02 | | | |

## 情報アーキテクチャ / 画面グルーピング
<!-- 画面群の論理的なまとまり（機能領域・ロール別など）。ナビゲーション構造の本質。具体的なメニュー配置(左/上)は REF に留める。 -->

## 対外契約（画面に関わる、GP-13 ルール5）
<!-- 保持必須の URL パターン等。具体パターンまで確定（抽象記述で止めない）。 -->

## 視覚デザインの再現要件（GP-13 ルール11、帳票=ルール12 と対称）
<!--
原則: 見た目（配色/レイアウト/余白/コンポーネント形状）は (B) の技術非依存記述に入れない。REF スクショに留める。
分岐: ブランド一貫性・UX 継続性・デザインシステム準拠が再構築の要件になる場合は、見た目の再現を
      「対外契約に準ずる制約」として明示し、参照資産（REF スクショ）を実装者が参照できる状態にする。
      ※ 見た目を仕様化するのではなく「参照可能性を保証する」。
成果物同梱（実装完走かつ見た目が要件のときのみ）: REF スクショを specs/rebuild/screens/ に同梱する。
      「解析対象からのコピー」と明示し locator で原本に紐づける（解析対象は変更しない＝SB-5）。
      見た目が非要件・保守理解目的なら locator のみで足りる（不要な同梱で肥大化させない）。
-->

- 見た目の再現は要件か: <要件 / 非要件（＝情報構造・遷移のみ再現でよい）>
- （要件の場合）参照資産の所在: <specs/rebuild/screens/ に同梱 / REF locator のみ>

## 実装事実へのトレース / 参考情報
<!-- 画面の (A) 根拠（テンプレート/アクションの path）と、裏取りに使った REF（スクショ・画面設計書）。 -->

## 要確認事項（UNKNOWN / GP-5、再構築ブロック度タグ付き）
<!-- 🔍 UNKNOWN[blocking] 画面の入出力詳細 など。blocking は再構築前に (A) 追補で解消（GP-13 ルール9）。 -->
EOF

# specs/rebuild の帳票・出力物 雛形（画面とは別の関心事: GP-13 ルール12。再構築目的のときのみ）
cat > "$SPEC_REPO/specs/rebuild/_report-spec-template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: rebuild
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 再構築仕様（技術非依存）: 帳票・出力物

<!-- artifact-key: report-spec -->
<!-- ↑成果物形態ゲート（GP-19/SB-16）の突合キー。複製した実成果物にも同じ行を残す。非該当は ADR に同キーを含める。 -->

<!--
GP-13 ルール12。帳票（レポート/PDF/CSV/Excel/印刷/フィード等）は画面と別の関心事。
画面と違い「見た目・書式が要件（契約）になりうる」点に注意（法規制・取引先合意・監査・他システム連携で固定）。
(B) に入れる: 帳票インベントリ・用途/受け手・項目定義とレイアウト構造・集計/端数/改ページ等の業務ルール・出力トリガー/データソース。
固定フォーマットは「保持必須」の対外契約（ルール5）として具体パターンまで確定。変えてよい見た目のみ REF に留める。
一次情報はコード（生成コード・帳票テンプレート・集計クエリ）。帳票サンプル（実出力 PDF/Excel/CSV）は GP-12 の REF（能動取得）。必ずコードで裏取り。
-->

## 帳票インベントリ
<!-- 出力物と用途・受け手（人間/他システム）・形式（PDF/CSV/Excel/印刷/フィード）。各々を (A) の生成コード path に紐づける。 -->

| 帳票ID | 名称 | 用途 | 受け手 | 形式 | 出力トリガー | (A) 根拠(path) | サンプル(REF) |
|--------|------|------|--------|------|-------------|----------------|---------------|
| RPT-01 | | | 人間 / 他システム | PDF/CSV/Excel/印刷/フィード | バッチ/オンデマンド | | [[REF-n]] |

## 項目定義とレイアウト構造
<!-- 各帳票の項目（列/欄）・並び順・階層（ヘッダ/明細/合計行）・グルーピング。論理データ（ルール2）に紐づける。 -->

## 集計・計算・書式ルール（帳票固有の業務ルール、実装精読で抽出＝SB-8）
<!-- 小計/合計の計算方法、端数処理・丸め、単位・桁、日付/数値の書式、改ページ条件、ソート・絞り込み。コード path 付きで。 -->

## 固定フォーマットの契約性（ルール5）
<!-- 法規制/取引先合意/監査/他システム連携で固定の書式は「保持必須」。列順・区切り・文字コード・桁など具体パターンまで確定。
     変えてよい見た目は「変更可」または REF に留める。 -->

## 出力トリガーとデータソース
<!-- いつ・何を条件に・どのデータから生成されるか。対象期間/範囲の絞り込み。ルール3 の相互作用と接続。 -->

## 実装事実へのトレース / 参考情報
<!-- 生成コード/テンプレートの path と、裏取りに使った帳票サンプル REF。 -->

## 要確認事項（UNKNOWN / GP-5、再構築ブロック度タグ付き）
<!-- 🔍 UNKNOWN[blocking] 端数処理の丸め方向・改ページ条件 など。blocking は再構築前に (A) 追補で解消（GP-13 ルール9）。 -->
EOF

# specs/rebuild のバッチ/ジョブ実行 雛形（ジョブ本体=コード ＋ オーケストレーション=外部ツール: GP-13 ルール13。再構築目的のときのみ）
cat > "$SPEC_REPO/specs/rebuild/_job-spec-template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: rebuild
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 再構築仕様（技術非依存）: バッチ/ジョブ実行仕様

<!-- artifact-key: job-spec -->
<!-- ↑成果物形態ゲート（GP-19/SB-16）の突合キー。複製した実成果物にも同じ行を残す。非該当は ADR に同キーを含める。 -->

<!--
GP-13 ルール13。バッチは 2 層に分離される。両方を統合しないと再構築で動かない:
  (1) ジョブ本体（コード内）= 各バッチが「何をするか」。コードから抽出し (A) に紐づける。
  (2) オーケストレーション（多くは外部ジョブ管理ツール JP1/Control-M/Autosys 等）= スケジュール・ジョブ間依存/順序・
      前提条件・異常時分岐/リトライ/アラート・多重起動制御・リカバリ要件。リポジトリに欠落しがち。
オーケストレーション情報は GP-12 の参考情報（JobNet 定義・ジョブフロー図・運用手順書）として能動取得し、コードと突き合わせる
（doc↔code ドリフト検出）。実行制御は技術非依存で書く（JP1 固有記法は REF/(A)。再構築先が Airflow/Step Functions/k8s CronJob 等でも満たすべき要件）。
オーケストレーションは業務要件（起動時刻・順序・締め期限は業務/運用制約に由来）。単なる技術設定として扱わない。
-->

## ジョブインベントリ（ジョブ本体、コードから抽出）
<!-- 各バッチが何をするか・入出力・冪等性。(A) の実装 path に紐づける。 -->

| ジョブID | 名称 | 処理内容 | 入力/出力・データ操作 | 冪等性 | (A) 根拠(path) |
|----------|------|----------|----------------------|--------|----------------|
| JOB-01 | | | | 有/無 | |

## オーケストレーション（実行制御、外部ツール由来＝GP-12 REF で取得・裏取り）
<!-- スケジュール・ジョブ間依存/順序・前提条件・異常時分岐/リトライ/アラート・多重起動制御。技術非依存で。 -->

| ジョブID | スケジュール(いつ) | 依存/順序(前提ジョブ) | 異常時の振る舞い | 多重起動制御 | 由来(REF: JobNet等) | コードとの突合 |
|----------|-------------------|----------------------|-----------------|-------------|---------------------|----------------|
| JOB-01 | 日次02:00 等 | JOB-00 完了後 等 | リトライ/アラート/スキップ | | [[REF-n]] | ✅一致 / ⚠️ドリフト |

## 業務・運用制約（なぜこのスケジュール/順序か）
<!-- 締め処理の期限・営業日・他システム連携時刻など、実行制御の由来となる業務要件。技術設定でなく仕様として。 -->

## doc↔code ドリフト（JobNet ↔ コード）
<!-- 「JobNet にあるがコードに無い」「コードにあるが JobNet に未登録」を記録。コードを WHAT の正とする。 -->

## 実装事実へのトレース / 参考情報
<!-- ジョブ本体の (A) path と、実行制御の REF（外部ツール定義・ジョブフロー図）。 -->

## 要確認事項（UNKNOWN / GP-5、再構築ブロック度タグ付き）
<!-- 🔍 UNKNOWN[blocking] ジョブ間の依存条件・異常時分岐 など（外部ツール情報が未取得なら取得依頼）。blocking は再構築前に解消（GP-13 ルール9）。 -->
EOF

# specs/rebuild の非機能要件 雛形（品質特性の観点リストで網羅: GP-3 NFR 観点 / GP-13 ルール4。再構築目的のときのみ）
cat > "$SPEC_REPO/specs/rebuild/_nonfunctional-template.md" << 'EOF'
---
spec-id: TEMPLATE-DO-NOT-INDEX
category: rebuild
source-commit: <断面コミット。00-ingestion/scope.md と一致させる>
source-paths: []
coverage-status: draft
updated: YYYY-MM-DD
---
# 再構築仕様（技術非依存）: 非機能要件（NFR）

<!-- artifact-key: nonfunctional -->
<!-- ↑成果物形態ゲート（GP-19/SB-16）の突合キー。複製した実成果物にも同じ行を残す。非該当は ADR に同キーを含める。 -->

<!--
GP-13 (B) 層 / GP-3 NFR 観点。品質特性の観点リスト（ISO/IEC 25010 ベース）で網羅的に記述する（SEC だけにしない）。
- どこを見るか: NFR は機能コードでなく 設定ファイル・DI・インフラ定義・横断的箇所に散る（GP-11 CC と連携）。
- 観測→要件の逆算: 「この実装機構は どんな NFR 要件を満たすために在るか」を推定。観測(事実)と推定要件(要確認)を区別（SB-4）。
- 観測できる NFR と目標値の二分: 実装から観測できる特性は (B) に事実として。定量目標(SLA/応答時間/可用性)は現行に無い→🔍 UNKNOWN[deferred]。
- 実装機構(現スタック固有の製品名等)は (A)/REF に。(B) は「満たすべき特性」を技術非依存で。
-->

## 性能効率性
<!-- 観測: キャッシュ・インデックス・非同期/バッチ化・コネクションプール等（path 付き）。推定要件と区別。目標値は UNKNOWN[deferred]。 -->

## 信頼性（可用性・障害許容・回復性）
<!-- 観測: リトライ・タイムアウト・トランザクション境界・冗長化・ヘルスチェック。目標(SLA/RTO/RPO)は UNKNOWN[deferred]。 -->

## セキュリティ
<!-- 観測: 認証・認可・暗号化・CSRF・レート制限・監査ログ。従来の SEC を包含。 -->

## 保守性
<!-- 観測: レイヤ構造・設定外出し・テスト有無・ログ。 -->

## 互換性（相互運用性・共存性）
<!-- 観測: 外部 I/F・データ形式・対外契約（SB-7・GP-13 ルール5 と連携）。 -->

## 使用性 / 移植性
<!-- 観測: i18n・アクセシビリティ・環境依存・DB 抽象。 -->

## 実装事実へのトレース（(A) 層 / 抽出根拠）
<!-- 各 NFR の観測箇所 path:line、関連する CC・仕様。 -->

## 要確認事項（UNKNOWN / GP-5、再構築ブロック度タグ付き）
<!-- 🔍 UNKNOWN[deferred] 性能/可用性の定量目標（現行に無い・再構築時に定義）。🔍 UNKNOWN[blocking] 精読で埋まる観測不足。 -->
EOF

# ---- 4. git 初期化とコミット ----
cd "$SPEC_REPO"
git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
# 【解析対象の初期状態を記録する（G-SOURCE-INTACT が比べる。SB-5）】止めるのではなく気づく——解析対象への書き込みは
# ホストの承認では止めきれない（シェル経由で書ける）。記録の正本は gates.sh の source-baseline（人が記録し直すときも同じ経路）。
# gates.sh は git ルートを起点に自己解決するので、git init の後・初期コミットの前に呼ぶ（記録も初期コミットに入れる）。
bash "$WROOT/03-audit/gates.sh" source-baseline | sed 's/^/  /' || {
  echo "Error: 解析対象の初期状態を記録できなかった（gates.sh source-baseline）" >&2; exit 1; }
# 【行末を LF に固定する】Windows 既定の `core.autocrlf=true` でクローンすると
# **`gates.sh` 自身が CRLF になって読めなくなり**、しかも「git リポジトリ内で実行してください」
# という誤った診断で止まる（実測）。生成先にも必ず置く——ゲートの設定値の CR 剥がしは
# その先の防御であって、これの代わりにはならない。
cat > .gitattributes << 'EOF'
# 行末は LF に固定する（Windows でクローンしても gates.sh が読めるように）
* text=auto eol=lf
*.sh text eol=lf
*.md text eol=lf
*.tsv text eol=lf
*.env text eol=lf
*.template text eol=lf
EOF

cat > .gitignore << 'EOF'
# --- 環境個別ファイル（リポジトリに含めない）---
.vscode/
.idea/
.DS_Store
*.log
*~
# 【入口文書とホスト固有の配置物は追跡する】以前ベンダ固有の入口ファイルをここで無視していたため、
# 実運用の 3 リポジトリでルートの入口文書が引き継がれなかった。
# **`placement.sh` が置いたものを無視リストに入れてはいけない**（追跡されないと引き継がれず、
# 環境によっては入口が発火しない）。ホスト固有の無視が必要なら `placement.sh` が追記する。

# --- 着手時に開く受け皿（GP-28）---
# 進行中の調査メモ。完了時に worklog へ集約して削除する（育てばサブタスクへ昇格＝そちらは管理下）。
# _template.md だけは配布物なので追跡する。
spec-extraction/worklog/investigation-notes/*
!spec-extraction/worklog/investigation-notes/_template.md
EOF
git add -A
git commit -q -m "Initial commit: spec-extraction assets for ${NAME}"
# 【実行ビットを管理しない（初期コミットの後で設定する）】仕様リポジトリは Markdown が中心で、実行ビットに意味が無い。
# 管理すると、Windows 側のツールで作ったファイルが WSL の git から実行ビットだけ違って見え、内容の差 0 行の
# 「未コミット変更」が大量に出た（完走試験 2 回とも。`gates.sh session` が FAIL した）。
# 初期コミットの前に設定すると gates.sh が 100644 で記録され、クローン先で `./gates.sh` が動かなくなるので後にする。
git config core.fileMode false
git switch -q -c "$BRANCH"

# --- 完了 ---
echo ""
echo "=== 完了 ==="
echo "  source   : $SRC  (参照専用・変更しない)"
echo "  spec repo: $SPEC_REPO  (独立 git リポジトリ)"
echo "  assets   : $WROOT/"
echo "  branch   : $BRANCH"
echo "  host     : ${HOST_NAME}（対応レベル: ${HOST_LEVEL:-不明}）"
if [ "${HOST_LEVEL:-placed-unverified}" = "placed-unverified" ]; then  # 宣言が無いものも未検証として扱う
  echo ""
  echo "  ⚠ このホストは **未検証** である（実測記録が無い／未測定の項目が残る）。"
  echo "    ${HOST_DIR}/MEASURED.md を読み、何が確かめられていないかを把握してから進めること。"
fi
if [ "${HOST_SETUP_PLACED:-0}" = 1 ]; then
  echo ""
  echo "  ★ セッションを開く前に ${SPEC_REPO}/HOST-SETUP.md を読むこと（承認・skill の配置など）。"
fi
echo ""
echo "--------------------------------------------------------------------"
echo "★ 初期化完了。以降は ${SPEC_REPO} を開いて【新しいセッション】で進めること。"
echo "--------------------------------------------------------------------"
echo ""
echo "次セッションの最初のステップ（${SPEC_REPO} を開く。spec-extraction/ で開かない）:"
echo "  cd ${SPEC_REPO}"
echo "  1. spec-extraction/AGENTS.md の <PLACEHOLDER> を埋める  ← まずここから始める"
echo "  2. Phase 0（取り込み・スコープ確定）から開始する"
echo ""
echo "次セッションでの AI エージェントへの最初の指示（例）:"
echo "  spec-extraction/AGENTS.md を読んで、まず <PLACEHOLDER> を埋めてから Phase 0 を始めてください。"
echo "  解析対象ソース(参照専用)は ${SRC}。仕様書は ${SPEC_REPO}/specs/ に作成します。"
