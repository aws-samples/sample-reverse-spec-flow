#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（java-struts1-ejb2 / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 入口の 2 経路（宣言が指すクラス / Java 側の Action・MDB の派生クラス）の要素差分
#   mod-diff              → 配備単位の 2 経路（ビルド定義 / 配備記述子の持ち主）の要素差分
#   bnd-schema            → DB 表の経路B（CREATE TABLE）の一覧
#   bnd-diff              → DB 表の 2 経路（参照側 / 定義側）の要素差分
#   list-ejb              → EJB の一覧（ejb-jar.xml と XDoclet の @ejb.bean の両方）
#   ejb-diff              → EJB の 2 経路（宣言された ejb-class / SessionBean・EntityBean・MessageDrivenBean の実装クラス）の要素差分
#   list-tx               → EJB のトランザクション属性と権限（container-transaction・method-permission と XDoclet の @ejb.transaction・@ejb.permission）
#   list-forwards         → 画面遷移の辺（action の forward・global-forwards・input・XDoclet の @struts.action-forward）
#   list-forms            → フォーム Bean（form-bean・form-property・XDoclet の @struts.form）
#   list-validation       → 入力検証（validation.xml の form / field / depends）
#   list-dispatch         → DispatchAction 系のクラスと、要求を受けるメソッド（1 つの宣言が複数の操作に分かれる）
#   list-refs             → JSP からの参照（html:form / html:link 等の action・.do のリンク）
#   list-crud             → ファイル × 表 × 操作（select / insert / update / delete / create）
#   scope                 → ディレクトリごとの件数（同梱ライブラリ・生成物を見つけて SCAN_EXCLUDE を決める）
#   idents-table | idents-endpoint | idents-ejb → 識別子の抽出（G-IDENT 用。出典の綴りで出す）
#
# 環境変数（未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む。Phase 4 の再実行で付け忘れないように）:
#   SCAN_EXCLUDE : 走査から外すパスの POSIX ERE（`./` 始まりの相対パスに当てる。例: '^\./lib/'）。
#                  同梱した第三者ライブラリのソースを外す。外したものは ADR で処分する
#   GEN_EXCLUDE  : ビルドの生成物として外すパスの POSIX ERE。既定は '(^|/)(target|build|dist|classes|bin|out)/'。
#                  パスの最初の /src/ か /java/ より前の部分にだけ当てる（パッケージ名の out / dist を外さない）。
#                  XDoclet が生成した struts-config.xml / ejb-jar.xml を数えると宣言が倍になる（enumeration.md 落とし穴 1）。
#                  生成物しか無い（ソースの XDoclet タグも XML も無い）ときだけ GEN_EXCLUDE='' で外す
#
# 実測検証（2026-10-25）: xPetstore 3.1（Struts 1 ＋ EJB 2.0 CMP。記述子は XDoclet で生成）、
#   Apache Struts 1.3.10 のサンプル（MailReader・examples。ワイルドカード・extends・モジュール）、
#   Java Pet Store 1.3.2（EJB 2.0 の手書きの ejb-jar.xml 18 本。Web 層は独自の MVC）。値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。日本の旧資産は Shift_JIS / EUC-JP が多く、
#   UTF-8 ロケールの awk/grep は不正バイトで黙って行を落とす（enumeration.md 落とし穴 10）。
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
# `find` は引数のリンクを辿らず、`grep -r` は実装で違う。入口で 1 度だけ物理パスに解決する。
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
      last = v; seen = 1 }
    END { if (seen) printf "%s\n", last }'
}
[ -n "${SCAN_EXCLUDE+x}" ] || SCAN_EXCLUDE="$(cfg_get SCAN_EXCLUDE)"
if [ -z "${GEN_EXCLUDE+x}" ]; then
  _ge="$(cfg_get GEN_EXCLUDE; echo x)"; _ge="${_ge%x}"
  # 設定ファイルに行が無ければ既定値。行があれば空でもその値（空 = 生成物も数える）
  if [ -n "$_ge" ]; then GEN_EXCLUDE="${_ge%$'\n'}"; else GEN_EXCLUDE='(^|/)(target|build|dist|classes|bin|out)/'; fi
fi
export SCAN_EXCLUDE="${SCAN_EXCLUDE:-}" GEN_EXCLUDE

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
# 出力のパスは解析対象からの相対（`./` 始まり）にする。引用（path:line）にそのまま使えるように。
cd "$SRC" || { echo "unknown"; exit 0; }

# 走査対象のファイル一覧（1 行 1 パス）。VCS 管理領域・生成物（GEN_EXCLUDE）・SCAN_EXCLUDE を除く。拡張子は大小を区別しない。
list_files() { # $@ = -iname のパターン
  local first=1
  local args=()
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -name CVS -o -name node_modules \) -prune -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort \
    | gen_filter keep \
    | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; }
}
# 【GEN_EXCLUDE はソースの根より前の部分にだけ当てる】Java のパッケージ名にも out / dist / bin がある（com.acme.out.OutAction）。
#   パスを最初の /src/ か /java/ で切り、その前の部分（と、切れないときは全体）に当てる。build/java/... の生成物は前の部分の build/ で外れる
#   $1 = keep（外れないものを出す）／ drop（外れるものを出す）
gen_filter() {
  awk -v G="$GEN_EXCLUDE" -v M="$1" '
    { p = $0; i = index(p, "/src/"); j = index(p, "/java/"); if (j > 0 && (i == 0 || j < i)) i = j
      q = (i > 0) ? substr(p, 1, i) : p; x = (G != "" && q ~ G)
      if ((M == "keep" && !x) || (M == "drop" && x)) print }'
}

# 複数のファイルをまとめて読む: stdin = ファイル一覧 → path<TAB>行番号<TAB>行（CR と先頭の BOM を外し、TAB を空白にする。UTF-16 は NUL を落とす）
# 【ファイルごとにプロセスを起こさない】Windows（Git Bash）ではプロセス起動が遅い。UTF-16 のファイルだけを先に grep で見つけて
#   個別に読み、残りは awk 1 回で読む。
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
# XML の字句解析（落とし穴 2: 属性・子要素は複数行に分かれる。`grep '<action '` は行頭の `<action` 単独行を落とす）
#   stdin = ファイル一覧 → 1 行 1 事象:
#   E<TAB>path<TAB>行<TAB>id<TAB>親 id<TAB>祖父 id<TAB>要素の経路（/a/b/c）<TAB>属性の文字列
#   T<TAB>path<TAB>行<TAB>id<TAB>親 id<TAB>祖父 id<TAB>要素の経路<TAB>テキスト（直近に開いた要素の中身）
#   注釈（<!-- -->）は改行だけを残して消す。CDATA の中身はテキストとして残す。名前空間の接頭辞（j2ee:）は外す。
# -----------------------------------------------------------------------------
xml_events() {
  read_many | awk -F '\t' -v OFS='\t' -v sq="'" '
    # 【引用符の中の > でタグを切らない】属性値に > を書いても XML として合法（parameter="a>b"）
    BEGIN { TAGRE = "<([^>\"" sq "]|\"[^\"]*\"|" sq "[^" sq "]*" sq ")*>" }
    function flush(   t, out, i, r, e, c, ln, pre, tg, inner, nl, nl2, name, attrs, selfc, txt, d, k) {
      if (pf == "") return
      t = buf; out = ""
      while ((i = index(t, "<!--")) > 0) {
        out = out substr(t, 1, i - 1); r = substr(t, i + 4); e = index(r, "-->")
        c = (e ? substr(r, 1, e - 1) : r); gsub(/[^\n]/, "", c); out = out c; t = (e ? substr(r, e + 3) : "") }
      t = out t; out = ""
      while ((i = index(t, "<![CDATA[")) > 0) {
        out = out substr(t, 1, i - 1); r = substr(t, i + 9); e = index(r, "]]>")
        c = (e ? substr(r, 1, e - 1) : r); gsub(/</, "\\&lt;", c); gsub(/>/, "\\&gt;", c); out = out c; t = (e ? substr(r, e + 3) : "") }
      t = out t
      ln = 1; d = 0; st_n[0] = ""; st_i[0] = 0; st_p[0] = ""
      while (match(t, TAGRE)) {
        pre = substr(t, 1, RSTART - 1); tg = substr(t, RSTART + 1, RLENGTH - 2); t = substr(t, RSTART + RLENGTH)
        txt = pre; nl = gsub(/\n/, " ", txt); gsub(/^[ \t]+|[ \t]+$/, "", txt)
        if (txt != "" && d > 0) print "T", pf, ln, st_i[d], st_i[d - 1], (d > 1 ? st_i[d - 2] : 0), st_p[d], txt
        ln += nl
        inner = tg; nl2 = gsub(/\n/, " ", inner)
        if (inner ~ /^[?!]/) { ln += nl2; continue }
        if (inner ~ /^\//) {
          name = substr(inner, 2); sub(/[ \t].*$/, "", name); sub(/^[A-Za-z0-9_.-]+:/, "", name)
          for (k = d; k > 0; k--) if (st_n[k] == name) break
          if (k > 0) d = k - 1
          ln += nl2; continue }
        selfc = (inner ~ /\/[ \t]*$/); sub(/\/[ \t]*$/, "", inner)
        name = inner; sub(/[ \t].*$/, "", name); attrs = substr(inner, length(name) + 1); sub(/^[A-Za-z0-9_.-]+:/, "", name)
        seq++; d++; st_n[d] = name; st_i[d] = seq; st_p[d] = st_p[d - 1] "/" name
        print "E", pf, ln, seq, st_i[d - 1], (d > 1 ? st_i[d - 2] : 0), st_p[d], attrs
        if (selfc) d--
        ln += nl2
      }
      buf = ""
    }
    $1 != pf { flush(); pf = $1; buf = "" }
    { l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l); buf = buf l "\n" }
    END { flush() }'
}

