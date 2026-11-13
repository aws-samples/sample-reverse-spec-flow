#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（vb6 / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 画面の 2 経路（ディスクの .frm / .vbp の Form= の宣言）の要素差分
#   mod-diff              → コードモジュールの 2 経路（ディスクの .bas / .cls / .ctl / .dob / .pag / .dsr / .vbp の宣言）の要素差分
#   bnd-schema            → DB 表の経路B（CREATE TABLE・DAO の CreateTableDef）の一覧
#   bnd-diff              → DB 表の 2 経路（参照側 / 定義側）の要素差分
#   list-projects         → プロジェクト（.vbp）の種類・名前・起動オブジェクト・メンバー数・グループ（.vbg）からの参照
#   list-controls         → 画面のコントロール（画面・型・名前・コントロール配列の添字・データ連結のプロパティ）
#   list-handlers         → イベントハンドラ（画面・コントロール・イベント・path:行。対応するコントロールが無いものは orphan）
#   list-procs            → 手続き（モジュール・公開範囲・種類・名前・path:行）
#   list-crud             → ファイル × 表 × 操作（SQL 文字列・テーブル名だけを渡す Open / OpenRecordset・データコントロールの RecordSource）
#   list-refs             → 参照（Reference= のタイプライブラリ・Object= の OCX）
#   list-external         → 外部境界（Declare の Win32 API・CreateObject / GetObject の COM・ファイル I/O・Shell）
#   scope                 → ディレクトリごとの件数（同梱ライブラリ・サンプル・別プロジェクトを見つけて SCAN_EXCLUDE を決める）
#   idents-form | idents-table | idents-module → 識別子の抽出（G-IDENT 用。出典の綴りで出す。ASCII 以外を含む名前は外す）
#   idents-nonascii       → ASCII 以外を含む識別子（G-IDENT で突き合わせられないので手で確かめる）
#
# 環境変数（未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む）:
#   SCAN_EXCLUDE : 走査から外すパスの POSIX ERE（`./` 始まりの相対パスに当てる）。外したものは ADR で処分する
#
# 実測検証（2026-10-25）: PhotoDemon（画像編集ソフト。.vbp 5・フォーム 232・クラス 165・ユーザーコントロール 56。DB は無い）、
#   pcgestion20（店舗の販売管理。.vbp 17・.vbg 5・ADO の SQL と表名だけの Open）、erp_vb6（DAO と Access。.vbp が無い）、
#   frei-vb6-projeto-vendas（販売の例。ADO）。値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。VB6 のソースは ANSI（Windows-1252・Shift_JIS 等）と CRLF で、
#   UTF-8 ロケールの awk/grep は不正バイトで黙って行を落とす（enumeration.md 落とし穴 1）。
# 【重要】このスクリプト自体の正しさを検証すること（GP-6（ゲートのコマンド自体を検証する））。
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
export SCAN_EXCLUDE="${SCAN_EXCLUDE:-}"

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
cd "$SRC" || { echo "unknown"; exit 0; }

list_files() { # $@ = -iname のパターン
  local first=1 args=() p
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -name CVS -o -name node_modules \) -prune -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort \
    | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; }
}

# 複数のファイルをまとめて読む: stdin = ファイル一覧 → path<TAB>行番号<TAB>行（CR と先頭の BOM を外し、TAB を空白にする）
read_many() {
  local lst b8
  lst="$TMPD/rm.$$.$RANDOM"; b8="$(printf '\357\273\277')"
  cat > "$lst"
  awk -v bom="$b8" '{ f = $0; n = 0; while ((getline line < f) > 0) { n++; sub(/\r$/, "", line); gsub(/\t/, " ", line); if (n == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1); print f "\t" n "\t" line } close(f) }' "$lst"
}

