#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（php-procedural-mysql / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 画面の 2 経路（入口のファイル / 名指しされるファイル）の要素差分
#   mod-diff              → 共通ファイルの 2 経路（関数・クラスを宣言するファイル / include されるファイル）の要素差分
#   bnd-schema            → DB 表の経路B（スキーマ定義側）の一覧
#   bnd-diff              → DB 表の 2 経路（コードの SQL / スキーマ定義）の要素差分
#   list-includes         → include / require の辺（呼び出し元・書かれた式・解決先・解決の仕方）
#   list-refs             → 画面への参照（リンク・フォームの送信先・リダイレクト・定数経由）と解決先
#   list-crud             → 画面・ファイル × 表 × 操作（select / insert / update / delete / replace）
#   list-params           → 要求の引数（$_GET / $_POST / $_REQUEST / $_COOKIE / $_SESSION / PHP 4 の $HTTP_*_VARS・gpc_get_* 等）
#   list-actions          → 画面の操作の分母（action 等の値で分ける case / 比較・送信ボタンの isset）
#   list-constants        → define() / const の定数と値（表名・ファイル名を定数で書く対象の解決表）
#   scope                 → ディレクトリごとの件数（同梱した composer のライブラリ等を見つけて SCAN_EXCLUDE を決める）
#   sql-stores            → SQL を含む PHP 以外のファイル（外部 SQL 置き場の発見用）
#   bnd-idents            → 参照側の表名の全出現（idents-table の内部用。キー<TAB>綴り）
#   idents-table | idents-page | idents-function → 識別子の抽出（G-IDENT 用。出典の綴りで出す）
#
# 環境変数（未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む。Phase 4 の再実行で付け忘れないように）:
#   SQL_STORE_GLOBS : 外部 SQL 置き場の -iname パターン（空白区切り。例: '*.sqlx'）
#   SCAN_EXCLUDE    : 走査から外すパスの POSIX ERE（`./` 始まりの相対パスに当てる。例: '^\./vendor/'）。
#                     同梱した第三者ライブラリ（composer の vendor/ 等）を外す。外したものは ADR で処分する（enumeration.md 落とし穴 2）
#
# 実測検証（2026-10-24）: webERP（会計・在庫の ERP。1 画面 1 ファイル・DB_query・.sql 305 本）、osCommerce 2.3.4.1（ネットショップ。
#   tep_db_query・表名とファイル名を定数で書く）、MantisBT（バグ管理。core/*_api.php・{表} の置換記号・ADOdb のスキーマ配列）。
#   値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。PHP の資産は UTF-8（BOM 有無）と ISO-8859-1 / Shift_JIS 等が混在し、
#   UTF-8 ロケールの awk/grep は不正バイトで黙って行を落とす（enumeration.md 落とし穴 1）。
#
# 【awk の 2 ファイル入力は FILENAME で分岐する】`FNR == NR` は先に読むファイルが空だと 2 つ目を全部食う。
#
# 【重要】このスクリプト自体の正しさを検証すること（GP-6（ゲートのコマンド自体を検証する））。
#   件数が期待と桁違いなら、データを疑う前にコマンドを疑う。
# =============================================================================
set -uo pipefail
export LC_ALL=C

SUB="${1:-}"
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")"
SRC="${2:-}"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "unknown"; exit 0; }
# 【シンボリックリンクを物理パスに解決する（2026-09-21。実プロジェクトで踏んだ偽陰性）】
SRC="$(CDPATH= cd -- "$SRC" 2>/dev/null && pwd -P)" || { echo "unknown"; exit 0; }
[ -n "$SRC" ] || { echo "unknown"; exit 0; }

# gate-config.env から値だけを取り出す（source しない。引用符つき・export つき・行末コメントつき・CRLF のどれでも。最後の行が勝つ）
cfg_get() { # $1 = キー
  local gc
  gc="$(dirname -- "$SELF")/../00-ingestion/gate-config.env"
  [ -f "$gc" ] || return 0
  tr -d '\r' < "$gc" | awk -v q="'" -v key="$1" '
    $0 ~ "^[ \t]*(export[ \t]+)?" key "=" {
      v = $0; sub("^[ \t]*(export[ \t]+)?" key "=", "", v); c = substr(v, 1, 1)
      if (c == q || c == "\"") { v = substr(v, 2); i = index(v, c); if (i > 0) v = substr(v, 1, i - 1) }
      else sub(/[ \t#].*$/, "", v)
      last = v }
    END { printf "%s", last }'
}
[ -n "${SQL_STORE_GLOBS+x}" ] || SQL_STORE_GLOBS="$(cfg_get SQL_STORE_GLOBS)"
[ -n "${SCAN_EXCLUDE+x}" ] || SCAN_EXCLUDE="$(cfg_get SCAN_EXCLUDE)"
export SQL_STORE_GLOBS="${SQL_STORE_GLOBS:-}" SCAN_EXCLUDE="${SCAN_EXCLUDE:-}"

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
# 出力のパスは解析対象からの相対（`./` 始まり）にする。引用（path:line）にそのまま使えるように。
cd "$SRC" || { echo "unknown"; exit 0; }
TAB="$(printf '\t')"
BOM="$(printf '\357\273\277')"

# 走査対象のファイル一覧（1 行 1 パス）。VCS 管理領域・node_modules・SCAN_EXCLUDE を除く。拡張子は大小を区別しない。
list_files() { # $@ = -iname のパターン
  local first=1
  local args=()
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -name node_modules \) -prune -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort \
    | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; }
}

# 複数のファイルをまとめて読む: stdin = ファイル一覧 → path<TAB>行番号<TAB>行（CR と先頭の BOM を外す。UTF-16 は NUL を落とす。落とし穴 1）
# 【ファイルごとにプロセスを起こさない】Windows（Git Bash）ではプロセス起動が遅い。UTF-16 のファイルだけを先に grep で見つけて
#   個別に読み、残りは awk 1 回で読む。BOM は正規表現の 8 進表記に頼らず、文字列として渡して先頭を比べる。
read_many() {
  local lst u16 b8 b16le b16be
  lst="$TMPD/rm.$$.$RANDOM"; u16="$lst.u16"
  b8="$(printf '\357\273\277')"; b16le="$(printf '\377\376')"; b16be="$(printf '\376\377')"
  cat > "$lst"
  if [ -s "$lst" ]; then
    tr '\n' '\000' < "$lst" | xargs -0 -r grep -l -e "^$b16le" -e "^$b16be" 2>/dev/null > "$u16" || true
  else
    : > "$u16"
  fi
  awk -v u="$u16" -v bom="$b8" 'FILENAME == u { skip[$0] = 1; next }
    !($0 in skip) { f = $0; n = 0; while ((getline line < f) > 0) { n++; sub(/\r$/, "", line); if (n == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1); print f "\t" n "\t" line } close(f) }' "$u16" "$lst"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tr -d '\000' < "$f" | awk -v f="$f" -v b1="$b16le" -v b2="$b16be" '{ sub(/\r$/, ""); if (NR == 1 && (index($0, b1) == 1 || index($0, b2) == 1)) $0 = substr($0, 3); print f "\t" NR "\t" $0 }'
  done < "$u16"
}

# SQL ファイル: *.sql ＋ SQL_STORE_GLOBS。行の流れ（path<TAB>行<TAB>本文）で、-- / # の注釈と複数行の /* */ を外す
#   （同じ行で閉じる '...' の中の -- / /* は注釈ではない。行をまたぐ文字列は追わない）
list_sql_files() {
  local globs=('*.sql')
  local g
  set -f
  for g in ${SQL_STORE_GLOBS:-}; do globs+=("$g"); done
  set +f
  list_files "${globs[@]}"
}
sql_stream() {
  list_sql_files | read_many | awk -F '\t' -v OFS='\t' -v sq="'" '
    $1 != pf { pf = $1; inb = 0 }
    { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); out = ""
      while (t != "") {
        if (inb) { i = index(t, "*/"); if (i == 0) { t = ""; break } t = substr(t, i + 2); inb = 0; continue }
        i = index(t, "/*"); j = index(t, "--"); h = (t ~ /^[ \t]*#/) ? 1 : 0; q = index(t, sq)
        if (h) { t = ""; break }
        if (q > 0 && (i == 0 || q < i) && (j == 0 || q < j)) { r = index(substr(t, q + 1), sq)
          if (r > 0) { out = out substr(t, 1, q + r); t = substr(t, q + r + 1); continue } }
        if (j > 0 && (i == 0 || j < i)) { out = out substr(t, 1, j - 1); t = ""; break }
        if (i == 0) { out = out t; break }
        out = out substr(t, 1, i - 1) " "; t = substr(t, i + 2); inb = 1
      }
      print $1, $2, out }'
}

