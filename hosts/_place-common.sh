#!/bin/bash
# _place-common.sh — harness の配置のうち、ホストを知らずに行える共通部分（GP-107）
#
# 【なぜ切り出すか】`init.sh`（新規生成）と `apply-host.sh`（後付け）の両方が、`placement.sh` を呼んだ**後**に
# 同じ処理を行う: (1) `entry.md` を生成先の `HOST.md` に写す、(2) `setup.md` があれば `HOST-SETUP.md` に写す、
# (3) 前のホストの配置物が残っていれば報告する。初版は (1) を両スクリプトに同じ 6 行で複製し、(3) の対象を
# `apply-host.sh` にホスト名で直書きしていた（kiro-cli を足したとき `hosts/` の外に差分が出た＝GP-107 の
# チェック方法「2 つ目の harness を足したときに hosts/ 以外へ差分が出ないか」に自分で該当した。2026-10-26 に是正）。
# `hosts/_resolve.sh` と同じ理由で、**共通部分の正本はこのファイル 1 つ**にする。
#
# 【呼ばれ方】`placement.sh` の後に source する。次を設定済みで渡すこと:
#   HOSTS_DIR  本体の hosts/ ディレクトリ      HOST_DIR / HOST_NAME  hosts/_resolve.sh が返したもの
#   SPEC_REPO  生成先リポジトリのルート
# 次を設定して返す:
#   HOST_SETUP_PLACED  1 なら HOST-SETUP.md を置いた（呼び出し側が「開く前に読め」と案内する）
# PLACE_COMMON_FUNCS_ONLY=1 で source すると関数（host_leftovers / _placed_paths_of）だけを定義して配置は行わない
# （selftest が PLACED_PATHS の読み方を複製しないために使う。パーサの正本もこのファイル 1 つ）。
#
# 【契約（hosts/README.md「1 つの harness の中身」）】
#   entry.md  → <spec-repo>/HOST.md        （必須。手順書・skill が「HOST.md に従う」と指す正本）
#   setup.md  → <spec-repo>/HOST-SETUP.md  （任意。セッションを開く前に人が済ませる手順）
#   profile.env の PLACED_PATHS=            placement.sh が置くもののリポジトリ相対パス（空白区切り）。
#                                           ホストを切り替えたときに「前のホストの残り」を報告するのに使う。
#                                           HOST.md / HOST-SETUP.md はここに書かない（共通部分が置き直す）。