# パスの正規化（VB6 は Windows のパス: \ 区切り・大小を区別しない・..\ を含む）。キーは小文字・/ 区切り・./ 始まり
AWK_PATH='
function normpath(base, p,   d, n, a, i, m, s, out) {
  gsub(/\\/, "/", p); gsub(/"/, "", p); sub(/^[ ]+/, "", p); sub(/[ ]+$/, "", p)
  if (p ~ /^[A-Za-z]:/ || p ~ /^\//) return "(絶対パス)" p
  d = base; sub(/\/[^\/]*$/, "", d); n = split(d "/" p, a, "/"); m = 0
  for (i = 1; i <= n; i++) { if (a[i] == "" || (a[i] == "." && i > 1)) continue; if (a[i] == "..") { if (m > 1) m--; continue } s[++m] = a[i] }
  out = s[1]; for (i = 2; i <= m; i++) out = out "/" s[i]; return out }
# キーで ASCII 以外のバイトを ? に畳む（.vbp の cp1252 とディスクの UTF-8 の名前を同じキーにする。落とし穴 11）。「(絶対パス)」の印は残す
function fold(p,   mk, r) { mk = "(絶対パス)"; if (index(p, mk) == 1) { r = substr(p, length(mk) + 1); gsub(/[\200-\377]+/, "?", r); return mk r } gsub(/[\200-\377]+/, "?", p); return p }
'

# -----------------------------------------------------------------------------
# プロジェクト（.vbp）とグループ（.vbg）→
#   $TMPD/projects.tsv : vbp のパス  Type  Name  Startup  ExeName32
#   $TMPD/members.tsv  : vbp のパス  種類(Form|Module|Class|UserControl|Designer|PropertyPage|UserDocument)  宣言の名前  解いたパス（小文字のキー）  書かれたパス  行
#   $TMPD/vbrefs.tsv   : vbp のパス  種類(Reference|Object)  名前（説明・OCX のファイル名）  行
#   $TMPD/vbg.tsv      : vbg のパス  解いた vbp のパス（小文字のキー）  StartupProject なら 1  行
# -----------------------------------------------------------------------------
projects_parse() {
  [ -f "$TMPD/projects.tsv" ] && return 0
  list_files '*.vbp' '*.vbg' > "$TMPD/vbp.lst"
  : > "$TMPD/projects.tsv"; : > "$TMPD/members.tsv"; : > "$TMPD/vbrefs.tsv"; : > "$TMPD/vbg.tsv"
  [ -s "$TMPD/vbp.lst" ] || return 0
  read_many < "$TMPD/vbp.lst" | awk -F '\t' -v OFS='\t' -v D="$TMPD" "$AWK_PATH"'
    function flush() { if (pf != "" && pf ~ /\.[vV][bB][pP]$/) print pf, ty, nm, st, ex > (D "/projects.tsv"); ty = ""; nm = ""; st = ""; ex = "" }
    $1 != pf { flush(); pf = $1 }
    { l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l); k = l; sub(/=.*$/, "", k); v = l; sub(/^[^=]*=/, "", v); lk = tolower(k) }
    pf ~ /\.[vV][bB][gG]$/ { if (lk == "project" || lk == "startupproject") { p = fold(tolower(normpath(pf, v))); print pf, p, (lk == "startupproject" ? 1 : 0), $2 > (D "/vbg.tsv") } next }
    lk == "type" { ty = v; next }
    lk == "name" { gsub(/"/, "", v); nm = v; next }
    lk == "startup" { gsub(/"/, "", v); st = v; next }
    lk == "exename32" { gsub(/"/, "", v); ex = v; next }
    lk ~ /^(form|module|class|usercontrol|designer|propertypage|userdocument)$/ {
      dn = ""; fp = v; if (index(v, ";") > 0) { dn = v; sub(/;.*$/, "", dn); gsub(/^[ ]+|[ ]+$/, "", dn); fp = v; sub(/^[^;]*;/, "", fp) }
      p = fold(tolower(normpath(pf, fp))); print pf, k, dn, p, fp, $2 > (D "/members.tsv"); next }
    lk == "reference" { d = v; n = split(d, a, "#"); print pf, "Reference", (n >= 5 ? a[5] : d), $2 > (D "/vbrefs.tsv"); next }
    lk == "object" { d = v; sub(/^[^;]*;[ ]*/, "", d); print pf, "Object", d, $2 > (D "/vbrefs.tsv"); next }
    END { flush() }'
}

# -----------------------------------------------------------------------------
# VB6 のソース（.frm / .ctl / .dob / .pag / .dsr / .bas / .cls）の字句解析（落とし穴 2〜4）
#   ヘッダ（Begin ... End の入れ子・Attribute）とコードを分け、コードは注釈（' と Rem）・文字列（"..." の ""）・行の継続（ _）を読む
#   $TMPD/vbfiles.tsv : path  モジュールの名前（VB_Name）  最上位のオブジェクトの型（VB.Form 等。.bas は (module)・.cls は (class)）  VB_Exposed  公開の種類（MultiUse 等）
#   $TMPD/controls.tsv: path  画面の名前  型  名前  添字  行  RecordSource  DataSource  ConnectionString / DatabaseName
#   $TMPD/vbcode.tsv  : path  行（論理行の始まり）  文字列を "S" に置き換えた論理行  文字列の中身を \001...\002 で残した論理行
# -----------------------------------------------------------------------------
vb_lex() {
  [ -f "$TMPD/vbfiles.tsv" ] && return 0
  list_files '*.frm' '*.ctl' '*.dob' '*.pag' '*.dsr' '*.bas' '*.cls' > "$TMPD/src.lst"
  : > "$TMPD/vbfiles.tsv"; : > "$TMPD/controls.tsv"; : > "$TMPD/vbcode.tsv"
  [ -s "$TMPD/src.lst" ] || return 0
  read_many < "$TMPD/src.lst" | awk -F '\t' -v OFS='\t' -v D="$TMPD" -v dq='"' '
    function endfile() { if (pf == "") return
      if (cont) emitline()
      if (top == "") { e = tolower(pf); top = (e ~ /\.bas$/) ? "(module)" : ((e ~ /\.cls$/) ? "(class)" : "(不明)") }
      # 公開の種類: VB_Creatable = False は PublicNotCreatable、公開しないクラスは Private（ヘッダの MultiUse だけでは決まらない）
      if (creatable == "False" && exposed == "True") inst = "PublicNotCreatable"; else if (exposed != "True" && inst != "") inst = "Private"
      print pf, vbname, top, exposed, inst > (D "/vbfiles.tsv")
      for (i = 1; i <= nc; i++) print pf, vbname, CT[i], CN[i], CI[i], CL[i], CR[i], CD[i], CC[i] > (D "/controls.tsv")
      nc = 0; delete CT; delete CN; delete CI; delete CL; delete CR; delete CD; delete CC }
    function emitline() { print pf, sl, mbuf, rbuf > (D "/vbcode.tsv"); mbuf = ""; rbuf = ""; cont = 0 }
    function pval(v) { sub(/^[^=]*=[ ]*/, "", v); if (substr(v, 1, 1) == dq) { v = substr(v, 2); sub(/".*$/, "", v) } else sub(/[ ]+.*$/, "", v); return v }
    $1 != pf { endfile(); pf = $1; inhead = 1; depth = 0; top = ""; vbname = ""; exposed = ""; inst = ""; creatable = ""; ccont = 0; cont = 0; mbuf = ""; rbuf = ""; cur = 0; seenbegin = 0 }
    { ln = $2; l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l); ll = tolower(l) }
    # ---- ヘッダ ----
    inhead && ll ~ /^[ ]*attribute[ ]+vb_name[ ]*=/ { v = l; sub(/^[^=]*=[ ]*/, "", v); gsub(/"/, "", v); sub(/[ ]+$/, "", v); vbname = v; next }
    inhead && ll ~ /^[ ]*attribute[ ]+vb_exposed[ ]*=/ { exposed = (ll ~ /true/) ? "True" : "False"; next }
    inhead && ll ~ /^[ ]*attribute[ ]+vb_creatable[ ]*=/ { creatable = (ll ~ /true/) ? "True" : "False"; next }
    inhead && ll ~ /^[ ]*attribute[ ]+vb_/ { next }
    inhead && ll ~ /^[ ]*(version|object)[ ]/ && depth == 0 { next }
    inhead && ll ~ /^[ ]*begin[ ]+[a-z0-9_]+\.[a-z0-9_]+[ ]+[a-z0-9_\200-\377]+/ { n = split(l, w, " "); j = 0; for (i = 1; i <= n; i++) if (w[i] != "") { j++; ww[j] = w[i] }
      depth++; seenbegin = 1; if (depth == 1) { top = ww[2]; if (vbname == "") vbname = ww[3] }
      nc++; CT[nc] = ww[2]; CN[nc] = ww[3]; CI[nc] = ""; CL[nc] = ln; CR[nc] = ""; CD[nc] = ""; CC[nc] = ""; stk[depth] = nc; next }
    inhead && ll ~ /^[ ]*begin[ ]*$/ && depth == 0 { cbeg = 1; next }
    inhead && cbeg && ll ~ /^[ ]*multiuse[ ]*=/ { inst = (ll ~ /-1/) ? "MultiUse" : "SingleUse"; next }
    inhead && cbeg && ll ~ /^[ ]*end[ ]*$/ { cbeg = 0; next }
    inhead && cbeg { next }
    # デザイナ（.dsr の DataEnvironment / DataReport）は Begin {GUID} 名前
    inhead && ll ~ /^[ ]*begin[ ]+\{[^}]*\}[ ]+[a-z0-9_\200-\377]+/ { n = split(l, w, " "); j = 0; for (i = 1; i <= n; i++) if (w[i] != "") { j++; ww[j] = w[i] }
      # 既知のデザイナの GUID: Microsoft Forms 2.0 の UserForm（VBA から書き出したフォーム）・DataEnvironment・DataReport（落とし穴 3）
      g = toupper(ww[2]); dt = (g ~ /C62A69F0-16DC-11CE-9E98-00AA00574A4F/) ? "MSForms.UserForm" : ((g ~ /C0E45035-5775-11D0-B388-00A0C9055D8E/) ? "(DataEnvironment)" : ((g ~ /78E93846-85FD-11D0-8487-00A0C90DC8A9/) ? "(DataReport)" : "(designer)"))
      depth++; seenbegin = 1; if (depth == 1) { top = dt; if (vbname == "") vbname = ww[3] }
      nc++; CT[nc] = dt; CN[nc] = ww[3]; CI[nc] = ""; CL[nc] = ln; CR[nc] = ""; CD[nc] = ""; CC[nc] = ""; stk[depth] = nc; next }
    inhead && ll ~ /^[ ]*beginproperty[ ]/ { pdepth++; next }
    inhead && ll ~ /^[ ]*endproperty[ ]*$/ { pdepth--; next }
    inhead && depth > 0 && pdepth == 0 && ll ~ /^[ ]*end[ ]*$/ { depth--; next }
    inhead && depth > 0 { c = stk[depth]
      if (pdepth == 0 && ll ~ /^[ ]*index[ ]*=/) CI[c] = pval(l)
      else if (pdepth == 0 && ll ~ /^[ ]*recordsource[ ]*=/) CR[c] = pval(l)
      else if (pdepth == 0 && ll ~ /^[ ]*datasource[ ]*=/) CD[c] = pval(l)
      else if (pdepth == 0 && ll ~ /^[ ]*(connectionstring|databasename|connect)[ ]*=/) CC[c] = pval(l)
      next }
    inhead && depth == 0 && (seenbegin || ll !~ /^[ ]*(begin|end|multiuse|persistable|databindingbehavior|datasourcebehavior|mtstransactionmode)/) { inhead = 0 }
    inhead { next }
    # ---- コード（論理行: 行末の「 _」で次の行に続く） ----
    # 注釈の行が「 _」で終わると、次の行も注釈になる
    ccont { ccont = (l ~ /[ ]_[ ]*$/); next }
    { if (!cont) sl = ln
      out = ""; raw = ""; n = length(l); i = 1; instr = 0
      # Rem の注釈（文の始まり）
      if (!cont && ll ~ /^[ ]*rem([ ]|$)/) { n = 0 }
      while (i <= n) { c = substr(l, i, 1)
        if (c == dq) { j = i + 1; v = ""
          while (j <= n) { d = substr(l, j, 1); if (d == dq) { if (substr(l, j + 1, 1) == dq) { v = v dq; j += 2; continue } break } v = v d; j++ }
          gsub(/[\001\002]/, " ", v); out = out dq "S" dq; raw = raw "\001" v "\002"; i = j + 1; continue }
        if (c == "\047") { if (l ~ /[ ]_[ ]*$/) ccont = 1; break }
        # 文の区切りの「:」の後の Rem
        if (c == ":" && tolower(substr(l, i + 1)) ~ /^[ ]*rem([ ]|$)/) break
        out = out c; raw = raw c; i++ }
      if (out ~ /[ ]_[ ]*$/ || out ~ /^_[ ]*$/) { sub(/_[ ]*$/, "", out); sub(/_[ ]*$/, "", raw); mbuf = mbuf out " "; rbuf = rbuf raw " "; cont = 1; next }
      mbuf = mbuf out; rbuf = rbuf raw; emitline() }
    END { endfile() }'
}

# -----------------------------------------------------------------------------
# 手続き → $TMPD/procs.tsv : path  モジュール  公開範囲  種類(sub|function|property get|...|declare|event)  名前  行
# イベントハンドラ → $TMPD/handlers.tsv : path  画面  イベント元  イベント  ハンドラ  行  種類(control|form|withevents|orphan)
#   ハンドラは「イベント元_イベント」の名前で結び付く（VB6 は宣言の Handles を持たない。落とし穴 5）。
#   イベント元 = その画面のコントロール（コントロール配列は Index 引数）・Form / MDIForm / UserControl / Class 自身・WithEvents の変数
# -----------------------------------------------------------------------------
procs_build() {
  [ -f "$TMPD/procs.tsv" ] && return 0
  vb_lex
  awk -F '\t' -v OFS='\t' -v D="$TMPD" '
    FILENAME ~ /vbfiles\.tsv$/ { mn[$1] = $2; tp[$1] = tolower($3); next }
    FILENAME ~ /controls\.tsv$/ { ctl[$1, tolower($4)] = 1; next }
    { t = tolower($3); gsub(/^[ ]+/, "", t)
      if (match(t, /^((public|private|friend|global)[ ]+)?((static)[ ]+)?(sub|function|property[ ]+(get|let|set))[ ]+[a-z_\200-\377][a-z0-9_\200-\377]*/)) {
        m = substr(t, 1, RLENGTH); sc = "public"; if (m ~ /^private/) sc = "private"; else if (m ~ /^friend/) sc = "friend"
        k = m; sub(/^((public|private|friend|global)[ ]+)?((static)[ ]+)?/, "", k); nm = k; sub(/^(sub|function|property[ ]+(get|let|set))[ ]+/, "", nm); sub(/[ ]+[a-z_\200-\377][a-z0-9_\200-\377]*$/, "", k)
        sp = $3; p = index(tolower(sp), " " nm); sp = (p > 0) ? substr(sp, p + 1, length(nm)) : nm
        print $1, mn[$1], sc, k, sp, $2 > (D "/procs.tsv")
        # イベントハンドラ: 名前の最後の「_」で イベント元 と イベント に分ける（Sub cmdOK_Click）
        if (k == "sub" && index(nm, "_") > 0) { src = nm; sub(/_[^_]*$/, "", src); ev = nm; sub(/^.*_/, "", ev)
          # 綴りは宣言のまま出す（照合は小文字で行う）
          ssrc = sp; sub(/_[^_]*$/, "", ssrc); sev = sp; sub(/^.*_/, "", sev)
          kind = ""
          if (((($1) SUBSEP src) in ctl)) kind = "control"
          else if (src ~ /^(form|mdiform|usercontrol|userform|class|propertypage|userdocument|dataenvironment|datareport)$/) kind = "form"
          else if ((($1) SUBSEP src) in we) kind = "withevents"
          # 対応するコントロールが無いのに、名前の後ろが VB の標準のイベント名のものだけを orphan にする
          #   （Calcula_Descuentos のような「_」を含むただの手続きを拾わない。実測 pcgestion20 で 146 件が化けた）
          # VBA の UserForm はコントロールを .frx（バイナリ）にしか持たないので、照合できない（実測 erp_vb6）
          else if (tp[$1] ~ /userform$/ && ev ~ /^(click|dblclick|change|initialize|terminate|activate|deactivate|keypress|keydown|keyup|mousedown|mouseup|mousemove|exit|enter|afterupdate|beforeupdate|queryclose|layout|resize|scroll)$/) kind = "userform"
          else if ((tp[$1] ~ /^vb\.(form|mdiform|usercontrol|propertypage|userdocument)$/ || tp[$1] ~ /\.(form|usercontrol)$/) && ev ~ /^(click|dblclick|change|load|unload|queryunload|activate|deactivate|initialize|terminate|resize|paint|gotfocus|lostfocus|keypress|keydown|keyup|mousedown|mouseup|mousemove|validate|timer|scroll|dragdrop|dragover|keyascii|itemclick|nodeclick|beforeupdate|afterupdate|rowcolchange|selchange|enterfocus|exitfocus|buttonclick|buttonmenuclick|itemcheck|columnclick|nodecheck|beforelabeledit|afterlabeledit|headclick|rowcolchange|tabclick|statechanged|datachanged|ole[a-z]+)$/) kind = "orphan"
          if (kind != "") print $1, mn[$1], ssrc, sev, sp, $2, kind > (D "/handlers.tsv") } }
      if (match(t, /^((public|private)[ ]+)?declare[ ]+(ptrsafe[ ]+)?(function|sub)[ ]+[a-z_\200-\377][a-z0-9_\200-\377]*/)) { m = substr(t, 1, RLENGTH); nm = m; sub(/^.*(function|sub)[ ]+/, "", nm)
        sp = $3; p = index(tolower(sp), " " nm); if (p > 0) nm = substr(sp, p + 1, length(nm))
        lib = $4; sub(/^[^\001]*\001/, "", lib); sub(/\002.*$/, "", lib); print $1, mn[$1], (t ~ /^private/ ? "private" : "public"), "declare", nm " (" lib ")", $2 > (D "/procs.tsv") }
      if (match(t, /^((public|private|dim)[ ]+)withevents[ ]+[a-z_\200-\377][a-z0-9_\200-\377]*/)) { w = substr(t, 1, RLENGTH); sub(/^.*withevents[ ]+/, "", w); we[$1, w] = 1 }
      if (match(t, /^((public|private)[ ]+)?event[ ]+[a-z_\200-\377][a-z0-9_\200-\377]*/)) { w = substr(t, 1, RLENGTH); sub(/^.*event[ ]+/, "", w); print $1, mn[$1], "public", "event", w, $2 > (D "/procs.tsv") } }' \
    "$TMPD/vbfiles.tsv" "$TMPD/controls.tsv" "$TMPD/vbcode.tsv"
  touch "$TMPD/procs.tsv" "$TMPD/handlers.tsv"
}

AWK_SQL='
function sqlscan(s, loc, org,   l, kw, nm, lst, n, a, i, x, cs, cs2, op) {
  l = " " tolower(s) " "; gsub(/[\t\r\n]+/, " ", l)
  if (l ~ /object[ ]*\(/) return
  # Java の文字列の中のエスケープした引用符（\"T_QUOTED\"）を外す。引用符の中身（値）を消す
  gsub(/\\"/, "\"", l)
  gsub(/'"'"'[^'"'"']*'"'"'/, "'"''"'", l)
  # IF NOT EXISTS / IF EXISTS は表名ではない
  gsub(/[ ]if[ ]+(not[ ]+)?exists[ ]/, " ", l)
  if (l !~ /(^|[^a-z0-9_])(select|insert|update|delete|create|merge|from)[ ]/) return
  # 【文言を SQL と読まない】Java の文字列・XML のテキストは、SQL の句の語で始まるものだけを読む
  #   （"Could not delete from database" の database を表にしない。StringBuffer で継ぎ足す " from t" は読む。落とし穴 9）
  # 【VB6 の文字列は SQL の形まで見る】画面の文言・メニューの名前（"Delete layer"・"Select all"・"From file"）が多い（実測 PhotoDemon: DB が無いのに表 10 が化けた）。
  #   文を継ぎ足して組み立てた後の文字列を読むので、FROM / WHERE で始まる断片は単独では読まない。SELECT は FROM、DELETE は FROM か WHERE を伴うものだけ（落とし穴 6）
  if (org != "sqlfile" && l !~ /^[ (]*(select|insert[ ]+into|update|delete|create[ ]+(global[ ]+temporary[ ]+)?table|merge|with)[ ]/) return
  # 画面の文言の「Delete from history?」（WHERE が無く ? ! . で終わる）は SQL ではない
  if (org != "sqlfile" && l ~ /^[ (]*delete[ ]/ && l !~ /[ ]where[ ]/ && l ~ /[?!.][ ]*$/) return
  if (org != "sqlfile" && l ~ /^[ (]*delete[ ]/ && l !~ /^[ (]*delete[ ]+(from[ ]+)?[a-z_][a-z0-9_$#.\[\]]*[ ]+where[ ]/ && l !~ /^[ (]*delete[ ]+from[ ]/) return
  cs = l
  # FROM / INTO を省略した DELETE・INSERT（Oracle / SQL Server）と MERGE INTO も読む。最長一致なので delete from t は「delete from」で取れる
  while (match(cs, /[^a-z0-9_](insert[ ]+into|delete[ ]+from|merge[ ]+into|insert|delete|update|create[ ]+table|create[ ]+temporary[ ]+table|from|join|into)[ (]+["`\[]?[a-z_][a-z0-9_$#.]*/)) {
    kw = substr(cs, RSTART + 1, RLENGTH - 1); cs2 = substr(cs, RSTART + RLENGTH)
    nm = kw; sub(/^(insert[ ]+into|delete[ ]+from|merge[ ]+into|insert|delete|update|create[ ]+table|create[ ]+temporary[ ]+table|from|join|into)[ (]+/, "", nm); gsub(/["`\[\]]/, "", nm)
    op = (kw ~ /^(insert|merge)/) ? "insert" : ((kw ~ /^delete/) ? "delete" : ((kw ~ /^update/) ? "update" : ((kw ~ /^create[ ]+temporary/) ? "temp" : ((kw ~ /^create/) ? "create" : ((kw ~ /^into/) ? "into" : "select")))))
    if (op == "update" && cs2 !~ /^[ ]*([a-z_][a-z0-9_]*[ ]+)?set[ ]/) { cs = cs2; continue }
    if (op == "into") { cs = cs2; continue }
    # 【スキーマ修飾は外す】from s1.t と DDL の t を同じ表として突き合わせる（スキーマの違いは仕様本文に書く）
    sub(/^[a-z0-9_$#]+\./, "", nm)
    if (nm !~ /^(select|where|set|values|dual|on|as|the|a|an|this|that|your|our|from|into|table|all|distinct|cascade|restrict|no)$/) emit(loc, nm, op, org)
    # FROM a, b x, c の並び
    if (op == "select") { lst = cs2; sub(/[ ](where|group|order|having|union|left|right|inner|outer|full|cross|join|on|for|limit|minus|except|intersect)[ ].*$/, "", lst); sub(/[)].*$/, "", lst)
      n = split(lst, a, ","); for (i = 2; i <= n; i++) { x = a[i]; gsub(/^[ ]+/, "", x); sub(/[ ].*$/, "", x); gsub(/["`\[\]]/, "", x); sub(/^[a-z0-9_$#]+\./, "", x); if (x ~ /^[a-z_][a-z0-9_$#]*$/) emit(loc, x, "select", org) } }
    cs = cs2
  }
}
function emit(loc, nm, op, org,   o) { o = orig(nm); print loc, o, op, org }
'

# -----------------------------------------------------------------------------
# SQL と表 → $TMPD/sql.tsv : path:行  表  操作(select|insert|update|delete|create|table)  由来(code|control|sqlfile)
#   【SQL を変数に継ぎ足す】sql = "SELECT a " / sql = sql & "FROM t" のように文をまたいで組み立てる（落とし穴 6）。
#     同じ変数への「v = v & ...」は前の文字列に足し、別の代入・手続きの終わりで 1 つの SQL として読む
#   【表名だけを渡す】rs.Open "CLIENTES"・db.OpenRecordset("Clientes")・データコントロールの RecordSource = "Clientes" は SQL でなく表名（落とし穴 7）
# -----------------------------------------------------------------------------
sql_build() {
  [ -f "$TMPD/sql.tsv" ] && return 0
  vb_lex
  {
    awk -F '\t' -v OFS='\t' '
      function lits(r,   o, t) { o = ""; t = r; while (match(t, /\001[^\002]*\002/)) { o = o (o == "" ? "" : " ") substr(t, RSTART + 1, RLENGTH - 2); t = substr(t, RSTART + RLENGTH) } return o }
      function fl(v) { if (v in buf && buf[v] != "") print pf ":" bl[v], buf[v], "code"; delete buf[v]; delete bl[v] }
      function flall(   v) { for (v in buf) fl(v) }
      $1 != pf { flall(); pf = $1 }
      { m = tolower($3); gsub(/^[ ]+/, "", m)
        # 単一行の If ... Then 代入・Else 代入・Case n: 代入 の先頭を外してから読む
        sub(/^(else)?if[ ].*[ ]then[ ]+/, "", m); sub(/^else[ ]+/, "", m); sub(/^case[ ][^:]*:[ ]*/, "", m)
        if (m ~ /^((public|private|friend|static)[ ]+)*(sub|function|property)[ ]/ || m ~ /^end[ ]+(sub|function|property)/) { flall(); next }
        # 単独の表名（Open / OpenRecordset / OpenTable / .Source / .RecordSource / .CommandText に名前だけの文字列）
        r = $4; t = tolower(r); if (t ~ /adcmdstoredproc/) sp_proc[pf] = 1
        while (match(t, /(\.open|openrecordset|opentable|\.source[ ]*=|\.recordsource[ ]*=|\.commandtext[ ]*=)[ (]*\001[a-z_][a-z0-9_$#]*\002/)) {
          w = substr(r, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", w); sub(/\002$/, "", w)
          # 受け手（.Open の前の名前）。接続（cn.Open "MyDsn"）・Err.Source は表ではない
          recv = substr(t, 1, RSTART - 1); sub(/^.*[^a-z0-9_]/, "", recv); kwm = substr(t, RSTART, RLENGTH)
          skip = 0
          if (kwm ~ /^\.open/ && recv ~ /^(cn|cnn|cnx|con|conn|conexion|connection|adoconn|db)[a-z0-9_]*$|(conn|connection|cnn)$/) skip = 1
          if (kwm ~ /^\.source/ && recv == "err") skip = 1
          # ストアドの名前（cmd.CommandText = "sp_x" ＋ adCmdStoredProc）は表ではない
          if (kwm ~ /^\.commandtext/ && (tolower($4) ~ /adcmdstoredproc/ || sp_proc[pf])) skip = 1
          # XMLHTTP の .Open "GET", url の HTTP の方法は表ではない（実測 PhotoDemon）
          if (tolower(w) ~ /^(get|post|put|delete|head|options|patch)$/) skip = 1
          if (!skip) print pf ":" $2, "@TABLE " w, "code"
          t = substr(t, RSTART + RLENGTH); r = substr(r, RSTART + RLENGTH) }
        # 継ぎ足し: v = v & ...
        if (match(m, /^(let[ ]+)?[a-z_][a-z0-9_.]*[ ]*=[ ]*[a-z_][a-z0-9_.]*[ ]*[&+]/)) { a = substr(m, 1, RLENGTH); v = a; sub(/^(let[ ]+)?/, "", v); sub(/[ ]*=.*$/, "", v); w2 = a; sub(/^[^=]*=[ ]*/, "", w2); sub(/[ ]*[&+]$/, "", w2)
          if (v == w2) { if (!(v in buf)) { buf[v] = ""; bl[v] = $2 } buf[v] = buf[v] " " lits($4); next } }
        # 新しい代入: v = "..."（前の継ぎ足しを読み終える）
        if (match(m, /^(let[ ]+)?[a-z_][a-z0-9_.]*[ ]*=/)) { v = substr(m, 1, RLENGTH); sub(/^(let[ ]+)?/, "", v); sub(/[ ]*=$/, "", v)
          fl(v); s = lits($4); if (s != "") { buf[v] = s; bl[v] = $2 } next }
        s = lits($4); if (s != "") print pf ":" $2, s, "code" }
      END { flall() }' "$TMPD/vbcode.tsv"
    # データコントロール（Data / ADODC）の RecordSource
    awk -F '\t' -v OFS='\t' '$7 != "" { if ($7 ~ /^[A-Za-z_][A-Za-z0-9_$#]*$/) print $1 ":" $6, "@TABLE " $7, "control"; else print $1 ":" $6, $7, "control" }' "$TMPD/controls.tsv"
    # SQL ファイル（-- と /* */ の注釈を外し、; までを 1 文にする）
    list_files '*.sql' '*.ddl' | read_many | awk -F '\t' '
      $1 != pf { if (stm != "") print pf ":" sl "\t" stm "\tsqlfile"; pf = $1; stm = ""; inb = 0 }
      { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); out = ""
        while (t != "") { if (inb) { i = index(t, "*/"); if (!i) { t = ""; break } t = substr(t, i + 2); inb = 0; continue }
          i = index(t, "/*"); j = index(t, "--"); if (j > 0 && (i == 0 || j < i)) { out = out substr(t, 1, j - 1); break }
          if (i == 0) { out = out t; break } out = out substr(t, 1, i - 1) " "; t = substr(t, i + 2); inb = 1 }
        while ((k = index(out, ";")) > 0) { if (stm == "") sl = $2; stm = stm " " substr(out, 1, k - 1); print pf ":" sl "\t" stm "\tsqlfile"; stm = ""; out = substr(out, k + 1) }
        if (out ~ /[^ ]/) { if (stm == "") sl = $2; stm = stm " " out } }
      END { if (stm != "") print pf ":" sl "\t" stm "\tsqlfile" }'
  } > "$TMPD/sqlsrc.tsv"
  # DAO の CreateTableDef("名前") は定義
  awk -F '\t' -v OFS='\t' '{ t = tolower($4); r = $4
      while (match(t, /createtabledef[ ]*\([ ]*\001[a-z_][a-z0-9_$# ]*\002/)) { w = substr(r, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", w); sub(/\002$/, "", w); print $1 ":" $2, "@CREATE " w, "code"; t = substr(t, RSTART + RLENGTH); r = substr(r, RSTART + RLENGTH) } }' "$TMPD/vbcode.tsv" >> "$TMPD/sqlsrc.tsv"
  awk -F '\t' -v OFS='\t' "$AWK_SQL"'
    function orig(nm,   x) { x = nm; return (x in sp) ? sp[x] : x }
    { if ($2 ~ /^@TABLE /) { w = substr($2, 8); print $1, w, "table", $3; next }
      if ($2 ~ /^@CREATE /) { w = substr($2, 9); print $1, w, "create", $3; next }
      s = $2; if (tolower(s) !~ /(select|insert|update|delete|create|from)[ ]/) s = ""
      while (match(s, /[A-Za-z_][A-Za-z0-9_$#]*/)) { w = substr(s, RSTART, RLENGTH); k = tolower(w); cnt[k, w]++; if (cnt[k, w] > best[k]) { best[k] = cnt[k, w]; sp[k] = w } s = substr(s, RSTART + RLENGTH) }
      line[++nl] = $0 }
    END { for (i = 1; i <= nl; i++) { split(line[i], f, "\t"); sqlscan(f[2], f[1], f[3]) } }' "$TMPD/sqlsrc.tsv" > "$TMPD/sql.tsv"
}

# 参照側（経路A）/ 定義側（経路B）
bnd_build() {
  [ -f "$TMPD/bndref.tsv" ] && return 0
  sql_build
  awk -F '\t' -v OFS='\t' -v D="$TMPD" '
    { k = tolower($2)
      if ($3 == "create") { if (!(k in d)) { d[k] = $2; dl[k] = $1 } next }
      if ($3 == "temp") next
      if ($4 == "sqlfile" && $3 == "insert") { if (!(k in sf)) { sf[k] = $2; sfl[k] = $1 } next }
      if (!(k in r)) { r[k] = $2; rl[k] = $1 } o = $4 ($3 == "table" ? ":表名" : ""); if (index(" " ro[k] " ", " " o " ") == 0) ro[k] = ro[k] (ro[k] == "" ? "" : " ") o }
    END { for (k in r) print k, r[k], ro[k], rl[k] > (D "/bndref.tsv"); for (k in d) print k, d[k], dl[k] > (D "/bnddef.tsv")
          for (k in sf) if (!(k in r)) print k, sf[k], sfl[k] > (D "/bndsf.tsv") }' "$TMPD/sql.tsv"
  touch "$TMPD/bndref.tsv" "$TMPD/bnddef.tsv" "$TMPD/bndsf.tsv"
  for f in bndref bnddef bndsf; do sort -o "$TMPD/$f.tsv" "$TMPD/$f.tsv"; done
}

# 画面（ディスク）→ $TMPD/screens.tsv : キー（小文字のパス）  画面の名前  最上位の型  path
screens_build() {
  [ -f "$TMPD/screens.tsv" ] && return 0
  vb_lex
  awk -F '\t' -v OFS='\t' 'tolower($1) ~ /\.frm$/ { k = tolower($1); gsub(/[\200-\377]+/, "?", k); print k, $2, $3, $1 }' "$TMPD/vbfiles.tsv" | sort > "$TMPD/screens.tsv"
}

# 入口 → $TMPD/ep.tsv : 種類(screen|startup|com)  キー  付記  path
ep_build() {
  [ -f "$TMPD/ep.tsv" ] && return 0
  screens_build; projects_parse
  {
    awk -F '\t' -v OFS='\t' '$3 ~ /(^|\.)(Form|MDIForm|UserForm)$/ { print "screen", $2, $3, $4 }' "$TMPD/screens.tsv"
    awk -F '\t' -v OFS='\t' 'tolower($2) ~ /exe/ && tolower($2) !~ /ole/ { print "startup", $3, "Startup=" ($4 == "" ? "(既定)" : $4), $1 }' "$TMPD/projects.tsv"
    # ActiveX（OleDll / OleExe）の公開クラス（VB_Exposed = True かつ Private 以外）
    awk -F '\t' -v OFS='\t' -v P="$TMPD/projects.tsv" -v M="$TMPD/members.tsv" "$AWK_PATH"'
      BEGIN { while ((getline x < P) > 0) { split(x, a, "\t"); if (tolower(a[2]) ~ /ole/) ole[a[1]] = 1 }
              while ((getline x < M) > 0) { split(x, a, "\t"); if (a[1] in ole) inole[a[4]] = 1 } }
      # 外から作れる公開クラス = VB_Exposed = True かつ VB_Creatable = False でない（PublicNotCreatable は入口に数えない）
      { k = tolower($1); gsub(/[\200-\377]+/, "?", k) }
      $4 == "True" && $5 != "PublicNotCreatable" && (k in inole) { print "com", $2, $5, $1 }' "$TMPD/vbfiles.tsv"
  } > "$TMPD/ep.tsv"
}

# コードモジュール（ディスク）→ $TMPD/mods.tsv : キー（小文字のパス）  名前  種類  path
mods_build() {
  [ -f "$TMPD/mods.tsv" ] && return 0
  vb_lex
  awk -F '\t' -v OFS='\t' 'tolower($1) !~ /\.frm$/ { k = tolower($1); gsub(/[\200-\377]+/, "?", k); print k, $2, $3, $1 }' "$TMPD/vbfiles.tsv" | sort > "$TMPD/mods.tsv"
}

# -----------------------------------------------------------------------------
# サブコマンド
# 【出力は一時ファイルに溜めてから 1 回で出す】Git Bash では読み手（| head）が先に閉じた管に複数のプロセスが書くと止まることがある
# -----------------------------------------------------------------------------
main() {
case "$SUB" in
  ep)
    # 入口 = 画面（.frm の VB.Form / MDIForm）＋ 実行ファイルのプロジェクトの起動点 ＋ ActiveX の公開クラス
    ep_build
    awk 'END { print (NR ? NR : "unknown") }' "$TMPD/ep.tsv"
    ;;
  list-ep)
    ep_build
    sort "$TMPD/ep.tsv"
    ;;
  ep-diff)
    # 経路A: ディスクの .frm（VB.Form / MDIForm）。経路B: .vbp の Form= の宣言（解いたパス）
    screens_build; projects_parse
    awk -F '\t' '$3 ~ /(^|\.)(Form|MDIForm|UserForm)$/ { print $1 }' "$TMPD/screens.tsv" | sort -u > "$TMPD/eA"
    awk -F '\t' 'tolower($2) == "form" { print $4 }' "$TMPD/members.tsv" | sort -u > "$TMPD/eB"
    echo "経路A（ディスクの画面）: $(wc -l < "$TMPD/eA" | tr -d ' ')"
    echo "経路B（.vbp の Form= の宣言）: $(wc -l < "$TMPD/eB" | tr -d ' ')"
    [ -s "$TMPD/vbp.lst" ] || echo "★.vbp が 1 つも無い（プロジェクトの宣言がソースに無い）。経路B を単一経路として理由を書く"
    echo "== 経路A のみ（どの .vbp にも入らない画面。死蔵・別のプロジェクトの写し・.vbp がソースに無いの別） =="
    comm -23 "$TMPD/eA" "$TMPD/eB" | sed 's/^/  /'
    echo "== 経路B のみ（.vbp が宣言するのにファイルが無い。参照切れ・絶対パス・SCAN_EXCLUDE で外したの別） =="
    comm -13 "$TMPD/eA" "$TMPD/eB" | awk -F '\t' -v M="$TMPD/members.tsv" 'BEGIN { while ((getline x < M) > 0) { split(x, a, "\t"); w[a[4]] = w[a[4]] " " a[1] ":" a[6] } } { print "  " $0 "\t" w[$0] }'
    echo "== 複数の .vbp が同じ画面を宣言する（共有の画面。仕様は 1 つに書き、使うプロジェクトを列挙する） =="
    awk -F '\t' 'tolower($2) == "form" { c[$4]++; w[$4] = w[$4] " " $1 } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/members.tsv" | sort
    echo "== 同じ名前の画面が複数ある（VB_Name が重なる。別のプロジェクトの写しか、版違いか） =="
    awk -F '\t' '$3 ~ /(^|\.)(Form|MDIForm|UserForm)$/ { k = tolower($2); c[k]++; w[k] = w[k] " " $4 } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/screens.tsv" | sort
    ;;
  mod)
    # モジュール = ディスクのコードモジュール（.bas / .cls / .ctl / .dob / .pag / .dsr）
    mods_build
    awk 'END { print (NR ? NR : "unknown") }' "$TMPD/mods.tsv"
    ;;
  list-mod)
    mods_build
    awk -F '\t' -v OFS='\t' '{ print $3, $2, $4 }' "$TMPD/mods.tsv" | sort
    ;;
  mod-diff)
    # 経路A: ディスクのコードモジュール。経路B: .vbp の Module= / Class= / UserControl= / Designer= / PropertyPage= / UserDocument= の宣言
    mods_build; projects_parse
    cut -f1 "$TMPD/mods.tsv" | sort -u > "$TMPD/mA"
    awk -F '\t' 'tolower($2) != "form" { print $4 }' "$TMPD/members.tsv" | sort -u > "$TMPD/mB"
    echo "経路A（ディスクのコードモジュール）: $(wc -l < "$TMPD/mA" | tr -d ' ')"
    echo "経路B（.vbp の宣言）: $(wc -l < "$TMPD/mB" | tr -d ' ')"
    [ -s "$TMPD/vbp.lst" ] || echo "★.vbp が 1 つも無い（プロジェクトの宣言がソースに無い）。経路B を単一経路として理由を書く"
    echo "== 経路A のみ（どの .vbp にも入らないモジュール。死蔵・別のプロジェクトの写し・.vbp がソースに無いの別） =="
    comm -23 "$TMPD/mA" "$TMPD/mB" | sed 's/^/  /'
    echo "== 経路B のみ（.vbp が宣言するのにファイルが無い。参照切れ・絶対パス・SCAN_EXCLUDE で外したの別） =="
    comm -13 "$TMPD/mA" "$TMPD/mB" | awk -v M="$TMPD/members.tsv" 'BEGIN { while ((getline x < M) > 0) { split(x, a, "\t"); w[a[4]] = w[a[4]] " " a[1] ":" a[6] } } { print "  " $0 "\t" w[$0] }'
    echo "== 複数の .vbp が同じモジュールを宣言する（共有のモジュール） =="
    awk -F '\t' 'tolower($2) != "form" { c[$4]++; w[$4] = w[$4] " " $1 } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/members.tsv" | sort
    echo "== グループ（.vbg）が指すのに無い .vbp =="
    awk -F '\t' -v P="$TMPD/projects.tsv" 'BEGIN { while ((getline x < P) > 0) { split(x, a, "\t"); has[tolower(a[1])] = 1 } } !($2 in has) { print "  " $2 "\t" $1 ":" $4 }' "$TMPD/vbg.tsv"
    ;;
  list-projects)
    projects_parse
    awk -F '\t' -v OFS='\t' -v M="$TMPD/members.tsv" -v G="$TMPD/vbg.tsv" '
      BEGIN { while ((getline x < M) > 0) { split(x, a, "\t"); n[a[1]]++ } while ((getline x < G) > 0) { split(x, a, "\t"); g[a[2]] = g[a[2]] " " a[1] } }
      { print $1, $2, $3, "Startup=" $4, "members=" n[$1] + 0, (tolower($1) in g ? "vbg:" g[tolower($1)] : "") }' "$TMPD/projects.tsv" | sort
    ;;
  list-controls)
    vb_lex
    awk -F '\t' -v OFS='\t' '{ print $1 ":" $6, $2, $3, $4, ($5 == "" ? "" : "Index=" $5), ($7 == "" ? "" : "RecordSource=" $7), ($8 == "" ? "" : "DataSource=" $8), ($9 == "" ? "" : "Connect=" $9) }' "$TMPD/controls.tsv"
    ;;
  list-handlers)
    procs_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4, $7, $1 ":" $6 }' "$TMPD/handlers.tsv" | sort
    ;;
  list-procs)
    procs_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4, $5, $1 ":" $6 }' "$TMPD/procs.tsv"
    ;;
  bnd)
    bnd_build
    n=$(wc -l < "$TMPD/bndref.tsv" | tr -d ' ')
    [ "${n:-0}" -gt 0 ] && echo "$n" || echo unknown
    ;;
  list-bnd)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4 }' "$TMPD/bndref.tsv"
    ;;
  bnd-schema)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3 }' "$TMPD/bnddef.tsv"
    ;;
  bnd-diff)
    bnd_build
    cut -f1 "$TMPD/bndref.tsv" > "$TMPD/bA"; cut -f1 "$TMPD/bnddef.tsv" > "$TMPD/bB"
    echo "経路A（参照側: SQL ＋ 表名だけの Open ＋ データコントロール）: $(wc -l < "$TMPD/bA" | tr -d ' ')"
    echo "経路B（定義側: CREATE TABLE ＋ CreateTableDef）: $(wc -l < "$TMPD/bB" | tr -d ' ')"
    if [ ! -s "$TMPD/bA" ] && [ ! -s "$TMPD/bB" ]; then echo "★参照側も定義側も 0 件（DB を使わない、または SQL を静的に読めない）"
    elif [ ! -s "$TMPD/bB" ]; then echo "★定義側が 0 件（スキーマがソースに無い: Access の .mdb の中・別リポジトリ・DB のダンプだけ）。経路B を単一経路として理由を書く"; fi
    echo "== 経路A のみ（参照されるのに定義が無い） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bndref.tsv" "$TMPD/bB" | awk -F '\t' '{ print "  " $2 "\t" $3 "\t" $4 }'
    echo "== 経路B のみ（定義されるのに参照されない） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bnddef.tsv" "$TMPD/bA" | awk -F '\t' '{ print "  " $2 "\t" $3 }'
    echo "== SQL ファイルの INSERT にだけ出る表（初期データ。経路A に入れない） =="
    awk -F '\t' '{ print "  " $2 "\t" $3 }' "$TMPD/bndsf.tsv"
    ;;
  list-crud)
    sql_build
    awk -F '\t' -v OFS='\t' '$3 != "temp" { print $1, $2, $3, $4 }' "$TMPD/sql.tsv" | sort -u
    ;;
  list-refs)
    projects_parse
    awk -F '\t' -v OFS='\t' '{ print $1 ":" $4, $2, $3 }' "$TMPD/vbrefs.tsv" | sort
    ;;
  list-external)
    # 外部境界: Declare の Win32 API・CreateObject / GetObject の COM・ファイル I/O（Open ... For）・Shell
    procs_build
    awk -F '\t' -v OFS='\t' '$4 == "declare" { print "api", $5, $1 ":" $6 }' "$TMPD/procs.tsv"
    awk -F '\t' -v OFS='\t' '{ t = tolower($4); r = $4
        while (match(t, /(createobject|getobject)[ ]*\([ ]*\001[^\002]*\002/)) { w = substr(r, RSTART, RLENGTH); sub(/^[^\001]*\001/, "", w); sub(/\002$/, "", w); print "com", w, $1 ":" $2; t = substr(t, RSTART + RLENGTH); r = substr(r, RSTART + RLENGTH) }
        m = tolower($3); if (m ~ /(^|[^a-z0-9_.])open[ ]+[^ ].*[ ]for[ ]+(input|output|append|binary|random)/) print "file", "open ... for", $1 ":" $2
        if (m ~ /(^|[^a-z0-9_.])shell[ (]/) print "shell", "shell", $1 ":" $2 }' "$TMPD/vbcode.tsv"
    ;;
  scope)
    list_files '*.vbp' '*.frm' '*.bas' '*.cls' '*.ctl' '*.dsr' '*.pag' '*.dob' > "$TMPD/scope.lst"
    awk -F '/' -v OFS='\t' 'NF > 2 { d = $1 "/" $2; if (NF > 3) d = d "/" $3; c[d]++ } NF == 2 { c["."]++ } END { for (d in c) print d, c[d] }' "$TMPD/scope.lst" | sort
    ;;
  idents-form)
    screens_build
    awk -F '\t' '$3 ~ /(^|\.)(Form|MDIForm|UserForm)$/ { print $2 }' "$TMPD/screens.tsv" | awk '{ k = tolower($0); c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort | awk '!/[\200-\377]/'
    ;;
  idents-module)
    mods_build
    cut -f2 "$TMPD/mods.tsv" | awk '{ k = tolower($0); c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort | awk '!/[\200-\377]/'
    ;;
  idents-table)
    bnd_build
    cut -f1 "$TMPD/bndref.tsv" "$TMPD/bnddef.tsv" | sort -u > "$TMPD/idk"
    cut -f2 "$TMPD/sql.tsv" | awk -v K="$TMPD/idk" 'BEGIN { while ((getline x < K) > 0) want[x] = 1 } { k = tolower($0); if (!(k in want)) next; c[k, $0]++; if (c[k, $0] > b[k]) { b[k] = c[k, $0]; s[k] = $0 } } END { for (k in s) print s[k] }' | sed '/^$/d' | sort | awk '!/[\200-\377]/'
    ;;
  idents-nonascii)
    # ASCII 以外を含む識別子（cp1252 の á・Shift_JIS の名前）は、ソースのバイト列のままでは UTF-8 の仕様本文と突き合わせられない（G-IDENT が永久に未記載にする）。
    #   idents-form / idents-module / idents-table から外し、ここに種類つきで出す。仕様には読める綴りで書き、この一覧を見て手で確かめる（enumeration.md 落とし穴 11）
    screens_build; mods_build; bnd_build
    { awk -F '\t' '$3 ~ /(^|\.)(Form|MDIForm|UserForm)$/ { print "form\t" $2 }' "$TMPD/screens.tsv"; awk -F '\t' '{ print "module\t" $2 }' "$TMPD/mods.tsv"; awk -F '\t' '{ print "table\t" $2 }' "$TMPD/bndref.tsv" "$TMPD/bnddef.tsv"; } | awk '/[\200-\377]/' | sort -u
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-projects|list-controls|list-handlers|list-procs|list-crud|list-refs|list-external|scope|idents-form|idents-table|idents-module|idents-nonascii} <source-path>" >&2
    exit 2
    ;;
esac
}
main > "$TMPD/out.txt"
rc=$?
cat "$TMPD/out.txt" 2>/dev/null || true
exit "$rc"
