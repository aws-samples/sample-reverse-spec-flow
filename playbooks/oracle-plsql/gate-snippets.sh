#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（oracle-plsql / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 入口の 2 経路（パッケージ仕様の公開サブプログラム / パッケージ本体の実装）の要素差分
#   mod-diff              → モジュールの 2 経路（パッケージ仕様・メソッドを持つ型仕様 / パッケージ本体・型本体）の要素差分
#   bnd-schema            → DB 表の経路B（CREATE TABLE / VIEW / MATERIALIZED VIEW）の一覧
#   bnd-diff              → DB 表の 2 経路（PL/SQL と VIEW とトリガーが参照する表 / 定義）の要素差分
#   list-objects          → スクリプトが作るオブジェクトの全数（種類・名前・スキーマ・定義の位置・ラップの有無）
#   list-crud             → ユニット × 表 × 操作（select / insert / update / delete / merge / trigger / view。スクリプトの DML は script）
#   list-calls            → ユニットからパッケージのサブプログラムへの呼び出し（コードグラフのエッジ）
#   list-dynamic          → 動的 SQL（EXECUTE IMMEDIATE / DBMS_SQL / OPEN FOR）の位置と、リテラルなら先頭の語
#   list-jobs             → DBMS_SCHEDULER.CREATE_JOB / DBMS_JOB.SUBMIT のジョブ名と実行内容
#   list-grants           → GRANT（EXECUTE / SELECT 等）。他のスキーマに公開する API の分母
#   list-wrapped          → ラップ（wrapped）されて読めないユニット
#   scope                 → ディレクトリごとの PL/SQL のファイル数（テスト・インストーラー・同梱ライブラリを見つけて SCAN_EXCLUDE を決める）
#   idents-table | idents-package | idents-subprogram | idents-trigger → 識別子の抽出（G-IDENT 用。出典の綴りで出す）
#
# 環境変数（未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む）:
#   SCAN_EXCLUDE : 走査から外すパスの POSIX ERE（`./` 始まりの相対パスに当てる。例: '^\./test/'）。外したものは ADR で処分する
#   PLSQL_GLOBS  : 走査するファイルの -iname パターン（空白区切り）。既定は enumeration.md の前提 1 の拡張子
#
# 実測検証（2026-10-25）: Oracle Database Sample Schemas（HR / CO / OE / SH / PM。SQL*Plus のスクリプト・置換変数・REM の注釈）、
#   utPLSQL v3（パッケージ・型・動的 SQL が多い。テストは文字列の中で PL/SQL を作る）、Alexandria PL/SQL Utility Library（.pks / .pkb の対）。
#   値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う（Shift_JIS / EUC-JP の注釈・文言で awk が行を落とさないように）。
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
[ -n "${SCAN_EXCLUDE+x}" ] || SCAN_EXCLUDE="$(cfg_get SCAN_EXCLUDE)"
[ -n "${PLSQL_GLOBS+x}" ] || PLSQL_GLOBS="$(cfg_get PLSQL_GLOBS)"
export SCAN_EXCLUDE="${SCAN_EXCLUDE:-}"
PLSQL_GLOBS="${PLSQL_GLOBS:-*.sql *.pks *.pkb *.pkg *.pck *.pls *.plb *.spc *.bdy *.prc *.fnc *.trg *.tps *.tpb *.typ *.vw *.tab *.ddl *.seq *.syn}"

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
cd "$SRC" || { echo "unknown"; exit 0; }

# 走査対象のファイル一覧（1 行 1 パス）。VCS 管理領域・SCAN_EXCLUDE を除く。拡張子は大小を区別しない
list_files() {
  local args=() first=1 g
  set -f
  for g in $PLSQL_GLOBS; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$g"); first=0; else args+=(-o -iname "$g"); fi
  done
  set +f
  find . \( -name .git -o -name .svn -o -name CVS -o -name node_modules \) -prune -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort \
    | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; }
}

# 複数のファイルをまとめて読む: stdin = ファイル一覧 → path<TAB>行番号<TAB>行（CR と先頭の BOM を外し、TAB を空白にする。UTF-16 は NUL を落とす）
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
    !($0 in skip) { f = $0; n = 0; while ((getline line < f) > 0) { n++; sub(/\r$/, "", line); gsub(/\t/, " ", line); if (n == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1); print f "\t" n "\t" line } close(f) }' "$u16" "$lst"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tr -d '\000' < "$f" | awk -v f="$f" -v b1="$b16le" -v b2="$b16be" '{ sub(/\r$/, ""); gsub(/\t/, " "); if (NR == 1 && (index($0, b1) == 1 || index($0, b2) == 1)) $0 = substr($0, 3); print f "\t" NR "\t" $0 }'
  done < "$u16"
}