# ---- (3) 前のホストの配置物を報告する関数（削除はしない） ----
# host_leftovers <spec-repo> <今のホスト名> [<前に適用したホスト名>...]:
#   指定した harness（省略時は _template 以外の全 harness）の PLACED_PATHS のうち、生成先に存在するものを 1 行ずつ出す。
# 【ホスト名を書かない】何が残りうるかは各 harness の profile.env が宣言する。ここは走査するだけ。
# 外部パスの private harness は走査に入らない（HOST-APPLIED の履歴で名前は分かる）。
host_leftovers() {
  local _repo="$1" _cur="$2"; shift 2
  local _only=" $* " _pf _hn _paths _p _curpaths _seen="|"
  _curpaths=" $(_placed_paths_of "$HOST_DIR/profile.env") "   # 外部パスの harness でも HOST_DIR は解決済み
  # 名指しされたのに hosts/ に無い（外部パスの harness だった）ものは、そう言う（黙って抜けると「残り無し」に見える）
  for _hn in $_only; do
    case "$_hn" in ""|_template|"$_cur") continue ;; esac
    [ -f "$HOSTS_DIR/$_hn/profile.env" ] || echo "      - （${_hn} の配置物の一覧が hosts/ に無い。外部の harness なら、その profile.env の PLACED_PATHS を見る）"
  done
  # HOST-SETUP.md は共通部分が置くので PLACED_PATHS に無い。今のホストに setup.md が無ければ、残っているのは前のホストの手順である
  if [ ! -f "$HOST_DIR/setup.md" ] && [ -e "$_repo/HOST-SETUP.md" ]; then
    echo "      - HOST-SETUP.md（前のホストの手順。今のホストには setup.md が無い）"
  fi
  for _pf in "$HOSTS_DIR"/*/profile.env; do
    [ -f "$_pf" ] || continue
    _hn="$(basename "$(dirname "$_pf")")"
    case "$_hn" in _template|"$_cur") continue ;; esac
    if [ "${_only// /}" != "" ]; then case "$_only" in *" $_hn "*) ;; *) continue ;; esac; fi
    _paths="$(_placed_paths_of "$_pf")"
    set -f   # 値の語分割が目的。glob 展開はしない（`*` を含む値を書かれても展開されない）
    for _p in $_paths; do
      # いまのホストも置くもの（例: 両方が同じ skill ディレクトリを使う）は残置物ではない。同じパスは 1 回だけ出す
      case "$_curpaths" in *" $_p "*) continue ;; esac
      case "$_seen" in *"|$_p|"*) continue ;; esac
      # 【`&&` だけで書かない】`set -e` のもとで「存在しない」が非 0 を返すと**そこで落ちる**。if で書く。
      if [ -e "$_repo/$_p" ]; then _seen="$_seen$_p|"; echo "      - ${_p}（${_hn}）"; fi
    done
    set +f
  done
}
# _placed_paths_of <profile.env>: PLACED_PATHS の値（引用符・コメントを除く）。無ければ空
_placed_paths_of() {
  [ -f "$1" ] || return 0
  grep -E '^PLACED_PATHS=' "$1" | head -1 | cut -d= -f2- | sed 's/#.*$//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//'
}

if [ "${PLACE_COMMON_FUNCS_ONLY:-0}" != 1 ]; then
# 直接実行された・前提の変数が無い状態で動かない（/HOST.md に書こうとする等）
if [ -z "${HOST_DIR:-}" ] || [ -z "${HOST_NAME:-}" ] || [ -z "${HOSTS_DIR:-}" ] || [ -z "${SPEC_REPO:-}" ]; then
  echo "hosts/_place-common.sh: HOSTS_DIR / HOST_DIR / HOST_NAME / SPEC_REPO を設定して source する（直接実行しない）" >&2
  return 1 2>/dev/null || exit 1
fi

# ---- (1) entry.md → HOST.md ----
# 手順書・skill はホスト固有の起動方法やツール名を書かず「HOST.md に従う」と役割で書く（GP-107 ルール1）。
# 写さないと**実行時にその正本が存在しない**（手順書に無いルールは実行時には存在しないのと同じ）。
{ printf '<!-- hosts/%s/entry.md の写し（配置時に置いた。編集はフレームワーク側で行う。根拠の MEASURED.md もフレームワーク側の hosts/%s/ にある。--host に外部パスを渡した場合はそのディレクトリ） -->\n\n' "$HOST_NAME" "$HOST_NAME"
  cat "$HOST_DIR/entry.md"; } > "$SPEC_REPO/HOST.md"
echo "  placed   : HOST.md（${HOST_NAME} の規範の読ませ方・ツール名・禁止事項・検証官の隔離）"

# ---- (2) setup.md → HOST-SETUP.md（任意） ----
# 承認の恒久化などリポジトリ外に残る前提は `gates.sh` から検査できないので、**人が開く前に読む手順**として生成先に置く。
HOST_SETUP_PLACED=0
if [ -f "$HOST_DIR/setup.md" ]; then
  cp "$HOST_DIR/setup.md" "$SPEC_REPO/HOST-SETUP.md"
  echo "  placed   : HOST-SETUP.md（セッションを開く前に人が済ませる手順）"
  HOST_SETUP_PLACED=1
fi
fi   # PLACE_COMMON_FUNCS_ONLY