# XML の分類（ルート要素で見る。Struts 1 の設定ファイルは名前が自由: struts-config-admin.xml・/WEB-INF/admin/struts.xml 等）
xml_classify() {
  [ -f "$TMPD/xml.lst" ] && return 0
  list_files '*.xml' '*.xmi' > "$TMPD/xml.lst"
  : > "$TMPD/x-struts.lst"; : > "$TMPD/x-web.lst"; : > "$TMPD/x-ejb.lst"; : > "$TMPD/x-app.lst"; : > "$TMPD/x-valid.lst"
  : > "$TMPD/x-frag.lst"; : > "$TMPD/x-other.lst"; : > "$TMPD/x-s2.lst"; : > "$TMPD/xev.tsv"
  [ -s "$TMPD/xml.lst" ] || return 0
  # 字句解析は全 XML について 1 回だけ行い（$TMPD/xev.tsv）、分類も解析もそこから読む（Windows ではプロセスと読み直しが遅い）。
  # ルート要素（最初の開始タグ）で分類する。注釈の中の要素は字句解析で消えているので誤分類しない
  xml_events < "$TMPD/xml.lst" > "$TMPD/xev.tsv"
  awk -F '\t' -v D="$TMPD" '
    function cls(f) {
      if (root == "/struts-config") print f > (D "/x-struts.lst")
      else if (root == "/web-app") print f > (D "/x-web.lst")
      else if (root == "/ejb-jar") print f > (D "/x-ejb.lst")
      else if (root == "/application" && hasmod) print f > (D "/x-app.lst")
      else if (root == "/form-validation") print f > (D "/x-valid.lst")
      else if (root == "/struts" && haspkg) print f > (D "/x-s2.lst")
      else if (frag || root ~ /^\/(servlet|filter|servlet-mapping|filter-mapping)$/) print f > (D "/x-frag.lst")
      else print f > (D "/x-other.lst")
    }
    FILENAME != D "/xev.tsv" { all[$0] = 1; next }
    $1 != "E" { next }
    $2 != pf { if (pf != "") { cls(pf); done[pf] = 1 } pf = $2; root = $7; hasmod = 0; haspkg = 0; frag = 0 }
    $7 == "/application/module" { hasmod = 1 }
    $7 == "/struts/package" { haspkg = 1 }
    $7 ~ /(^|\/)(filter|servlet)-mapping$/ || ($7 ~ /(^|\/)action$/ && $8 ~ /(^|[ \t])path[ \t]*=/) { frag = 1 }
    END { if (pf != "") { cls(pf); done[pf] = 1 } for (f in all) if (!(f in done)) print f > (D "/x-other.lst") }' "$TMPD/xml.lst" "$TMPD/xev.tsv"
  for l in struts web ejb app valid s2 frag other; do sort -o "$TMPD/x-$l.lst" "$TMPD/x-$l.lst"; done
}

# 解析済みの XML の事象から、指定したファイル一覧のものだけを出す（$@ = 一覧のファイル）
xev() {
  xml_classify
  local l="$TMPD/xev.want.$$.$RANDOM"
  cat "$@" > "$l"
  awk -F '\t' -v L="$l" 'BEGIN { while ((getline x < L) > 0) w[x] = 1 } ($2 in w)' "$TMPD/xev.tsv"
}

