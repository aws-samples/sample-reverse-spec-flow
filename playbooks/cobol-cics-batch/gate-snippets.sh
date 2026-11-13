#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（cobol-cics-batch / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（タブ区切り）
#   ep-diff               → トランザクションの 2 経路（資源定義 / コード中の TRANSID）の要素差分
#   screen-diff           → 画面の 2 経路（BMS のマップ定義 / コード中の SEND・RECEIVE MAP）の要素差分
#   mod-diff              → プログラムの 2 経路（ソースの PROGRAM-ID / 呼び出し・資源定義・JCL からの参照）の要素差分
#   bnd-schema            → データ境界の経路B（DDL・DCLGEN・CICS のファイル定義）の一覧
#   bnd-diff              → データ境界の 2 経路（コード / 定義）の要素差分
#   list-calls            → プログラム間の呼び出し（CALL / LINK / XCTL / JCL の EXEC PGM=）。コードグラフのエッジの分母
#   list-dd               → バッチのファイル入出力（ジョブ・ステップ・DD 名・データセット名）
#   overflow              → 73 桁目以降にはみ出たコード（コンパイラは読まない。observed-anomalies の候補）
#   idents-table | idents-program | idents-transaction | idents-map → 識別子の抽出（G-IDENT 用）
#
# 実測検証（2026-10-23）: AWS CardDemo（CICS ＋ VSAM ＋ JCL ＋ DB2/IMS/MQ 拡張）、IBM Bank-of-Z（CICS ＋ DB2 ＋ IMS。
#   資源定義が YAML・JCL が Jinja2 テンプレート）、IBM CICS GenApp（CICS ＋ DB2 ＋ VSAM。資源定義が JCL の DFHCSDUP 入力）。
#   値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。COBOL は固定形式（7 桁目が標識、8〜72 桁が本文、73〜80 桁は無視）を
#   字句解析してから数える（素の grep は注釈・73 桁目以降の連番・継続行を区別できない。enumeration.md 落とし穴 1〜4）。
#   COBOL の語は `-` を含むので、単語境界に `\b` 相当の「英数字以外」を使わない（`WS-CALL` を CALL と読む。落とし穴 5）。
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

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
cd "$SRC" || { echo "unknown"; exit 0; }
TAB="$(printf '\t')"

# 走査対象のファイル一覧。拡張子は大小を区別しない（メインフレームから落とした資産は大文字のことが多い）。
list_files() { # $@ = -iname のパターン
  local first=1
  local args=()
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -name node_modules \) -prune -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort
}
COBOL_GLOBS=('*.cbl' '*.cob' '*.cobol' '*.ccp' '*.cpy' '*.cbx' '*.copy')
# JCL・資源定義・DDL を探す範囲（テンプレート .j2 と拡張子なしのメンバーも含む）
JCL_GLOBS=('*.jcl' '*.cntl' '*.prc' '*.proc' '*.j2' '*.job')
DEF_GLOBS=('*.csd' '*.jcl' '*.cntl' '*.txt' '*.j2' '*.yaml' '*.yml')
DDL_GLOBS=('*.ddl' '*.sql' '*.ctl' '*.jcl' '*.cntl' '*.j2' '*.txt' '*.dcl')