# -----------------------------------------------------------------------------
# 字句解析（落とし穴 1〜4）。注釈（-- と /* */）・文字列（'...' の '' と q'[...]' の引用演算子）・二重引用符の識別子を区別し、
#   SQL*Plus のコマンド行（REM / PROMPT / SET / @ / DEFINE 等）を飛ばし、文を切り出す:
#   ・PL/SQL のユニット（CREATE PACKAGE / PROCEDURE / FUNCTION / TRIGGER / TYPE / JAVA、DECLARE / BEGIN の無名ブロック）は「/」だけの行で終わる
#   ・それ以外の SQL は文の外の「;」で終わる
# 出力:
#   $TMPD/units.tsv : uid  種類  スキーマ  名前  path  行  wrapped(0|1)  見出し（小文字・空白をつめた先頭）
#   $TMPD/ucode.tsv : uid  path  行  文字列を 'S' に置き換えた行  文字列の中身を \001...\002 で残した行
#   $TMPD/stmts.tsv : sid  path  行  文字列を 'S' に置き換えた文（1 行につないだもの）  文字列を残した文
# -----------------------------------------------------------------------------
lex() {
  [ -f "$TMPD/units.tsv" ] && return 0
  list_files > "$TMPD/files.lst"
  : > "$TMPD/units.tsv"; : > "$TMPD/ucode.tsv"; : > "$TMPD/stmts.tsv"
  [ -s "$TMPD/files.lst" ] || return 0
  read_many < "$TMPD/files.lst" | awk -F '\t' -v OFS='\t' -v D="$TMPD" -v sq="'" -v dq='"' '
    function head(   i, h) { h = ""; for (i = 1; i <= nl && length(h) < 400; i++) h = h " " M[i]; h = tolower(h); gsub(/[ ]+/, " ", h); sub(/^ /, "", h); return h }
    function decide(   h) { h = head()
      if (h ~ /^create (or replace )?((non)?editionable )?(package|procedure|function|trigger|type|library|java|and (resolve|compile) )/) return "plsql"
      if (h ~ /^(declare|begin)( |$)/) return "anon"
      return "sql" }
    function pushline(   t) { if (out ~ /[^ ]/ || nl > 0) { nl++; L[nl] = ln; M[nl] = out; R[nl] = raw } out = ""; raw = "" }
    function endstmt(   i, h, kind, sch, nm, w, x, rest, j, txt, rtxt) {
      if (nl == 0) return
      if (mode == "") mode = decide()
      if (mode == "plsql" || mode == "anon") {
        uid++; h = head(); kind = "anonymous"; sch = ""; nm = ""; w = 0
        if (mode == "plsql") {
          x = h; sub(/^create (or replace )?((non)?editionable )?/, "", x)
          if (x ~ /^package body /) { kind = "package body"; sub(/^package body /, "", x) }
          else if (x ~ /^type body /) { kind = "type body"; sub(/^type body /, "", x) }
          else if (x ~ /^and (resolve|compile) java source named /) { kind = "java"; sub(/^and (resolve|compile) java source named /, "", x) }
          else if (match(x, /^(package|procedure|function|trigger|type|library|java source named|java source|java class|java)/)) { kind = substr(x, 1, RLENGTH); x = substr(x, RLENGTH + 2); sub(/ source named$| source$| class$/, "", kind) }
          # 名前（スキーマつき・二重引用符・置換変数 &&owner..name を含む）。綴りは元の文字列から取り直す
          nm = x; sub(/[ (;].*$/, "", nm)
          rest = substr(x, length(nm) + 1); w = (rest ~ /^ wrapped( |$)/) ? 1 : 0
          nm = orig(nm); gsub(dq, "", nm); gsub(/&&?[A-Za-z0-9_]+\.\./, "\001.", nm); gsub(/&&?[A-Za-z0-9_]+\./, "\001.", nm)
          j = 0; for (i = length(nm); i > 0; i--) if (substr(nm, i, 1) == ".") { j = i; break }
          if (j > 0) { sch = substr(nm, 1, j - 1); nm = substr(nm, j + 1) } gsub(/\001/, "&", sch); if (sch == "\001" || sch == "&") sch = "(置換変数)"
        }
        print uid, kind, sch, nm, F, L[1], w, h > (D "/units.tsv")
        for (i = 1; i <= nl; i++) print uid, F, L[i], M[i], R[i] > (D "/ucode.tsv")
      } else {
        sid++; txt = ""; rtxt = ""
        for (i = 1; i <= nl; i++) { txt = txt " " M[i]; rtxt = rtxt " " R[i] }
        if (txt ~ /[^ ;]/) print sid, F, L[1], txt, rtxt > (D "/stmts.tsv")
      }
      nl = 0; mode = ""; delete L; delete M; delete R
    }
    # 元の綴りを見出しの小文字から取り直す: 最初の行群の生の文字列から同じ語を探す
    function orig(w,   i, s, p, lw) { lw = tolower(w); for (i = 1; i <= nl; i++) { s = M[i]; p = index(tolower(s), lw); if (p > 0) return substr(s, p, length(w)) } return w }
    function endfile() { if (instr) { out = out sq "S" sq; raw = raw "\001" sbuf "\002"; instr = 0 } pushline(); endstmt(); inb = 0 }
    $1 != F { if (F != "") endfile(); F = $1; nl = 0; mode = ""; inb = 0; instr = 0; out = ""; raw = ""; skipcont = 0; blanks = 0 }
    { ln = $2; l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l)
      # 【SQL*Plus のコマンドの継続行】行末の「-」で次の行に続く（SET LINESIZE 200 - / EXECUTE dbms_stats...( -）。続きの行も飛ばす（落とし穴 1）
      if (skipcont) { skipcont = (l ~ /-[ ]*$/); next }
      if (!inb && !instr) {
        if (l ~ /^[ ]*\/[ ]*$/) { pushline(); endstmt(); next }
        # 【空行は SQL の文を終える】SQL*Plus の既定（SQLBLANKLINES OFF）では、終端（; か /）の無い SQL の文は空行で入力が終わる。
        #   例のスクリプト（文を ; 無しで並べる）で、次の CREATE が前の文に吸い込まれて数えられなかった（実測 Alexandria の demos。落とし穴 3）。
        #   同じファイルで SET SQLBLANKLINES ON を流した後は空行で切らない
        if (!blanks && l ~ /^[ ]*$/ && nl > 0 && mode != "plsql" && mode != "anon" && decide() == "sql") { endstmt(); next }
        if (l ~ /^[ ]*\.[ ]*$/ && nl > 0 && mode != "plsql" && mode != "anon") { out = ""; raw = ""; nl = 0; delete L; delete M; delete R; next }
        if (nl == 0 && out !~ /[^ ]/ && tolower(l) ~ /^[ ]*set[ ].*sqlbl[a-z]*[ ]+(on|off)/) blanks = (tolower(l) ~ /sqlbl[a-z]*[ ]+on/) ? 1 : 0
        # SQL*Plus のコマンド（文の始まりにだけある）
        if (nl == 0 && out !~ /[^ ]/ && l ~ /-[ ]*$/ && tolower(l) ~ /^[ ]*(set|col|column|exec|execute|host|tti|ttitle|bti|btitle|break|bre|compute|comp|acc|accept|var|variable|def|define)[ ]/) { skipcont = 1; next }
        if (nl == 0 && out !~ /[^ ]/ && tolower(l) ~ /^[ ]*(rem|remark|pro|prom|promp|prompt|set|def|defi|defin|define|undef|undefine|spo|spool|@|start|sta|conn|connect|disc|disconnect|whenever|exit|quit|show|sho|col|column|tti|ttitle|bti|btitle|break|bre|compute|comp|host|pause|acc|accept|var|variable|print|exec|execute|desc|describe|clear|cl|timing|store|repfooter|repheader|sav|save|get|edit|ed|run|r|l|list|xquery|archive|startup|shutdown|recover|attribute|copy|password|passw)([ ;]|$)/) next
        if (nl == 0 && out !~ /[^ ]/ && l ~ /^[ ]*@/) next
        # PL/SQL のユニットで「/」を書かずに次の CREATE が来た（.pks / .pkb を 1 ファイルに並べる書き方）
        #   無名ブロックも、例のスクリプトでは「/」を書かずに次の文を並べる（実測 Alexandria の demos）。
        #   内側の文と取り違えないよう、END; の直後で、行の 1 桁目から始まる CREATE / DECLARE / BEGIN / SELECT 等だけを区切りとみなす
        if (mode == "plsql" && lastend && tolower(l) ~ /^[ ]*create[ ]+(or[ ]+replace[ ]+)?/) { pushline(); endstmt() }
        else if (mode == "anon" && lastend && tolower(l) ~ /^(create|declare|begin|select|insert|update|delete|merge|with|grant|alter|drop|comment)[ ]/) { pushline(); endstmt() }
      }
      n = length(l); i = 1
      while (i <= n) {
        c = substr(l, i, 1)
        if (inb) { e = index(substr(l, i), "*/"); if (!e) { i = n + 1; break } i += e + 1; inb = 0; out = out " "; raw = raw " "; continue }
        if (instr) {
          if (qc == sq) { j = index(substr(l, i), sq)
            if (!j) { sbuf = sbuf substr(l, i) " "; i = n + 1; break }
            if (substr(l, i + j, 1) == sq) { sbuf = sbuf substr(l, i, j); i += j + 1; continue }
            sbuf = sbuf substr(l, i, j - 1); i += j }
          else { j = index(substr(l, i), qc sq)
            if (!j) { sbuf = sbuf substr(l, i) " "; i = n + 1; break }
            sbuf = sbuf substr(l, i, j - 1); i += j + 1 }
          instr = 0; gsub(/[\001\002]/, " ", sbuf); out = out sq "S" sq; raw = raw "\001" sbuf "\002"; continue }
        if (c == "-" && substr(l, i + 1, 1) == "-") break
        if (c == "/" && substr(l, i + 1, 1) == "*") { inb = 1; i += 2; continue }
        if (c == sq) {
          p = substr(out, length(out), 1); pp = (length(out) > 1) ? substr(out, length(out) - 1, 1) : ""
          if ((p == "q" || p == "Q") && (pp == "" || pp !~ /[A-Za-z0-9_$#]/ || pp == "n" || pp == "N")) {
            d = substr(l, i + 1, 1); qc = (d == "[") ? "]" : ((d == "{") ? "}" : ((d == "(") ? ")" : ((d == "<") ? ">" : d)))
            out = substr(out, 1, length(out) - 1); raw = substr(raw, 1, length(raw) - 1); if (pp == "n" || pp == "N") { out = substr(out, 1, length(out) - 1); raw = substr(raw, 1, length(raw) - 1) }
            instr = 1; sbuf = ""; i += 2; continue }
          qc = sq; instr = 1; sbuf = ""; i++; continue }
        if (c == dq) { j = index(substr(l, i + 1), dq); if (j) { out = out substr(l, i, j + 1); raw = raw substr(l, i, j + 1); i += j + 1; continue } }
        if (c == ";") { out = out c; raw = raw c; i++
          if (mode == "") mode = decide2()
          if (mode == "sql") { pushline(); endstmt() }
          continue }
        out = out c; raw = raw c; i++
      }
      # 最後の非空行が END; / END 名前; か（END IF; / END LOOP; / END CASE; は文の中の終わりなので数えない）
      if (!instr) { lo = tolower(out); lastend = (lo ~ /(^|[^a-z0-9_$#])end([ ]+[a-z0-9_$#"]+)?[ ]*;[ ]*$/ && lo !~ /end[ ]+(if|loop|case)[ ]*;[ ]*$/) ? 1 : ((out ~ /[^ ]/) ? 0 : lastend); pushline() }
      else { nl++; L[nl] = ln; M[nl] = out; R[nl] = raw; out = ""; raw = "" }
    }
    # 文の途中（今の行の out をまだ足していない）で種類を決める
    function decide2(   h, i) { h = ""; for (i = 1; i <= nl && length(h) < 400; i++) h = h " " M[i]; h = tolower(h " " out); gsub(/[ ]+/, " ", h); sub(/^ /, "", h)
      if (h ~ /^create (or replace )?((non)?editionable )?(package|procedure|function|trigger|type|library|java|and (resolve|compile) )/) return "plsql"
      if (h ~ /^(declare|begin)( |$)/) return "anon"
      return "sql" }
    END { if (F != "") endfile() }'
}

# -----------------------------------------------------------------------------
# オブジェクトの一覧 → $TMPD/objects.tsv : 種類  スキーマ  名前  path:行  付記（ラップ・同義語の先・トリガーの表 等）  uid または sid
#   ユニット（PL/SQL）と DDL 文（TABLE / GLOBAL TEMPORARY TABLE / VIEW / MATERIALIZED VIEW / SEQUENCE / SYNONYM / INDEX）
# -----------------------------------------------------------------------------
objects_build() {
  [ -f "$TMPD/objects.tsv" ] && return 0
  lex
  {
    awk -F '\t' -v OFS='\t' '$2 != "anonymous" {
        note = ($7 == 1) ? "wrapped" : ""
        # INSTEAD OF ... ON NESTED TABLE 列 OF ビュー は、ビューの入れ子の表に付くトリガー（表はビュー）
        if ($2 == "trigger") { h = $8; t = ""
          if (match(h, / on nested table [a-z0-9_$#"]+ of ([a-z0-9_$#"&]+\.)*[a-z0-9_$#"]+/)) { t = substr(h, RSTART, RLENGTH); sub(/^.* of /, "", t); gsub(/"/, "", t); sub(/^.*\./, "", t) }
          else if (match(h, / on ([a-z0-9_$#"&]+\.)*[a-z0-9_$#"]+/)) { t = substr(h, RSTART + 4, RLENGTH - 4); gsub(/"/, "", t); sub(/^.*\./, "", t) }
          if (h ~ / on ([a-z0-9_$#"]+\.)?(database|schema)( |$)/) t = "(" (h ~ / on database/ ? "database" : "schema") ")"; note = note (note == "" ? "" : " ") "on=" t }
        print $2, $3, $4, $5 ":" $6, note, "u" $1 }' "$TMPD/units.tsv"
    awk -F '\t' -v OFS='\t' '
      { h = " " tolower($4); gsub(/[ ]+/, " ", h)
        # EDITIONING VIEW（エディションを使う構成の表の窓口）も読む。MATERIALIZED VIEW LOG はビューではない（落とし穴 4）
        if (!match(h, /^ create (or replace )?(force |noforce )?(editionable |noneditionable )?(editioning )?(public )?(global temporary |private temporary |sharded |duplicated )?(table|view|materialized view|sequence|synonym|index|unique index|bitmap index) /)) next
        k = substr(h, RSTART, RLENGTH); x = substr(h, RSTART + RLENGTH); sub(/^ create (or replace )?(force |noforce )?(editionable |noneditionable )?(editioning )?/, "", k); sub(/ $/, "", k)
        if (k == "materialized view" && x ~ /^log /) next
        if (k ~ /^public synonym/) k = "public synonym"; else if (k ~ /temporary table/) k = "temporary table"; else if (k ~ /index$/) k = "index"; else sub(/^(public |sharded |duplicated )/, "", k)
        if (x ~ /^if not exists /) x = substr(x, 15)
        nm = x; sub(/[ (;,].*$/, "", nm); gsub(/"/, "", nm); gsub(/&&?[a-z0-9_]+\.\./, "\001.", nm); gsub(/&&?[a-z0-9_]+\./, "\001.", nm)
        sch = ""; if (match(nm, /^.*\./)) { sch = substr(nm, 1, RLENGTH - 1); nm = substr(nm, RLENGTH + 1) } if (sch ~ /\001/) sch = "(置換変数)"
        note = ""
        if (k ~ /synonym/) { t = x; if (match(t, / for [a-z0-9_$#".&@]+/)) { t = substr(t, RSTART + 5, RLENGTH - 5); gsub(/"/, "", t); sub(/@.*$/, "", t); sub(/^.*\./, "", t); note = "for=" t } }
        if (k == "index") { t = x; if (match(t, / on [a-z0-9_$#".&]+/)) { t = substr(t, RSTART + 4, RLENGTH - 4); gsub(/"/, "", t); sub(/^.*\./, "", t); note = "on=" t } }
        print k, sch, orig($4, nm), $2 ":" $3, note, "s" $1 }
      # 元の綴りを文から取り直す（キーは小文字。表示は出典の綴り）
      function orig(s, w,   p) { p = index(tolower(s), w); return (p > 0) ? substr(s, p, length(w)) : w }' "$TMPD/stmts.tsv"
    # 【文字列の中の DDL も定義に数える】導入スクリプトは、何度流しても通るように無名ブロックの EXECUTE IMMEDIATE で表を作る
    #   （実測 utPLSQL: ut_coverage_runs・ut_dbms_output_cache 等）。付記に dynamic:anonymous / dynamic:<ユニットの種類> を付ける（落とし穴 5）
    awk -F '\t' -v OFS='\t' '
      FILENAME ~ /units\.tsv$/ { uk[$1] = $2; next }
      { r = $5
        while (match(r, /\001[^\002]*\002/)) { lit = substr(r, RSTART + 1, RLENGTH - 2); r = substr(r, RSTART + RLENGTH)
          h = " " tolower(lit); gsub(/[ \n]+/, " ", h)
          if (!match(h, /^ ?\(? ?create (or replace )?(force |noforce )?(editionable |noneditionable )?(global temporary |private temporary )?(table|view|materialized view|sequence) /)) continue
          k = substr(h, RSTART, RLENGTH); x = substr(h, RSTART + RLENGTH); if (k ~ /temporary/) k = "temporary table"; else if (k ~ /materialized view/) k = "materialized view"; else if (k ~ / view /) k = "view"; else if (k ~ /sequence/) k = "sequence"; else k = "table"
          if (x ~ /^if not exists /) x = substr(x, 15)
          nm = x; sub(/[ (;,].*$/, "", nm); gsub(/"/, "", nm); sch = ""; if (match(nm, /^.*\./)) { sch = substr(nm, 1, RLENGTH - 1); nm = substr(nm, RLENGTH + 1) }
          if (nm == "" || nm ~ /[^a-z0-9_$#]/) continue
          print k, sch, nm, $2 ":" $3, "dynamic:" (uk[$1] == "anonymous" ? "anonymous" : uk[$1]), "u" $1 } }' "$TMPD/units.tsv" "$TMPD/ucode.tsv"
  } > "$TMPD/objects.tsv"
}

# -----------------------------------------------------------------------------
# パッケージ仕様・本体・型のサブプログラム → $TMPD/subs.tsv : 種別(spec|body|tspec|tbody)  パッケージ・型の名前(小文字)  サブプログラム(小文字)  path:行  綴り  procedure|function
#   仕様: (procedure|function) 名前 が出るたびに 1 つ（オーバーロードは別々に数える）。型仕様は member / static / constructor / map / order の付くもの
#   本体: (procedure|function) 名前 の後、次の「;」までに IS / AS があるもの（前方宣言は IS / AS を持たない）。入れ子のサブプログラムも数える
# -----------------------------------------------------------------------------
subs_build() {
  [ -f "$TMPD/subs.tsv" ] && return 0
  lex
  awk -F '\t' -v OFS='\t' '
    FILENAME ~ /units\.tsv$/ { if ($2 == "package" || $2 == "package body" || $2 == "type" || $2 == "type body") { k[$1] = $2; nm[$1] = tolower($4) } next }
    !($1 in k) { next }
    $1 != pu { if (pu != "") flush(); pu = $1; buf = ""; nl = 0 }
    { nl++; LN[nl] = $3; F = $2; t = $4; buf = buf t "\n" }
    function nlc(x) { return gsub(/\n/, "\n", x) }
    function flush(   s, off, ln, m, w, rest, e, kind, lw, first, seg, acc, sk) {
      kind = k[pu]; s = buf; lw = tolower(s); off = 0; first = 1; acc = 0
      while (match(lw, /(^|[^a-z0-9_$#.%])(procedure|function)[ \n]+"?[a-z0-9_$#]+"?/)) {
        m = substr(lw, RSTART, RLENGTH); ln = LN[1 + off + nlc(substr(lw, 1, RSTART))]
        # 【ACCESSIBLE BY (procedure x, function y) の並びは宣言ではない】呼んでよい相手の一覧（12c 以降）。括弧が閉じるまで飛ばす
        seg = substr(lw, 1, RSTART); sk = 0
        if (acc) { if (index(seg, ")") > 0) acc = 0; else sk = 1 }
        if (!sk && seg ~ /accessible[ \n]+by[ \n]*\([^)]*$/) { acc = 1; sk = 1 }
        sb = m; sub(/^[^a-z]*/, "", sb); sub(/[ \n].*$/, "", sb)
        w = m; sub(/^.*(procedure|function)[ \n]+/, "", w); gsub(/"/, "", w)
        sp = substr(s, RSTART + RLENGTH - length(w) - (index(m, "\"") ? 1 : 0), length(w))
        pre = substr(lw, (RSTART > 40 ? RSTART - 40 : 1), (RSTART > 40 ? 40 : RSTART))
        rest = substr(lw, RSTART + RLENGTH); e = index(rest, ";")
        off += nlc(substr(lw, 1, RSTART + RLENGTH - 1)); s = substr(s, RSTART + RLENGTH); lw = substr(lw, RSTART + RLENGTH)
        if (sk) continue
        # 仕様の見出し（create ... package x）自身の「function」等ではないこと（create function は単独のユニットでここに来ない）
        if (kind == "package" || kind == "type") {
          # pre は一致の始まり（function の前の区切りの 1 文字）より前なので、修飾語の後ろに空白が残らないことがある
          if (kind == "type" && pre !~ /(member|static|constructor|map|order)[ \n]*$/) continue
          print (kind == "package" ? "spec" : "tspec"), nm[pu], w, F ":" ln, sp, sb
        } else {
          body = (e > 0) ? substr(rest, 1, e) : rest
          if (body ~ /(^|[^a-z0-9_$#])(is|as)([^a-z0-9_$#]|$)/) print (kind == "package body" ? "body" : "tbody"), nm[pu], w, F ":" ln, sp, sb
        }
      }
    }
    END { if (pu != "") flush() }' "$TMPD/units.tsv" "$TMPD/ucode.tsv" > "$TMPD/subs.tsv"
}

# -----------------------------------------------------------------------------
# DML の参照 → $TMPD/refs.tsv : 表(小文字)  綴り  操作  由来の種類(unit|view|trigger|script|dynamic)  path:行  ユニット(種類:名前)
#   PL/SQL のユニットの文字列の外（静的 SQL）、VIEW の問い合わせ、トリガーの ON の表、スクリプトの DML（script）、
#   動的 SQL のリテラル（dynamic。EXECUTE IMMEDIATE の直後の文字列だけ）
#   【取り違えを外す】EXTRACT(YEAR FROM x)・TRIM('x' FROM y) の FROM、コレクションの .DELETE、FOR UPDATE、WITH 句の名前、関数呼び出し（FROM f(...)）、
#   SELECT ... INTO 変数（落とし穴 6・7）
# -----------------------------------------------------------------------------
AWK_DML='
function nlc(x) { return gsub(/\n/, "\n", x) }
function cte(lw,   s, w) { delete CTE; s = lw
  # 再帰の WITH は列の並びを持つ（with t1 (a, b) as (...)）
  while (match(s, /(with|,)[ \n]+[a-z_][a-z0-9_$#]*[ \n]*(\([^()]*\))?[ \n]+as[ \n]*\(/)) { w = substr(s, RSTART, RLENGTH); sub(/^(with|,)[ \n]+/, "", w); sub(/[ \n(].*$/, "", w); CTE[w] = 1; s = substr(s, RSTART + RLENGTH) } }
# 【MERGE の USING の表・INSERT ALL / FIRST の INTO の表・LOCK TABLE】主の走査（キーワードの直後の名前）では取れない形（落とし穴 7）。
#   USING の後が「(」なら副問い合わせ（中の FROM は主の走査が取る）。JOIN ... USING (列) は MERGE の文の中でないので取らない
function dmlextra(s, lw, org,   off, t, ts, m, nm, sp, ln, pre, rest, op, cons) {
  t = lw; ts = s; off = 0; cons = 0
  while (match(t, /(^|[^a-z0-9_$#.])(using|into|lock[ \n]+table)[ \n]+"?[a-z_][a-z0-9_$#.@"]*/)) {
    m = substr(t, RSTART, RLENGTH); ln = LNb[1 + off + nlc(substr(t, 1, RSTART))]
    pre = substr(lw, 1, cons + RSTART); rest = substr(t, RSTART + RLENGTH); cons += RSTART + RLENGTH - 1
    nm = m; sub(/^.*(using|into|table)[ \n]+/, "", nm); sp = substr(ts, RSTART + RLENGTH - length(nm), length(nm))
    off += nlc(substr(t, 1, RSTART + RLENGTH - 1)); t = substr(t, RSTART + RLENGTH); ts = substr(ts, RSTART + RLENGTH)
    op = ""
    if (m ~ /using/ && pre ~ /merge[ \n]+into[^;]*$/ && rest !~ /^[ \n]*\(/) op = "select"
    if (m ~ /into/ && pre ~ /insert[ \n]+(all|first)[^;]*$/ && pre !~ /(select|bulk[ \n]+collect)[^;]*$/) op = "insert"
    if (m ~ /lock/) op = "lock"
    if (op == "") continue
    gsub(/"/, "", nm); sub(/@.*$/, "", nm); gsub(/"/, "", sp); sub(/@.*$/, "", sp)
    if (nm ~ /\./) { sub(/^.*\./, "", nm); sub(/^.*\./, "", sp) }
    if (nm in CTE || nm ~ /^(select|dual|table|values|with)$/) continue
    emit(nm, sp, op, org, ln)
  }
}
# s = 文字列を 'S' に置き換えた本文（改行つき）。LNb = 行番号の配列（1 始まり）。emit(表, 綴り, 操作, 行)
function dmlscan(s, org,   lw, off, m, kw, nm, sp, op, rest, pre, ln, lst, n, a, i, x, cs) {
  lw = tolower(s); cte(lw); dmlextra(s, lw, org); off = 0
  while (match(lw, /(^|[^a-z0-9_$#.])(insert[ \n]+into|delete[ \n]+from|merge[ \n]+into|delete|update|from|join)[ \n(]+"?[a-z_][a-z0-9_$#.@"]*/)) {
    m = substr(lw, RSTART, RLENGTH); ln = LNb[1 + off + nlc(substr(lw, 1, RSTART))]
    pre = substr(lw, (RSTART > 30 ? RSTART - 30 : 1), (RSTART > 30 ? 30 : RSTART))
    kw = m; sub(/^[^a-z]*/, "", kw); nm = kw; sub(/^(insert[ \n]+into|delete[ \n]+from|merge[ \n]+into|delete|update|from|join)[ \n(]+/, "", nm)
    sp = substr(s, RSTART + RLENGTH - length(nm), length(nm))
    rest = substr(lw, RSTART + RLENGTH)
    off += nlc(substr(lw, 1, RSTART + RLENGTH - 1)); s = substr(s, RSTART + RLENGTH); lw = substr(lw, RSTART + RLENGTH)
    op = (kw ~ /^insert/) ? "insert" : ((kw ~ /^merge/) ? "merge" : ((kw ~ /^delete/) ? "delete" : ((kw ~ /^update/) ? "update" : "select")))
    # DELETE / UPDATE という名前のサブプログラム（PROCEDURE delete (p_conn ...)。実測 Alexandria の ftp_util_pkg）
    if (pre ~ /(procedure|function)[ \n]*$/) continue
    if (op == "update" && (pre ~ /for[ \n]*$/ || rest !~ /^[ \n]*([a-z_][a-z0-9_$#]*[ \n]+)?set[ \n(]/)) continue
    if (op == "delete" && kw !~ /from/ && (rest ~ /^[ \n]*[(;]/)) continue
    if (op == "select" && kw ~ /^from/ && (pre ~ /(year|month|day|hour|minute|second|timezone_hour|timezone_minute|timezone_region|timezone_abbr|both|leading|trailing)[ \n]*$/ || pre ~ /[\047)][ \n]*$/ || pre ~ /(trim|extract)[ \n]*\([^()]*$/)) continue
    # 名前の直後の「(」は関数の呼び出し（FROM f(...)）。INSERT INTO 表 (列, ...) の「(」は列の並びなので外さない
    if (rest ~ /^[ \n]*\(/ && m !~ /\($/ && op != "insert") continue
    gsub(/"/, "", nm); sub(/@.*$/, "", nm); gsub(/"/, "", sp); sub(/@.*$/, "", sp)
    if (nm ~ /\./) { sub(/^.*\./, "", nm); sub(/^.*\./, "", sp) }
    if (nm in CTE) continue
    if (nm ~ /^(dual|table|the|select|lateral|json_table|xmltable|values|with|only|where|set|on|or|of|as|cast|multiset|sys|all|distinct|unique|xmlsequence|s)$/) continue
    emit(nm, sp, op, org, ln)
    if (op == "select" && kw ~ /^from/) { lst = rest; sub(/[ \n](where|group|order|having|union|left|right|inner|outer|full|cross|join|on|for|connect|start|model|minus|except|intersect|fetch|offset|pivot|unpivot|into|bulk)[ \n].*$/, "", lst); sub(/[();].*$/, "", lst)
      n = split(lst, a, ","); for (i = 2; i <= n; i++) { x = a[i]; gsub(/^[ \n]+/, "", x); sub(/[ \n(].*$/, "", x); gsub(/"/, "", x); sub(/@.*$/, "", x); sub(/^.*\./, "", x); if (x ~ /^[a-z_][a-z0-9_$#]*$/ && !(x in CTE) && x !~ /^(dual|table|lateral|json_table|xmltable|the|only|s)$/) emit(x, x, "select", org, ln) } }
  }
}
'

refs_build() {
  [ -f "$TMPD/refs.tsv" ] && return 0
  objects_build
  : > "$TMPD/refs.tsv"
  # PL/SQL のユニット（静的 SQL）と、EXECUTE IMMEDIATE の直後のリテラル（動的 SQL）
  awk -F '\t' -v OFS='\t' -v D="$TMPD" "$AWK_DML"'
    function emit(nm, sp, op, org, ln) { print nm, sp, op, org, F ":" ln, U > (D "/refs.tsv") }
    FILENAME ~ /units\.tsv$/ { uk[$1] = $2 ":" $4; next }
    $1 != pu { if (pu != "") flush(); pu = $1; buf = ""; rbuf = ""; nl = 0 }
    { nl++; LNb[nl] = $3; F = $2; buf = buf $4 "\n"; rbuf = rbuf $5 "\n" }
    function flush(   s, r, ln, off, lit, nlit) { U = uk[pu]; dmlscan(buf, "unit")
      # 動的 SQL のリテラル
      r = rbuf; off = 0
      while (match(tolower(r), /execute[ \n]+immediate[ \n]*\001[^\002]*\002/)) { lit = substr(r, RSTART, RLENGTH); ln = LNb[1 + off + nlc(substr(r, 1, RSTART))]
        off += nlc(substr(r, 1, RSTART + RLENGTH - 1)); r = substr(r, RSTART + RLENGTH)
        sub(/^[^\001]*\001/, "", lit); sub(/\002$/, "", lit); if (tolower(lit) ~ /^[ \n(]*(create|drop|alter|grant|revoke|truncate|comment)[ \n]/) continue
        delete SAVE; for (k in LNb) SAVE[k] = LNb[k]; delete LNb; nlit = split(lit, junk, "\n"); for (k = 1; k <= nlit + 1; k++) LNb[k] = ln + k - 1
        dmlscan(lit, "dynamic"); delete LNb; for (k in SAVE) LNb[k] = SAVE[k] } }
    END { if (pu != "") flush() }' "$TMPD/units.tsv" "$TMPD/ucode.tsv"
  # VIEW の問い合わせ・スクリプトの DML
  awk -F '\t' -v OFS='\t' -v D="$TMPD" "$AWK_DML"'
    function emit(nm, sp, op, org, ln) { print nm, sp, op, org, F ":" ln, U >> (D "/refs.tsv") }
    { F = $2; delete LNb; LNb[1] = $3; h = " " tolower($4); gsub(/[ ]+/, " ", h)
      if (h !~ /^ create materialized view log / && match(h, /^ create (or replace )?(force |noforce )?(editionable |noneditionable )?(editioning )?(materialized )?view [^ ]+/)) { v = substr(h, RSTART, RLENGTH); sub(/^.* view /, "", v); gsub(/"/, "", v); sub(/^.*\./, "", v)
        p = index(h, " as "); if (p > 0) { U = "view:" v; dmlscan(substr($4, p + 3), "view") } next }
      if (h ~ /^ (insert|update|delete|merge)[ ]/) { U = "script"; dmlscan($4, "script") } }' "$TMPD/stmts.tsv"
  # トリガーの ON の表
  awk -F '\t' -v OFS='\t' '$1 == "trigger" && match($5, /on=[^ ]+/) { t = substr($5, RSTART + 3, RLENGTH - 3); if (t !~ /^\(/) print tolower(t), t, "trigger", "trigger", $4, "trigger:" $3 }' "$TMPD/objects.tsv" >> "$TMPD/refs.tsv"
}

# 参照側（経路A）と定義側（経路B）
#   $TMPD/bndA.tsv : キー  綴り  由来の一覧  最初の path:行      （unit / view / trigger の参照。同義語は先に解く。システムの表・WITH の名前は除く）
#   $TMPD/bndB.tsv : キー  綴り  種類  path:行                   （TABLE / VIEW / MATERIALIZED VIEW。一時表は temporary として別に数える）
#   $TMPD/bndX.tsv : キー  綴り  理由  path:行                   （どちらにも入れなかった参照: system / script のみ / dynamic のみ）
bnd_build() {
  [ -f "$TMPD/bndA.tsv" ] && return 0
  refs_build
  awk -F '\t' -v OFS='\t' -v D="$TMPD" '
    FILENAME ~ /objects\.tsv$/ { k = tolower($3)
      if ($1 ~ /synonym/ && $5 ~ /^for=/) { syn[k] = tolower(substr($5, 5)) }
      if ($1 == "table" || $1 == "view" || $1 == "materialized view" || $1 == "temporary table") { if (!(k in def)) { def[k] = $3; dk[k] = $1; dl[k] = $4 } }
      next }
    { k = $1; sp = $2; if (k in syn && !(k in def)) { k = syn[k]; sp = k }
      # データディクショナリ・動的性能ビュー・DBMS / UTL の表・NLS の設定ビュー・APEX のビュー（落とし穴 8）
      # 同じ名前の定義がソースにあれば業務の表（sys_param・role_master 等）として扱う
      if (!(k in def) && (k ~ /^(all_|user_|dba_|cdb_|v\$|gv\$|v_\$|gv_\$|x\$|sys_|dbms_|utl_|nls_|apex_|wwv_|xdb\$|role_)/ || k ~ /^(resource_view|path_view|dictionary|dict|tab|cat|obj|col|global_name|session_privs|session_roles|plan_table|chained_rows)$/)) { sysr[k] = sp; sysl[k] = $5; next }
      if ($4 == "unit" || $4 == "view" || $4 == "trigger") { if (!(k in a)) { a[k] = sp; al[k] = $5 } if (index(" " ao[k] " ", " " $4 " ") == 0) ao[k] = ao[k] (ao[k] == "" ? "" : " ") $4 }
      else { if (!(k in o)) { o[k] = sp; ol[k] = $5 } if (index(" " oo[k] " ", " " $4 " ") == 0) oo[k] = oo[k] (oo[k] == "" ? "" : " ") $4 } }
    END {
      for (k in a) print k, a[k], ao[k], al[k] > (D "/bndA.tsv")
      for (k in def) print k, def[k], dk[k], dl[k] > (D "/bndB.tsv")
      for (k in sysr) print k, sysr[k], "system", sysl[k] > (D "/bndX.tsv")
      for (k in o) if (!(k in a)) print k, o[k], oo[k] " のみ", ol[k] > (D "/bndX.tsv") }' "$TMPD/objects.tsv" "$TMPD/refs.tsv"
  touch "$TMPD/bndA.tsv" "$TMPD/bndB.tsv" "$TMPD/bndX.tsv"
  for f in bndA bndB bndX; do sort -o "$TMPD/$f.tsv" "$TMPD/$f.tsv"; done
}

# 入口 → $TMPD/ep.tsv : 種類(api|procedure|function|trigger|job)  キー  付記  path:行
ep_build() {
  [ -f "$TMPD/ep.tsv" ] && return 0
  objects_build; subs_build; jobs_build
  {
    awk -F '\t' -v OFS='\t' '$1 == "spec" { c[$2 "." $3]++; print "api", $2 "." $3, "#" c[$2 "." $3], $4 }' "$TMPD/subs.tsv"
    awk -F '\t' -v OFS='\t' '$1 == "procedure" || $1 == "function" { print $1, tolower($3), $5, $4 }
      $1 == "trigger" { print "trigger", tolower($3), $5, $4 }' "$TMPD/objects.tsv"
    awk -F '\t' -v OFS='\t' '{ print "job", tolower($1), "action=" $2, $3 }' "$TMPD/jobs.tsv"
  } > "$TMPD/ep.tsv"
}

# ジョブ → $TMPD/jobs.tsv : ジョブ名  実行内容（job_action / what の文字列）  path:行
#   位置で渡す引数（第 1 引数がジョブ名）と名前で渡す引数（job_name => ...）の両方を読む
jobs_build() {
  [ -f "$TMPD/jobs.tsv" ] && return 0
  lex
  { awk -F '\t' '{ print $2 "\t" $3 "\t" $5 }' "$TMPD/ucode.tsv"; awk -F '\t' '{ print $2 "\t" $3 "\t" $5 }' "$TMPD/stmts.tsv"; } | awk -F '\t' -v OFS='\t' '
    function nlc(x) { return gsub(/\n/, "\n", x) }
    $1 != pf { if (pf != "") scan(); pf = $1; buf = ""; n = 0 }
    { n++; LN[n] = $2; buf = buf $3 "\n" }
    function arg(s, k,   t) { t = s; if (match(tolower(t), k "[ \n]*=>[ \n]*\001[^\002]*\002")) { t = substr(t, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", t); sub(/\002$/, "", t); return t } return "" }
    function scan(   s, off, ln, call, nm, act, t) { s = buf; off = 0
      while (match(tolower(s), /dbms_(scheduler[.]create_job|job[.]submit)[ \n]*\(/)) { ln = LN[1 + off + nlc(substr(s, 1, RSTART))]
        call = substr(s, RSTART, 800); off += nlc(substr(s, 1, RSTART + RLENGTH - 1)); s = substr(s, RSTART + RLENGTH)
        sub(/\)[ \n]*;.*$/, "", call)
        if (tolower(call) ~ /^dbms_scheduler/) { nm = arg(call, "job_name"); act = arg(call, "job_action")
          if (nm == "" && match(call, /\(\n*[ \n]*\001[^\002]*\002/)) { t = substr(call, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", t); sub(/\002$/, "", t); nm = t }
          # 位置で渡すとき（CREATE_JOB('名前', 'PLSQL_BLOCK', '実行内容', ...)）は 3 つ目の文字列が job_action
          if (act == "" && call !~ /=>/) { t = call; q = 0; while (match(t, /\001[^\002]*\002/)) { q++; if (q == 3) { act = substr(t, RSTART + 1, RLENGTH - 2); break } t = substr(t, RSTART + RLENGTH) } } }
        else { nm = "(dbms_job)"; act = arg(call, "what"); if (act == "" && match(call, /,[ \n]*\001[^\002]*\002/)) { t = substr(call, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", t); sub(/\002$/, "", t); act = t } }
        gsub(/[\t\n]+/, " ", act); if (nm == "") nm = "(名前が式)"; print nm, act, pf ":" ln } }
    END { if (pf != "") scan() }' > "$TMPD/jobs.tsv"
}

# -----------------------------------------------------------------------------
# サブコマンド
# 【出力は一時ファイルに溜めてから 1 回で出す】Git Bash では読み手（| head）が先に閉じた管に複数のプロセスが書くと止まることがある
# -----------------------------------------------------------------------------
main() {
case "$SUB" in
  ep)
    # 入口 = パッケージ仕様の公開サブプログラム（オーバーロードは別々）＋ 単独の PROCEDURE / FUNCTION ＋ トリガー ＋ ジョブ
    ep_build
    awk 'END { print (NR ? NR : "unknown") }' "$TMPD/ep.tsv"
    ;;
  list-ep)
    ep_build
    sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 "$TMPD/ep.tsv"
    ;;
  ep-diff)
    # 経路A: パッケージ仕様の公開サブプログラム（パッケージ.名前#オーバーロードの番号）。経路B: パッケージ本体の実装（同じ形）
    subs_build; objects_build
    # キー = パッケージ.名前(procedure|function)#その種類の中での順番。種類を入れないと、仕様の function を本体の非公開の procedure と組にして欠落を隠す
    awk -F '\t' '$1 == "spec" { k = $2 "." $3 "(" $6 ")"; c[k]++; print k "#" c[k] }' "$TMPD/subs.tsv" | sort -u > "$TMPD/eA"
    awk -F '\t' '$1 == "body" { k = $2 "." $3 "(" $6 ")"; c[k]++; print k "#" c[k] }' "$TMPD/subs.tsv" | sort -u > "$TMPD/eB"
    awk -F '\t' '$1 == "package body" { print tolower($3) }' "$TMPD/objects.tsv" | sort -u > "$TMPD/hasbody"
    echo "経路A（仕様の公開サブプログラム）: $(wc -l < "$TMPD/eA" | tr -d ' ')"
    echo "経路B（本体の実装）: $(wc -l < "$TMPD/eB" | tr -d ' ')"
    echo "== 経路A のみ（仕様にあるのに本体に実装が無い。本体の無いパッケージ・本体のオーバーロードが少ない・ラップされた本体・外部ルーチンの別） =="
    comm -23 "$TMPD/eA" "$TMPD/eB" | awk -v H="$TMPD/hasbody" 'BEGIN { while ((getline x < H) > 0) hb[x] = 1 }
      { p = $0; sub(/\..*$/, "", p); print "  " $0 "\t" ((p in hb) ? "(本体はある)" : "(本体が無い)") }'
    echo "== 経路B のみ（本体にだけある。非公開のサブプログラム・入れ子のサブプログラム。公開 API ではない） =="
    comm -13 "$TMPD/eA" "$TMPD/eB" | sed 's/^/  /'
    echo "== 単独の PROCEDURE / FUNCTION・トリガー・ジョブ（経路の比較に入らない入口） =="
    ep_build; awk -F '\t' '$1 != "api" { print "  " $1 "\t" $2 "\t" $4 "\t" $3 }' "$TMPD/ep.tsv" | sort
    echo "== 同じ名前のユニットの定義が複数ある（別のスキーマか、作り直しか。スキーマごとに SCAN_EXCLUDE で分けて走査する） =="
    awk -F '\t' '$1 ~ /^(package|package body|procedure|function|trigger|type|type body)$/ { k = $1 " " tolower($3); c[k]++; w[k] = w[k] " " $4 } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/objects.tsv" | sort
    ;;
  mod)
    # モジュール = パッケージ（仕様）＋ メソッドを持つオブジェクト型
    subs_build; objects_build
    { awk -F '\t' '$1 == "package" { print "p " tolower($3) }' "$TMPD/objects.tsv"; awk -F '\t' '$1 == "tspec" { print "t " $2 }' "$TMPD/subs.tsv"; } | sort -u | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-mod)
    subs_build; objects_build
    awk -F '\t' -v OFS='\t' -v S="$TMPD/subs.tsv" '
      BEGIN { while ((getline x < S) > 0) { split(x, a, "\t"); n[a[1] "\t" a[2]]++ } }
      $1 == "package" { print "package", $3, $4, "公開 " n["spec\t" tolower($3)] + 0, $5 }
      $1 == "package body" { print "package body", $3, $4, "実装 " n["body\t" tolower($3)] + 0, $5 }
      $1 == "type" && n["tspec\t" tolower($3)] > 0 { print "type", $3, $4, "メソッド " n["tspec\t" tolower($3)], $5 }
      $1 == "type body" { print "type body", $3, $4, "実装 " n["tbody\t" tolower($3)] + 0, $5 }' "$TMPD/objects.tsv" | sort
    ;;
  mod-diff)
    # 経路A: パッケージ仕様 ＋ メソッドを持つ型仕様。経路B: パッケージ本体 ＋ 型本体
    subs_build; objects_build
    { awk -F '\t' '$1 == "package" { print "package " tolower($3) }' "$TMPD/objects.tsv"; awk -F '\t' '$1 == "tspec" { print "type " $2 }' "$TMPD/subs.tsv"; } | sort -u > "$TMPD/mA"
    awk -F '\t' '$1 == "package body" { print "package " tolower($3) } $1 == "type body" { print "type " tolower($3) }' "$TMPD/objects.tsv" | sort -u > "$TMPD/mB"
    awk -F '\t' '$1 == "spec" { print "package " $2 }' "$TMPD/subs.tsv" | sort -u > "$TMPD/mSub"
    echo "経路A（仕様）: $(wc -l < "$TMPD/mA" | tr -d ' ')"
    echo "経路B（本体）: $(wc -l < "$TMPD/mB" | tr -d ' ')"
    echo "== 経路A のみ（本体が無い仕様。定数・型・例外だけの仕様は本体が要らない） =="
    comm -23 "$TMPD/mA" "$TMPD/mB" | while IFS= read -r x; do
      case "$x" in
        type\ *) printf '  %s\t(メソッドを宣言しているのに型本体が無い。NOT INSTANTIABLE のメソッドだけの抽象型なら正しい)\n' "$x" ;;
        *) if grep -qxF -- "$x" "$TMPD/mSub"; then printf '  %s\t(サブプログラムを宣言しているのに本体が無い)\n' "$x"; else printf '  %s\t(宣言だけの仕様。本体は要らない)\n' "$x"; fi ;;
      esac
    done
    echo "== 経路B のみ（仕様の無い本体。作成に失敗する・仕様が別のスキーマ・メソッドの無い型仕様の別） =="
    comm -13 "$TMPD/mA" "$TMPD/mB" | sed 's/^/  /'
    echo "== ラップされたユニット（中身を読めない。仕様の宣言だけを分母に使う） =="
    awk -F '\t' '$5 ~ /wrapped/ { print "  " $1 "\t" $3 "\t" $4 }' "$TMPD/objects.tsv"
    ;;
  list-objects)
    objects_build
    awk -F '\t' -v OFS='\t' '{ print $1, $2, $3, $4, $5 }' "$TMPD/objects.tsv" | sort
    ;;
  list-wrapped)
    objects_build
    awk -F '\t' -v OFS='\t' '$5 ~ /wrapped/ { print $1, $3, $4 }' "$TMPD/objects.tsv"
    ;;
  bnd)
    bnd_build
    n=$(wc -l < "$TMPD/bndA.tsv" | tr -d ' ')
    [ "${n:-0}" -gt 0 ] && echo "$n" || echo unknown
    ;;
  list-bnd)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4 }' "$TMPD/bndA.tsv"
    ;;
  bnd-schema)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4 }' "$TMPD/bndB.tsv"
    ;;
  bnd-diff)
    bnd_build
    cut -f1 "$TMPD/bndA.tsv" > "$TMPD/bA"; cut -f1 "$TMPD/bndB.tsv" > "$TMPD/bB"
    echo "経路A（参照側: PL/SQL・VIEW・トリガー）: $(wc -l < "$TMPD/bA" | tr -d ' ')"
    echo "経路B（定義側: TABLE / VIEW / MATERIALIZED VIEW）: $(wc -l < "$TMPD/bB" | tr -d ' ')"
    if [ ! -s "$TMPD/bA" ] && [ ! -s "$TMPD/bB" ]; then echo "★参照側も定義側も 0 件（PL/SQL も DDL も無い、または拡張子が PLSQL_GLOBS に無い）"
    elif [ ! -s "$TMPD/bB" ]; then echo "★定義側が 0 件（DDL がソースに無い: 別リポジトリ・DB のダンプだけ）。経路B を単一経路として理由を書く"; fi
    echo "== 経路A のみ（参照されるのに定義が無い。別のスキーマ・同義語の先・動的 DDL で作る・パッケージ変数のコレクションの誤検出の別） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bndA.tsv" "$TMPD/bB" | awk -F '\t' '{ print "  " $2 "\t" $3 "\t" $4 }'
    echo "== 経路B のみ（定義されるのに PL/SQL から参照されない。アプリだけが使う・死蔵・動的 SQL だけで使うの別） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bndB.tsv" "$TMPD/bA" | awk -F '\t' '{ print "  " $2 "\t" $3 "\t" $4 }'
    echo "== どちらにも入れなかった参照（system＝データディクショナリ・DBMS の表、script のみ＝導入スクリプトの DML、dynamic のみ＝動的 SQL のリテラル） =="
    awk -F '\t' '{ print "  " $2 "\t" $3 "\t" $4 }' "$TMPD/bndX.tsv"
    echo "== 同じ名前の表・ビューの定義が複数ある（別のスキーマの別の表か、作り直しか。キーは名前だけなので 1 つに束ねている。スキーマごとに分けて走査する） =="
    awk -F '\t' '$1 == "table" || $1 == "view" || $1 == "materialized view" || $1 == "temporary table" { k = tolower($3); c[k]++; w[k] = w[k] " " $4 } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/objects.tsv" | sort
    ;;
  list-crud)
    refs_build
    awk -F '\t' -v OFS='\t' '{ print $5, $6, $2, $3, $4 }' "$TMPD/refs.tsv" | sort -u
    ;;
  list-calls)
    # ユニット → パッケージ.サブプログラム（仕様にある名前だけ。同じパッケージの中の呼び出しは修飾しないので出ない）
    subs_build; lex
    awk -F '\t' -v OFS='\t' '
      FILENAME ~ /subs\.tsv$/ { if ($1 == "spec") api[$2 "." $3] = 1; next }
      FILENAME ~ /units\.tsv$/ { uk[$1] = $2 ":" $4; next }
      { t = tolower($4)
        while (match(t, /(^|[^a-z0-9_$#.])"?[a-z_][a-z0-9_$#]*"?\."?[a-z_][a-z0-9_$#]*"?[ ]*[(;]/)) { m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
          gsub(/[^a-z0-9_$#.]/, "", m); sub(/^\./, "", m); if ((m in api) && !(($1 SUBSEP m) in seen)) { seen[$1, m] = 1; print uk[$1], m, $2 ":" $3 } } }' "$TMPD/subs.tsv" "$TMPD/units.tsv" "$TMPD/ucode.tsv" | sort
    ;;
  list-dynamic)
    lex
    awk -F '\t' -v OFS='\t' '
      FILENAME ~ /units\.tsv$/ { uk[$1] = $2 ":" $4; next }
      { t = tolower($5)
        if (t ~ /execute[ ]+immediate/) { r = $5; lit = ""; if (match(tolower(r), /execute[ ]+immediate[ ]*\001[^\002]*/)) { lit = substr(r, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", lit); gsub(/[ ]+/, " ", lit); lit = substr(lit, 1, 60) }
          print uk[$1], "execute immediate", (lit == "" ? "(式)" : lit), $2 ":" $3 }
        if (t ~ /dbms_sql\.parse/) print uk[$1], "dbms_sql.parse", "(式)", $2 ":" $3
        if (t ~ /open[ ]+[a-z_][a-z0-9_$#]*[ ]+for[ ]+(\001|[a-z_])/ && t !~ /open[ ]+[a-z_][a-z0-9_$#]*[ ]+for[ ]+(select|with)[ (]/) print uk[$1], "open for", "(式)", $2 ":" $3 }' "$TMPD/units.tsv" "$TMPD/ucode.tsv"
    ;;
  list-jobs)
    jobs_build
    cat "$TMPD/jobs.tsv"
    ;;
  list-grants)
    lex
    awk -F '\t' -v OFS='\t' '{ h = tolower($4); gsub(/[ ]+/, " ", h); sub(/^ /, "", h)
      if (h ~ /^grant /) { p = h; sub(/^grant /, "", p); o = ""; g = ""; if (match(p, / on [^ ]+/)) { o = substr(p, RSTART + 4, RLENGTH - 4); gsub(/"/, "", o) } if (match(p, / to [^;]+/)) { g = substr(p, RSTART + 4, RLENGTH - 4) }
        pr = p; sub(/ on .*$/, "", pr); sub(/ to .*$/, "", pr); print pr, (o == "" ? "(システム権限)" : o), g, $2 ":" $3 } }' "$TMPD/stmts.tsv" | sort
    ;;
  scope)
    # ディレクトリ（2 階層）ごとの PL/SQL のファイル数
    list_files > "$TMPD/scope.lst"
    awk -F '/' -v OFS='\t' 'NF > 2 { d = $1 "/" $2; if (NF > 3) d = d "/" $3; c[d]++ } NF == 2 { c["."]++ } END { for (d in c) print d, c[d] }' "$TMPD/scope.lst" | sort
    ;;
  idents-table)
    bnd_build
    # 表ごとに最も多く現れた綴り（参照の全出現 ＋ 定義）を出す（G-IDENT は大小を区別して突合する。教訓 64）
    #   対象は経路A ∪ 経路B の表だけ（データディクショナリ・導入スクリプトだけの表は出さない）
    cut -f1 "$TMPD/bndA.tsv" "$TMPD/bndB.tsv" | sort -u > "$TMPD/idk"
    { cut -f2 "$TMPD/refs.tsv"; awk -F '\t' '$1 ~ /table|view/ { print $3 }' "$TMPD/objects.tsv"; } \
      | awk -v K="$TMPD/idk" 'BEGIN { while ((getline x < K) > 0) want[x] = 1 } { k = tolower($0); if (!(k in want)) next; c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort
    ;;
  idents-package)
    objects_build
    awk -F '\t' '$1 == "package" || $1 == "package body" { print $3 }' "$TMPD/objects.tsv" | awk '{ k = tolower($0); c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort
    ;;
  idents-subprogram)
    # パッケージ.サブプログラム（仕様の綴り）
    subs_build; objects_build
    awk -F '\t' 'FILENAME ~ /objects\.tsv$/ { if ($1 == "package") ps[tolower($3)] = $3; next } $1 == "spec" { print ((($2) in ps) ? ps[$2] : $2) "." $5 }' "$TMPD/objects.tsv" "$TMPD/subs.tsv" | awk '{ k = tolower($0); c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort
    ;;
  idents-trigger)
    objects_build
    awk -F '\t' '$1 == "trigger" { print $3 }' "$TMPD/objects.tsv" | awk '{ k = tolower($0); c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-objects|list-crud|list-calls|list-dynamic|list-jobs|list-grants|list-wrapped|scope|idents-table|idents-package|idents-subprogram|idents-trigger} <source-path>" >&2
    exit 2
    ;;
esac
}
main > "$TMPD/out.txt"
rc=$?
cat "$TMPD/out.txt" 2>/dev/null || true
exit "$rc"