# -----------------------------------------------------------------------------
# PHP の字句解析: ファイルを「HTML の部分」と「PHP の文」に分ける。
#   H<TAB>path<TAB>行<TAB>HTML の行（PHP の外。テンプレートの本文）
#   Q<TAB>path<TAB>開始行<TAB>深さ<TAB>文（文字列は \001 中身 \002 で囲む。注釈は除く）
#     文の区切り: `;`・`{`・`}`・`?>`（深さは文の始まりの {} の深さ。関数・クラスの宣言はその前の文として出る）
# 【注釈】`//` と `#` は行末まで（ただし `?>` で PHP の外へ出る）、`/* */` は複数行。文字列の中の `//`・`#`・`?>` は注釈ではない（落とし穴 3）。
# 【文字列】'...'（\' と \\ だけが特別）・"..."（\ で何でもエスケープ。中の $変数 は展開されるが、そのまま残す）・
#   ヒアドキュメント <<<ID / <<<"ID" / ナウドキュメント <<<'ID'（終わりの ID は行頭の空白の後でもよい。PHP 7.3 以降）。
# 【HTML の中の PHP】`<?php` / `<?=`（echo の省略形）/ 短いタグ `<?`（`<?xml` は除く）で PHP に入る。
# -----------------------------------------------------------------------------
lex_php() { # stdin = ファイル一覧
  awk -v sq="'" -v bom="$BOM" '
    function flushq() { if (qb ~ /[^ \t]/) { gsub(/[\t\n]/, " ", qb); print "Q\t" f "\t" qln "\t" qd "\t" qb } qb = ""; qln = 0 }
    function addq(s) { if (qln == 0 && s ~ /[^ \t]/) { qln = ln; qd = depth } qb = qb s }
    function emith(s) { if (s ~ /[^ \t]/) { gsub(/\t/, " ", s); print "H\t" f "\t" ln "\t" s "\t" depth } }
    {
      f = $0; ln = 0; mode = "html"; depth = 0; qb = ""; qln = 0; lit = ""; hid = ""
      while ((getline line < f) > 0) {
        ln++; sub(/\r$/, "", line); if (ln == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
        while (1) {
          if (mode == "html") {
            # `<?xml` は PHP の開始ではない。同じ行の後ろの `<?php` は読む（`<?xml ...?><?php ... ?>`。反証レビューで実証）
            hb = ""
            while (match(line, /<\?([Pp][Hh][Pp]|=)?/) && tolower(substr(line, RSTART, 5)) == "<?xml") { hb = hb substr(line, 1, RSTART + 4); line = substr(line, RSTART + 5) }
            if (match(line, /<\?([Pp][Hh][Pp]|=)?/)) {
              emith(hb substr(line, 1, RSTART - 1)); tok = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH); mode = "php"
              if (tok == "<?=") addq("echo "); continue }
            emith(hb line); break
          }
          if (mode == "bc") { i = index(line, "*/"); if (i == 0) break; line = substr(line, i + 2); mode = "php"; addq(" "); continue }
          if (mode == "sq" || mode == "dq") {
            q = (mode == "sq") ? sq : "\""
            while (1) {
              if (!match(line, (mode == "sq") ? "[\\\\" sq "]" : "[\\\\\"]")) { lit = lit line "\n"; line = ""; break }
              c = substr(line, RSTART, 1)
              if (c == "\\") { lit = lit substr(line, 1, RSTART + 1); line = substr(line, RSTART + 2); continue }
              lit = lit substr(line, 1, RSTART - 1); line = substr(line, RSTART + 1); addq("\001" lit "\002"); lit = ""; mode = "php"; break
            }
            if (mode != "php") break
            continue
          }
          if (mode == "hd") {
            if (match(line, "^[ \t]*" hid) && substr(line, RSTART + RLENGTH, 1) !~ /[A-Za-z0-9_]/) { line = substr(line, RSTART + RLENGTH); addq("\001" lit "\002"); lit = ""; mode = "php"; continue }
            lit = lit line "\n"; break
          }
          # mode == php
          if (!match(line, "\\?>|//|#|/\\*|" sq "|\"|<<<|;|[{}]")) { addq(line " "); break }
          addq(substr(line, 1, RSTART - 1)); tok = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
          if (tok == "?>") { flushq(); mode = "html"; continue }
          if (tok == "//" || tok == "#") { i = index(line, "?>"); if (i == 0) { addq(" "); break } line = substr(line, i); continue }
          if (tok == "/*") { mode = "bc"; continue }
          if (tok == sq) { mode = "sq"; lit = ""; continue }
          if (tok == "\"") { mode = "dq"; lit = ""; continue }
          if (tok == "<<<") { if (match(line, /^[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) { hid = substr(line, RSTART, RLENGTH); gsub(/[ \t"\047]/, "", hid); line = ""; mode = "hd"; lit = ""; break } addq("<<<"); continue }
          if (tok == ";") { flushq(); continue }
          if (tok == "{") { addq(" "); flushq(); depth++; continue }
          if (tok == "}") { flushq(); if (depth > 0) depth--; continue }
        }
      }
      if (mode == "sq" || mode == "dq" || mode == "hd") addq("\001" lit "\002")
      flushq(); close(f)
    }'
}
LEX="$TMPD/lex.tsv"
ensure_lex() {
  [ -f "$LEX" ] && return 0
  list_files '*.php' '*.inc' '*.phtml' '*.php3' '*.php4' '*.php5' > "$TMPD/php.list"
  lex_php < "$TMPD/php.list" > "$LEX"
}

# -----------------------------------------------------------------------------
# 定数（define('NAME', 値) / const NAME = 値）の表: 名前<TAB>値<TAB>場所。値は文字列と既知の定数の連結を解決する（変数が入れば値は空）
# 【表名とファイル名を定数で書く】osCommerce は `define('TABLE_ORDERS', 'orders')` / `define('FILENAME_ACCOUNT', 'account.php')` で
#   名前を決め、SQL とリンクは定数を連結して書く（`"select ... from " . TABLE_ORDERS`）。定数を解かないと表もリンクも 0 件に見える（落とし穴 6）。
# 【同じ名前の定数が複数】公開側と管理側（catalog / admin）で同じ定数を別の値で定義することがある。最初の定義を使い、別の値は list-constants に出す。
# -----------------------------------------------------------------------------
CONSTS="$TMPD/consts.tsv"
ensure_consts() {
  [ -f "$CONSTS" ] && return 0
  ensure_lex
  awk -F '\t' '
    $1 != "Q" { next }
    { t = $5
      # if (!defined(X)) define(X, ...) のように文の途中の define() も読む（反証レビューで実証。awk が単引用符の中なので注釈に単引用符を書かない）
      if (match(t, /(^|[^A-Za-z0-9_$>:])define[ \t]*\([ \t]*\001[A-Za-z_][A-Za-z0-9_]*\002[ \t]*,/)) {
        n = substr(t, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", n); sub(/\002.*$/, "", n)
        v = substr(t, RSTART + RLENGTH); sub(/\)[ \t]*$/, "", v); print n "\t" v "\t" $2 ":" $3; next }
      if (match(t, /^[ \t]*const[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) {
        n = substr(t, RSTART, RLENGTH); sub(/^[ \t]*const[ \t]+/, "", n); sub(/[ \t]*=$/, "", n)
        v = substr(t, RSTART + RLENGTH); print n "\t" v "\t" $2 ":" $3 }
    }' "$LEX" | awk -F '\t' '
    # 値の式を解く: 文字列・既知の定数・. の連結だけなら値、それ以外（変数・関数）があれば空
    function ev(x,   out, s, i, j, tok) {
      out = ""; evok = 1
      while (x != "") {
        if (match(x, /^[ \t.]+/)) { x = substr(x, RLENGTH + 1); continue }
        if (substr(x, 1, 1) == "\001") { j = index(x, "\002"); if (j == 0) { evok = 0; return "" } out = out substr(x, 2, j - 2); x = substr(x, j + 1); continue }
        if (match(x, /^[A-Za-z_][A-Za-z0-9_]*/)) { tok = substr(x, 1, RLENGTH); x = substr(x, RLENGTH + 1); if (tok in val) { out = out val[tok]; continue } evok = 0; return "" }
        evok = 0; return ""
      }
      return out
    }
    { nm[NR] = $1; ex[NR] = $2; wh[NR] = $3; n = NR }
    END {
      # 4 列目: used（使う値＝最初に解けた定義）/ dup（同じ値の再定義）/ other（別の値の再定義）/ unresolved（数値・true・関数・変数で値が解けない）
      # 5 列目: 値が解けたら 1（空文字列の定数も 1。接頭辞を空にする設定がある）
      for (pass = 1; pass <= 4; pass++) for (i = 1; i <= n; i++) if (!(nm[i] in val)) { v = ev(ex[i]); if (evok) { val[nm[i]] = v; at[nm[i]] = wh[i] } }
      for (i = 1; i <= n; i++) { v = (nm[i] in val) ? val[nm[i]] : ""; e = ev(ex[i]); ok = evok
        lab = !ok ? "unresolved" : ((at[nm[i]] == wh[i]) ? "used" : ((e != v) ? "other" : "dup"))
        print nm[i] "\t" e "\t" wh[i] "\t" lab "\t" ok }
    }' > "$CONSTS"
}

# 文を「値の見える文」に直す awk の部品: 文字列の中身はそのまま、コードの部分は . を空白にし、既知の定数を値に置き換え、
#   表名を返す関数（名前が table で終わる関数。`db_get_table('bug')`）を引数の名前に置き換える（落とし穴 7）。定数表を cmap に読んでおく。
AWK_EVAL='
  function evaltext(t,   out, j, code, m, nm) {
    # 表名を返す関数の呼び出し（db_get_table に表の名前の文字列を渡す形）を、その名前の文字列に置き換える
    while (match(t, /[A-Za-z_]*[Tt]able[ \t]*\([ \t]*\001[A-Za-z_][A-Za-z0-9_]*\002[ \t]*\)/)) {
      m = substr(t, RSTART, RLENGTH); nm = m; sub(/^[^\001]*\001/, "", nm); sub(/\002.*$/, "", nm)
      t = substr(t, 1, RSTART - 1) "\001" nm "\002" substr(t, RSTART + RLENGTH) }
    out = ""
    while (t != "") {
      j = index(t, "\001")
      if (j == 0) { code = t; t = "" } else { code = substr(t, 1, j - 1); t = substr(t, j) }
      out = out evcode(code)
      if (t != "") { j = index(t, "\002"); if (j == 0) { out = out substr(t, 2); t = "" } else { out = out substr(t, 2, j - 2); t = substr(t, j + 1) } }
    }
    return out
  }
  function evcode(c,   out, tok) {
    out = ""
    # 連結の . は前後の空白ごと詰める（`"FROM " . DB_PREFIX . "users"` を FROM pre_users にする。空白にすると pre_ と users に割れる。反証レビューで実証）
    gsub(/[ \t]*\.[ \t]*/, "\004", c)
    while (c != "") {
      # 置き換えるのは名前・パスらしい値の定数だけ（表名・ファイル名・ディレクトリ）。文言の定数（`ENTRY_COUNTRY_ERROR`）の語を SQL に混ぜない
      if (match(c, /^[A-Za-z_][A-Za-z0-9_]*/)) { tok = substr(c, 1, RLENGTH); c = substr(c, RLENGTH + 1); out = out (((tok in cmap) && cmap[tok] ~ /^[A-Za-z0-9_.\/-]*$/) ? cmap[tok] : tok); continue }
      if (substr(c, 1, 1) == "\004") { c = substr(c, 2); continue }
      out = out substr(c, 1, 1); c = substr(c, 2)
    }
    return out
  }'

# -----------------------------------------------------------------------------
# include / require の辺: 呼び出し元<TAB>書かれた式<TAB>場所<TAB>解決先（./ 始まり・小文字。解けなければ空）<TAB>解決の仕方
#   系統: include / include_once / require / require_once（括弧の有無を問わない）・名前が require_ / include_ で始まる関数
#   （MantisBT の `require_api('gpc_api.php')`）。式は文字列・定数・__DIR__・dirname(__FILE__) の連結だけを解き、変数・関数が入れば dynamic。
# 【相対パスの起点】PHP は相対パスを include_path（既定は . ＝入口のスクリプトのディレクトリ）と呼び出し元のディレクトリから探す。
#   ここでは呼び出し元のディレクトリから上へ順に探し、無ければファイル名（一意なら）・末尾のディレクトリ名の一致で決める（落とし穴 8）。
# -----------------------------------------------------------------------------
INCS="$TMPD/incs.tsv"
FILES="$TMPD/files.txt"
ensure_incs() {
  [ -f "$INCS" ] && return 0
  ensure_lex; ensure_consts
  awk '{ print tolower($0) }' "$TMPD/php.list" | sort -u > "$FILES"
  awk -F '\t' -v cf="$CONSTS" -v ff="$FILES" '
    FILENAME == cf { if ($4 == "used" && $5 == 1) cmap[$1] = $2; next }
    FILENAME == ff { have[$0] = 1; b = $0; sub(/^.*\//, "", b); nb[b]++; bpath[b] = $0; cand[b] = cand[b] SUBSEP $0; next }
    function norm(path,   n, a, i, k, out) {
      n = split(path, a, "/"); k = 0
      for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue; if (a[i] == "..") { if (k > 0) k--; continue } st[++k] = a[i] }
      out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]; return out
    }
    function bysuffix(lv, b,   n, c, i, best, bn, k, m, ra, ca, nr, nc, j) {
      nr = split(lv, ra, "/"); n = split(cand[b], c, SUBSEP); best = 0; bn = 0
      for (i = 2; i <= n; i++) { nc = split(c[i], ca, "/"); m = 0
        for (j = 0; j < nr && j < nc; j++) { if (ra[nr - j] == "" || ra[nr - j] == ".." || ra[nr - j] == ".") break; if (ra[nr - j] != ca[nc - j]) break; m++ }
        if (m > best) { best = m; bn = 1; k = c[i] } else if (m == best) bn++ }
      return (best >= 2 && bn == 1) ? k : ""
    }
    # 式を解く: 文字列・定数・__DIR__ / dirname(__FILE__) の連結。それ以外は {} にする
    function evinc(x, dir,   out, j, tok, pd) {
      out = ""
      while (x != "") {
        if (match(x, /^[ \t.()]+/)) { x = substr(x, RLENGTH + 1); continue }
        if (substr(x, 1, 1) == "\001") { j = index(x, "\002"); if (j == 0) return out "{}"; out = out substr(x, 2, j - 2); x = substr(x, j + 1); continue }
        if (match(x, /^dirname[ \t]*\([ \t]*(__DIR__|dirname[ \t]*\([ \t]*__FILE__[ \t]*\))[ \t]*\)/)) { pd = dir; sub(/\/[^\/]*$/, "", pd); if (pd == "") pd = "."; out = out pd; x = substr(x, RLENGTH + 1); continue }
        if (match(x, /^(__DIR__|dirname[ \t]*\([ \t]*__FILE__[ \t]*\))/)) { out = out dir; x = substr(x, RLENGTH + 1); continue }
        if (match(x, /^[A-Za-z_][A-Za-z0-9_]*/)) { tok = substr(x, 1, RLENGTH); x = substr(x, RLENGTH + 1); if (tok in cmap) { out = out cmap[tok]; continue } out = out "{}"; continue }
        if (match(x, /^\$[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\]|->[A-Za-z_]+)*/)) { out = out "{}"; x = substr(x, RLENGTH + 1); continue }
        out = out "{}"; x = substr(x, 2)
      }
      return out
    }
    function resolve(raw, from,   lv, d, base, r, b, k, cur) {
      lv = tolower(raw); gsub(/\\/, "/", lv)
      if (lv ~ /\{\}/) return "\tdynamic"
      if (lv ~ /^\.\//) lv = substr(lv, 3)
      d = tolower(from); sub(/\/[^\/]*$/, "", d)
      if (lv ~ /^\//) { r = norm(lv); if (r in have) return r "\texact" }
      cur = d
      while (1) { r = norm(cur "/" lv); if (r in have) return r "\texact"; if (cur == "." || cur == "") break; sub(/\/[^\/]*$/, "", cur); if (cur !~ /\//) cur = "." }
      b = lv; sub(/^.*\//, "", b)
      if (nb[b] == 1) return bpath[b] "\tbasename"
      if (nb[b] > 1) { k = bysuffix(lv, b); if (k != "") return k "\tsuffix"; return "\tambiguous" }
      return "\tmissing"
    }
    # 位置 pos が文字列（\001 ... \002）の中か
    function instr(t, pos,   pre, a, b) { pre = substr(t, 1, pos); a = gsub(/\001/, "", pre); pre = substr(t, 1, pos); b = gsub(/\002/, "", pre); return a > b }
    $1 != "Q" { next }
    # 関数の宣言（`function require_api( $p_api )`）は include ではない
    tolower($5) ~ /^[ \t]*((public|private|protected|static|final|abstract)[ \t]+)*function[ \t]/ { next }
    { t = $5; d = $2; sub(/\/[^\/]*$/, "", d); base = 0
      # 文の途中の include も読む（if (USE_CACHE == true) include(...) / $ok = include ...。実測 osCommerce。反証レビューで実証）
      while (match(substr(t, base + 1), /(^|[^A-Za-z0-9_$>:])(@[ \t]*)?(include|include_once|require|require_once)([ \t(]|\001)/)) {
        pos = base + RSTART; len = RLENGTH; base = pos + len - 1
        if (instr(t, pos)) continue
        x = substr(t, base); sub(/^[^ \t(\001]*/, "", x); sub(/;.*$/, "", x)
        raw = evinc(x, d); print $2 "\t" raw "\t" $2 ":" $3 "\t" resolve(raw, $2) }
      if (match(t, /(^|[^A-Za-z0-9_$>:])(require|include)_[a-z_]+[ \t]*\(/) && !instr(t, RSTART)) { x = substr(t, RSTART + RLENGTH)
        raw = evinc(x, d); print $2 "\t" raw "\t" $2 ":" $3 "\t" resolve(raw, $2) }
    }' "$CONSTS" "$FILES" "$LEX" > "$INCS"
}

# 宣言とトップレベルの処理: path<TAB>関数・クラスの宣言の数<TAB>トップレベルの処理の文の数<TAB>HTML の行の数<TAB>種類の手掛かり（cli|json|-）
#   トップレベルの処理 = 深さ 0 の文のうち、宣言（function / class / interface / trait / namespace / use / declare / define / const）・
#   include / require・`defined(...) or die` 型の入口の守り・return 以外のもの（落とし穴 4）
SHAPE="$TMPD/shape.tsv"
ensure_shape() {
  [ -f "$SHAPE" ] && return 0
  ensure_lex
  awk -F '\t' '
    { f = $2; seen[f] = 1 }
    # 関数の中の HTML（`function f() { ?> <div> <?php }`）はトップレベルではない（反証レビューで実証）
    $1 == "H" { if ($5 == 0) html[f]++; next }
    $1 != "Q" { next }
    { t = $5; lt = tolower(t); sub(/^[ \t]+/, "", lt)
      if (lt ~ /^((abstract|final|readonly)[ \t]+)*(function|class|interface|trait|enum)[ \t]/) { decl[f]++; if ($4 == 0) next }
      if (lt ~ /\$argv|php_sapi_name|stdin/) hint[f] = "cli"
      else if (lt ~ /json_encode|application\/json/ && hint[f] == "") hint[f] = "json"
      if ($4 != 0) next
      if (lt ~ /^(namespace|use|declare|define|const|global|static|return|exit|die)([ \t(;]|$)/) next
      if (lt ~ /^(@[ \t]*)?(include|include_once|require|require_once)([ \t(]|\001)/ || lt ~ /^(require|include)_[a-z_]+[ \t]*\(/) next
      # 入口の守り: defined(X) or die / if (!defined(X)) { exit; }（括弧で書く形。MantisBT の *_inc.php）。or は語として探す
      if (lt ~ /defined[ \t]*\(/ && (lt ~ /(^|[^a-z0-9_])or([^a-z0-9_]|$)|\|\||die|exit/ || lt ~ /^if[ \t]*\([ \t]*![ \t]*defined[ \t]*\([^)]*\)[ \t]*\)[ \t]*$/)) next
      # try は処理の始まり（`try { echo json_encode(go()); }` で全体を包むスクリプトがある。反証レビューで実証）。else / catch / finally は前の文の続き
      if (lt ~ /^(else|elseif|catch|finally|do)([ \t({]|$)/ && lt !~ /[a-z0-9_]\(/) next
      top[f]++ }
    END { for (f in seen) print f "\t" decl[f] + 0 "\t" top[f] + 0 "\t" html[f] + 0 "\t" ((f in hint) ? hint[f] : "-") }' "$LEX" | sort > "$SHAPE"
}

# 入口のファイル（経路A）: 種類（page|cli|json）<TAB>キー（./ 始まり・小文字）<TAB>ファイル（綴りどおり）
#   = トップレベルの処理（または HTML）を持ち、どのファイルからも include されないファイル
#   【変数でパスを組み立てる include】`include(DIR_WS_MODULES . 'payment/' . $module)` / `require(DIR_WS_LANGUAGES . $language . '/x.php')` の
#   先のファイル（決済モジュール・言語ファイル・部品のテンプレート）は、どこからも名前で include されないので入口に見える
#   （実測 osCommerce: 入口 165 のうち 36 がこれ。落とし穴 5）。解けなかった部分を「任意の文字列」にした式（includes/modules/payment/*）に
#   当たるファイルは include されるものとして入口から外す（DYNINC に一覧を残す）。式の固定部分が短すぎるもの（`{}.php` 等）は使わない。
EPS="$TMPD/eps.tsv"
DYNINC="$TMPD/dyninc.tsv"
ensure_eps() {
  [ -f "$EPS" ] && return 0
  ensure_shape; ensure_incs
  awk -F '\t' -v incf="$INCS" -v dynf="$DYNINC" '
    function rx(p,   out, i, c) { out = ""
      for (i = 1; i <= length(p); i++) { c = substr(p, i, 1)
        if (c == "{" && substr(p, i, 2) == "{}") { out = out ".*"; i++; continue }
        out = out ((index(".[]()^$*+?|\\{}", c) > 0) ? "\\" c : c) }
      return out }
    FILENAME == incf { if ($4 != "") inc[$4] = 1
      else if ($5 == "dynamic") { p = tolower($2); gsub(/\\/, "/", p); fixed = p; gsub(/\{\}/, "", fixed)
        if (fixed ~ /\// && length(fixed) >= 8 && fixed ~ /[a-z0-9_-]+\/[^\/]*$|\/[a-z0-9_-]+\/$/) { np++; pr[np] = "(^|/)" rx(p) "$"; praw[np] = $2 "\t" $3 } }
      next }
    { k = tolower($1); if (k in inc) next; if ($3 == 0 && $4 == 0) next
      for (i = 1; i <= np; i++) if (k ~ pr[i]) { print $1 "\t" praw[i] > dynf; next }
      kind = ($5 == "cli") ? "cli" : (($5 == "json" && $4 == 0) ? "json" : "page"); print kind "\t" k "\t" $1 }' "$INCS" "$SHAPE" | sort -t "$TAB" -k2,2 > "$EPS"
  [ -f "$DYNINC" ] || : > "$DYNINC"
}

# -----------------------------------------------------------------------------
# 画面への参照（経路B の材料）: 種類<TAB>書かれた値<TAB>場所<TAB>解決先<TAB>解決の仕方
#   種類: html（PHP の外の HTML の href / action / src / location 等）・code（PHP の文の中の文字列・定数の値。header('Location: ...')・
#   tep_href_link(FILENAME_X) 等）。define() の文そのものは数えない（ファイル名の一覧は遷移ではない。落とし穴 6）。
#   include / require の文も数えない（それは list-includes）。HTML の注釈 <!-- --> の中は数えない。
# -----------------------------------------------------------------------------
REFS="$TMPD/refs.tsv"
ensure_refs() {
  [ -f "$REFS" ] && return 0
  ensure_lex; ensure_consts; ensure_incs
  awk -F '\t' -v cf="$CONSTS" -v ff="$FILES" "$AWK_EVAL"'
    FILENAME == cf { if ($4 == "used" && $5 == 1) cmap[$1] = $2; next }
    FILENAME == ff { have[$0] = 1; b = $0; sub(/^.*\//, "", b); nb[b]++; bpath[b] = $0; cand[b] = cand[b] SUBSEP $0; next }
    function norm(path,   n, a, i, k, out) {
      n = split(path, a, "/"); k = 0
      for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue; if (a[i] == "..") { if (k > 0) k--; continue } st[++k] = a[i] }
      out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]; return out
    }
    function bysuffix(lv, b,   n, c, i, best, bn, k, m, ra, ca, nr, nc, j) {
      nr = split(lv, ra, "/"); n = split(cand[b], c, SUBSEP); best = 0; bn = 0
      for (i = 2; i <= n; i++) { nc = split(c[i], ca, "/"); m = 0
        for (j = 0; j < nr && j < nc; j++) { if (ra[nr - j] == "" || ra[nr - j] == ".." || ra[nr - j] == ".") break; if (ra[nr - j] != ca[nc - j]) break; m++ }
        if (m > best) { best = m; bn = 1; k = c[i] } else if (m == best) bn++ }
      return (best >= 2 && bn == 1) ? k : ""
    }
    function resolve(kind, raw, where,   from, lv, d, r, b, k, cur, rootv, na, anc, i, nh, fr) {
      from = where; sub(/:[0-9]+$/, "", from)
      lv = tolower(raw); gsub(/\\/, "/", lv)
      if (lv ~ /^(https?|ftp|mailto|javascript):/ || lv ~ /^\/\//) return
      # 先頭の変数 1 つの後ろに / が続く形（$RootPath . /X.php）は、変数を基点のパスとみなして / 以下で解く
      #   （実測 webERP: 画面のリンクのほとんどがこの形。dynamic にすると経路B が 475 から 400 に減る）
      #   基点がどの階層かは静的に決まらない（$RootPath は上の階層・dirname(PHP_SELF) は呼ぶ側の階層）。当たる階層が 1 つなら exact、
      #   複数の階層に同名のファイルがあれば ambiguous にして人が決める（反証レビューで実証）
      rootv = 0; if (lv ~ /^[$][a-z_][a-z0-9_]*\// && substr(lv, index(lv, "/")) !~ /[${]/) { lv = substr(lv, index(lv, "/")); rootv = 1 }
      if (lv ~ /\$|\{|^\.php$|^[^a-z0-9_.\/-]/) { print kind "\t" raw "\t" where "\t\tdynamic"; return }
      d = tolower(from); sub(/\/[^\/]*$/, "", d)
      if (lv ~ /^\//) lv = substr(lv, 2)
      cur = d; na = 0; nh = 0
      while (1) { anc[++na] = cur; if (cur == "." || cur == "") break; sub(/\/[^\/]*$/, "", cur); if (cur !~ /\//) cur = "." }
      for (i = 1; i <= na; i++) { r = norm(anc[i] "/" lv); if (r in have && !(r in hseen)) { hseen[r] = 1; nh++; if (nh == 1) fr = r; if (!rootv) break } }
      for (r in hseen) delete hseen[r]
      if (nh > 1) { print kind "\t" raw "\t" where "\t\tambiguous"; return }
      if (nh == 1) { print kind "\t" raw "\t" where "\t" fr "\texact"; return }
      b = lv; sub(/^.*\//, "", b)
      if (nb[b] == 1) { print kind "\t" raw "\t" where "\t" bpath[b] "\tbasename"; return }
      if (nb[b] > 1) { k = bysuffix(lv, b); if (k != "") { print kind "\t" raw "\t" where "\t" k "\tsuffix"; return } print kind "\t" raw "\t" where "\t\tambiguous"; return }
      print kind "\t" raw "\t" where "\t\tmissing"
    }
    function scan(kind, s, where,   m) {
      while (match(s, /[A-Za-z0-9_.\/~${}-]*[.][Pp][Hh][Pp]([?#][^ \t"\047<>]*)?([^A-Za-z0-9_]|$)/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/[^A-Za-z0-9_]$/, "", m); sub(/[?#].*$/, "", m)
        if (m ~ /^[.]?[Pp][Hh][Pp]$/) continue
        resolve(kind, m, where)
      }
    }
    $2 != pf { pf = $2; incmt = 0 }
    $1 == "H" { t = $4; out = ""
      while (t != "") { if (incmt) { i = index(t, "-->"); if (i == 0) { t = ""; break } t = substr(t, i + 3); incmt = 0; continue }
        i = index(t, "<!--"); if (i == 0) { out = out t; break } out = out substr(t, 1, i - 1); t = substr(t, i + 4); incmt = 1 }
      scan("html", out, $2 ":" $3); next }
    $1 == "Q" { lt = tolower($5); sub(/^[ \t]+/, "", lt)
      if (lt ~ /^const[ \t]/ || lt ~ /(^|[^a-z0-9_$>:])define[ \t]*\(/) next
      if (lt ~ /(^|[^a-z0-9_$>:])(@[ \t]*)?(include|include_once|require|require_once)([ \t(]|\001)/ || lt ~ /(^|[^a-z0-9_$>:])(require|include)_[a-z_]+[ \t]*\(/) next
      # 変数の直後に / で始まらない文字列を連結する形（$base . admin/x.php）は、変数の値が名前の一部になるので {} を挟んで dynamic にする
      #   （連結の . を詰めると変数名と文字列がつながり、変数を基点として外すときに admin まで落ちる。反証レビューで実証: osCommerce の install_4.php）
      q5 = $5; o5 = ""
      #   $this->base . / $cfg[root] . / $base . (x) / "$base" . x の形も同じ
      while (match(q5, /\$[A-Za-z_][A-Za-z0-9_]*((->[A-Za-z_][A-Za-z0-9_]*|[[][^]]*[]])*[ \t]*|\002[ \t]*)\.[ \t]*\(?[ \t]*\001[^\/]/)) { o5 = o5 substr(q5, 1, RSTART + RLENGTH - 2) "{}"; q5 = substr(q5, RSTART + RLENGTH - 1) }
      scan("code", evaltext(o5 q5), $2 ":" $3) }' "$CONSTS" "$FILES" "$LEX" > "$REFS"
}

# -----------------------------------------------------------------------------
# SQL の表: 文を値の見える形に直してから、SQL の句の語で始まる文字列を含む文だけを SQL とみなして表を拾う。
#   出力（SQLREFS）: 表（小文字）<TAB>場所<TAB>綴り<TAB>操作（select|insert|update|delete|replace|?）
# 【SQL 文字列の判定】文の中の文字列のどれかが SQL の句の語で始まること（`$SQL .= " FROM x"` のような続きの文字列も拾う）。
#   先頭語が「先頭だけ大文字」（Select / From）で英文に特有の語（the / your / please / you 等）を含む文字列は英文として除く（落とし穴 12）。翻訳の関数の引数・echo・define() の文言も外す
# 【表名の置換記号】MantisBT は SQL に `{bug}` と書き、実行時に接頭辞つきの物理名へ置き換える。`{名前}` は名前の表とみなす（落とし穴 7）。
# -----------------------------------------------------------------------------
SQLREFS="$TMPD/sqlrefs.tsv"
AWK_SQLTAB='
  BEGIN {
    split("select from where join inner outer left right full cross on as set values into update delete insert replace table exists not null and or by order group having union all distinct top case when then else end in is like with nolock dual if begin declare exec execute cascade restrict no action ignore low_priority delayed high_priority straight_join sql_calc_found_rows using", kk, " ")
    for (ii in kk) kw[kk[ii]] = 1
    PART = "(\\[[^]]*\\]|`[^`]*`|\\{[A-Za-z_][A-Za-z0-9_]*\\}|[^] \t,;()=<>[`{}]+)"
    QNAME = "^" PART "(\\." PART ")*"
  }
  function emitname(raw, where, op,   c, part, o, n, br, nn) {
    if (raw ~ /^\{[A-Za-z_][A-Za-z0-9_]*\}$/) { o = substr(raw, 2, length(raw) - 2); print tolower(o) "\t" where "\t" o "\t" op; return }
    if (raw ~ /[{}%\/:$\047"]/) return
    c = split(raw, part, "."); o = part[c]; br = (o ~ /^[[`]/)
    gsub(/[][`]/, "", o); n = tolower(o)
    if (c > 1) { nn = tolower(part[c - 1]); gsub(/[][`]/, "", nn); if (nn ~ /^(information_schema|mysql|performance_schema|sys)$/) return }
    if (n == "" || n ~ /^[@:?0-9#$.+-]/ || n == "dual") return
    if (!br && (n in kw)) return
    print n "\t" where "\t" o "\t" op
  }
  # SQL の中の文字列値を消す（単引用符と二重引用符の両方。バックスラッシュと引用符 2 個のエスケープを数える。MySQL のダンプの INSERT の
  #   文言にある。実測 webERP。落とし穴 13）。awk がシェルの単引用符の中にあるので、注釈に単引用符を書かない
  #   1 文字ずつ見ると巨大な INSERT の行で遅いので、引用符とバックスラッシュの位置へ飛ぶ
  function sqstrip(s,   out, q, c) {
    out = ""
    while (s != "") {
      if (!match(s, "[\"" sq "]")) { out = out s; break }
      out = out substr(s, 1, RSTART); q = substr(s, RSTART, 1); s = substr(s, RSTART + 1)
      while (1) {
        if (!match(s, (q == sq) ? "[\\\\" sq "]" : "[\\\\\"]")) { s = ""; break }
        c = substr(s, RSTART, 1)
        if (c == "\\") { s = substr(s, RSTART + 2); continue }
        if (substr(s, RSTART + 1, 1) == q) { s = substr(s, RSTART + 2); continue }
        out = out q; s = substr(s, RSTART + 1); break
      }
    }
    return out
  }
  function sqltables(s, where, op,   kwm, raw, rest, alen, al, top, nx) {
    s = " " s
    # DDL の ON UPDATE CURRENT_TIMESTAMP・INSERT の ON DUPLICATE KEY UPDATE 列 = ... の update は表の更新ではない（実測 webERP の amount / pagesecurity）
    gsub(/[Oo][Nn][ \t]+([Dd][Uu][Pp][Ll][Ii][Cc][Aa][Tt][Ee][ \t]+[Kk][Ee][Yy][ \t]+)?[Uu][Pp][Dd][Aa][Tt][Ee][ \t]+[A-Za-z_`]+/, " ", s)
    # 関数の引数の FROM（EXTRACT(YEAR_MONTH FROM 列)・TRIM(... FROM 列)・SUBSTRING(... FROM n)）は表の前置詞ではない（実測 webERP の orddate / duedate）
    while (match(s, /([Ee][Xx][Tt][Rr][Aa][Cc][Tt]|[Tt][Rr][Ii][Mm]|[Ss][Uu][Bb][Ss][Tt][Rr][Ii][Nn][Gg]|[Pp][Oo][Ss][Ii][Tt][Ii][Oo][Nn]|[Oo][Vv][Ee][Rr][Ll][Aa][Yy])[ \t]*\([^()]*\)/)) s = substr(s, 1, RSTART - 1) " " substr(s, RSTART + RLENGTH)
    while (match(tolower(s), /(^|[^a-z0-9_])(from|join|into|update|delete[ \t]+from|truncate[ \t]+table|replace[ \t]+into|insert[ \t]+into|lock[ \t]+tables?)[ \t]+/)) {
      kwm = tolower(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH)
      if (!match(s, QNAME)) continue
      raw = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
      if (kwm ~ /update[ \t]+$/ && tolower(raw) ~ /^(low_priority|ignore)$/) continue
      # 名前の直後が ( なら関数の呼び出し（FROM の後に implode(...) / JOIN の後に DB_escape_string(...) を連結する形）。表は静的に決まらない（落とし穴 15）
      #   INSERT INTO 表 (列, ...) の括弧は列の一覧なので、この判定は FROM / JOIN の後だけに掛ける
      if (kwm ~ /(from|join)[ \t]+$/ && raw ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && rest ~ /^[ \t]*\(/) continue
      # 操作は表ごとに決める: 書き込みの文の中でも FROM / JOIN の後の表は読むだけ（`INSERT INTO a SELECT ... FROM b` の b は select）
      top = (kwm ~ /(from|join)[ \t]+$/ && kwm !~ /delete[ \t]+from/ && op != "?") ? "select" : op
      emitname(raw, where, top)
      if (kwm ~ /(from|join)[ \t]+$/) {
        while (1) {
          if (match(tolower(rest), /^[ \t]+(as[ \t]+)?[a-z_][a-z0-9_]*/)) { alen = RLENGTH; al = tolower(substr(rest, RSTART, RLENGTH)); sub(/^[ \t]+(as[ \t]+)?/, "", al); if (!(al in kw)) rest = substr(rest, alen + 1) }
          if (!match(rest, /^[ \t]*,[ \t]*/)) break
          rest = substr(rest, RLENGTH + 1)
          if (!match(rest, QNAME)) break
          # , の後の名前の直後が ( なら関数の呼び出し（FROM t, __(x) の形。SQL の文字列の後ろの引数）
          nx = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1); if (rest ~ /^[ \t]*\(/) break
          emitname(nx, where, top)
        }
      }
    }
  }'
ensure_sqlrefs() {
  [ -f "$SQLREFS" ] && return 0
  ensure_lex; ensure_consts; ensure_schema
  {
    # 【SQL を書かない書き込み】`tep_db_perform(TABLE_X, $data, 'update')` のように、表名と列の配列を渡して SQL を作る関数がある
    #   （実測 osCommerce: 140 か所。SQL 文字列だけを見ると insert / update の大半を落とす。落とし穴 10）。名前が perform / insert / update /
    #   delete / replace で終わる関数・ADOdb の AutoExecute の第 1 引数が、スキーマにある表の名前に解けるものを拾う
    awk -F '\t' -v cf="$CONSTS" -v scf="$SCHEMA" "$AWK_EVAL"'
      FILENAME == cf { if ($4 == "used" && $5 == 1) cmap[$1] = $2; next }
      FILENAME == scf { st[$1] = 1; next }
      $1 != "Q" { next }
      { t = $5
        # 名前に db / sql / query / table を含む関数だけ（`str_replace(表名, ...)` を書き込みと読まない。反証レビューで実証）
        while (match(t, /([A-Za-z_]*([Dd][Bb]|[Ss][Qq][Ll]|[Qq]uery|[Tt]able)[A-Za-z0-9_]*(perform|_insert|_update|_delete|_replace)|[A-Za-z_][A-Za-z0-9_]*AutoExecute)[ \t]*\([ \t]*(\001[A-Za-z_][A-Za-z0-9_]*\002|[A-Z_][A-Z0-9_]*)[ \t]*[,)][^;]*/)) {
          m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
          fn = m; sub(/[ \t]*\(.*$/, "", fn); a1 = m; sub(/^[^(]*\([ \t]*/, "", a1); sub(/[ \t]*[,)].*$/, "", a1)
          nm = evaltext(a1); gsub(/[ \t]/, "", nm); ln = tolower(nm)
          if (!(ln in st)) continue
          lf = tolower(fn); op = "insert"
          if (lf ~ /_update$/ || (lf ~ /perform$|autoexecute$/ && tolower(m) ~ /\001update\002/)) op = "update"
          else if (lf ~ /_delete$/) op = "delete"; else if (lf ~ /_replace$/) op = "replace"
          print ln "\t" $2 ":" $3 "\t" nm "\t" op } }' "$CONSTS" "$SCHEMA" "$LEX"
    awk -F '\t' -v cf="$CONSTS" -v sq="'" "$AWK_EVAL$AWK_SQLTAB"'
      FILENAME == cf { if ($4 == "used" && $5 == 1) cmap[$1] = $2; next }
      $1 != "Q" { next }
      # define() / const は文言・設定（言語ファイルの `define(TEXT_X, Update your account)` の語が表に化ける。実測 osCommerce）
      tolower($5) ~ /^[ \t]*(define[ \t]*\(|const[ \t])/ { next }
      # 出力・ログ・例外の文（echo / print / die / throw / trigger_error / error_log / log_*）の文言は SQL ではない（実測 MantisBT: echo の update Database）
      tolower($5) ~ /^[ \t]*(echo|print|die|exit|throw|trigger_error|error_log|log_[a-z_]+|printf|sprintf)([ \t(]|$)/ { next }
      { t = $5; isq = 0; op = "?"
        # 翻訳の関数の引数（`_(...)` / `__(...)` / gettext / lang_get）は利用者への文言。中身を消す（実測 webERP: DB_query の第 2 引数の
        #   エラー文言の from the database が表 the に化けた）
        while (match(t, /(^|[^A-Za-z0-9_>$:])(_|__|gettext|ngettext|_e|_x|lang_get)[ \t]*\([ \t]*\001[^\002]+\002/)) {
          m = substr(t, RSTART, RLENGTH); k = index(m, "\001"); t = substr(t, 1, RSTART - 1) substr(m, 1, k) "\002" substr(t, RSTART + RLENGTH) }
        # 先頭だけ大文字の語で始まる文字列・英文の語を含む文字列（SQL の語で始まらないもの）は文言として消す（`Update BLOB in ` のログ）
        #   翻訳の関数の後ろに . で連結した文字列（__(copied to sample) . from sample の形）も文言の続き（実測 webERP）。
        #   間に挟まる変数・配列の添字（$_POST[CopyToSampleID] の添字も文字列）では続きを切らない。, や関数の呼び出しで切る。
        #   SQL の引用符が開いている所に連結した翻訳（THEN " . __(Yes) . " ELSE / LIKE %" . __(x) . "%）は SQL の値なので、続きにしない
        #   （実測 webERP: FROM 句が消えた。反証レビューで実証）。開いているかは、連結の続く間に残した文字列の引用符の数の奇偶で決める。
        #   , = ; を挟むと連結が切れるので数え直す（DB_query(SQL, __(エラー文言) . from x) の文言は SQL の続きでない）
        #   先頭だけ大文字の語で始まる文字列は、英文の語を含むか、SQL の記号（* = ( )）を含まないときだけ文言とする（`Select * from t` は SQL。, は英文にもあるので記号に数えない。実測 MantisBT のテストの文言）
        u = ""; r = t; inmsg = 0; qs = 0; qd = 0; qb = 0
        while ((j = index(r, "\001")) > 0) { pre = substr(r, 1, j - 1); sub(/^\002/, "", pre); u = u substr(r, 1, j); r = substr(r, j + 1); k = index(r, "\002"); lit = (k > 0) ? substr(r, 1, k - 1) : r; r = (k > 0) ? substr(r, k) : ""
          if (pre ~ /[,=;]/) { qs = 0; qd = 0; qb = 0 }
          if (pre ~ /(^|[^A-Za-z0-9_>$:])(_|__|gettext|ngettext|_e|_x|lang_get)[ \t]*\([ \t]*$/) inmsg = (qs % 2 == 0 && qd % 2 == 0 && qb % 2 == 0)
          else if (inmsg) { x = pre; gsub(/[ \t).$A-Za-z0-9_>-]/, "", x); gsub(/\[/, "", x); gsub(/\]/, "", x); if (x != "" || pre !~ /[.\[\]]/) inmsg = 0 }
          ll = tolower(lit); sqlstart = (ll ~ /^[ \t\n]*\(?[ \t]*(select|insert|update|delete|replace|with|create|alter|drop|truncate|from|join|inner|left|right|where|and|or|set|values|union|order|group|lock|on|limit|having)([^a-z_]|$)/)
          eng = (ll ~ /(^|[^a-z])(the|your|please|you|this|could|not|been|unable|failed)([^a-z]|$)/)
          if (inmsg || (lit ~ /^[ \t\n]*[A-Z][a-z]+[ \t]/ && (eng || lit !~ /[*=()]/)) || (!sqlstart && eng)) lit = ""
          c = lit; gsub(/\\./, "", c); qs += gsub(/\047/, "", c); qd += gsub(/"/, "", c); qb += gsub(/`/, "", c)
          u = u lit }
        t = u r; s = t
        while ((j = index(s, "\001")) > 0) { s = substr(s, j + 1); k = index(s, "\002"); lit = (k > 0) ? substr(s, 1, k - 1) : s; s = (k > 0) ? substr(s, k + 1) : ""
          if (!match(lit, /^[ \t\n]*\(?[ \t]*[A-Za-z]+/)) continue
          w = substr(lit, RSTART, RLENGTH); sub(/^[ \t\n]*\(?[ \t]*/, "", w); lw = tolower(w)
          if (lw !~ /^(select|insert|update|delete|replace|with|create|alter|drop|truncate|from|join|inner|left|right|where|and|or|set|values|union|order|group|lock)$/) continue
          if ((w ~ /^[A-Z][a-z]+$/ && lit !~ /[*=()]/) || tolower(lit) ~ /(^|[ \t])(the|your|please|you|this)([ \t.,!?]|$)/) continue
          isq = 1; if (op == "?" && lw ~ /^(select|insert|update|delete|replace)$/) op = lw }
        if (!isq) next
        e = sqstrip(evaltext(t)); sqltables(e, $2 ":" $3, op) }' "$CONSTS" "$LEX"
    sql_stream | awk -F '\t' -v sq="'" "$AWK_SQLTAB"'
      { s = sqstrip($3); lw = tolower(s); op = "?"; if (match(lw, /^[ \t]*(select|insert|update|delete|replace)/)) { op = substr(lw, RSTART, RLENGTH); gsub(/[ \t]/, "", op) }
        sqltables(s, $1 ":" $2, op) }'
  } > "$SQLREFS"
}

# -----------------------------------------------------------------------------
# 経路B: スキーマ定義側の表名。系統: DDL（.sql の CREATE TABLE・PHP の文字列の CREATE TABLE）・ADOdb のスキーマ配列（`CreateTableSQL`）。
#   出力: キー（小文字）<TAB>系統と場所<TAB>綴り。一時表（CREATE TEMPORARY TABLE）は表にしない。
# 【スキーマが SQL ファイルに無い】MantisBT は表を PHP の配列で定義し、ADOdb の DataDict が実行時に DDL を作る（落とし穴 9）
SCHEMA="$TMPD/schema.tsv"
TEMPS="$TMPD/temps.tsv"
ensure_schema() {
  [ -f "$SCHEMA" ] && return 0
  ensure_lex; ensure_consts
  {
    sql_stream | awk -F '\t' '{ print "ddl\t" $1 ":" $2 "\t" $3 }'
    awk -F '\t' -v cf="$CONSTS" "$AWK_EVAL"'
      FILENAME == cf { if ($4 == "used" && $5 == 1) cmap[$1] = $2; next }
      $1 == "Q" && tolower($5) ~ /create[ \t]+(temporary[ \t]+)?table|createtablesql/ { print "code\t" $2 ":" $3 "\t" evaltext($5) }' "$CONSTS" "$LEX"
  } | awk -F '\t' -v temps="$TEMPS" '
    function out(n, kind, where,   c, p) { gsub(/[][`"]/, "", n); sub(/^\{/, "", n); sub(/\}$/, "", n); c = split(n, p, "."); n = p[c]; if (n == "" || n ~ /^[#@$]/) return; print tolower(n) "\t" kind " " where "\t" n }
    { t = $3; lt = tolower(t)
      # 一時表（CREATE TEMPORARY TABLE）は定義側の表にせず TEMPS に残す（bnd-diff が「一時表」の節に出す。実測 webERP: 作業用の一時表 7 つ。落とし穴 14）
      l2 = lt
      while (match(l2, /create[ \t]+temporary[ \t]+table[ \t]+(if[ \t]+not[ \t]+exists[ \t]+)?`?[a-z_][a-z0-9_]*/)) {
        r = substr(l2, RSTART, RLENGTH); l2 = substr(l2, RSTART + RLENGTH); sub(/^.*table[ \t]+(if[ \t]+not[ \t]+exists[ \t]+)?`?/, "", r); print r "\t" $2 > temps }
      while (match(lt, /create[ \t]+table[ \t]+(if[ \t]+not[ \t]+exists[ \t]+)?/)) {
        r = substr(t, RSTART + RLENGTH); t = r; lt = tolower(t)
        if (match(r, /^(\[[^]]*\]|`[^`]*`|\{[A-Za-z_][A-Za-z0-9_]*\}|[^ \t(;[`{]+)(\.(\[[^]]*\]|`[^`]*`|[^ \t(;[`]+))*/)) out(substr(r, 1, RLENGTH), ($1 == "ddl") ? "ddl" : "code", $2) }
      t = $3
      while (match(t, /[Cc]reate[Tt]able[Ss][Qq][Ll][^A-Za-z0-9_]+array[ \t]*\([ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
        r = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); sub(/^.*array[ \t]*\([ \t]*/, "", r); out(r, "adodb", $2) }
    }' | sort -u -t "$TAB" -k1,1 > "$SCHEMA"
  [ -f "$TEMPS" ] || : > "$TEMPS"
}

case "$SUB" in
  ep)
    ensure_eps
    awk 'END { print (NR ? NR : "unknown") }' "$EPS"
    ;;
  list-ep)
    # 種類<TAB>名前（ファイル名）<TAB>場所
    ensure_eps
    awk -F '\t' '{ n = $3; sub(/^.*\//, "", n); print $1 "\t" n "\t" $3 }' "$EPS"
    ;;
  list-includes)
    ensure_incs; cat "$INCS"
    ;;
  list-refs)
    ensure_refs; cat "$REFS"
    ;;
  list-constants)
    # 名前<TAB>値<TAB>場所<TAB>used（使う値）|dup（同じ値の再定義）|other（別の値の再定義）
    ensure_consts; cat "$CONSTS"
    ;;
  ep-diff)
    # 画面の 2 経路: 経路A = 入口のファイル（include されず、トップレベルの処理か HTML を持つ）/ 経路B = 名指しされるファイル（リンク・
    #   フォームの送信先・リダイレクト・定数経由の参照）
    ensure_eps; ensure_refs
    cut -f2 "$EPS" | sort -u > "$TMPD/sa"
    awk -F '\t' -v ef="$EPS" 'FILENAME == ef { e[$2] = 1; next } $4 != "" && ($4 in e) { print $4 }' "$EPS" "$REFS" | sort -u > "$TMPD/sb"
    echo "== 経路A（入口のファイル）$(grep -c . "$TMPD/sa" || true) 件 / 経路B（名指しされるファイル）$(grep -c . "$TMPD/sb" || true) 件 =="
    echo "== 経路A のみ（どこからも名指しされない: 外から直接開く・cron / CLI・名前を組み立てて開く・死蔵。人が確認する） =="
    comm -23 "$TMPD/sa" "$TMPD/sb" | awk -F "$TAB" -v ef="$EPS" 'FILENAME == ef { o[$2] = $3; k[$2] = $1; next } { print "  " (($1 in o) ? o[$1] "\t" k[$1] : $1) }' "$EPS" -
    echo "== 名指しされるが入口でないファイル（include される部品・宣言だけのファイルへのリンク。人が確認する） =="
    awk -F '\t' -v ef="$EPS" 'FILENAME == ef { e[$2] = 1; next } $4 != "" && !($4 in e) { print "  " $4 "\t" $3 }' "$EPS" "$REFS" | sort -u -t "$TAB" -k1,1
    echo "== 参照先のファイルが無い（★参照切れ・断面外） =="
    awk -F '\t' '$5 == "missing" { print "  " $2 "\t" $3 "\t" $1 }' "$REFS" | sort -u
    echo "== 名前を組み立てて開く箇所（静的に決まらない。組み立てる側のコードを読んで補う） =="
    awk -F '\t' '$5 == "dynamic" { print "  " $2 "\t" $3 "\t" $1 }' "$REFS" | sort -u
    echo "== 同じファイル名が複数ある参照（パスで解決できない） =="
    awk -F '\t' '$5 == "ambiguous" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    echo "== 変数で組み立てる include の式に当たるので入口から外したファイル（ファイル<TAB>式<TAB>場所。外してよいか人が確認する） =="
    sed 's/^/  /' "$DYNINC"
    ;;
  mod)
    bash "$SELF" list-mod "$SRC" | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-mod)
    # 共通ファイル（経路A）: 関数・クラスを宣言するファイル。種類（lib = 宣言だけ / mixed = 宣言とトップレベルの処理）<TAB>ファイル<TAB>宣言の数
    ensure_shape
    awk -F '\t' '$2 > 0 { print (($3 > 0 || $4 > 0) ? "mixed" : "lib") "\t" $1 "\t" $2 }' "$SHAPE"
    ;;
  mod-diff)
    # 共通ファイルの 2 経路: 経路A = 関数・クラスを宣言するファイル / 経路B = include されるファイル
    ensure_shape; ensure_incs; ensure_eps
    awk -F '\t' '$2 > 0 { print tolower($1) }' "$SHAPE" | sort -u > "$TMPD/ma"
    { awk -F '\t' '$4 != "" { print $4 }' "$INCS"; awk -F '\t' '{ print tolower($1) }' "$DYNINC"; } | sort -u > "$TMPD/mb"
    echo "== 経路A（宣言するファイル）$(grep -c . "$TMPD/ma" || true) 件 / 経路B（include されるファイル）$(grep -c . "$TMPD/mb" || true) 件 =="
    echo "== 経路A のみ（include されない宣言ファイル: オートロードされるクラス・入口の画面が自分で関数を持つ・死蔵） =="
    comm -23 "$TMPD/ma" "$TMPD/mb" | awk -F "$TAB" -v sf="$SHAPE" 'FILENAME == sf { o[tolower($1)] = $1; tp[tolower($1)] = ($3 > 0 || $4 > 0) ? "（トップレベルの処理あり＝入口の画面が関数を持つ形）" : ""; next } { print "  " (($1 in o) ? o[$1] : $1) "\t" tp[$1] }' "$SHAPE" -
    echo "== 経路B のみ（宣言の無い include 先: 設定・テンプレート・言語ファイル・部品の画面） =="
    comm -13 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    echo "== 解決できなかった include（変数・関数でパスを組み立てる。組み立てる側を読む） =="
    awk -F '\t' '$5 != "exact" && $5 != "basename" && $5 != "suffix" { print "  " $2 "\t" $3 "\t" $5 }' "$INCS" | sort -u
    ;;
  bnd)
    bash "$SELF" list-bnd "$SRC" | cut -f1 | sort -u | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-bnd)
    # 経路A: コードの SQL（定数・{表}・表名の関数を解いた後）と SQL ファイルが参照する表名。出力: キー<TAB>最初の場所<TAB>綴り
    ensure_sqlrefs; cut -f1-3 "$SQLREFS" | sort -u -t "$TAB" -k1,1
    ;;
  bnd-idents)
    ensure_sqlrefs; awk -F '\t' '{ print $1 "\t" $3 }' "$SQLREFS"
    ;;
  list-crud)
    # ファイル<TAB>表<TAB>操作（select|insert|update|delete|replace|?）。? は「SQL の続きの文字列だけの文」（`$SQL .= " FROM x"`）
    ensure_sqlrefs
    awk -F '\t' '{ f = $2; sub(/:[0-9]+$/, "", f); print f "\t" $1 "\t" $4 }' "$SQLREFS" | sort -u
    ;;
  bnd-schema)
    ensure_schema; cat "$SCHEMA"
    ;;
  bnd-diff)
    bash "$SELF" list-bnd "$SRC" | cut -f1 | sort -u > "$TMPD/ba"
    bash "$SELF" bnd-schema "$SRC" | cut -f1 | sort -u > "$TMPD/bb"
    echo "== 経路A（コード・SQL ファイルから参照）$(grep -c . "$TMPD/ba" || true) 件 / 経路B（スキーマ定義）$(grep -c . "$TMPD/bb" || true) 件 =="
    if [ ! -s "$TMPD/bb" ]; then
      echo "★経路B が 0 件。スキーマがソースに無い（インストーラーが別リポジトリ・DB のダンプだけ・ORM のマイグレーション）。"
      echo "  sql-stores で SQL 置き場を探し、見つからなければ enumeration.md の注記に従い経路B を書き換える"
    fi
    ensure_schema; cut -f1 "$TEMPS" | sort -u > "$TMPD/bt"
    comm -23 "$TMPD/ba" "$TMPD/bb" > "$TMPD/aonly"
    echo "== 経路A のみ（参照はあるが定義が無い: 接頭辞の違い・ビュー・別 DB・英文の混入・定義の取りこぼし。一時表は下の節） =="
    comm -23 "$TMPD/aonly" "$TMPD/bt" | sed 's/^/  /'
    echo "== 一時表（コードの CREATE TEMPORARY TABLE で作る作業用の表。定義側の表には数えない） =="
    comm -12 "$TMPD/aonly" "$TMPD/bt" | sed 's/^/  /'
    echo "== 経路B のみ（定義はあるがコードから参照されない: 死蔵・名前を組み立てる SQL・アップグレードで消えた表） =="
    comm -13 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    ;;
  list-params)
    # ファイル<TAB>出どころ（GET|POST|REQUEST|COOKIE|SESSION|SERVER|FILES|wrapper:関数名）<TAB>名前<TAB>場所
    # 【PHP 4 の長い名前】`$HTTP_GET_VARS` / `$HTTP_POST_VARS` / `$HTTP_COOKIE_VARS` / `$HTTP_SESSION_VARS`（実測 osCommerce 2.3）も同じ。
    # 【引数を読む関数】MantisBT は `gpc_get_string('name')` / `gpc_get_int(...)` で読み、$_GET を直接は書かない（落とし穴 11）。
    #   `gpc_get_*` / `gpc_isset` / `filter_input(INPUT_GET, 'x')` を拾う。ほかの対象で独自の関数を使うなら名前を grep で探して足す
    ensure_lex
    awk -F '\t' '$1 == "Q" { t = $5
        while (match(t, /\$(_GET|_POST|_REQUEST|_COOKIE|_SESSION|_SERVER|_FILES|HTTP_GET_VARS|HTTP_POST_VARS|HTTP_COOKIE_VARS|HTTP_SESSION_VARS|HTTP_SERVER_VARS|HTTP_POST_FILES)[ \t]*\[[ \t]*\001[^\002]*\002/)) {
          m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); src = m; sub(/^\$/, "", src); sub(/[ \t]*\[.*$/, "", src)
          sub(/^HTTP_/, "", src); sub(/_VARS$/, "", src); sub(/^_/, "", src); if (src == "POST_FILES") src = "FILES"
          n = m; sub(/^[^\001]*\001/, "", n); sub(/\002$/, "", n); print $2 "\t" src "\t" n "\t" $2 ":" $3 }
        t = $5
        while (match(t, /(gpc_get[a-z_]*|gpc_isset[a-z_]*|filter_input[ \t]*\([ \t]*INPUT_[A-Z]+[ \t]*,)[ \t]*\(?[ \t]*\001[^\002]*\002/)) {
          m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); fn = m; sub(/[ \t(].*$/, "", fn)
          if (m ~ /^filter_input/) { fn = m; sub(/^[^I]*INPUT_/, "", fn); sub(/[ \t,].*$/, "", fn) } else fn = "wrapper:" fn
          n = m; sub(/^[^\001]*\001/, "", n); sub(/\002$/, "", n); print $2 "\t" fn "\t" n "\t" $2 ":" $3 }
      }' "$LEX" | sort -u
    ;;
  list-actions)
    # 画面の操作の分母: ファイル<TAB>手掛かり<TAB>値<TAB>場所
    #   case: 操作を選ぶ switch（式に action / mode / step / cmd / do / op / task を含む）の case の値
    #   compare: `$action == 'x'` / `$_GET['action'] == 'x'` / `$HTTP_GET_VARS['action'] == 'x'` の値
    #   submit: `isset($_POST['Name'])` の名前（送信ボタンの name で処理を分ける形。実測 webERP）
    ensure_lex
    awk -F '\t' '$1 == "Q" { t = $5; lt = tolower(t)
        if ($2 != pf) { pf = $2; split("", swd); split("", altn) }
        # 【積み重ねた case】`case "a": case "b": ...` と `default: case "c":` は : で文が切れないので 1 つの文に並ぶ。文の中の case を全部読み、
        #   case の後に書いた入れ子の switch も見る（実測 osCommerce: 約 30 の case が落ちていた。反証レビューで実証）
        #   switch の種類は { の深さごとに持つ。入れ子の switch（操作でない式）の後でも外側の case を読む（実測 osCommerce: 5 つの case が落ちていた）
        #   switch (式): ... endswitch; の書き方は { が無いので、同じ深さに種類を置き、endswitch で前の値に戻す
        sw = ($4 in swd) ? swd[$4] : 0; cs = t; ca = ""; alt = 0
        if (match(lt, /(^|[^a-z0-9_$>])switch[ \t]*\(/)) {
          sp = RSTART; kd = (substr(lt, sp) ~ /action|mode|step|cmd|[^a-z]do[^a-z]|[^a-z]op[^a-z]|task/) ? 1 : 0
          # 式の括弧の対応を取り、閉じた直後が : なら別の書き方
          i = index(substr(lt, sp), "("); pd = 0; ii = sp + i - 1
          for (; ii <= length(lt); ii++) { ch = substr(lt, ii, 1); if (ch == "\001") { while (ii <= length(lt) && substr(lt, ii, 1) != "\002") ii++; continue } if (ch == "(") pd++; else if (ch == ")") { pd--; if (pd == 0) break } }
          if (substr(lt, ii + 1) ~ /^[ \t]*:/) { alt = 1; cs = substr(t, 1, sp - 1); ca = substr(t, ii + 1); altv[$4, ++altn[$4]] = ($4 in swd) ? swd[$4] : -1; swd[$4] = kd }
          else delete swd[$4 + 1]
        } else delete swd[$4 + 1]
        while (sw && match(cs, /(^|[ \t:;])case[ \t]+\001[^\002]*\002[ \t]*:/)) { v = substr(cs, RSTART, RLENGTH); cs = substr(cs, RSTART + RLENGTH); sub(/^[^\001]*\001/, "", v); sub(/\002.*$/, "", v); print $2 "\tcase\t" v "\t" $2 ":" $3 }
        while (alt && kd && match(ca, /(^|[ \t:;])case[ \t]+\001[^\002]*\002[ \t]*:/)) { v = substr(ca, RSTART, RLENGTH); ca = substr(ca, RSTART + RLENGTH); sub(/^[^\001]*\001/, "", v); sub(/\002.*$/, "", v); print $2 "\tcase\t" v "\t" $2 ":" $3 }
        if (match(lt, /(^|[^a-z0-9_$>])switch[ \t]*\(/) && !alt) swd[$4 + 1] = kd
        if (lt ~ /(^|[^a-z0-9_$>])endswitch([^a-z0-9_]|$)/ && altn[$4] > 0) { pv = altv[$4, altn[$4]--]; if (pv == -1) delete swd[$4]; else swd[$4] = pv }
        s = t
        while (match(s, /(\$action|\[[ \t]*\001(action|mode|step|cmd)\002[ \t]*\])[ \t]*(===?|!==?)[ \t]*\001[^\002]*\002/)) {
          m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); v = m; sub(/^.*\001/, "", v); sub(/\002$/, "", v); print $2 "\tcompare\t" v "\t" $2 ":" $3 }
        s = t
        while (match(s, /isset[ \t]*\([ \t]*\$(_POST|HTTP_POST_VARS)[ \t]*\[[ \t]*\001[^\002]*\002/)) {
          m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); v = m; sub(/^.*\001/, "", v); sub(/\002$/, "", v); print $2 "\tsubmit\t" v "\t" $2 ":" $3 }
      }' "$LEX" | sort -u -t "$TAB" -k1,3
    ;;
  scope)
    # ディレクトリ（2 階層まで）ごとの件数: ディレクトリ<TAB>.php<TAB>.sql<TAB>composer.json
    # 【同梱した第三者ライブラリ】composer の vendor/ をリポジトリに入れていることがある（実測 webERP: .php 5,303 のうち 4,534 が vendor/）。
    #   数えると関数・表・SQL が桁で増える（落とし穴 2）。ここで見つけて SCAN_EXCLUDE に書き、ADR で処分する。
    find . \( -name .git -o -name .svn -o -name node_modules \) -prune -o -type f -print 2>/dev/null \
      | awk '{ l = tolower($0); n = split($0, a, "/"); d = (n >= 4) ? a[1] "/" a[2] "/" a[3] : ((n == 3) ? a[1] "/" a[2] : ".")
          k = ""; if (l ~ /\.php$/) k = "php"; else if (l ~ /\.sql$/) k = "sql"; else if (l ~ /(^|\/)composer\.json$/) k = "composer"
          if (k != "") { c[d SUBSEP k]++; ds[d] = 1 } }
          END { for (d in ds) print d "\t" c[d SUBSEP "php"] + 0 "\t" c[d SUBSEP "sql"] + 0 "\t" c[d SUBSEP "composer"] + 0 }' \
      | sort -t "$TAB" -k2,2nr
    ;;
  sql-stores)
    find . \( -name .git -o -name .svn -o -name node_modules \) -prune \
      -o -type f ! -iname '*.php' ! -iname '*.inc' ! -iname '*.phtml' ! -iname '*.php[345]' ! -iname '*.png' ! -iname '*.jpg' ! -iname '*.gif' ! -iname '*.ico' ! -iname '*.js' ! -iname '*.css' \
      ! -iname '*.zip' ! -iname '*.gz' ! -iname '*.pdf' ! -iname '*.woff*' ! -iname '*.ttf' ! -iname '*.eot' ! -iname '*.svg' ! -iname '*.webp' -print 2>/dev/null \
      | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; } \
      | read_many | awk -F '\t' '{ l = tolower($0); sub(/^[^\t]*\t[^\t]*\t/, "", l)
          if (l ~ /(select[ \t].*[ \t]from|insert[ \t]+into|update[ \t].*[ \t]set|create[ \t]+table)/) c[$1]++ }
          END { for (f in c) print c[f] "\t" f }' | sort -rn
    ;;
  idents-table)
    # 表ごとに最も多く現れた綴りを 1 つ出す（同数なら辞書順で先）。仕様はこの綴りで書く（G-IDENT は大小を区別する）
    { bash "$SELF" bnd-idents "$SRC"; bash "$SELF" bnd-schema "$SRC" | awk -F '\t' '{ print $1 "\t" $3 }'; } \
      | awk -F '\t' '
          NF >= 2 && $1 != "" && $2 != "" { c[$1 SUBSEP $2]++ }
          END {
            for (k in c) { split(k, a, SUBSEP)
              if (!(a[1] in best) || c[k] > best[a[1]] || (c[k] == best[a[1]] && a[2] < pick[a[1]])) { best[a[1]] = c[k]; pick[a[1]] = a[2] } }
            for (n in pick) print pick[n]
          }' | sort
    ;;
  idents-page)
    # 入口のファイル名（綴りどおり。`AccountGroups.php` のように拡張子つきで仕様に書く）。同じ名前は 1 つ
    ensure_eps
    awk -F '\t' '{ n = $3; sub(/^.*\//, "", n); if (!seen[tolower(n)]++) print n }' "$EPS" | sort
    ;;
  idents-function)
    # 関数名（function の宣言。クラスのメソッドを除くトップレベルの関数。綴りどおり）
    ensure_lex
    awk -F '\t' '$1 == "Q" && $4 == 0 && match($5, /^[ \t]*function[ \t]+&?[A-Za-z_][A-Za-z0-9_]*/) { n = substr($5, RSTART, RLENGTH); sub(/^[ \t]*function[ \t]+&?/, "", n); if (!seen[tolower(n)]++) print n }' "$LEX" | sort
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-includes|list-refs|list-crud|list-params|list-actions|list-constants|scope|sql-stores|bnd-idents|idents-table|idents-page|idents-function} <source-path>" >&2
    exit 2
    ;;
esac