# -----------------------------------------------------------------------------
# 字句解析（COBOL）: ファイルごとに「論理行」を出す。出力: path<TAB>行番号<TAB>本文（大文字化・リテラルはそのまま）
# 【固定形式】1〜6 桁は連番、7 桁目が標識（`*` `/` は注釈、`D` はデバッグ行、`-` は継続）、8〜72 桁が本文、73〜80 桁は無視。
#   実測 CardDemo: 73〜80 桁に連番がある行が 4,340。切らないと名前の後ろに数字が付く（落とし穴 1）。
# 【自由形式】`>>SOURCE FORMAT FREE` があれば桁で切らず、`*>` 以降を注釈とする（落とし穴 2）。
# 【継続行】7 桁目が `-` の行は前の行の続き（英数字リテラルは次の行の最初の引用符の後から続く。落とし穴 3）。
# 【タブ】8 桁ごとのタブ位置に展開してから桁で切る（実測: タブを含むソースが CardDemo 3・Bank-of-Z 2。落とし穴 4）。
# -----------------------------------------------------------------------------
lex_cobol() { # stdin = ファイル一覧
  awk '
    function expand(s,   out, i, c) {
      if (index(s, "\t") == 0) return s
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (c == "\t") { do out = out " "; while (length(out) % 8 != 0) } else out = out c }
      return out
    }
    function strip_inline(s,   i, c, q, out) {
      # 引用符の外の *> 以降を落とす
      q = ""; out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
        if (q == "" && (c == "\"" || c == sq)) q = c
        else if (q != "" && c == q) q = ""
        else if (q == "" && c == "*" && substr(s, i + 1, 1) == ">") break
        out = out c }
      return out
    }
    # 【見出し部の注記項目は自由な文章】AUTHOR / INSTALLATION / DATE-WRITTEN / DATE-COMPILED / SECURITY / REMARKS の段落は
    #   注記（comment-entry）で、引用符の対応を取らない（実測 Bank-of-Z: 著者名の中のアポストロフィ 1 個で、
    #   ファイル全体のリテラルの内外が反転し、そのプログラムの参照が 0 件になった。落とし穴 17）。次の段落・部まで捨てる。
    #   注記として扱うのは見出し部（IDENTIFICATION DIVISION）の中だけ。手続き部の段落名 SECURITY. や、REMARKS の文章の途中の
    #   DATA で始まる行で注記の始まり・終わりを誤らない。注記は次の見出し部の段落・部の見出しで終わる。
    #   （この awk はシェルの単引用符の中にあるので、注釈にも単引用符を書かない）
    function flush(   u) {
      if (have) {
        gsub(/\t/, " ", buf); u = toupper(buf)
        if (u ~ /^ *(IDENTIFICATION|ID) +DIVISION/) { iddiv = 1; cmt = 0 }
        else if (u ~ /^ *(ENVIRONMENT|DATA|PROCEDURE) +DIVISION/) { iddiv = 0; cmt = 0 }
        else if (iddiv && u ~ /^ *(AUTHOR|INSTALLATION|DATE-WRITTEN|DATE-COMPILED|SECURITY|REMARKS) *(\.|$)/) cmt = 1
        # 見出し部の見出しを省いた形（PROGRAM-ID から始まる。GnuCOBOL 等が許す）も見出し部に入ったとみなす
        else if (u ~ /^ *PROGRAM-ID/) { iddiv = 1; cmt = 0 }
        if (!cmt) print f "\t" bufln "\t" u
      }
      have = 0; buf = ""
    }
    BEGIN { sq = sprintf("%c", 39) }
    {
      f = $0; ln = 0; free = 0; have = 0; buf = ""; cmt = 0; iddiv = 0
      while ((getline line < f) > 0) {
        ln++; sub(/\r$/, "", line)
        if (ln <= 5 && toupper(line) ~ />>[ \t]*SOURCE[ \t]+(FORMAT[ \t]+)?(IS[ \t]+)?FREE/) { free = 1; continue }
        if (free) { t = strip_inline(line); if (t ~ /^[ \t]*$/) continue; flush(); buf = t; bufln = ln; have = 1; continue }
        line = expand(line)
        if (length(line) < 7) { continue }
        ind = substr(line, 7, 1); t = substr(line, 8, 65)
        if (ind == "*" || ind == "/" || ind == "D" || ind == "d") continue
        if (ind == "-") {
          # 継続: 次の行の最初の引用符の後から続ける（英数字リテラルの継続）。引用符が無ければ空白を詰めて続ける
          if (match(t, /^[ \t]*["\047]/)) t = substr(t, RSTART + RLENGTH); else sub(/^[ \t]+/, "", t)
          if (have) { buf = buf t; continue }
        }
        t = strip_inline(t)
        flush(); buf = t; bufln = ln; have = 1
      }
      flush()
      close(f)
    }'
}
LEX="$TMPD/lex.tsv"
ensure_lex() {
  [ -f "$LEX" ] && return 0
  list_files "${COBOL_GLOBS[@]}" > "$TMPD/cob.list"
  lex_cobol < "$TMPD/cob.list" > "$LEX"
}

# ファイルごとに論理行を 1 本の文字列へ連結した「文の流れ」（EXEC ... END-EXEC が複数行に渡るため）
#   出力: path<TAB>連結した本文（空白 1 個で区切る）
# 【連結しても行番号を捨てない】引用は path:line で書くので、論理行ごとに「連結した本文の中の開始位置 → 行番号」を
#   OFFS に残し、連結した本文で見つけた位置を行番号へ戻す（lineof）。出力: path<TAB>開始位置<TAB>行番号
FLAT="$TMPD/flat.tsv"
OFFS="$TMPD/offs.tsv"
ensure_flat() {
  [ -f "$FLAT" ] && return 0
  ensure_lex
  awk -F '\t' -v offs="$OFFS" '
    $1 != pf { if (pf != "") print pf "\t" acc; pf = $1; acc = "" }
    { t = $3; gsub(/[ \t]+/, " ", t); print $1 "\t" (length(acc) + 2) "\t" $2 > offs; acc = acc " " t }
    END { if (pf != "") print pf "\t" acc; close(offs) }' "$LEX" > "$FLAT"
  [ -f "$OFFS" ] || : > "$OFFS"
}
# OFFS を読み込む awk の部品（FILENAME == OFFS の行で呼ぶ）と、位置 → 行番号の変換（二分探索）
AWK_LINEOF='
  function addoff(file, p, l) { on[file]++; op[file, on[file]] = p; ol[file, on[file]] = l }
  function lineof(file, p,   lo, hi, mid) {
    lo = 1; hi = on[file]; if (hi < 1) return 0
    while (lo < hi) { mid = int((lo + hi + 1) / 2); if (op[file, mid] <= p) lo = mid; else hi = mid - 1 }
    return ol[file, lo]
  }'
# SQL の表の参照を拾う awk の部品（COBOL の EXEC SQL と JCL の入力データの SQL で共用する）
#   sqltables(文, 種別, 場所, 経路, 付記): 表ごとに「種別<TAB>表名<TAB>場所<TAB>経路<TAB>付記」を出す。文はリテラルを伏せておく
# 【FROM は表の前置詞とは限らない】EXTRACT(YEAR FROM ...)・TRIM(LEADING ... FROM 列)・SUBSTRING(... FROM ...) の FROM は
#   関数の引数の区切り。SELECT を含まない括弧の中身を内側から消してから探す（副問い合わせの括弧は残す）。
# 【別名】省略でき、AS も付けられ、カンマの前後の空白も省略できる（`FROM T1 X, T2 Y` / `FROM T1 AS X, T2` / `FROM T1,T2`）。
#   LOCK TABLE も表の参照。FOR UPDATE OF の列・CURRENT OF のカーソル・ホスト変数・システム表・`-` を含む名前は表ではない。
AWK_SQLTABLES='
  function sqltables(blk, kind, where, how, note,   b, m, n, k, pp, c, q, g, r) {
    while (match(blk, /\([^()]*\)/)) { g = substr(blk, RSTART + 1, RLENGTH - 2)
      # 表を囲む括弧（副問い合わせ・括弧で囲んだ結合・FINAL TABLE (INSERT ...)）は残す
      r = (g ~ /(^|[^A-Z0-9_-])(SELECT|INSERT|UPDATE|DELETE|JOIN)([^A-Z0-9_-]|$)/) ? "\001" g "\002" : " "
      blk = substr(blk, 1, RSTART - 1) r substr(blk, RSTART + RLENGTH) }
    gsub(/\001/, "(", blk); gsub(/\002/, ")", blk)
    gsub(/FOR +UPDATE( +OF +[^ ]+)?/, " ", blk); gsub(/CURRENT +OF +[^ ]+/, " ", blk)
    # データ変更の結果表（`FROM FINAL TABLE (INSERT INTO T ...)`）: 表は括弧の中の INSERT / UPDATE / DELETE の側にある
    gsub(/(FINAL|NEW|OLD) +TABLE/, " ", blk)
    b = " " blk
    # 括弧で囲んだ結合（`FROM (T1 X JOIN T2 Y ON ...)`）の先頭の表も拾う（`FROM (SELECT` は下で SELECT として捨てる）
    while (match(b, /[^A-Z0-9_-](FROM|JOIN|INTO|UPDATE|DELETE +FROM|LOCK +TABLE) +(\( *)?[^ ,();]+/)) {
      m = substr(b, RSTART + 1, RLENGTH - 1); b = substr(b, RSTART + RLENGTH)
      n = m; sub(/^(DELETE +FROM|LOCK +TABLE|[A-Z]+) +/, "", n); sub(/^\( */, "", n)
      # DB2 の表名に `-` は使えない（`-` を含むのは COBOL の項目名・カーソル名）
      if (n ~ /^[:(&{<]/ || n ~ /^(SELECT|WHERE|SET|VALUES|TABLE|INSERT|UPDATE|DELETE)$/ || n ~ /-/) continue
      k = split(n, pp, "."); q = (k > 1) ? pp[k - 1] : ""
      if (q == "SYSIBM" || pp[k] ~ /^SYSDUMMY/) continue
      print kind "\t" pp[k] "\t" where "\t" how "\t" note
      if (m ~ /^FROM /) {
        while (match(b, /^ *(AS +)?([A-Z][A-Z0-9_]*)? *, *[^ ,();]+/)) { c = substr(b, RSTART, RLENGTH); b = substr(b, RSTART + RLENGTH)
          sub(/^.*, */, "", c); if (c ~ /^[:(&{<]/) break; k = split(c, pp, "."); print kind "\t" pp[k] "\t" where "\t" how "\t" note }
      }
    }
  }'

# 項目名 → リテラルの値（ファイルごと・複数可）。CICS の FILE(項目名) / PROGRAM(項目名) / TRANSID(項目名) を値に解決する。
#   系統: ① VALUE 句（`05 LIT-FILE PIC X(8) VALUE 'ACCTDAT'`）② MOVE 文（`MOVE 'COACTVWC' TO CDEMO-TO-PROGRAM`）
#   COPY した登録集の値も引く（実測 CardDemo: ファイル名・画面名の多くが VALUE 経由、画面遷移の XCTL は MOVE 経由。落とし穴 9）。
#   出力: path<TAB>項目名<TAB>値<TAB>VALUE|MOVE
VALS="$TMPD/vals.tsv"
COPIES="$TMPD/copies.tsv"
ensure_vals() {
  [ -f "$VALS" ] && return 0
  ensure_flat
  awk -F '\t' -v sq="'" '
    {
      s = $2
      # 書き方の揺れ: `PIC X(8)` / `PIC XXXXXXXX` / `PIC IS X(8)` / `VALUE IS` / PIC を省いて VALUE だけ（PIC は VALUE の後に書いてもよい）
      while (match(s, /(^|[^A-Z0-9-])[0-9][0-9]? +[A-Z0-9][A-Z0-9-]*( +PIC(TURE)?( +IS)? +X+ *(\( *[0-9]+ *\))?)? +VALUE( +IS)? +["\047][^"\047]*["\047]/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/^[^0-9]*[0-9][0-9]? +/, "", m); name = m; sub(/ .*$/, "", name)
        v = m; sub(/^.* VALUE( +IS)? +["\047]/, "", v); sub(/["\047]$/, "", v); gsub(/ +$/, "", v)
        if (v != "") print $1 "\t" name "\t" v "\tVALUE"
      }
      s = $2
      while (match(s, /(^|[^A-Z0-9-])MOVE +["\047][A-Z0-9#@$-]+ *["\047] +TO +[A-Z0-9][A-Z0-9-]*/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        v = m; sub(/^.*MOVE +["\047]/, "", v); sub(/ *["\047].*$/, "", v)
        name = m; sub(/^.* TO +/, "", name)
        if (v != "") print $1 "\t" name "\t" v "\tMOVE"
      }
      # 項目から項目への MOVE（`MOVE LIT-MENUPGM TO CDEMO-TO-PROGRAM`）: 1 段だけ辿るために記録する
      s = $2
      while (match(s, /(^|[^A-Z0-9-])MOVE +[A-Z][A-Z0-9-]* +TO +[A-Z0-9][A-Z0-9-]*/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        v = m; sub(/^.*MOVE +/, "", v); sub(/ .*$/, "", v)
        name = m; sub(/^.* TO +/, "", name)
        if (v !~ /^(SPACES?|ZEROE?S?|LOW-VALUES?|HIGH-VALUES?|ALL|FUNCTION|CORR|CORRESPONDING)$/) print $1 "\t" name "\t" v "\tMOVEVAR"
      }
    }' "$FLAT" | sort -u > "$VALS"
  # COPY <名前> と EXEC SQL INCLUDE <名前>: path<TAB>登録集名
  awk -F '\t' '
    { s = $2
      while (match(s, /(^|[^A-Z0-9-])COPY +[A-Z0-9#@$-]+/)) { m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); sub(/^.*COPY +/, "", m); print $1 "\t" m }
      s = $2
      while (match(s, /EXEC +SQL +INCLUDE +[A-Z0-9#@$-]+/)) { m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); sub(/^.*INCLUDE +/, "", m); print $1 "\t" m }
    }' "$FLAT" > "$COPIES"
}

# -----------------------------------------------------------------------------
# コード側の参照（COBOL）: 種別<TAB>名前<TAB>path<TAB>経路（lit|resolved|var）<TAB>付記
#   program   : CALL 'X' / CALL 項目 / EXEC CICS LINK|XCTL|LOAD PROGRAM(...)
#   transid   : EXEC CICS RETURN|START TRANSID(...)
#   map/mapset: EXEC CICS SEND|RECEIVE MAP(...) MAPSET(...)
#   cicsfile  : EXEC CICS ... FILE(...) / DATASET(...)
#   table     : EXEC SQL の FROM / JOIN / INTO / UPDATE / DELETE FROM（ホスト変数・FOR UPDATE OF・CURRENT OF を除く）
#   tabledef  : EXEC SQL DECLARE <表> TABLE（DCLGEN。定義側）
# 【語の境界に `-` を含める】COBOL の語は `-` を含む。`WS-CALL IF ...` を CALL 文と読まない（実測 CardDemo で混入。落とし穴 5）。
# 【文字列の中の CALL は文ではない】`DISPLAY 'CALL FAILED'` を CALL 文と読まない（実測 CardDemo で FAILED / FAIL が混入）。
#   項目名で呼ぶ CALL は、リテラルを伏せた本文で探す。
# 【変数は値の候補すべてに解決する】MOVE で何通りもの値が入る項目（画面遷移の XCTL 先）は、候補の値ごとに 1 行出す。
#   表（OCCURS）の要素経由（`PROGRAM(OPT-PGMNAME(WS-OPTION))`）は静的に決まらないので var として残す。
# -----------------------------------------------------------------------------
REFS="$TMPD/refs.tsv"
ensure_refs() {
  [ -f "$REFS" ] && return 0
  ensure_vals
  # 登録集名 → ファイル（拡張子を除いた名前。大文字）
  list_files "${COBOL_GLOBS[@]}" | awk '{ n = $0; sub(/^.*\//, "", n); sub(/\.[^.]*$/, "", n); print toupper(n) "\t" $0 }' > "$TMPD/cpyfile.tsv"
  awk -F '\t' -v valsf="$VALS" -v copf="$COPIES" -v cpyf="$TMPD/cpyfile.tsv" -v offsf="$OFFS" -v sq="'" "$AWK_LINEOF$AWK_SQLTABLES"'
    FILENAME == offsf { addoff($1, $2 + 0, $3); next }
    # 【配列を参照するだけで要素ができる】val[k] を先に読むと空の要素ができ、先頭に空の値が入る。存在を先に確かめる
    FILENAME == valsf {
      if ($4 == "MOVEVAR") { k = $1 SUBSEP $2; ali[k] = (k in ali) ? ali[k] SUBSEP $3 : $3; next }
      k = $1 SUBSEP $2; if (!(k in val)) val[k] = $3; else if (index(SUBSEP val[k] SUBSEP, SUBSEP $3 SUBSEP) == 0) val[k] = val[k] SUBSEP $3; next }
    FILENAME == copf { cop[$1] = cop[$1] SUBSEP $2; next }
    FILENAME == cpyf { if (!($1 in cpy)) cpy[$1] = $2; next }
    function direct(file, name,   n, a, i, cf, r) {
      r = ((file SUBSEP name) in val) ? val[file SUBSEP name] : ""
      n = split(cop[file], a, SUBSEP)
      for (i = 2; i <= n; i++) { cf = cpy[a[i]]; if (cf != "" && ((cf SUBSEP name) in val)) r = (r == "") ? val[cf SUBSEP name] : r SUBSEP val[cf SUBSEP name] }
      return r
    }
    # 値の候補: 自分の VALUE / MOVE のリテラル ＋ 自分へ MOVE された項目の VALUE / MOVE のリテラル（1 段だけ）
    function lookup(file, name,   r, n, a, i, v) {
      r = direct(file, name)
      if ((file SUBSEP name) in ali) {
        n = split(ali[file SUBSEP name], a, SUBSEP)
        for (i = 1; i <= n; i++) { v = direct(file, a[i]); if (v != "") r = (r == "") ? v : r SUBSEP v }
      }
      return r
    }
    # 場所（at）は path:line。値の解決（lookup）はファイル単位
    function emit(kind, raw, file, note,   q, v, n, k, vv, j) {
      q = (raw ~ /^["\047]/); n = raw; gsub(/["\047]/, "", n); gsub(/^ +| +$/, "", n)
      if (n == "") return
      if (q) { print kind "\t" n "\t" at "\tlit\t" note; return }
      if (n ~ /\(/) { print kind "\t" n "\t" at "\tvar\t" note " (表の要素)"; return }
      v = lookup(file, n)
      if (v == "") { print kind "\t" n "\t" at "\tvar\t" note; return }
      k = split(v, vv, SUBSEP)
      for (j = 1; j <= k; j++) if (!((n SUBSEP vv[j]) in done)) { done[n SUBSEP vv[j]] = 1; print kind "\t" vv[j] "\t" at "\tresolved\t" note " via " n }
      delete done
    }
    function opt(blk, key,   r) {
      # blk の中の KEY ( 値 ) を返す（無ければ空）。値の中の括弧（表の添字）は 1 段まで許す
      if (!match(blk, "(^|[^A-Z0-9-])" key " *\\( *([^()]|\\([^()]*\\))*\\)")) return ""
      r = substr(blk, RSTART, RLENGTH); sub(/^[^(]*\( */, "", r); sub(/ *\)$/, "", r); return r
    }
    # 【伏せても長さを変えない】リテラルの中身を同じ長さの x に置き換える。長さが変わると、伏せた本文で見つけた位置で
    #   原文を切り出せない（EXEC CICS の値を原文から取るため）
    function mask(str,   out, re, m) {
      out = ""; re = "\"[^\"]*\"|" sq "[^" sq "]*" sq
      while (match(str, re)) {
        m = substr(str, RSTART + 1, RLENGTH - 2); gsub(/./, "x", m)
        out = out substr(str, 1, RSTART) m substr(str, RSTART + RLENGTH - 1, 1); str = substr(str, RSTART + RLENGTH)
      }
      return out str
    }
    FILENAME == ARGV[5] {
      file = $1; s = $2
      masked = mask(s)
      # CALL: 位置はリテラルを伏せた本文で決め（文字列の中の CALL を文と読まない）、リテラルの名前は原文から取る
      #   EXEC SQL の中の CALL（DB2 のストアドプロシージャの呼び出し）はプログラムの CALL ではないので、SQL の中を伏せてから探す
      nosql = masked; p0 = 1
      while (match(substr(nosql, p0), /EXEC +SQL /)) { a = p0 + RSTART - 1; e = index(substr(nosql, a), "END-EXEC"); if (e == 0) e = length(nosql) - a + 2
        m = substr(nosql, a, e - 1); gsub(/./, "x", m); nosql = substr(nosql, 1, a - 1) m substr(nosql, a + e - 1); p0 = a + e - 1 }
      pos = 1
      while (match(substr(nosql, pos), /(^|[^A-Z0-9-])CALL +(["\047][^"\047]+["\047]|[A-Z0-9][A-Z0-9-]*)/)) {
        a = pos + RSTART - 1; L = RLENGTH; pos = a + L
        m = substr(s, a, L); sub(/^[^"\047]*CALL +/, "", m)
        at = file ":" lineof(file, a + (substr(masked, a, 1) !~ /[A-Z0-9-]/)); emit("program", m, file, "CALL")
      }
      # EXEC CICS ... END-EXEC（ブロックの位置はリテラルを伏せた本文で決め、値は原文から取る）
      pos = 1
      while (1) {
        t = substr(masked, pos)
        if (!match(t, /EXEC +CICS +/)) break
        ex = pos + RSTART - 1; st = pos + RSTART + RLENGTH - 1; e = index(substr(masked, st), "END-EXEC"); if (e == 0) e = length(masked) - st + 2
        blk = " " substr(s, st, e - 1); pos = st + e - 1; at = file ":" lineof(file, ex)
        if (blk ~ /^ *(LINK|XCTL|LOAD)([^A-Z0-9-]|$)/) { v = opt(blk, "PROGRAM"); if (v != "") emit("program", v, file, "CICS") }
        if (blk ~ /^ *(RETURN|START)([^A-Z0-9-]|$)/) { v = opt(blk, "TRANSID"); if (v != "") emit("transid", v, file, "CICS") }
        if (blk ~ /^ *(SEND|RECEIVE) +MAP([^A-Z0-9-]|$)/) {
          v = opt(blk, "MAP"); if (v != "") emit("map", v, file, "CICS")
          v = opt(blk, "MAPSET"); if (v != "") emit("mapset", v, file, "CICS") }
        v = opt(blk, "FILE"); if (v == "") v = opt(blk, "DATASET")
        if (v != "") emit("cicsfile", v, file, "CICS")
      }
      # EXEC SQL ... END-EXEC
      pos = 1
      while (1) {
        t = substr(masked, pos)
        if (!match(t, /EXEC +SQL +/)) break
        ex = pos + RSTART - 1; st = pos + RSTART + RLENGTH - 1; e = index(substr(masked, st), "END-EXEC"); if (e == 0) e = length(masked) - st + 2
        blk = " " substr(masked, st, e - 1) " "; pos = st + e - 1
        at = file ":" lineof(file, ex)
        if (match(blk, /^ *DECLARE +[^ ]+ +TABLE/)) { d = substr(blk, RSTART, RLENGTH); sub(/^ *DECLARE +/, "", d); sub(/ +TABLE$/, "", d)
          k = split(d, pp, "."); print "tabledef\t" pp[k] "\t" at "\tdclgen\tDECLARE TABLE"; continue }
        if (blk ~ /^ *INCLUDE /) continue
        # 【カーソル操作の FROM は表ではない】FETCH FROM <カーソル> / OPEN / CLOSE（実測 Bank-of-Z: ACC-CURSOR が表に混入）
        if (blk ~ /^ *(FETCH|OPEN|CLOSE)( |$)/) continue
        sqltables(blk, "table", at, "lit", "SQL")
      }
    }' "$OFFS" "$VALS" "$COPIES" "$TMPD/cpyfile.tsv" "$FLAT" > "$REFS"
}

# -----------------------------------------------------------------------------
# 定義側: 種別<TAB>名前<TAB>path<TAB>形式<TAB>付記
#   program   : PROGRAM-ID（ソース）
#   transaction / tranprog / csdprog / csdmapset / csdfile : CICS 資源定義（CSD の抜き出し・DFHCSDUP の入力・YAML）
#   job / jclpgm / jcldd : JCL（JOB 文・EXEC PGM=・DD DSN=）
#   map / mapset : BMS（DFHMDI / DFHMSD）
#   tabledef  : DDL の CREATE TABLE
# 【資源定義の置き場所は対象ごとに違う】実測: CardDemo は `.csd`、GenApp は JCL の DFHCSDUP 入力、Bank-of-Z は YAML
#   （`- transaction:` の下に `name:` / `program:`）。どれか 1 つの形式だけを見ると、他の 2 件では定義が 0 件に見える（落とし穴 6）。
# -----------------------------------------------------------------------------
DEFS="$TMPD/defs.tsv"
# 【ファイルごとにプロセスを起こさない】1 ファイルずつ tr | awk を起動すると、Windows（Git Bash）では
#   プロセス起動だけで数分かかる（実測 CardDemo: 定義側の走査が 327 秒）。種類ごとに awk を 1 回だけ起動し、
#   ファイル一覧を読んで getline で開く。
ensure_defs() {
  [ -f "$DEFS" ] && return 0
  ensure_flat
  list_files "${DEF_GLOBS[@]}" > "$TMPD/def.list"
  list_files "${JCL_GLOBS[@]}" > "$TMPD/jcl.list"
  list_files '*.bms' > "$TMPD/bms.list"
  list_files "${DDL_GLOBS[@]}" > "$TMPD/ddl.list"
  {
    # PROGRAM-ID
    awk -F '\t' -v offsf="$OFFS" "$AWK_LINEOF"'
      FILENAME == offsf { addoff($1, $2 + 0, $3); next }
      { s = $2; pos = 1
        while (match(substr(s, pos), /(^|[^A-Z0-9-])PROGRAM-ID\.? +["\047]?[A-Z0-9#@$-]+/)) { a = pos + RSTART - 1; m = substr(s, a, RLENGTH); pos = a + RLENGTH
          sub(/^.*PROGRAM-ID\.? +["\047]?/, "", m); print "program\t" m "\t" $1 ":" lineof($1, a + (substr(s, a, 1) !~ /[A-Z0-9-]/)) "\tsource\tPROGRAM-ID" } }' "$OFFS" "$FLAT"
    # CICS 資源定義（DEFINE 形式: CSD の抜き出し・DFHCSDUP の入力）と YAML
    awk '
      function arg(s, key,   r) { if (!match(s, "(^|[^A-Z])" key " *\\( *[^) ]+")) return ""; r = substr(s, RSTART, RLENGTH); sub(/^.*\( */, "", r); return r }
      function flushdef(   t, v, p) {
        if (cur == "") return
        t = cur; cur = ""
        if (t ~ /DEFINE +TRANS(ACTION)? *\(/) { v = arg(t, "TRANS(ACTION)?"); p = arg(t, "PROG(RAM)?")
          print "transaction\t" v "\t" f ":" curln "\tdefine\t" p; if (p != "") print "tranprog\t" p "\t" f ":" curln "\tdefine\t" v }
        else if (t ~ /DEFINE +PROG(RAM)? *\(/) print "csdprog\t" arg(t, "PROG(RAM)?") "\t" f ":" curln "\tdefine\t"
        else if (t ~ /DEFINE +MAPSET *\(/) print "csdmapset\t" arg(t, "MAPSET") "\t" f ":" curln "\tdefine\t"
        else if (t ~ /DEFINE +FILE *\(/) print "csdfile\t" arg(t, "FILE") "\t" f ":" curln "\tdefine\t"
      }
      function yflush() {
        if (yk != "" && yname != "") {
          if (yk == "TRANSACTION") { print "transaction\t" yname "\t" f ":" yln "\tyaml\t" yprog; if (yprog != "") print "tranprog\t" yprog "\t" f ":" yln "\tyaml\t" yname }
          else if (yk == "PROGRAM") print "csdprog\t" yname "\t" f ":" yln "\tyaml\t"
          else if (yk == "FILE") print "csdfile\t" yname "\t" f ":" yln "\tyaml\t"
          else if (yk == "MAPSET") print "csdmapset\t" yname "\t" f ":" yln "\tyaml\t"
        }
        yk = ""; yname = ""; yprog = ""
      }
      # 【YAML の注釈は空白の後の #】名前に # を含むトランザクション（実測 Bank-of-Z: CDT#）を # で切らない
      function yval(u,   v) { v = u; sub(/^[ \t]+[A-Z]+:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/["\047]/, "", v); sub(/[ \t].*$/, "", v); return v }
      {
        f = $0; ln = 0; cur = ""; yk = ""
        while ((getline line < f) > 0) {
          ln++; sub(/\r$/, "", line); u = toupper(line)
          # DFHCSDUP の入力・CSD の抜き出しは 1 桁目が * の行が注釈（注釈にした古い DEFINE を数えない）
          if (u ~ /^\*/) continue
          # DEFINE 形式: 1 つの定義は次の DEFINE（か空行・JCL 文）まで続く
          if (u ~ /(^|[^A-Z])DEFINE +(TRANS(ACTION)?|PROG(RAM)?|MAPSET|FILE) *\(/) { flushdef(); cur = u; curln = ln; continue }
          if (cur != "") { if (u ~ /^\/\// || u ~ /^\/\*/ || u ~ /^[ \t]*$/ || u ~ /(^|[^A-Z])(DEFINE|ADD|LIST|ALTER) /) flushdef(); else { cur = cur " " u; continue } }
          # YAML
          if (u ~ /^[ \t]*-[ \t]*(TRANSACTION|PROGRAM|FILE|MAPSET):[ \t]*$/) { yflush(); yk = u; sub(/^[ \t]*-[ \t]*/, "", yk); sub(/:.*$/, "", yk); yind = index(line, "-"); yln = ln; continue }
          if (yk != "") {
            if (match(line, /[^ \t]/) && RSTART <= yind) yflush()
            else { if (u ~ /^[ \t]+NAME:/) yname = yval(u); if (u ~ /^[ \t]+PROGRAM:/) yprog = yval(u) }
          }
        }
        flushdef(); yflush(); close(f)
      }' "$TMPD/def.list"
    # JCL: JOB 文・EXEC PGM=・DD DSN=（//* は注釈。テンプレートの {{ }} / <...> / &記号 はそのまま）
    awk "$AWK_SQLTABLES"'
      # 【JCL の入力データ（DD *）の SQL も表の参照】DB2 のアンロード・バッチ SQL（DSNTIAUL / DSNTEP2 等）は SQL を JCL に書く
      #   （実測 CardDemo: TRANSACTION_TYPE_CATEGORY は JCL の入力データからしか参照されず、COBOL だけを見ると死蔵に見えた。落とし穴 13）
      function sqlrefs(s, where) { gsub(sq "[^" sq "]*" sq, " ", s); sqltables(s, "jclsql", where, "jcl", "") }
      BEGIN { sq = sprintf("%c", 39) }
      {
        f = $0; ln = 0; job = ""; step = ""; inst = 0; sqlstep = 0; indd = 0; dd = ""
        while ((getline line < f) > 0) {
          ln++; sub(/\r$/, "", line); u = toupper(line)
          if (inst) {
            if (u ~ /^\/\*/ || u ~ /^\/\//) { inst = 0; if (sqlstep) sqlrefs(ibuf, f ":" iln) }
            else { if (u !~ /^[ \t]*(\*|--)/) ibuf = ibuf " " substr(u, 1, 72); continue }
          }
          if (u ~ /^\/\/\*/) continue
          # 入力データを SQL として読むのは DB2 の SQL を流すステップだけ（TSO バッチ IKJEFT*・DSN の実行・ユーティリティ）。
          #   DFHCSDUP・IDCAMS・IMS のコマンド・SORT の制御文は SQL ではない（実測: IMS の UPDATE DB ／ CSD 定義の注釈が表に化けた）
          if (u ~ /^\/\/[^ ]* +DD +(\*|DATA)( |,|$)/) { inst = 1; ibuf = ""; iln = ln + 1 }
          if (u ~ /^\/\/[^ ]+ +JOB( |,|$)/) { j = u; sub(/^\/\//, "", j); sub(/ .*$/, "", j); print "job\t" j "\t" f ":" ln "\tjcl\t"; job = j; indd = 0; continue }
          if (u ~ /^\/\/[^ ]* +EXEC +/) {
            st = u; sub(/^\/\//, "", st); sub(/ .*$/, "", st); step = st; p = ""
            if (match(u, /EXEC +PGM=[^ ,]+/)) { p = substr(u, RSTART, RLENGTH); sub(/^EXEC +PGM=/, "", p); print "jclpgm\t" p "\t" f ":" ln "\tjcl\t" job "." step }
            else if (match(u, /EXEC +(PROC=)?[^ ,=]+/)) { p = substr(u, RSTART, RLENGTH); sub(/^EXEC +(PROC=)?/, "", p); print "jclproc\t" p "\t" f ":" ln "\tjcl\t" job "." step }
            sqlstep = (p ~ /^(IKJEFT|DSN|ADU)/); indd = 0
            continue }
          # 【DD 文は 1 行とは限らない】DSN= が継続行にある形（`//IN1 DD DISP=SHR,` の次行に `//    DSN=...`）と、
          #   名前欄が空の連結 DD（`//        DD DSN=...`。直前の DD 名に連結される）がある（実測: データセットの行が CardDemo 165 → 344・Bank-of-Z 119 → 201。落とし穴 19）。
          #   DD 文の続き（名前欄が空で、最初の語が文の種類でない行）の中で最初の DSN= を、その DD 文のデータセットとする
          if (u ~ /^\/\/[^ ]+ +DD( |$)/ || u ~ /^\/\/ +DD( |$)/) {
            if (u ~ /^\/\/[^ ]/) { dd = u; sub(/^\/\//, "", dd); sub(/ .*$/, "", dd) }
            indd = 1 }
          else if (indd && u ~ /^\/\/ +[^ ]/) { w = u; sub(/^\/\/ +/, "", w); sub(/ .*$/, "", w)
            if (w ~ /^(DD|EXEC|JOB|PROC|PEND|IF|THEN|ELSE|ENDIF|SET|INCLUDE|JCLLIB|OUTPUT|CNTL|ENDCNTL)$/) indd = 0 }
          else indd = 0
          if (indd && match(u, /DSN(AME)?=[^ ,]+/)) { d = substr(u, RSTART, RLENGTH); sub(/^DSN(AME)?=/, "", d)
            print "jcldd\t" d "\t" f ":" ln "\tjcl\t" job "." step "." dd; indd = 0 }
        }
        if (inst && sqlstep) sqlrefs(ibuf, f ":" iln)
        close(f)
      }' "$TMPD/jcl.list"
    # BMS
    awk '
      { f = $0; ln = 0
        while ((getline line < f) > 0) {
          ln++; sub(/\r$/, "", line); u = toupper(line)
          if (u ~ /^\*/) continue
          if (u ~ /^[A-Z0-9#@$]+ +DFHMSD( |$)/ && u !~ /TYPE=FINAL/) { n = u; sub(/ .*$/, "", n); print "mapset\t" n "\t" f ":" ln "\tbms\t" }
          if (u ~ /^[A-Z0-9#@$]+ +DFHMDI( |$)/) { n = u; sub(/ .*$/, "", n); print "map\t" n "\t" f ":" ln "\tbms\t" }
        }
        close(f) }' "$TMPD/bms.list"
    # DDL: CREATE TABLE（スキーマ部のテンプレート記号 <DB2DBID> / {{ }} は外して表名だけにする）
    awk '
      { f = $0; ln = 0
        while ((getline line < f) > 0) {
          ln++; sub(/\r$/, "", line); u = toupper(line); sub(/^ *--.*$/, "", u)
          # テンプレートの式（{{ schema }} / <DB2DBID>）は空白を含むことがあるので、名前を切る前に 1 語へ置き換える
          gsub(/\{\{[^}]*\}\}/, "TPL", u); gsub(/<[A-Z0-9_]+>/, "TPL", u)
          while (match(u, /CREATE +TABLE +[^ (]+/)) { t = substr(u, RSTART, RLENGTH); u = substr(u, RSTART + RLENGTH)
            sub(/^CREATE +TABLE +/, "", t); gsub(/"/, "", t); k = split(t, pp, "."); n = pp[k]
            # 表名そのものがテンプレート（CREATE TABLE {{ tbl }}）なら名前は静的に決まらない
            if (n ~ /^[{<&]/ || n == "" || n == "TPL") continue
            print "tabledef\t" n "\t" f ":" ln "\tddl\t" }
        }
        close(f) }' "$TMPD/ddl.list"
  } > "$DEFS"
}

# システム・製品が提供するプログラム（ソースが対象に無いのが正常なもの）の名前の接頭辞。
# 【分類であって除外ではない】mod-diff は「システム提供の疑い」と付記するだけで、件数から黙って落とさない。
SYSPROG_RE='^(DFH|EYU|CEE|IGY|IEW|HEWL|IEB|IEF|IDCAMS|IKJ|DSN|DFS|EQA|EZA|ASMA|SORT|ICE|BPX|IRX|CBLTDLI|AIBTDLI|CSQ|MQ|FTP|SDSF|IGG|CSL|ADR|AMS|IDC|IRR|ICH|CEL|BZU|CBC)'

case "$SUB" in
  mod)
    ensure_defs
    awk -F '\t' '$1 == "program" { s[$2] = 1 } END { for (k in s) n++; print (n ? n : "unknown") }' "$DEFS"
    ;;
  list-mod)
    ensure_defs
    awk -F '\t' '$1 == "program" { print $2 "\t" $3 }' "$DEFS" | sort -u -t "$TAB" -k1,1
    ;;
  mod-diff)
    # 経路A = ソースの PROGRAM-ID / 経路B = 参照（CALL・LINK/XCTL・JCL の EXEC PGM=・トランザクション定義の PROGRAM・DEFINE PROGRAM）
    ensure_defs; ensure_refs
    awk -F '\t' '$1 == "program" { print $2 }' "$DEFS" | sort -u > "$TMPD/ma"
    { awk -F '\t' '$1 == "program" && $4 != "var" { print $2 }' "$REFS"
      awk -F '\t' '$1 == "jclpgm" || $1 == "tranprog" || $1 == "csdprog" { print $2 }' "$DEFS"; } | sort -u > "$TMPD/mb"
    echo "== 経路A（ソースの PROGRAM-ID）$(grep -c . "$TMPD/ma" || true) 件 / 経路B（参照）$(grep -c . "$TMPD/mb" || true) 件 =="
    echo "== ソースのみ（どこからも参照されない: 外部の JCL・スケジューラ・動的 CALL から呼ばれる・死蔵の疑い。人が確認する） =="
    comm -23 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    echo "== 参照のみ（ソースが無い: システム・製品提供／断面外／参照切れ） =="
    comm -13 "$TMPD/ma" "$TMPD/mb" | awk -v re="$SYSPROG_RE" '{ print "  " $0 "\t" (($0 ~ re) ? "（システム・製品提供の疑い）" : "★ソースが断面に無い（断面外か参照切れ）") }'
    echo "== 解決できなかった変数経由の呼び出し（CALL 項目名 / PROGRAM(項目名) で VALUE が見つからない） =="
    awk -F '\t' '$1 == "program" && $4 == "var" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    ;;
  ep)
    # ジョブはメンバー単位で数える。同名のジョブを別メンバーが使い回すので名前では数えない（落とし穴 18）
    ensure_defs
    awk -F '\t' '$1 == "transaction" { t[$2] = 1 } $1 == "job" { j[$3 SUBSEP $2] = 1 } END { for (k in t) n++; for (k in j) n++; print (n ? n : "unknown") }' "$DEFS"
    ;;
  list-ep)
    ensure_defs
    awk -F '\t' '$1 == "transaction" && !seen[$2]++ { print "transaction\t" $2 "\t" $3 "\t" $5 }' "$DEFS"
    awk -F '\t' '$1 == "job" { print "job\t" $2 "\t" $3 }' "$DEFS"
    ;;
  ep-diff)
    # トランザクションの 2 経路: 経路A = 資源定義 / 経路B = コード中の RETURN|START TRANSID（リテラルと VALUE 解決）
    ensure_defs; ensure_refs
    awk -F '\t' '$1 == "transaction" { print $2 }' "$DEFS" | sort -u > "$TMPD/ta"
    awk -F '\t' '$1 == "transid" && $4 != "var" { print $2 }' "$REFS" | sort -u > "$TMPD/tb"
    echo "== 経路A（資源定義のトランザクション）$(grep -c . "$TMPD/ta" || true) 件 / 経路B（コード中の TRANSID）$(grep -c . "$TMPD/tb" || true) 件 =="
    echo "== 定義のみ（端末から入力する開始トランザクション・製品提供・テスト用・死蔵。人が確認する） =="
    comm -23 "$TMPD/ta" "$TMPD/tb" | sed 's/^/  /'
    echo "== コードのみ（★定義が無い: 定義の取りこぼし・断面外） =="
    comm -13 "$TMPD/ta" "$TMPD/tb" | sed 's/^/  /'
    echo "== トランザクション定義の PROGRAM のうちソースが無いもの =="
    awk -F '\t' '$1 == "program" { print $2 }' "$DEFS" | sort -u > "$TMPD/ps"
    awk -F '\t' '$1 == "tranprog" { print $2 "\t" $5 }' "$DEFS" | sort -u | awk -F '\t' -v psf="$TMPD/ps" 'FILENAME == psf { p[$1] = 1; next } !($1 in p) { print "  " $2 " → " $1 }' "$TMPD/ps" -
    echo "== 解決できなかった変数経由の TRANSID =="
    awk -F '\t' '$1 == "transid" && $4 == "var" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    ;;
  screen-diff)
    # 画面の 2 経路: 経路A = BMS の DFHMDI（マップ）/ 経路B = コード中の SEND|RECEIVE MAP（リテラルと VALUE 解決）
    ensure_defs; ensure_refs
    awk -F '\t' '$1 == "map" { print $2 }' "$DEFS" | sort -u > "$TMPD/sa"
    awk -F '\t' '$1 == "map" && $4 != "var" { print $2 }' "$REFS" | sort -u > "$TMPD/sb"
    echo "== 経路A（BMS のマップ）$(grep -c . "$TMPD/sa" || true) 件 / 経路B（コード中の SEND・RECEIVE MAP）$(grep -c . "$TMPD/sb" || true) 件 =="
    echo "== BMS のみ（使われない画面・動的に名前を作る画面） =="
    comm -23 "$TMPD/sa" "$TMPD/sb" | sed 's/^/  /'
    echo "== コードのみ（★BMS が無い: 断面外・参照切れ） =="
    comm -13 "$TMPD/sa" "$TMPD/sb" | sed 's/^/  /'
    echo "== マップセット: BMS / 資源定義（DEFINE MAPSET・YAML）/ コード =="
    awk -F '\t' '$1 == "mapset" { print $2 }' "$DEFS" | sort -u > "$TMPD/m1"
    awk -F '\t' '$1 == "csdmapset" { print $2 }' "$DEFS" | sort -u > "$TMPD/m2"
    awk -F '\t' '$1 == "mapset" && $4 != "var" { print $2 }' "$REFS" | sort -u > "$TMPD/m3"
    echo "  BMS $(grep -c . "$TMPD/m1" || true) / 資源定義 $(grep -c . "$TMPD/m2" || true) / コード $(grep -c . "$TMPD/m3" || true)"
    echo "  資源定義にあって BMS が無い: $(comm -13 "$TMPD/m1" "$TMPD/m2" | tr '\n' ' ')"
    echo "  コードにあって BMS が無い: $(comm -13 "$TMPD/m1" "$TMPD/m3" | tr '\n' ' ')"
    echo "== 解決できなかった変数経由の MAP =="
    awk -F '\t' '$1 == "map" && $4 == "var" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    ;;
  bnd|list-bnd)
    # 経路A: コードが参照するデータ境界（DB2 の表・CICS のファイル）。出力（list-bnd）: 種別<TAB>名前<TAB>最初の場所
    ensure_refs
    ensure_defs
    awk -F '\t' -v mode="$SUB" '$1 == "jclsql" { $1 = "table" }
      ($1 == "table" || $1 == "cicsfile") && $4 != "var" { k = $1 "\t" $2; if (!(k in seen)) { seen[k] = 1; n++; if (mode == "list-bnd") print k "\t" $3 } }
      END { if (mode == "bnd") print (n ? n : "unknown") }' OFS='\t' "$REFS" "$DEFS" | if [ "$SUB" = "list-bnd" ]; then sort; else cat; fi
    ;;
  bnd-schema)
    # 経路B: 定義側（DDL の CREATE TABLE・DCLGEN の DECLARE TABLE・CICS のファイル定義）。出力: 種別<TAB>名前<TAB>形式と場所
    ensure_defs; ensure_refs
    { awk -F '\t' '$1 == "tabledef" { print "table\t" $2 "\t" $4 " " $3 }' "$DEFS" "$REFS"
      awk -F '\t' '$1 == "csdfile" { print "cicsfile\t" $2 "\t" $4 " " $3 }' "$DEFS"; } | sort -u -t "$TAB" -k1,2
    ;;
  bnd-diff)
    bash "$SELF" list-bnd "$SRC" | cut -f1,2 | sort -u > "$TMPD/ba"
    bash "$SELF" bnd-schema "$SRC" | cut -f1,2 | sort -u > "$TMPD/bb"
    echo "== 経路A（コードの参照）$(grep -c . "$TMPD/ba" || true) 件 / 経路B（定義）$(grep -c . "$TMPD/bb" || true) 件 =="
    echo "== 参照のみ（定義が無い: 断面外の DDL・製品の表・別名・抽出の誤り） =="
    comm -23 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    echo "== 定義のみ（コードから参照されない: 死蔵・動的 SQL・別のアプリが使う） =="
    comm -13 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    echo "== 解決できなかった変数経由の FILE =="
    ensure_refs; awk -F '\t' '$1 == "cicsfile" && $4 == "var" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    ;;
  list-calls)
    # 呼び出し元<TAB>呼び出し先<TAB>種類<TAB>場所。元はソースの PROGRAM-ID（1 ファイル 1 プログラムとみなす）・ジョブのステップ
    ensure_defs; ensure_refs
    awk -F '\t' -v defsf="$DEFS" '
      function fp(x) { sub(/:[0-9]+$/, "", x); return x }
      FILENAME == defsf { if ($1 == "program" && !(fp($3) in pg)) pg[fp($3)] = $2; if ($1 == "jclpgm") print $5 "\t" $2 "\tJCL\t" $3; next }
      $1 == "program" { f = fp($3); print ((f in pg) ? pg[f] : f) "\t" $2 "\t" $5 ($4 == "var" ? "（未解決の変数）" : "") "\t" $3 }' "$DEFS" "$REFS" | sort -u
    ;;
  list-dd)
    ensure_defs
    awk -F '\t' '$1 == "jcldd" { print $5 "\t" $2 "\t" $3 }' "$DEFS" | sort
    ;;
  overflow)
    # 73 桁目以降にはみ出たコード（非注釈行）。コンパイラは 72 桁で切るので、書いたとおりには動かない
    #   （実測 Bank-of-Z: IMS のロードプログラム 5 本で UNSTRING の区切り文字の一部が 73 桁目以降にあった。落とし穴 1）
    # 【識別領域の目印と区別する】73〜80 桁は識別領域で、連番以外の文字（変更の目印など）も正当に置かれる
    #   （実測 CardDemo: 縦に並べた 1 文字の目印が 14 行）。次のどちらかだけを報告する:
    #   ① 72 桁目と 73 桁目がどちらも空白でない（語が境界をまたぐ） ② 73 桁目以降に引用符・括弧・ピリオド・等号・カンマがある
    list_files "${COBOL_GLOBS[@]}" > "$TMPD/cob.list"
    #   自由形式のファイルには桁の制限が無いので、ファイルごと対象外にする。タブは字句解析と同じく展開してから桁を数える
    awk -v sq="'" '
      function expand(s,   out, i, c) {
        if (index(s, "\t") == 0) return s
        out = ""
        for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
          if (c == "\t") { do out = out " "; while (length(out) % 8 != 0) } else out = out c }
        return out
      }
      { f = $0; ln = 0
        while ((getline line < f) > 0) { ln++; sub(/\r$/, "", line)
          if (ln <= 5 && toupper(line) ~ />>[ \t]*SOURCE[ \t]+(FORMAT[ \t]+)?(IS[ \t]+)?FREE/) break
          # 【タブの幅はソースから分からない】タブ幅 8 で展開すると 72 桁を越える行がある（実測 CardDemo: 登録集 1 本の 17 行）。
          #   報告はするが、タブを含む行であることを付記する（落とし穴 4）
          tb = (index(line, "\t") > 0); line = expand(line)
          if (length(line) <= 72 || substr(line, 7, 1) ~ /[*\/dD]/ || toupper(line) ~ />>[ \t]*SOURCE/) continue
          a = substr(line, 73, 8)
          if ((substr(line, 72, 1) != " " && substr(a, 1, 1) != " " && a !~ /^[0-9 ]+$/) || index(a, sq) || a ~ /["().=,]/) print f ":" ln "\t" a "\t" (tb ? "（タブを含む行。タブ幅 8 で展開した桁で、元のタブ幅が違えばはみ出していない）" : "")
        }
        close(f) }' "$TMPD/cob.list"
    ;;
  idents-program)
    ensure_defs; awk -F '\t' '$1 == "program" { print $2 }' "$DEFS" | sort -u
    ;;
  idents-transaction)
    ensure_defs; awk -F '\t' '$1 == "transaction" { print $2 }' "$DEFS" | sort -u
    ;;
  idents-map)
    ensure_defs; awk -F '\t' '$1 == "map" || $1 == "mapset" { print $2 }' "$DEFS" | sort -u
    ;;
  idents-table)
    # 表名・CICS のファイル名。DDL が小文字でもコードは大文字のことが多い（実測 GenApp: DDL は `customer`、コードは CUSTOMER）。
    #   COBOL・DB2 は大小を区別しないので大文字で出す（仕様は大文字で書く。G-IDENT は大小を区別する）。
    { bash "$SELF" list-bnd "$SRC" | cut -f2; bash "$SELF" bnd-schema "$SRC" | cut -f2; } | awk '{ print toupper($0) }' | sed '/^$/d' | sort -u
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|screen-diff|mod-diff|bnd-schema|bnd-diff|list-calls|list-dd|overflow|idents-table|idents-program|idents-transaction|idents-map} <source-path>" >&2
    exit 2
    ;;
esac