# -----------------------------------------------------------------------------
# web.xml の解析 → $TMPD/web.tsv
#   S webxml 行 servlet-name servlet-class        （servlet の宣言）
#   P webxml 行 servlet-name param-name param-value （init-param）
#   M webxml 行 servlet-name url-pattern           （servlet-mapping）
#   F webxml 行 filter-name url-or-servlet         （filter-mapping）
#   C webxml 行 filter-name filter-class           （filter の宣言）
#   XDoclet の断片（x-frag.lst）の filter-mapping / servlet-mapping も同じ形で出す（webxml 欄は断片のパス）
# -----------------------------------------------------------------------------
web_parse() {
  [ -f "$TMPD/web.tsv" ] && return 0
  xml_classify
  xev "$TMPD/x-web.lst" "$TMPD/x-frag.lst" | awk -F '\t' -v OFS='\t' '
    $1 == "E" && $7 ~ /(^|\/)(servlet|filter|servlet-mapping|filter-mapping|init-param)$/ { kind[$4] = $7; f[$4] = $2; ln[$4] = $3; par[$4] = $5; order[++n] = $4 }
    $1 == "T" { e = $7; sub(/^.*\//, "", e); v[$4] = $8
      if (e == "servlet-name" || e == "filter-name") nm[$5] = $8
      else if (e == "servlet-class" || e == "filter-class") cl[$5] = $8
      else if (e == "url-pattern") { up[$5] = up[$5] (up[$5] == "" ? "" : "\001") $8 }
      else if (e == "param-name") pn[$5] = $8
      else if (e == "param-value") pv[$5] = $8 }
    END {
      for (i = 1; i <= n; i++) { id = order[i]; k = kind[id]
        if (k ~ /(^|\/)servlet$/) print "S", f[id], ln[id], nm[id], cl[id]
        else if (k ~ /(^|\/)filter$/) print "C", f[id], ln[id], nm[id], cl[id]
        else if (k ~ /init-param$/ && k ~ /\/servlet\/init-param$/) print "P", f[id], ln[id], nm[par[id]], pn[id], pv[id]
        else if (k ~ /servlet-mapping$/ || k ~ /filter-mapping$/) {
          m = split(up[id], a, "\001"); t = (k ~ /servlet-mapping$/) ? "M" : "F"
          if (m == 0 && t == "F") print t, f[id], ln[id], nm[id], "(servlet)"
          for (j = 1; j <= m; j++) print t, f[id], ln[id], nm[id], a[j] } } }' > "$TMPD/web.tsv"
}

# -----------------------------------------------------------------------------
# Java の解析
#   $TMPD/classes.tsv : fqcn  simple  kind(class|abstract|interface)  super(書かれたまま)  ifaces(カンマ区切り・書かれたまま)  path:line  package
#   $TMPD/imports.tsv : path  import（a.b.C / a.b.*）
#   $TMPD/xd.tsv      : path  行  fqcn  level(class|method)  タグ名  属性の文字列        （XDoclet の javadoc タグ）
#   $TMPD/jstr.tsv    : path  行  文の中の文字列リテラルを空白でつないだもの            （SQL の抽出用）
#   $TMPD/meth.tsv    : fqcn  メソッド名  引数の型（カンマ区切り）  path:line        （public メソッド。DispatchAction の操作）
#   注釈と文字列を区別して読む（`/* class X */` や "class" を含む文字列で宣言を誤認しない）
# -----------------------------------------------------------------------------
java_parse() {
  [ -f "$TMPD/classes.tsv" ] && return 0
  list_files '*.java' > "$TMPD/java.lst"
  : > "$TMPD/classes.tsv"; : > "$TMPD/imports.tsv"; : > "$TMPD/xd.tsv"; : > "$TMPD/jstr.tsv"; : > "$TMPD/meth.tsv"
  [ -s "$TMPD/java.lst" ] || return 0
  read_many < "$TMPD/java.lst" | awk -F '\t' -v OFS='\t' -v D="$TMPD" -v dq='"' -v sq="'" '
    function flushtag() { if (tg != "") { tags[++nt] = tg; tagv[nt] = tv; tagl[nt] = tl } tg = ""; tv = "" }
    function nlc(x) { return gsub(/\n/, "\n", x) }
    function endfile(   s, s2, i, j, c, n, hdr, kw, nm, mods, sup, ifs, p, q, lnn, cl, pre, args, body, k, fq, lv, mm, off, a, t, ty) {
      if (pf == "") return
      flushtag()
      # ---- 宣言の解析（注釈を外し、文字列を空にしたコードで） ----
      s = code; off = 0
      while (match(s, /(^|[^A-Za-z0-9_$.])(class|interface)[ \n]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
        pre = substr(s, 1, RSTART); hdr = substr(s, RSTART, RLENGTH); s2 = substr(s, RSTART + RLENGTH)
        lnn = 1 + off + nlc(pre); off += nlc(substr(s, 1, RSTART + RLENGTH - 1))
        kw = (hdr ~ /interface[ \n]/) ? "interface" : "class"
        nm = hdr; sub(/^.*(class|interface)[ \n]+/, "", nm)
        # 修飾子は直前の文の区切り（; { }）から宣言までに書かれる
        mods = substr(s, 1, RSTART); i = 0
        for (j = length(mods); j > 0; j--) { c = substr(mods, j, 1); if (c == ";" || c == "{" || c == "}") { i = j; break } }
        mods = substr(mods, i + 1)
        p = index(s2, "{"); body = (p ? substr(s2, 1, p - 1) : s2)
        gsub(/\n/, " ", body); gsub(/<[^<>]*>/, "", body); gsub(/<[^<>]*>/, "", body)
        sup = ""; ifs = ""
        if (match(body, /(^|[ ])extends[ ]+[A-Za-z0-9_$.]+([ ]*,[ ]*[A-Za-z0-9_$.]+)*/)) { sup = substr(body, RSTART, RLENGTH); sub(/^[ ]*extends[ ]+/, "", sup); gsub(/[ ]/, "", sup) }
        if (match(body, /(^|[ ])implements[ ]+[A-Za-z0-9_$.]+([ ]*,[ ]*[A-Za-z0-9_$.]+)*/)) { ifs = substr(body, RSTART, RLENGTH); sub(/^[ ]*implements[ ]+/, "", ifs); gsub(/[ ]/, "", ifs) }
        # インタフェースの extends は複数ありうる → ifaces 側に寄せる
        if (kw == "interface") { ifs = sup; sup = "" }
        k = (kw == "interface") ? "interface" : (mods ~ /(^|[^A-Za-z])abstract([^A-Za-z]|$)/ ? "abstract" : "class")
        fq = (pkg == "" ? nm : pkg "." nm)
        print fq, nm, k, sup, ifs, pf ":" lnn, pkg > (D "/classes.tsv")
        if (first_fq == "") first_fq = fq
        s = s2
      }
      # ---- public メソッド（DispatchAction の操作の候補。引数の型だけを取る） ----
      # 総称型・配列の [] を先に消す（行数は変えない）
      s = code; gsub(/<[^<>\n]*>/, "", s); gsub(/<[^<>\n]*>/, "", s); gsub(/\[[ ]*\]/, "", s); off = 0
      while (match(s, /public[ \n]+((static|final|synchronized)[ \n]+)*[A-Za-z_$][A-Za-z0-9_$.]*[ \n]+[A-Za-z_$][A-Za-z0-9_$]*[ \n]*\([^()]*\)/)) {
        pre = substr(s, 1, RSTART); mm = substr(s, RSTART, RLENGTH)
        lnn = 1 + off + nlc(pre); off += nlc(substr(s, 1, RSTART + RLENGTH - 1)); s = substr(s, RSTART + RLENGTH)
        gsub(/\n/, " ", mm)
        if (mm ~ /(^|[ ])(class|interface|new|return)[ ]/) continue
        nm = mm; sub(/[ ]*\(.*$/, "", nm); sub(/^.*[ ]/, "", nm)
        args = mm; sub(/^[^(]*\(/, "", args); sub(/\)[ ]*$/, "", args)
        n = split(args, a, ","); ty = ""
        for (j = 1; j <= n; j++) { t = a[j]; gsub(/^[ ]+|[ ]+$/, "", t); gsub(/(^|[ ])final[ ]/, " ", t); gsub(/^[ ]+/, "", t); sub(/[ ]+[A-Za-z_$][A-Za-z0-9_$]*$/, "", t); sub(/^.*\./, "", t); ty = ty (ty == "" ? "" : ",") t }
        print (first_fq == "" ? "?" : first_fq), nm, ty, pf ":" lnn > (D "/meth.tsv")
      }
      # ---- XDoclet のタグ ----
      for (i = 1; i <= nt; i++) { lv = (tagl[i] in lvl) ? lvl[tagl[i]] : "method"; print pf, tagl[i], (tagc[tagl[i]] != "" ? tagc[tagl[i]] : first_fq), lv, tags[i], tagv[i] > (D "/xd.tsv") }
      # ---- 文字列リテラル（文ごと） ----
      for (i = 1; i <= nst; i++) print pf, stl[i], stv[i] > (D "/jstr.tsv")
      code = ""; pkg = ""; nt = 0; nst = 0; first_fq = ""; delete lvl; delete tagc; delete tags; delete tagv; delete tagl
    }
    $1 != pf { endfile(); pf = $1; inb = 0; injd = 0; cur = ""; curl = 0; pendjd = 0 }
    { ln = $2; l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l)
      if (!inb && l ~ /^[ ]*package[ ]+[A-Za-z0-9_.]+[ ]*;/) { pkg = l; sub(/^[ ]*package[ ]+/, "", pkg); sub(/[ ]*;.*$/, "", pkg) }
      if (!inb && l ~ /^[ ]*import[ ]+(static[ ]+)?[A-Za-z0-9_.*]+[ ]*;/) { im = l; sub(/^[ ]*import[ ]+(static[ ]+)?/, "", im); sub(/[ ]*;.*$/, "", im); print pf, im > (D "/imports.tsv") }
      # 1 文字ずつ: 注釈・文字列・javadoc を切り分ける
      out = ""; n = length(l); i = 1
      while (i <= n) {
        c = substr(l, i, 1)
        if (inb) {
          e = index(substr(l, i), "*/")
          seg = (e ? substr(l, i, e - 1) : substr(l, i))
          if (injd) { # javadoc の行: 行頭の * を外してタグを集める
            t = seg; sub(/^[ ]*\*+[ ]?/, "", t)
            # XDoclet 1.1 のコロン形式（@ejb:bean / @struts:action）も読み、名前は 1.2 の形（@ejb.bean）にそろえる
            if (t ~ /^[ ]*@[a-z]+[.:][a-z][a-z0-9.-]*/) { flushtag(); tg = t; sub(/^[ ]*@/, "", tg); sub(/[ ].*$/, "", tg); sub(/:/, ".", tg); tv = t; sub(/^[ ]*@[^ ]+/, "", tv); tl = ln }
            else if (t ~ /^[ ]*@/) flushtag()
            else if (tg != "") tv = tv " " t }
          if (!e) { i = n + 1; break }
          i += e + 1; inb = 0; if (injd) { flushtag(); injd = 0; pendjd = 1; jdl = ln } ; out = out " "; continue }
        if (c == "/" && substr(l, i + 1, 1) == "/") break
        if (c == "/" && substr(l, i + 1, 1) == "*") { inb = 1; injd = (substr(l, i + 2, 1) == "*" && substr(l, i + 3, 1) != "/"); jstart = nt; i += (injd ? 3 : 2); continue }
        if (c == dq || c == sq) { q = c; j = i + 1; v = ""
          while (j <= n) { d = substr(l, j, 1); if (d == "\\") { v = v substr(l, j, 2); j += 2; continue } if (d == q) break; v = v d; j++ }
          if (q == dq) { cur = cur (cur == "" ? "" : " ") v; if (curl == 0) curl = ln }
          out = out q q; i = j + 1; continue }
        if (c == ";" || c == "{" || c == "}") { if (cur != "") { nst++; stl[nst] = curl; stv[nst] = cur } cur = ""; curl = 0 }
        out = out c; i++
      }
      # javadoc の直後の宣言行で、タグを class か method かに振り分ける
      if (pendjd && out ~ /[^ ]/) {
        lv2 = (out ~ /(^|[^A-Za-z0-9_$])(class|interface)[ ]+[A-Za-z_$]/) ? "class" : "method"
        cn = ""; if (lv2 == "class") { cn = out; sub(/^.*(class|interface)[ ]+/, "", cn); sub(/[^A-Za-z0-9_$].*$/, "", cn); cn = (pkg == "" ? cn : pkg "." cn) }
        for (k = jstart + 1; k <= nt + (tg != "" ? 1 : 0); k++) if (k <= nt) { lvl[tagl[k]] = lv2; tagc[tagl[k]] = cn }
        pendjd = 0 }
      code = code out "\n" }
    END { endfile() }'
}

# 型の解決と派生の判定 → $TMPD/kinds.tsv : fqcn  kind  flags（action,dispatch,session,entity,mdb,timer,actionservlet。カンマ区切り）  path:line
#   【基底の判定は import で確かめる】`extends Action` は WebWork / XWork にもある（実測: xPetstore の servlet 版は
#   webwork.action.ActionSupport を継承する。名前だけで Struts と読むと別のフレームワークの画面が混ざる。落とし穴 6）
resolve_kinds() {
  [ -f "$TMPD/kinds.tsv" ] && return 0
  java_parse
  awk -F '\t' -v OFS='\t' '
    BEGIN {
      R["org.apache.struts.action.Action"] = "action"
      split("DispatchAction LookupDispatchAction MappingDispatchAction EventDispatchAction", da, " ")
      for (i in da) R["org.apache.struts.actions." da[i]] = "action,dispatch"
      split("ForwardAction IncludeAction LocaleAction SwitchAction DownloadAction", oa, " ")
      for (i in oa) R["org.apache.struts.actions." oa[i]] = "action"
      # Struts 1 の後期の資産に多い基底: Tiles の Action・Spring の Struts 連携（ActionSupport 系・DelegatingActionProxy）
      R["org.apache.struts.tiles.actions.TilesAction"] = "action"
      R["org.springframework.web.struts.ActionSupport"] = "action"; R["org.springframework.web.struts.DelegatingActionProxy"] = "action"
      split("DispatchActionSupport LookupDispatchActionSupport MappingDispatchActionSupport", sa, " ")
      for (i in sa) R["org.springframework.web.struts." sa[i]] = "action,dispatch"
      R["org.apache.struts.action.ActionServlet"] = "actionservlet"
      R["javax.ejb.SessionBean"] = "session"; R["javax.ejb.EntityBean"] = "entity"
      R["javax.ejb.MessageDrivenBean"] = "mdb"; R["javax.ejb.TimedObject"] = "timer"
      for (k in R) { s = k; sub(/^.*\./, "", s); pk = k; sub(/\.[^.]*$/, "", pk); LIB[pk "." s] = k }
    }
    FILENAME ~ /imports\.tsv$/ { imp[$1] = imp[$1] "\001" $2; next }
    { fq = $1; simple[fq] = $2; kind[fq] = $3; sup[fq] = $4; ifs[fq] = $5; loc[fq] = $6; pkgof[fq] = $7; p = $6; sub(/:[0-9]+$/, "", p); file[fq] = p
      if (!($2 in bysimple)) bysimple[$2] = fq; else bysimple[$2] = bysimple[$2] "\001" fq; order[++n] = fq }
    function res(name, fq,   f, m, a, i, x, pk, c) {
      if (name == "") return ""
      if (name ~ /\./) return name
      f = file[fq]; m = split(imp[f], a, "\001")
      for (i = 1; i <= m; i++) { x = a[i]; if (x != "" && x !~ /\*$/) { c = x; sub(/^.*\./, "", c); if (c == name) return x } }
      if (pkgof[fq] != "" && ((pkgof[fq] "." name) in kind)) return pkgof[fq] "." name
      if (pkgof[fq] == "" && (name in kind)) return name
      for (i = 1; i <= m; i++) { x = a[i]; if (x ~ /\.\*$/) { pk = substr(x, 1, length(x) - 2); if ((pk "." name) in kind) return pk "." name; if ((pk "." name) in LIB) return pk "." name } }
      return "?." name
    }
    END {
      for (i = 1; i <= n; i++) { fq = order[i]; rs[fq] = res(sup[fq], fq); m = split(ifs[fq], a, ","); ri[fq] = ""; for (j = 1; j <= m; j++) ri[fq] = ri[fq] "\001" res(a[j], fq) }
      changed = 1; it = 0
      while (changed && it < 30) { changed = 0; it++
        for (i = 1; i <= n; i++) { fq = order[i]; f = fl[fq]
          x = rs[fq]; if (x in R) f = f "," R[x]; if (x in fl) f = f "," fl[x]
          m = split(ri[fq], a, "\001"); for (j = 1; j <= m; j++) { x = a[j]; if (x == "") continue; if (x in R) f = f "," R[x]; if (x in fl) f = f "," fl[x] }
          # 重複を畳む
          k = split(f, b, ","); g = ""; delete seen; for (j = 1; j <= k; j++) if (b[j] != "" && !(b[j] in seen)) { seen[b[j]] = 1; g = g "," b[j] }
          if (g != fl[fq]) { fl[fq] = g; changed = 1 } } }
      for (i = 1; i <= n; i++) { fq = order[i]; f = fl[fq]; sub(/^,/, "", f); print fq, kind[fq], f, loc[fq], rs[fq] }
    }' "$TMPD/imports.tsv" "$TMPD/classes.tsv" > "$TMPD/kinds.tsv"
}

# XDoclet の属性を 1 つ取り出す awk 関数（前が英数字・`-`・`.` の位置では一致させない: `destination-type=` を `type=` と読まない。落とし穴 4）
AWK_XATTR='function xattr(s, k,   re, v) { re = "(^|[^A-Za-z0-9_.-])" k "[ \t]*=[ \t]*\"[^\"]*\""; if (match(s, re)) { v = substr(s, RSTART, RLENGTH); sub(/^[^=]*=[ \t]*"/, "", v); sub(/"$/, "", v); return v } return "" }
function attr(s, k,   re, v) { re = "(^|[ \t])" k "[ \t]*=[ \t]*(\"[^\"]*\"|" sq "[^" sq "]*" sq ")"; if (match(s, re)) { v = substr(s, RSTART, RLENGTH); sub(/^[^=]*=[ \t]*/, "", v); return substr(v, 2, length(v) - 2) } return "" }'

# -----------------------------------------------------------------------------
# Struts の解析 → $TMPD/actions.tsv / $TMPD/forwards.tsv / $TMPD/forms.tsv / $TMPD/configs.tsv
#   actions : 設定ファイル  行  モジュールの接頭辞  path  type  forward  include  extends  parameter  form(name)  由来(xml|xdoclet|merge)  input
#   forwards: 由来のファイル  行  遷移元（モジュールの接頭辞 + action の path、または (global)）  forward の名前  遷移先  由来
#   forms   : ファイル  行  フォームの名前  型  property の数  由来
#   configs : 設定ファイル  接頭辞  参照した web.xml（参照されていなければ "-"）
# 【モジュール】web.xml の ActionServlet の init-param `config/xxx` が接頭辞 /xxx のモジュールを作る。値はカンマ区切りで複数（落とし穴 3）
# -----------------------------------------------------------------------------
struts_parse() {
  [ -f "$TMPD/actions.tsv" ] && return 0
  xml_classify; web_parse; java_parse
  # web.xml → 設定ファイルと接頭辞
  awk -F '\t' -v OFS='\t' '
    FILENAME ~ /x-frag\.lst$/ { frag[$1] = 1; next }
    # XDoclet の断片（mergedir）の ActionServlet は既定の設定ファイルを持たない（struts-config.xml はタグから生成される）
    $1 == "S" && !($2 in frag) { cls[$2 "\t" $4] = $5; if ($5 ~ /(^|\.)ActionServlet$/) struts[$2 "\t" $4] = 1 }
    $1 == "P" && $5 ~ /^config(\/|$)/ { struts[$2 "\t" $4] = 1; pv[$2 "\t" $4 "\t" $5] = $6; pk[++np] = $2 "\t" $4 "\t" $5 }
    END {
      # 4 列: 解いたパス  接頭辞  web.xml  書かれた値。web.xml が WEB-INF の外にある（conf/web.xml を build でコピーする）と根が解けないので、
      #   struts_parse は書かれた値の後方一致でも探す。config が無く config/xxx だけのときも既定のモジュール（/WEB-INF/struts-config.xml）はある
      for (i = 1; i <= np; i++) { split(pk[i], a, "\t"); w = a[1]; nm = a[3]; root = w; sub(/\/WEB-INF\/[^\/]*$/, "", root); if (root == w) sub(/\/[^\/]*$/, "", root)
        pre = nm; sub(/^config/, "", pre); m = split(pv[pk[i]], v, ","); if (nm == "config") had[a[1] "\t" a[2]] = 1
        for (j = 1; j <= m; j++) { x = v[j]; gsub(/^[ ]+|[ ]+$/, "", x); if (x == "") continue; print root x, pre, w, x } }
      for (k in struts) if (!(k in had)) { split(k, a, "\t"); root = a[1]; sub(/\/WEB-INF\/[^\/]*$/, "", root); if (root == a[1]) sub(/\/[^\/]*$/, "", root)
        print root "/WEB-INF/struts-config.xml", "", a[1], "/WEB-INF/struts-config.xml" } }' "$TMPD/x-frag.lst" "$TMPD/web.tsv" > "$TMPD/configs.ref"
  xev "$TMPD/x-struts.lst" "$TMPD/x-frag.lst" | awk -F '\t' -v OFS='\t' -v sq="'" -v D="$TMPD" "$AWK_XATTR"'
    FILENAME ~ /configs\.ref$/ { p = $1; gsub(/\/\.\//, "/", p); pref[p] = $2; refw[p] = $3; if (!(p in exists)) { nr++; rv[nr] = $4; rp[nr] = $2; rw[nr] = $3 } next }
    FILENAME ~ /x-frag\.lst$/ { frag[$1] = 1; next }
    FILENAME ~ /x-struts\.lst$/ { exists[$1] = 1; next }
    $1 != "E" && $1 != "T" { next }
    { f = $2 }
    !(f in seenf) { seenf[f] = 1; p = f
      if (!(p in pref)) { c = 0; for (i = 1; i <= nr; i++) { v = rv[i]; if (v != "" && length(f) >= length(v) && substr(f, length(f) - length(v) + 1) == v) { c++; hit = i } }
        if (c == 1) { pref[p] = rp[hit]; refw[p] = rw[hit] "（後方一致）" } }
      if (p in pref) { mp[f] = pref[p]; print f, pref[p], refw[p] > (D "/configs.tsv") }
      else if (f in frag) { mp[f] = ""; print f, "", "(XDoclet の断片)" > (D "/configs.tsv") }
      else { mp[f] = "?"; print f, "?", "-" > (D "/configs.tsv") } }
    $1 == "E" && $7 ~ /(^|\/)action-mappings\/action$/ || ($1 == "E" && $7 == "/action" && (f in frag)) {
      a = $8; aid[$4] = mp[f] attr(a, "path")
      print f, $3, mp[f], attr(a, "path"), attr(a, "type"), attr(a, "forward"), attr(a, "include"), attr(a, "extends"), attr(a, "parameter"), attr(a, "name"), ((f in frag) ? "merge" : "xml"), attr(a, "input") > (D "/actions.tsv")
      if (attr(a, "input") != "") print f, $3, mp[f] attr(a, "path"), "(input)", attr(a, "input"), "xml" > (D "/forwards.tsv")
      if (attr(a, "forward") != "") print f, $3, mp[f] attr(a, "path"), "(forward 属性)", attr(a, "forward"), "xml" > (D "/forwards.tsv")
      next }
    $1 == "E" && $7 ~ /\/action\/forward$/ && ($5 in aid) { print f, $3, aid[$5], attr($8, "name"), attr($8, "path"), "xml" > (D "/forwards.tsv"); next }
    $1 == "E" && $7 ~ /\/action\/exception$/ && ($5 in aid) { if (attr($8, "path") != "") print f, $3, aid[$5], "(exception " attr($8, "key") ")", attr($8, "path"), "xml" > (D "/forwards.tsv"); next }
    $1 == "E" && $7 ~ /global-forwards\/forward$/ { print f, $3, mp[f] "(global)", attr($8, "name"), attr($8, "path"), "xml" > (D "/forwards.tsv"); next }
    $1 == "E" && $7 ~ /form-beans\/form-bean$/ { fid[$4] = ++nf; fl[nf] = f "\t" $3; fn[nf] = attr($8, "name"); ft[nf] = attr($8, "type"); fx[nf] = attr($8, "extends"); next }
    $1 == "E" && $7 ~ /form-bean\/form-property$/ && ($5 in fid) { fp[fid[$5]]++; next }
    END { for (i = 1; i <= nf; i++) print fl[i], fn[i], (ft[i] != "" ? ft[i] : "(extends " fx[i] ")"), fp[i] + 0, "xml" > (D "/forms.tsv") }' \
    "$TMPD/x-struts.lst" "$TMPD/configs.ref" "$TMPD/x-frag.lst" -
  touch "$TMPD/actions.tsv" "$TMPD/forwards.tsv" "$TMPD/forms.tsv" "$TMPD/configs.tsv"
  # XDoclet（@struts.action / @struts.action-forward / @struts.form）。クラス自身が type
  awk -F '\t' -v OFS='\t' -v sq="'" -v D="$TMPD" "$AWK_XATTR"'
    $4 != "class" { next }
    $5 == "struts.action" { p = xattr($6, "path"); last[$3] = p
      print $1, $2, "", p, $3, "", "", "", xattr($6, "parameter"), xattr($6, "name"), "xdoclet", xattr($6, "input") >> (D "/actions.tsv")
      if (xattr($6, "input") != "") print $1, $2, p, "(input)", xattr($6, "input"), "xdoclet" >> (D "/forwards.tsv") }
    $5 == "struts.action-forward" { print $1, $2, ($3 in last ? last[$3] : "(" $3 ")"), xattr($6, "name"), xattr($6, "path"), "xdoclet" >> (D "/forwards.tsv") }
    $5 == "struts.form" { print $1, $2, xattr($6, "name"), $3, "-", "xdoclet" >> (D "/forms.tsv") }' "$TMPD/xd.tsv"
}

# 宣言を解いた入口 → $TMPD/ep.tsv : 種類  キー（接頭辞 + path / url / ejb-name / クラス）  type（解いたもの）  path:line  備考
#   種類: action / action-wild（path に * を含む）/ action-base（path が // で始まる。extends の土台）/ servlet / filter / mdb / timer
#   【extends を解く】Struts 1.3 の extends は type・parameter を受け継ぐ（実測 MailReader: /Delete* の type は //BaseAction の {1}Action。落とし穴 5）
#   【重複した path は後の宣言が勝つ】同じモジュールに同じ path を 2 度書くと、Struts は後の宣言で上書きする（実測 MailReader: /Welcome が 2 つ）
ep_build() {
  [ -f "$TMPD/ep.tsv" ] && return 0
  struts_parse; resolve_kinds; ejb_parse; mod_build
  # 【重複と extends はアプリの中で解く】別の WAR に同じ path があっても上書きではない（管理用と利用者用の 2 つの WAR に /login 等）。
  #   アプリ = 最も近い祖先のビルド定義（unit / aggregate）のディレクトリ
  awk -F '\t' -v OFS='\t' -v MODL="$TMPD/mod.tsv" '
    BEGIN { while ((getline x < MODL) > 0) { split(x, a, "\t"); if (a[1] == "unit" || a[1] == "aggregate") has[a[2]] = 1 } }
    function appof(f,   d) { d = f; while (index(d, "/") > 0) { sub(/\/[^\/]*$/, "", d); if (d in has) return d } return "." }
    FILENAME ~ /actions\.tsv$/ { n++; F[n] = $1; L[n] = $2; P[n] = $3; PA[n] = $4; T[n] = $5; FW[n] = $6; IN[n] = $7; EX[n] = $8; PR[n] = $9; O[n] = $11
      A[n] = appof($1); key = A[n] SUBSEP $3 $4; byk[key] = n; next }
    FILENAME ~ /web\.tsv$/ {
      if ($1 == "S") { sc[$2 "\t" $4] = $5; dd = $2; sub(/\/[^\/]*$/, "", dd); scd[dd "\t" $4] = $5 }
      if ($1 == "P" && $5 ~ /^config(\/|$)/) st[$2 "\t" $4] = 1
      if ($1 == "M") { mn++; MW[mn] = $2; ML[mn] = $3; MN[mn] = $4; MU[mn] = $5 }
      if ($1 == "F") { fn++; FWX[fn] = $2; FL[fn] = $3; FN[fn] = $4; FU[fn] = $5 }
      next }
    FILENAME ~ /kinds\.tsv$/ { kf[$1] = $3; next }
    FILENAME ~ /beans\.tsv$/ { if ($1 == "message-driven") { bn++; BN[bn] = $3; BC[bn] = $4; BL[bn] = $10 } next }
    END {
      for (i = 1; i <= n; i++) {
        t = T[i]; pr = PR[i]; e = EX[i]; g = 0
        while ((t == "" || pr == "") && e != "" && g < 10) { k = A[i] SUBSEP P[i] e; if (!(k in byk)) break; j = byk[k]; if (t == "") t = T[j]; if (pr == "") pr = PR[j]; e = EX[j]; g++ }
        dup = (byk[A[i] SUBSEP P[i] PA[i]] != i) ? "（同じ path の後の宣言で上書きされる）" : ""
        kd = (PA[i] ~ /^\/\//) ? "action-base" : (PA[i] ~ /\*/ ? "action-wild" : "action")
        note = dup; if (t == "" && FW[i] != "") note = note "forward=" FW[i]; if (t == "" && IN[i] != "") note = note "include=" IN[i]
        if (pr != "") note = note (note == "" ? "" : " ") "parameter=" pr
        if (O[i] == "xdoclet") note = note (note == "" ? "" : " ") "XDoclet"
        print kd, P[i] PA[i], t, F[i] ":" L[i], note, (dup != "" ? "dup" : "") }
      for (i = 1; i <= mn; i++) { c = sc[MW[i] "\t" MN[i]]; if (c == "") { dd = MW[i]; sub(/\/[^\/]*$/, "", dd); c = scd[dd "\t" MN[i]] } if ((MW[i] "\t" MN[i]) in st || kf[c] ~ /actionservlet/ || c ~ /^org\.apache\.struts\.action\.ActionServlet$/) { print "struts-mapping", MU[i], c, MW[i] ":" ML[i], "ActionServlet の受け口（入口の数には入れない）", ""; continue }
        print "servlet", MU[i], c, MW[i] ":" ML[i], "servlet-name=" MN[i], "" }
      for (i = 1; i <= fn; i++) print "filter", FU[i], FN[i], FWX[i] ":" FL[i], "", ""
      for (i = 1; i <= bn; i++) print "mdb", BN[i], BC[i], BL[i], "", ""
    }' "$TMPD/actions.tsv" "$TMPD/web.tsv" "$TMPD/kinds.tsv" "$TMPD/beans.tsv" > "$TMPD/ep.tsv"
  # XDoclet の @web.servlet-mapping / @web.filter-mapping と TimedObject の実装
  awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
    FILENAME ~ /kinds\.tsv$/ { kf[$1] = $3; next }
    $5 == "web.servlet-mapping" { if (kf[$3] ~ /actionservlet/) print "struts-mapping", xattr($6, "url-pattern"), $3, $1 ":" $2, "ActionServlet の受け口（入口の数には入れない）。XDoclet", ""
      else print "servlet", xattr($6, "url-pattern"), $3, $1 ":" $2, "XDoclet", "" }
    $5 == "web.filter-mapping" { u = xattr($6, "url-pattern"); if (u == "") u = "(servlet-name=" xattr($6, "servlet-name") ")"; print "filter", u, $3, $1 ":" $2, "XDoclet", "" }' "$TMPD/kinds.tsv" "$TMPD/xd.tsv" >> "$TMPD/ep.tsv"
  awk -F '\t' -v OFS='\t' '$2 == "class" && $3 ~ /(^|,)timer(,|$)/ { print "timer", $1, $1, $4, "TimedObject", "" }' "$TMPD/kinds.tsv" >> "$TMPD/ep.tsv"
  # 【入口はアプリ（配備単位）ごとに数える】同じ EAR の 2 つの WAR が同じ path を持つことがある（実測 xPetstore: 2 つの版の
  #   filter /* が 1 つに潰れた）。最も近い祖先のビルド定義のディレクトリを 7 列目に足し、数えるときのキーに入れる
  mod_build
  awk -F '\t' -v OFS='\t' -v L="$TMPD/mod.tsv" '
    BEGIN { while ((getline x < L) > 0) { split(x, a, "\t"); if (a[1] == "unit" || a[1] == "aggregate") has[a[2]] = 1 } }
    { f = $4; sub(/:[0-9]+$/, "", f); d = f; o = ""
      while (index(d, "/") > 0) { sub(/\/[^\/]*$/, "", d); if (d in has) { o = d; break } }
      print $1, $2, $3, $4, $5, $6, (o == "" ? "." : o) }' "$TMPD/ep.tsv" > "$TMPD/ep.tmp" && mv "$TMPD/ep.tmp" "$TMPD/ep.tsv"
}

# -----------------------------------------------------------------------------
# EJB の解析 → $TMPD/beans.tsv
#   kind(session|entity|message-driven)  subtype(Stateless|Stateful|Container|Bean|Queue 等)  ejb-name  ejb-class  home  remote  local-home  local  schema  path:line  出典(xml|xdoclet)
#   $TMPD/tx.tsv : ejb-name  メソッド  属性  path:line  出典
#   $TMPD/cmpmap.tsv : 表名  ejb-name（分かれば）  path:line  出典（jboss / weblogic / orion / xdoclet / ri）
# 【ejb-name は ejb-jar ごとの名前】CMR は同じ ejb-jar の中でしか張れないので、依存する Entity Bean を複数の ejb-jar に
#   重ねて宣言する構成がある（実測 Pet Store 1.3.2: 宣言 43 / ejb-class 32。AddressEJB は 5 つの ejb-jar に出る。落とし穴 7）
# -----------------------------------------------------------------------------
ejb_parse() {
  [ -f "$TMPD/beans.tsv" ] && return 0
  xml_classify; java_parse
  xev "$TMPD/x-ejb.lst" | awk -F '\t' -v OFS='\t' -v D="$TMPD" '
    $1 == "E" && $7 ~ /\/enterprise-beans\/(session|entity|message-driven)$/ { k = $7; sub(/^.*\//, "", k); bk[$4] = k; bl[$4] = $2 ":" $3; ord[++n] = $4; next }
    $1 == "T" && ($5 in bk) { e = $7; sub(/^.*\//, "", e); v[$5, e] = $8; next }
    $1 == "T" && ($6 in bk) && $7 ~ /\/message-driven-destination\/destination-type$/ { v[$6, "destination-type"] = $8; next }
    $1 == "E" && $7 ~ /\/assembly-descriptor\/container-transaction$/ { ct[$4] = 1; ctl[$4] = $2 ":" $3; cto[++nc] = $4; next }
    $1 == "E" && $7 ~ /\/assembly-descriptor\/method-permission$/ { ct[$4] = 1; ctl[$4] = $2 ":" $3; cto[++nc] = $4; next }
    $1 == "E" && $7 ~ /\/method-permission\/unchecked$/ { ta[$5] = "unchecked"; next }
    $1 == "E" && $7 ~ /\/(container-transaction|method-permission)\/method$/ && ($5 in ct) { mo[$5] = mo[$5] "\001" $4; next }
    $1 == "T" && $7 ~ /\/(container-transaction|method-permission)\/method\/(ejb-name|method-name)$/ { e = $7; sub(/^.*\//, "", e); mv[$5, e] = $8; next }
    $1 == "T" && $7 ~ /\/container-transaction\/trans-attribute$/ { ta[$5] = $8; next }
    $1 == "T" && $7 ~ /\/method-permission\/role-name$/ { ta[$5] = ta[$5] (ta[$5] == "" ? "role:" : ",") $8; next }
    END {
      for (i = 1; i <= n; i++) { id = ord[i]; k = bk[id]
        st = v[id, "session-type"] v[id, "persistence-type"]; if (k == "message-driven") { st = v[id, "destination-type"]; if (st == "") st = v[id, "message-destination-type"]; sub(/^javax\.jms\./, "", st) }
        print k, st, v[id, "ejb-name"], v[id, "ejb-class"], v[id, "home"], v[id, "remote"], v[id, "local-home"], v[id, "local"], v[id, "abstract-schema-name"], bl[id], "xml" }
      for (i = 1; i <= nc; i++) { id = cto[i]; m = split(mo[id], a, "\001"); for (j = 1; j <= m; j++) if (a[j] != "") print mv[a[j], "ejb-name"], mv[a[j], "method-name"], ta[id], ctl[id], "xml" > (D "/tx.tsv") }
    }' > "$TMPD/beans.tsv"
  touch "$TMPD/tx.tsv"
  # XDoclet の @ejb.bean。type の無い MDB は MessageDrivenBean の実装で見分ける（destination-type だけを書く）
  resolve_kinds
  awk -F '\t' -v OFS='\t' -v sq="'" -v D="$TMPD" "$AWK_XATTR"'
    FILENAME ~ /kinds\.tsv$/ { kf[$1] = $3; next }
    $5 == "ejb.bean" && $4 == "class" { t = xattr($6, "type"); k = (t ~ /^(CMP|BMP)$/) ? "entity" : ((t ~ /^(Stateless|Stateful)$/) ? "session" : "")
      if (k == "" && (kf[$3] ~ /mdb/ || xattr($6, "destination-type") != "")) { k = "message-driven"; t = xattr($6, "destination-type"); sub(/^javax\.jms\./, "", t) }
      if (k == "") k = (kf[$3] ~ /session/ ? "session" : (kf[$3] ~ /entity/ ? "entity" : "?"))
      vt = xattr($6, "view-type"); h = (vt ~ /remote|both/ || vt == "") ? "(XDoclet 生成)" : ""; lc = (vt ~ /local|both/) ? "(XDoclet 生成)" : ""
      if (k == "message-driven") { h = ""; lc = "" }
      print k, t, xattr($6, "name"), $3, h, h, lc, lc, xattr($6, "schema"), $1 ":" $2, "xdoclet" >> (D "/beans.tsv") }
    $5 == "ejb.transaction" { print "(" $3 ")", ($4 == "class" ? "*" : "(メソッド)"), xattr($6, "type"), $1 ":" $2, "xdoclet" >> (D "/tx.tsv") }
    $5 == "ejb.permission" { r = xattr($6, "role-name"); if (r == "" && $6 ~ /unchecked/) r = "unchecked"; else r = "role:" r
      print "(" $3 ")", ($4 == "class" ? "*" : "(メソッド)"), r, $1 ":" $2, "xdoclet" >> (D "/tx.tsv") }' "$TMPD/kinds.tsv" "$TMPD/xd.tsv"
  # CMP の表の対応（ベンダの記述子と XDoclet。落とし穴 8）
  : > "$TMPD/cmpmap.tsv"
  xev "$TMPD/x-other.lst" | awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
    $1 == "T" && $7 ~ /\/ejb-name$/ { en[$5] = $8; next }
    $1 == "T" && $7 ~ /\/table-name$/ { v = $8; gsub(/"/, "", v); src = ($2 ~ /jboss/ ? "jboss" : ($2 ~ /weblogic/ ? "weblogic" : "vendor")); print v, (($5 in en) ? en[$5] : (($6 in en) ? en[$6] : "")), $2 ":" $3, src; next }
    $1 == "E" && $7 ~ /\/entity-deployment$/ && attr($8, "table") != "" { print attr($8, "table"), attr($8, "name"), $2 ":" $3, "orion" }
    # Hibernate の *.hbm.xml（Struts 1 ＋ Hibernate の構成）: class / subclass の table= と、多対多の set / bag / list / map の table=
    $1 == "E" && $7 ~ /^\/hibernate-mapping\// && $7 ~ /\/(class|joined-subclass|union-subclass|set|bag|list|map|idbag)$/ && attr($8, "table") != "" { print attr($8, "table"), "", $2 ":" $3, "hibernate" }' >> "$TMPD/cmpmap.tsv"
  awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
    { t = xattr($6, "table-name"); if (t != "" && $5 ~ /^(ejb|jboss|weblogic|orion|websphere)\./) print t, "", $1 ":" $2, "xdoclet:" $5 }' "$TMPD/xd.tsv" >> "$TMPD/cmpmap.tsv"
}

# -----------------------------------------------------------------------------
# SQL の抽出 → $TMPD/sql.tsv : path:line  表  操作(select|insert|update|delete|create)  由来(java|xml|sqlfile|ri)
#   Java の文字列は文ごとに空白でつないで読む（"select a " + "from t" の連結。落とし穴 9）。
#   EJB-QL（`OBJECT(`・ejb-ql 要素・XDoclet の query=）は抽象スキーマ名で、表ではないので読まない（落とし穴 8）。
# -----------------------------------------------------------------------------
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
  if (org != "sqlfile" && l !~ /^[ (]*(select|insert|update|delete|create|from|join|inner|left|right|outer|where|union|merge|with|replace)[ ]/) return
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

sql_build() {
  [ -f "$TMPD/sql.tsv" ] && return 0
  java_parse; xml_classify
  # 表名は元の綴りで出したいので、小文字で照合した位置から元の文字列を取り直す代わりに、出現した綴りの辞書を作る
  {
    # Java の文字列
    awk -F '\t' '{ print $1 ":" $2 "\t" $3 "\tjava" }' "$TMPD/jstr.tsv"
    # XML の要素のテキスト（記述子以外。DAO の SQL 置き場・RI の sql-statement・populate 等）。ejb-ql は除く
    xev "$TMPD/x-other.lst" | awk -F '\t' '$1 == "T" && $7 !~ /\/ejb-ql$/ { o = ($2 ~ /sun-j2ee-ri\.xml$/) ? "ri" : "xml"; print $2 ":" $3 "\t" $8 "\t" o }'
    # SQL ファイル（-- と /* */ の注釈を外し、; までを 1 文にする）
    list_files '*.sql' '*.ddl' | read_many | awk -F '\t' -v sq="'" '
      $1 != pf { if (stm != "") print pf ":" sl "\t" stm "\tsqlfile"; pf = $1; stm = ""; inb = 0 }
      { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); out = ""
        while (t != "") { if (inb) { i = index(t, "*/"); if (!i) { t = ""; break } t = substr(t, i + 2); inb = 0; continue }
          i = index(t, "/*"); j = index(t, "--"); if (j > 0 && (i == 0 || j < i)) { out = out substr(t, 1, j - 1); break }
          if (i == 0) { out = out t; break } out = out substr(t, 1, i - 1) " "; t = substr(t, i + 2); inb = 1 }
        while ((k = index(out, ";")) > 0) { if (stm == "") sl = $2; stm = stm " " substr(out, 1, k - 1); print pf ":" sl "\t" stm "\tsqlfile"; stm = ""; out = substr(out, k + 1) }
        if (out ~ /[^ ]/) { if (stm == "") sl = $2; stm = stm " " out } }
      END { if (stm != "") print pf ":" sl "\t" stm "\tsqlfile" }'
  } > "$TMPD/sqlsrc.tsv"
  awk -F '\t' -v OFS='\t' "$AWK_SQL"'
    function orig(nm,   x) { x = nm; return (x in sp) ? sp[x] : x }
    FILENAME ~ /sqlsrc\.tsv$/ && pass == 0 { # 綴りの辞書: 元の文字列の識別子を小文字のキーで覚える（最初に見た綴り。後で最頻に置き換える）
      s = $2; while (match(s, /[A-Za-z_][A-Za-z0-9_$#]*/)) { w = substr(s, RSTART, RLENGTH); k = tolower(w); cnt[k, w]++; if (cnt[k, w] > best[k]) { best[k] = cnt[k, w]; sp[k] = w } s = substr(s, RSTART + RLENGTH) }
      line[++nl] = $0; next }
    END { for (i = 1; i <= nl; i++) { split(line[i], f, "\t"); sqlscan(f[2], f[1], f[3]) } }' "$TMPD/sqlsrc.tsv" > "$TMPD/sql.tsv"
}

# 参照側（経路A）の表: SQL の DML ＋ CMP の対応 → $TMPD/bndref.tsv : キー（小文字）  綴り  由来の一覧  最初の path:line
# 定義側（経路B）の表: CREATE TABLE → $TMPD/bnddef.tsv : キー  綴り  path:line（一時表は除いて $TMPD/bndtmp.tsv）
bnd_build() {
  [ -f "$TMPD/bndref.tsv" ] && return 0
  sql_build; ejb_parse
  awk -F '\t' -v OFS='\t' '
    FILENAME ~ /sql\.tsv$/ { k = tolower($2); if ($3 == "create") { if (!(k in d)) { d[k] = $2; dl[k] = $1 } next } if ($3 == "temp") { tmp[k] = $2; tl[k] = $1; next }
      if (!(k in r)) { r[k] = $2; rl[k] = $1 } if (index(" " ro[k] " ", " " $4 " ") == 0) ro[k] = ro[k] (ro[k] == "" ? "" : " ") $4; next }
    FILENAME ~ /cmpmap\.tsv$/ { k = tolower($1); if (!(k in r)) { r[k] = $1; rl[k] = $3 } o = "cmp:" $4; if (index(" " ro[k] " ", " " o " ") == 0) ro[k] = ro[k] (ro[k] == "" ? "" : " ") o; next }
    END { for (k in r) if (!(k in tmp)) print k, r[k], ro[k], rl[k] > (D "/bndref.tsv")
          for (k in d) print k, d[k], dl[k] > (D "/bnddef.tsv")
          for (k in tmp) print k, tmp[k], tl[k] > (D "/bndtmp.tsv") }' D="$TMPD" "$TMPD/sql.tsv" "$TMPD/cmpmap.tsv"
  touch "$TMPD/bndref.tsv" "$TMPD/bnddef.tsv" "$TMPD/bndtmp.tsv"
  sort -o "$TMPD/bndref.tsv" "$TMPD/bndref.tsv"; sort -o "$TMPD/bnddef.tsv" "$TMPD/bnddef.tsv"; sort -o "$TMPD/bndtmp.tsv" "$TMPD/bndtmp.tsv"
}

# -----------------------------------------------------------------------------
# 配備単位（ビルド定義）→ $TMPD/mod.tsv : 種類  ディレクトリ  ビルド定義のファイル  使うタスク
#   Ant: ルートが <project> で <target> を持つ XML（build-jboss.xml のような別名も読む）。
#     種類 = unit（jar / war / ear / ejbdoclet / webdoclet / javac を使う）／ aggregate（<ant> / <subant> だけ）／ other（どれも無い。DB の初期化等）
#     【javac だけのビルドも単位に数える】依存する CMP の Entity Bean は自分で jar を作らず、使う側の ejb-jar に入る
#     （実測 Pet Store 1.3.2: lineitem は javac と <ant> だけで、ejb-jar.xml を持つ。jar の有無で判定すると「まとめ役」に見えた）
#   Maven: pom.xml。packaging=pom は aggregate、それ以外は unit
# -----------------------------------------------------------------------------
mod_build() {
  [ -f "$TMPD/mod.tsv" ] && return 0
  xml_classify
  # 注釈の中のタスク（<!-- <jar ... --> ）で誤判定しないよう、字句解析済みの事象から読む。
  # 【<import> と <macrodef> を辿る】共通の build ファイルの macrodef に <jar> を置き、各モジュールが import する構成がある。
  #   import した先（相対パスを解く）のタスクと macrodef の中のタスクを、取り込んだ側のタスクに足す（2 段まで）
  xev "$TMPD/x-other.lst" | awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
    function rel(base, p,   d, n, a, i, m, s, out) { if (p ~ /^\//) return p; d = base; sub(/\/[^\/]*$/, "", d); n = split(d "/" p, a, "/"); m = 0
      for (i = 1; i <= n; i++) { if (a[i] == "" || (a[i] == "." && i > 1)) continue; if (a[i] == "..") { if (m > 1) m--; continue } s[++m] = a[i] }
      out = s[1]; for (i = 2; i <= m; i++) out = out "/" s[i]; return out }
    $1 == "E" && !($2 in root) { root[$2] = $7; ord[++nf] = $2 }
    $1 == "E" && $7 == "/project/target" { tgt[$2] = 1 }
    $1 == "E" && $7 == "/project/artifactId" { art[$2] = 1 }
    $1 == "T" && $7 == "/project/packaging" { pack[$2] = $8 }
    $1 == "E" && $7 == "/project/import" && attr($8, "file") != "" { imp[$2] = imp[$2] "\001" rel($2, attr($8, "file")) }
    $1 == "E" && $7 ~ /^\/project\/(target|macrodef)\// { x = $7; sub(/^.*\//, "", x); if (x ~ /^(jar|war|ear|ejbdoclet|webdoclet|ejbjar|javac|ant|subant)$/) tk[$2, x] = 1 }
    END {
      split("jar war ear ejbdoclet webdoclet ejbjar javac ant subant", TN, " ")
      for (r = 1; r <= 2; r++) for (i = 1; i <= nf; i++) { f = ord[i]; m = split(imp[f], a, "\001")
        for (j = 1; j <= m; j++) if (a[j] != "") for (q in TN) if ((a[j], TN[q]) in tk) { tk[f, TN[q]] = 1; via[f] = 1 } }
      for (i = 1; i <= nf; i++) { f = ord[i]; if (root[f] != "/project") continue; d = f; sub(/\/[^\/]*$/, "", d)
        if (art[f]) { k = (pack[f] == "pom") ? "aggregate" : "unit"; print k, d, f, "maven:" (pack[f] == "" ? "jar" : pack[f]); continue }
        if (!tgt[f] && !via[f]) continue
        ts = ""; for (q = 1; q <= 9; q++) if ((f, TN[q]) in tk) ts = ts (ts == "" ? "" : ",") TN[q]
        k = (ts ~ /(^|,)(jar|war|ear|ejbdoclet|webdoclet|ejbjar|javac)(,|$)/) ? "unit" : ((ts ~ /(^|,)(ant|subant)(,|$)/) ? "aggregate" : "other")
        print k, d, f, "ant:" ts (via[f] ? "（import 経由を含む）" : "") } }' | sort > "$TMPD/mod.tsv"
}

# -----------------------------------------------------------------------------
# サブコマンド
# 【出力は一時ファイルに溜めてから 1 回で出す】Git Bash では、読み手（`| head`）が先に閉じた管に複数のプロセスが
#   順に書くと、後のプロセスが終わらずに止まることがある（実測: mod-diff | head -2 が 60 秒で打ち切り）。書き手を cat 1 つにする
# -----------------------------------------------------------------------------
main() {
case "$SUB" in
  ep)
    # 入口 = action（path に * を含むものは宣言 1 つ）＋ ActionServlet 以外の servlet-mapping ＋ filter-mapping ＋ MDB ＋ TimedObject。
    #   action-base（// で始まる土台）と、後の宣言で上書きされた同じ path は数えない
    ep_build
    awk -F '\t' '$1 ~ /^(action|action-wild|servlet|filter|mdb|timer)$/ && $6 != "dup" { k[$7 "\t" $1 "\t" $2 "\t" $3] = 1 } END { n = 0; for (x in k) n++; print (n ? n : "unknown") }' "$TMPD/ep.tsv"
    ;;
  list-ep)
    # 列: 種類  キー  type  path:line  備考  アプリ（最も近い祖先のビルド定義のディレクトリ）
    ep_build
    sort -t "$(printf '\t')" -k7,7 -k1,1 -k2,2 "$TMPD/ep.tsv" | cut -f1-5,7
    ;;
  ep-diff)
    # 経路A: 宣言（struts-config / XDoclet の action の type ＋ MDB の ejb-class）が指すクラス
    # 経路B: Java 側の具象クラスのうち、Struts の Action（import で確かめる）か MessageDrivenBean の派生
    ep_build
    awk -F '\t' '($1 == "action" || $1 == "action-wild") && $3 != "" && $3 !~ /\{[0-9]\}/ && $6 != "dup" { print $3 } $1 == "mdb" && $3 != "" { print $3 }' "$TMPD/ep.tsv" | sort -u > "$TMPD/epA"
    awk -F '\t' '$6 == "dup" && $3 != "" { print $3 }' "$TMPD/ep.tsv" | sort -u > "$TMPD/epD"
    awk -F '\t' '$2 == "class" && ($3 ~ /(^|,)action(,|$)/ || $3 ~ /(^|,)mdb(,|$)/) { print $1 }' "$TMPD/kinds.tsv" | sort -u > "$TMPD/epB"
    echo "経路A（宣言が指すクラス）: $(wc -l < "$TMPD/epA" | tr -d ' ')"
    echo "経路B（Action / MDB の派生クラス）: $(wc -l < "$TMPD/epB" | tr -d ' ')"
    echo "== 経路A のみ（宣言された type のクラスがソースに無い。Struts 同梱・依存 jar・誤記・削除済みの別） =="
    comm -23 "$TMPD/epA" "$TMPD/epB" | while IFS= read -r c; do
      case "$c" in org.apache.struts.*) printf '  %s\t(Struts 同梱のクラス)\n' "$c" ;;
        org.springframework.*) printf '  %s\t(Spring の委譲。実体は Spring の Bean 定義を読む)\n' "$c" ;;
        *) if awk -F '\t' -v c="$c" '$1 == c { f = 1 } END { exit !f }' "$TMPD/kinds.tsv"; then printf '  %s\t(ソースにあるが Action / MDB の派生と判定できない: 基底の import を確かめる)\n' "$c"; else printf '  %s\t(ソースに無い)\n' "$c"; fi ;; esac
    done
    echo "== 経路B のみ（Action / MDB の派生なのに、どの宣言からも指されない。ワイルドカードの候補・死蔵・XDoclet のタグ漏れの別） =="
    awk -F '\t' '($1 == "action" || $1 == "action-wild" || $1 == "action-base") && $3 ~ /\{[0-9]\}/ { print $3 }' "$TMPD/ep.tsv" | sort -u > "$TMPD/epW"
    comm -13 "$TMPD/epA" "$TMPD/epB" | while IFS= read -r c; do
      w=""; while IFS= read -r tpl; do
        re="^$(printf '%s' "$tpl" | sed -e 's/[.]/[.]/g' -e 's/{[0-9]}/[^.]*/g')\$"
        printf '%s\n' "$c" | grep -qE -- "$re" && w="（ワイルドカードの type ${tpl} の候補）"
      done < "$TMPD/epW"
      grep -qxF -- "$c" "$TMPD/epD" && w="${w}（同じ path の後の宣言で上書きされた宣言の type＝要求を受けない）"
      printf '  %s%s\n' "$c" "$w"
    done
    echo "== ワイルドカードの type（{N} を含む。要求の path で決まるのでクラスは静的に決まらない） =="
    awk -F '\t' '$3 ~ /\{[0-9]\}/ { print "  " $2 "\t" $3 "\t" $4 }' "$TMPD/ep.tsv"
    echo "== type を持たない宣言（forward / include だけで画面を返す。経路の比較には入らない） =="
    awk -F '\t' '($1 == "action" || $1 == "action-wild") && $3 == "" { print "  " $2 "\t" $5 "\t" $4 }' "$TMPD/ep.tsv"
    echo "== 同じ path の重複した宣言（後の宣言で上書きされる） =="
    awk -F '\t' '$6 == "dup" { print "  " $2 "\t" $4 }' "$TMPD/ep.tsv"
    echo "== 土台の宣言（path が // で始まる。extends で使い、要求は受けない） =="
    awk -F '\t' '$1 == "action-base" { print "  " $2 "\t" $4 }' "$TMPD/ep.tsv"
    echo "== web.xml から参照されない Struts の設定ファイル（モジュールの接頭辞が決まらない。読まれていない可能性） =="
    awk -F '\t' '$2 == "?" { print "  " $1 }' "$TMPD/configs.tsv"
    echo "== XML と XDoclet の両方で宣言された path（生成した XML を一緒に置いている。片方を GEN_EXCLUDE / SCAN_EXCLUDE で外す） =="
    awk -F '\t' '{ o = ($5 ~ /XDoclet/) ? "x" : "m"; s[$7 " " $2] = s[$7 " " $2] o } END { for (k in s) if (s[k] ~ /x/ && s[k] ~ /m/) print "  " k }' <(awk -F '\t' '$1 ~ /^action/' "$TMPD/ep.tsv") | sort
    echo "== Struts 以外のフロントコントローラ（拡張子・前方一致の servlet-mapping。画面の URL は別の対応表にある。enumeration.md に行を足して数える） =="
    awk -F '\t' '$1 == "servlet" && ($2 ~ /^\*\./ || $2 ~ /\/\*$/) { print "  " $7 "\t" $2 "\t" $3 "\t" $4 }' "$TMPD/ep.tsv"
    echo "== 同じ完全修飾名のクラスが複数ある（派生の判定が 1 つに潰れる。アプリごとに SCAN_EXCLUDE で分けて走査する） =="
    awk -F '\t' '{ c[$1]++; w[$1] = w[$1] " " $6 } END { for (k in c) if (c[k] > 1) print "  " k "\t" w[k] }' "$TMPD/classes.tsv" | sort
    ;;
  list-forwards)
    struts_parse
    awk -F '\t' -v OFS='\t' '{ print $3, $4, $5, $1 ":" $2, $6 }' "$TMPD/forwards.tsv" | sort
    ;;
  list-forms)
    struts_parse
    awk -F '\t' -v OFS='\t' '{ print $3, $4, $5, $1 ":" $2, $6 }' "$TMPD/forms.tsv" | sort
    ;;
  list-validation)
    xml_classify
    xev "$TMPD/x-valid.lst" | awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
      $1 == "E" && $7 ~ /\/formset\/form$/ { fm[$4] = attr($8, "name") }
      $1 == "E" && $7 ~ /\/form\/field$/ { print (($5 in fm) ? fm[$5] : "?"), attr($8, "property"), attr($8, "depends"), $2 ":" $3 }' | sort
    ;;
  list-dispatch)
    # DispatchAction 系: 1 つの宣言が parameter の値（要求の引数か宣言の固定値）で複数のメソッドに分かれる（落とし穴 5）。
    #   要求を受けるメソッド = public で、引数が (ActionMapping, ActionForm, HttpServletRequest, HttpServletResponse)
    ep_build
    awk -F '\t' -v OFS='\t' '
      FILENAME ~ /kinds\.tsv$/ { if ($3 ~ /(^|,)dispatch(,|$)/) d[$1] = $4; next }
      FILENAME ~ /meth\.tsv$/ { if (($1 in d) && $3 == "ActionMapping,ActionForm,HttpServletRequest,HttpServletResponse" && $2 != "execute" && $2 != "perform" && $2 != "unspecified" && $2 != "cancelled") print $1, $2, $4 }' \
      "$TMPD/kinds.tsv" "$TMPD/meth.tsv" | sort
    ;;
  list-refs)
    # JSP からの参照（遷移の辺）。html:form / html:link / html:rewrite / logic:redirect / html:frame の action・forward・page・href と、.do のリンク
    #   【ファイル単位で読む】タグは複数行に分かれる（<html:form\n action="/x">）。行番号はタグの始まりの行
    list_files '*.jsp' '*.jspf' '*.inc' | read_many | awk -F '\t' -v OFS='\t' -v sq="'" "$AWK_XATTR"'
      function nlc(x) { return gsub(/\n/, "\n", x) }
      function scan(f, b,   t, off, tg, nm, i, k, v, ln) {
        t = b; off = 0
        while (match(t, /<(html|logic|nested|bean):[a-zA-Z]+[^>]*>/)) { ln = 1 + off + nlc(substr(t, 1, RSTART)); tg = substr(t, RSTART, RLENGTH)
          off += nlc(substr(t, 1, RSTART + RLENGTH - 1)); t = substr(t, RSTART + RLENGTH); gsub(/\n/, " ", tg)
          nm = tg; sub(/^</, "", nm); sub(/[ \t>].*$/, "", nm)
          for (i = 1; i <= 4; i++) { k = (i == 1) ? "action" : ((i == 2) ? "forward" : ((i == 3) ? "page" : "href")); v = attr(tg, k); if (v != "") print f ":" ln, nm, k, v } }
        t = b; off = 0
        while (match(t, /(href|action|src)[ \t\n]*=[ \t\n]*"[^"]*\.do([?#][^"]*)?"/)) { ln = 1 + off + nlc(substr(t, 1, RSTART)); v = substr(t, RSTART, RLENGTH)
          off += nlc(substr(t, 1, RSTART + RLENGTH - 1)); t = substr(t, RSTART + RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); print f ":" ln, "a", "href", v } }
      $1 != pf { if (pf != "") scan(pf, buf); pf = $1; buf = "" }
      { l = $0; sub(/^[^\t]*\t[^\t]*\t/, "", l); buf = buf l "\n" }
      END { if (pf != "") scan(pf, buf) }' | sort
    ;;
  mod)
    mod_build
    awk -F '\t' '$1 == "unit" { d[$2] = 1 } END { n = 0; for (x in d) n++; print (n ? n : "unknown") }' "$TMPD/mod.tsv"
    ;;
  list-mod)
    mod_build
    cat "$TMPD/mod.tsv"
    ;;
  mod-diff)
    # 経路A: ビルド単位のディレクトリ（unit）。経路B: 配備記述子（ejb-jar.xml / web.xml / application.xml）を持つディレクトリを、
    #   最も近い祖先のビルド定義のディレクトリに寄せたもの ＋ XDoclet で記述子を生成するビルド単位（ejbdoclet / webdoclet）
    mod_build
    awk -F '\t' '$1 == "unit" { print $2 }' "$TMPD/mod.tsv" | sort -u > "$TMPD/mA"
    # 持ち主の候補は unit と aggregate だけ（other の Ant ファイル＝WEB-INF の webtest.xml 等を持ち主にしない。実測 MailReader）
    awk -F '\t' '$1 == "unit" || $1 == "aggregate" { print $2 }' "$TMPD/mod.tsv" | sort -u > "$TMPD/mAll"
    cat "$TMPD/x-ejb.lst" "$TMPD/x-web.lst" "$TMPD/x-app.lst" | awk -v L="$TMPD/mAll" '
      BEGIN { while ((getline d < L) > 0) has[d] = 1 }
      { d = $0; sub(/\/[^\/]*$/, "", d); o = ""
        while (d != "" && d != ".") { if (d in has) { o = d; break } sub(/\/[^\/]*$/, "", d) }
        if (o == "" && ("." in has)) o = "."
        print (o == "" ? "(ビルド定義なし)" : o) "\t" $0 }' > "$TMPD/mOwn"
    { cut -f1 "$TMPD/mOwn"; awk -F '\t' '$1 == "unit" && $4 ~ /(ejbdoclet|webdoclet)/ { print $2 }' "$TMPD/mod.tsv"; } | sort -u > "$TMPD/mB"
    echo "経路A（ビルド単位）: $(wc -l < "$TMPD/mA" | tr -d ' ')"
    echo "経路B（配備記述子の持ち主）: $(wc -l < "$TMPD/mB" | tr -d ' ')"
    echo "== 経路A のみ（配備記述子を持たないビルド単位。共通ライブラリの jar・クライアント・ツールの別） =="
    comm -23 "$TMPD/mA" "$TMPD/mB" | sed 's/^/  /'
    echo "== 経路B のみ（配備記述子の持ち主がビルド単位でない。まとめ役のビルド・ビルド定義の無い記述子） =="
    comm -13 "$TMPD/mA" "$TMPD/mB" | sed 's/^/  /'
    echo "== 配備記述子ごとの持ち主 =="
    sort "$TMPD/mOwn" | sed 's/^/  /'
    echo "== EAR の構成（application.xml の module） =="
    xev "$TMPD/x-app.lst" | awk -F '\t' '$1 == "T" && $7 ~ /\/module\/(ejb|java|connector|web\/web-uri)$/ { e = $7; sub(/^.*\//, "", e); if (e == "web-uri") e = "web"; print "  " $2 "\t" e "\t" $8 }'
    ;;
  list-ejb)
    ejb_parse
    awk -F '\t' -v OFS='\t' '
      FILENAME ~ /cmpmap\.tsv$/ { if ($2 != "") tb[$2] = $1; else { f = $3; sub(/:[0-9]+$/, "", f); tf[f] = $1 } next }
      { t = ($3 in tb) ? tb[$3] : ""; if (t == "" && $11 == "xdoclet") { f = $10; sub(/:[0-9]+$/, "", f); if (f in tf) t = tf[f] }
        v = ""; if ($5 != "" || $6 != "") v = "remote"; if ($7 != "" || $8 != "") v = v (v == "" ? "" : "+") "local"
        print $1, $2, $3, $4, v, $9, t, $11, $10 }' "$TMPD/cmpmap.tsv" "$TMPD/beans.tsv" | sort
    ;;
  ejb-diff)
    # 経路A: 宣言（ejb-jar.xml ＋ XDoclet の @ejb.bean）の ejb-class。経路B: SessionBean / EntityBean / MessageDrivenBean の具象の実装クラス
    ejb_parse
    awk -F '\t' '$4 != "" { print $4 }' "$TMPD/beans.tsv" | sort -u > "$TMPD/eA"
    awk -F '\t' '$2 != "interface" && $3 ~ /(^|,)(session|entity|mdb)(,|$)/ { print $1 }' "$TMPD/kinds.tsv" | sort -u > "$TMPD/eB"
    echo "宣言（ejb-jar.xml と @ejb.bean の行）: $(wc -l < "$TMPD/beans.tsv" | tr -d ' ')"
    echo "経路A（宣言された ejb-class）: $(wc -l < "$TMPD/eA" | tr -d ' ')"
    echo "経路B（Bean の実装クラス）: $(wc -l < "$TMPD/eB" | tr -d ' ')"
    echo "== 経路A のみ（宣言された ejb-class がソースに無いか、Bean のインタフェースの実装と判定できない） =="
    comm -23 "$TMPD/eA" "$TMPD/eB" | sed 's/^/  /'
    echo "== 経路B のみ（Bean の実装なのに宣言されていない。死蔵・基底クラス・XDoclet のタグ漏れの別。インタフェースは除くが、抽象クラス（CMP の Bean・基底クラス）は経路B に入る） =="
    comm -13 "$TMPD/eA" "$TMPD/eB" | sed 's/^/  /'
    echo "== 複数の ejb-jar で宣言された ejb-class（CMR のために重ねて宣言する構成。配備は別々の実体になる） =="
    awk -F '\t' '$11 == "xml" { f = $10; sub(/:[0-9]+$/, "", f); c[$4]++; w[$4] = w[$4] " " f } END { for (k in c) if (c[k] > 1) print "  " k "\t" c[k] "\t" w[k] }' "$TMPD/beans.tsv" | sort
    echo "== 種別の食い違い（宣言の種類と実装するインタフェースが違う） =="
    awk -F '\t' 'FILENAME ~ /kinds\.tsv$/ { kf[$1] = $3; next } { k = $1; f = kf[$4]; if (f == "") next
      want = (k == "session") ? "session" : ((k == "entity") ? "entity" : "mdb"); if (f !~ ("(^|,)" want "(,|$)")) print "  " $4 "\t宣言=" k "\t実装=" f "\t" $10 }' "$TMPD/kinds.tsv" "$TMPD/beans.tsv" | sort -u
    echo "== 宣言されたインタフェース（home / remote / local-home / local）がソースに無い =="
    awk -F '\t' 'FILENAME ~ /kinds\.tsv$/ { has[$1] = 1; next } $11 == "xml" { for (i = 5; i <= 8; i++) if ($i != "" && !($i in has)) print "  " $3 "\t" $i "\t" $10 }' "$TMPD/kinds.tsv" "$TMPD/beans.tsv" | sort -u
    echo "== 同じ完全修飾名のクラスが複数ある（派生の判定が 1 つに潰れる。アプリごとに SCAN_EXCLUDE で分けて走査する） =="
    awk -F '\t' '{ c[$1]++; w[$1] = w[$1] " " $6 } END { for (k in c) if (c[k] > 1) print "  " k "\t" w[k] }' "$TMPD/classes.tsv" | sort
    ;;
  list-tx)
    ejb_parse
    sort "$TMPD/tx.tsv"
    ;;
  bnd)
    bnd_build
    n=$(wc -l < "$TMPD/bndref.tsv" | tr -d ' ')
    [ "${n:-0}" -gt 0 ] && echo "$n" || echo unknown
    ;;
  list-bnd)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3, $4 }' "$TMPD/bndref.tsv" | sort
    ;;
  bnd-schema)
    bnd_build
    awk -F '\t' -v OFS='\t' '{ print $2, $3 }' "$TMPD/bnddef.tsv" | sort
    ;;
  bnd-diff)
    bnd_build
    cut -f1 "$TMPD/bndref.tsv" | sort -u > "$TMPD/bA"; cut -f1 "$TMPD/bnddef.tsv" | sort -u > "$TMPD/bB"
    echo "経路A（参照側: SQL ＋ CMP の対応）: $(wc -l < "$TMPD/bA" | tr -d ' ')"
    echo "経路B（定義側: CREATE TABLE）: $(wc -l < "$TMPD/bB" | tr -d ' ')"
    if [ ! -s "$TMPD/bA" ] && [ ! -s "$TMPD/bB" ]; then
      echo "★参照側も定義側も 0 件（DB を使わない、または SQL を静的に読めない: 設定ファイルの SQL・実行時に組み立てる表名）。どちらかを grep で確かめて理由を書く"
    elif [ ! -s "$TMPD/bB" ]; then
      echo "★定義側が 0 件（スキーマがソースに無い: 配備時の自動生成・別リポジトリ・DB のダンプだけ）。経路B を単一経路として理由を書く"
    fi
    echo "== 経路A のみ（参照されるのに定義が無い。配備時に生成・別 DB・誤検出の別） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bndref.tsv" "$TMPD/bB" | awk -F '\t' '{ print "  " $2 "\t" $3 "\t" $4 }'
    echo "== 経路B のみ（定義されるのに参照されない。死蔵・EJB-QL の先・動的 SQL の別） =="
    join -t "$(printf '\t')" -v 1 "$TMPD/bnddef.tsv" "$TMPD/bA" | awk -F '\t' '{ print "  " $2 "\t" $3 }'
    echo "== 一時表（CREATE TEMPORARY TABLE。どちらの経路にも入れない） =="
    awk -F '\t' '{ print "  " $2 "\t" $3 }' "$TMPD/bndtmp.tsv"
    ;;
  list-crud)
    sql_build; ejb_parse
    awk -F '\t' -v OFS='\t' '$3 != "temp" { print $1, $2, $3, $4 }' "$TMPD/sql.tsv" | sort -u
    ;;
  scope)
    # ディレクトリ（2 階層）ごとの .java / .jsp / .xml の数。同梱ライブラリのソース・生成物の置き場を見つける
    #   列: ディレクトリ  .java  .jsp  .xml  GEN_EXCLUDE で外れるファイルの数（深い階層のものも数える）
    find . \( -name .git -o -name .svn -o -name CVS \) -prune -o -type f \( -iname '*.java' -o -iname '*.jsp' -o -iname '*.xml' \) -print 2>/dev/null | sort > "$TMPD/scope.lst"
    gen_filter drop < "$TMPD/scope.lst" > "$TMPD/scope.gen"
    awk -F '/' -v OFS='\t' -v GL="$TMPD/scope.gen" '
      BEGIN { while ((getline x < GL) > 0) g[x] = 1 }
      NF > 2 { d = $1 "/" $2; if (NF > 3) d = d "/" $3; e = tolower($NF); sub(/^.*\./, "", e); c[d, e]++; ds[d] = 1; if ($0 in g) ge[d]++ }
      NF == 2 { d = "."; e = tolower($NF); sub(/^.*\./, "", e); c[d, e]++; ds[d] = 1; if ($0 in g) ge[d]++ }
      END { for (d in ds) print d, c[d, "java"] + 0, c[d, "jsp"] + 0, c[d, "xml"] + 0, ge[d] + 0 }' "$TMPD/scope.lst" | sort
    ;;
  idents-table)
    bnd_build
    { cut -f2 "$TMPD/bndref.tsv"; cut -f2 "$TMPD/bnddef.tsv"; } | awk '{ k = tolower($0); if (!(k in s)) s[k] = $0 } END { for (k in s) print s[k] }' | sed '/^$/d' | sort -u
    ;;
  idents-endpoint)
    ep_build
    # 接頭辞の決まらない設定ファイル（?）の印は外して path だけを出す（仕様本文に「?」を書かせない）
    awk -F '\t' '($1 == "action" || $1 == "action-wild") && $6 != "dup" { p = $2; sub(/^\?/, "", p); print p }' "$TMPD/ep.tsv" | sed '/^$/d' | sort -u
    ;;
  idents-ejb)
    ejb_parse
    cut -f3 "$TMPD/beans.tsv" | sed '/^$/d' | sort -u
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-ejb|ejb-diff|list-tx|list-forwards|list-forms|list-validation|list-dispatch|list-refs|list-crud|scope|idents-table|idents-endpoint|idents-ejb} <source-path>" >&2
    exit 2
    ;;
esac
}
main > "$TMPD/out.txt"
rc=$?
cat "$TMPD/out.txt" 2>/dev/null || true
exit "$rc"
