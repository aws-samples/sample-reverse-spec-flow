#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（aspnet-webforms / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 画面の 2 経路（マークアップ / 参照される画面）の要素差分
#   mod-diff              → プロジェクトの 2 経路（実在するプロジェクト・Web サイト / .sln・.slnx の宣言）の要素差分
#   bnd-schema            → DB 表の経路B（スキーマ定義側）の一覧
#   bnd-diff              → DB 表の 2 経路（コード・マークアップ・SQL ファイル / スキーマ定義）の要素差分
#   list-refs             → 画面・コントロールへの参照（遷移・埋め込み・動的読み込み・設定）と解決先
#   list-controls         → ユーザーコントロール（.ascx）の扱い（埋め込み / 画面として読み込まれる / 参照なし）
#   list-handlers         → イベント配線（マークアップの On〜 属性・Handles・+=・Page_Load 等の自動配線）
#   list-datasources      → マークアップのデータソースコントロール（SqlDataSource の SQL・ObjectDataSource の型とメソッド）
#   list-sproc            → ストアドプロシージャ名（呼び出し側 / 定義側）
#   inline-code           → マークアップの中のサーバーコード（<% %> / <script runat="server">）。コードの走査が読まない部分
#   scope                 → ディレクトリごとの件数（同梱した第三者ライブラリのソースを見つけて SCAN_EXCLUDE を決める）
#   sql-stores            → SQL を含むコード以外のファイル（外部 SQL 置き場の発見用）
#   bnd-idents            → 参照側の表名の全出現（idents-table の内部用。キー<TAB>綴り）
#   idents-table | idents-screen | idents-proc → 識別子の抽出（G-IDENT 用。出典の綴りで出す）
#
# 環境変数（未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む。Phase 4 の再実行で付け忘れないように）:
#   SQL_STORE_GLOBS : 外部 SQL 置き場の -iname パターン（空白区切り。例: '*.sqld'）
#   SCAN_EXCLUDE    : 走査から外すパスの POSIX ERE（`./` 始まりの相対パスに当てる。例: '^\./src/(ServiceStack|Lucene\.Net)/'）。
#                     同梱した第三者ライブラリのソースを外す。外したものは ADR で処分する（enumeration.md 落とし穴 3）
#
# 実測検証（2026-10-23）: ERPSYS_WebForms（C#・Web アプリケーション・ストアドプロシージャ）、YAF.NET v3.2.17（C#・
#   画面を .ascx で動的に読み込む・OrmLite のコードファースト）、TheBeerHouse VB 版（VB・Web サイト・ObjectDataSource）、
#   Property Agent（VB・DNN のモジュール・.SqlDataProvider）。値は enumeration.md の検証記録を参照。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。.NET の業務アプリは UTF-8(BOM 有無)・ANSI コードページ・UTF-16 が
#   混在するのが普通で、UTF-8 ロケールの awk/grep は不正バイトで黙って行を落とす（enumeration.md 落とし穴 1）。
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

# 【事前コンパイルした配備用の写し】PrecompiledApp.config のあるディレクトリは、aspnet_compiler が出力した配備用のサイト。
#   「更新可能」の形ではマークアップが残り（コードは bin/ の DLL）、ソースと同じ画面がもう 1 組できる
#   （実測 TheBeerHouse: TBH_Deploy/ の下に .aspx 50 本の写し。数えると画面が 2 倍になった。落とし穴 4）。その下はすべて走査しない。
find . \( -name .git -o -name .svn -o -name node_modules \) -prune -o -type f -iname 'PrecompiledApp.config' -print 2>/dev/null \
  | awk '{ d = $0; sub(/\/[^\/]*$/, "", d); print d "/" }' > "$TMPD/precomp.txt"
# 走査対象のファイル一覧（1 行 1 パス）。ビルド出力・VCS 管理領域・事前コンパイルの写し・SCAN_EXCLUDE を除く。拡張子は大小を区別しない。
list_files() { # $@ = -iname のパターン
  local first=1
  local args=()
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -iname bin -o -iname obj -o -name packages -o -name node_modules -o -name .vs \) -prune \
    -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort \
    | awk -v pf="$TMPD/precomp.txt" 'FILENAME == pf { if ($0 != "") pre[++n] = $0; next } { for (i = 1; i <= n; i++) if (index($0, pre[i]) == 1) next; print }' "$TMPD/precomp.txt" - \
    | { if [ -n "$SCAN_EXCLUDE" ]; then grep -vE -- "$SCAN_EXCLUDE" || true; else cat; fi; }
}

# 複数のファイルをまとめて読む: stdin = ファイル一覧 → path<TAB>行番号<TAB>行（CR と先頭の BOM を外す。UTF-16 は NUL を落とす。落とし穴 1）
# 【ファイルごとにプロセスを起こさない】Windows（Git Bash）ではプロセス起動が遅く、1 ファイルずつ読むと
#   SQL ファイル 90 本で数分かかった（実測 Property Agent）。UTF-16 のファイルだけを先に grep で見つけて個別に読み、
#   残りは awk 1 回で読む。BOM は正規表現の 8 進表記に頼らず、文字列として渡して先頭を比べる。
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

# SQL ファイル: *.sql ＋ DNN のモジュールの *.SqlDataProvider ＋ SQL_STORE_GLOBS（空白区切りの -iname パターン）
list_sql_files() {
  local globs=('*.sql' '*.sqldataprovider')
  local g
  set -f
  for g in ${SQL_STORE_GLOBS:-}; do globs+=("$g"); done
  set +f
  list_files "${globs[@]}"
}
# SQL ファイルを 1 本の流れで読む: path<TAB>行番号<TAB>行（-- 注釈と DNN の置換記号 {databaseOwner} / {objectQualifier} を外す）
# 【DNN の置換記号】.SqlDataProvider の名前は `{databaseOwner}{objectQualifier}Ventrian_PropertyAgent_Agent` の形で、
#   インストール時に置き換わる。記号ごと名前に含めるとスキーマ部と名前が分かれない（落とし穴 13）。
sql_stream() {
  # 【複数行の /* */ 注釈も外す】行ごとに外すだけでは、行をまたぐ注釈の中の旧 SQL を拾う（反証レビューで実証）
  list_sql_files | read_many | awk -F '\t' -v OFS='\t' -v sq="'" '
    $1 != pf { pf = $1; inb = 0 }
    { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); out = ""
      while (t != "") {
        if (inb) { i = index(t, "*/"); if (i == 0) { t = ""; break } t = substr(t, i + 2); inb = 0; continue }
        i = index(t, "/*"); j = index(t, "--"); q = index(t, sq)
        # 文字列の中の -- / /* は注釈ではない（`LIKE ` + 引用符 + `/*%`。反証レビューで実証）。同じ行で閉じる文字列はそのまま写して飛ばす
        #   （行をまたぐ文字列は追わない: sp_executesql に渡す手続きの本体の中の注釈は、実行時に注釈として働くので外してよい）
        if (q > 0 && (i == 0 || q < i) && (j == 0 || q < j)) { r = index(substr(t, q + 1), sq)
          if (r > 0) { out = out substr(t, 1, q + r); t = substr(t, q + r + 1); continue } }
        if (j > 0 && (i == 0 || j < i)) { out = out substr(t, 1, j - 1); t = ""; break }
        if (i == 0) { out = out t; break }
        out = out substr(t, 1, i - 1) " "; t = substr(t, i + 2); inb = 1
      }
      gsub(/\{[A-Za-z]+\}/, "", out); print $1, $2, out }'
}

# -----------------------------------------------------------------------------
# 字句解析（C# と VB）: コメントを除去し、コード行（C）と文字列リテラル（S）を分けて出す。
#   出力: C<TAB>path<TAB>行番号<TAB>コード（リテラルは "" に置換） ／ S<TAB>path<TAB>行番号<TAB>リテラルの中身
# 【#if false / #If False の中は捨てる】無効化された旧コードもコメントと同じく数えない（#else 以降は生きる）。
# -----------------------------------------------------------------------------
lex_cs() { # stdin = ファイル一覧
  awk -v sq="'" -v bom="$BOM" '
    function emit(t) { gsub(/\t/, " ", t); gsub(/\n/, " ", t); print "S\t" f "\t" litln "\t" t }
    function lexline(line,   out, tok, c, i) {
      out = ""
      while (length(line) > 0) {
        if (blk) {
          i = index(line, "*/"); if (i == 0) { line = ""; break }
          line = substr(line, i + 2); blk = 0; out = out " "; continue
        }
        if (vstr) {
          i = index(line, "\"")
          if (i == 0) { lit = lit line "\n"; line = ""; break }
          if (substr(line, i + 1, 1) == "\"") { lit = lit substr(line, 1, i); line = substr(line, i + 2); continue }
          lit = lit substr(line, 1, i - 1); emit(lit); vstr = 0; out = out "\"\""; line = substr(line, i + 1); continue
        }
        if (!match(line, "//|/[*]|[@$]*\"|" sq)) { out = out line; break }
        out = out substr(line, 1, RSTART - 1)
        tok = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        if (tok == "//") { line = ""; break }
        if (tok == "/*") { blk = 1; continue }
        if (tok == sq) {
          if (substr(line, 1, 1) == "\\") line = substr(line, 3); else line = substr(line, 2)
          i = index(line, sq); if (i > 0) line = substr(line, i + 1)
          out = out sq sq; continue
        }
        litln = ln
        if (index(tok, "@") > 0) { vstr = 1; lit = ""; continue }
        lit = ""
        while (1) {
          if (!match(line, "[\\\\\"]")) { lit = lit line; line = ""; break }
          lit = lit substr(line, 1, RSTART - 1); c = substr(line, RSTART, 1); line = substr(line, RSTART + 1)
          if (c == "\\") { lit = lit substr(line, 1, 1); line = substr(line, 2); continue }
          break
        }
        emit(lit); out = out "\"\""
      }
      return out
    }
    {
      f = $0; blk = 0; vstr = 0; ln = 0; skip = 0
      while ((getline line < f) > 0) {
        ln++
        if (ln == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
        sub(/\r$/, "", line)
        if (!blk && !vstr) {
          if (skip) {
            if (line ~ /^[ \t]*#[ \t]*if([ \t]|$)/) skip++
            else if (line ~ /^[ \t]*#[ \t]*endif/) skip--
            else if (skip == 1 && line ~ /^[ \t]*#[ \t]*(else|elif)([ \t]|$)/) skip = 0
            continue
          }
          if (line ~ /^[ \t]*#[ \t]*if[ \t]+(false|0)[ \t]*($|\/\/)/) { skip = 1; continue }
        }
        code = lexline(line)
        if (code ~ /[^ \t]/) { gsub(/\t/, " ", code); print "C\t" f "\t" ln "\t" code }
      }
      if (vstr) emit(lit)
      close(f)
    }'
}
lex_vb() { # stdin = ファイル一覧
  awk -v sq="'" -v bom="$BOM" '
    function emit(t) { gsub(/\t/, " ", t); print "S\t" f "\t" ln "\t" t }
    function remcut(seg,   l) {
      l = tolower(seg)
      if (match(l, /(^|:)[ \t]*rem([ \t]|$)/)) { remhit = 1; return substr(seg, 1, RSTART - 1) }
      return seg
    }
    function lexline(line,   out, c, i, lit, seg, at) {
      out = ""; remhit = 0
      while (length(line) > 0) {
        if (!match(line, "[\"" sq "]")) { out = out remcut(line); break }
        at = RSTART
        seg = remcut(substr(line, 1, at - 1)); out = out seg
        if (remhit) break
        c = substr(line, at, 1); line = substr(line, at + 1)
        if (c == sq) break
        lit = ""
        while (1) {
          i = index(line, "\"")
          if (i == 0) { lit = lit line; line = ""; break }
          lit = lit substr(line, 1, i - 1); line = substr(line, i + 1)
          if (substr(line, 1, 1) == "\"") { lit = lit "\""; line = substr(line, 2); continue }
          break
        }
        emit(lit); out = out "\"\""
      }
      return out
    }
    {
      f = $0; ln = 0; skip = 0
      while ((getline line < f) > 0) {
        ln++
        if (ln == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
        sub(/\r$/, "", line)
        l = tolower(line)
        if (skip) {
          if (l ~ /^[ \t]*#[ \t]*if[ \t]/) skip++
          else if (l ~ /^[ \t]*#[ \t]*end[ \t]+if/) skip--
          else if (skip == 1 && l ~ /^[ \t]*#[ \t]*(else|elseif)([ \t]|$)/) skip = 0
          continue
        }
        if (l ~ /^[ \t]*#[ \t]*if[ \t]+(false|0)[ \t]+then/) { skip = 1; continue }
        code = lexline(line)
        if (code ~ /[^ \t]/) { gsub(/\t/, " ", code); print "C\t" f "\t" ln "\t" code }
      }
      close(f)
    }'
}
LEX="$TMPD/lex.tsv"
ensure_lex() {
  [ -f "$LEX" ] && return 0
  list_files '*.cs' > "$TMPD/cs.list"
  list_files '*.vb' > "$TMPD/vb.list"
  { lex_cs < "$TMPD/cs.list"; lex_vb < "$TMPD/vb.list"; } > "$LEX"
}

# -----------------------------------------------------------------------------
# マークアップの字句解析（.aspx / .ascx / .master / .ashx / .asmx / .svc / Global.asax）:
#   D<TAB>path<TAB>行<TAB>種類（page|control|master|webhandler|webservice|servicehost|application|register|reference|mastertype|import ...）<TAB>属性…
#   T<TAB>path<TAB>行<TAB>タグ名（小文字）<TAB>属性…   … サーバーコントロール（`prefix:Name` か runat="server" のタグ）
#   H<TAB>path<TAB>行<TAB>タグ名<TAB>属性…            … それ以外で href / src / action を持つタグ（静的な遷移）
#   I<TAB>path<TAB>行<TAB>inline|script               … マークアップの中のサーバーコード（コードの走査が読まない）
#   X<TAB>path<TAB>行<TAB>式の中身                     … <% %> / <%# %> / <%= %> の中身（遷移先の文字列を拾うため）
#   M<TAB>path<TAB>1<TAB>precompiled                  … 事前コンパイルの印のファイル（中身は空。画面に数えない）
#   属性は「名前（小文字）=値」をタブで並べる。値の中の <% %>（データバインド式）は @EXPR@ に置き換える。
# 【サーバー側の注釈だけを捨てる】`<%-- --%>` の中は ASP.NET が読まない。**HTML の注釈 `<!-- -->` の中のサーバー
#   コントロールは生きている**（ASP.NET は HTML の注釈を解釈しないので、runat="server" のタグは実行される。落とし穴 6）。
# 【属性の値の中の <% %>】`Text="<%# Eval("X") %>"` のように、値の引用符の中に同じ引用符が来る。<% %> を先に読み飛ばす。
# 【事前コンパイルの出力】配備用に事前コンパイルしたサイトは、.aspx が「This is a marker file ...」の印だけになる
#   （実測 TheBeerHouse: 配備用のディレクトリに同じ画面の印が並び、数えると画面が 2 倍になった。落とし穴 4）。
# -----------------------------------------------------------------------------
MARKUP_GLOBS=('*.aspx' '*.ascx' '*.master' '*.ashx' '*.asmx' '*.svc' 'global.asax')
lex_markup() { # stdin = ファイル一覧
  awk -v sq="'" -v bom="$BOM" '
    function nl(s,   t) { t = s; return gsub(/\n/, "", t) }
    function attrs(s,   out, m, k, v) {
      out = ""
      while (match(s, /<%[^%]*%>/)) s = substr(s, 1, RSTART - 1) "@EXPR@" substr(s, RSTART + RLENGTH)
      while (match(s, /[A-Za-z_][A-Za-z0-9_:.-]*[ \t\n]*=[ \t\n]*("[^"]*"|\047[^\047]*\047)/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        k = m; sub(/[ \t\n]*=.*$/, "", k); v = m; sub(/^[^=]*=[ \t\n]*/, "", v); v = substr(v, 2, length(v) - 2)
        gsub(/[\t\n]/, " ", v); out = out "\t" tolower(k) "=" v
      }
      return out
    }
    {
      f = $0; buf = ""; ln = 0
      while ((getline line < f) > 0) { ln++; if (ln == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1); sub(/\r$/, "", line); buf = buf line "\n" }
      close(f)
      if (index(buf, "This is a marker file generated by the precompilation tool") > 0) { print "M\t" f "\t1\tprecompiled"; next }
      L = length(buf); pos = 1; line = 1; hcend = 0
      while (pos <= L) {
        i = index(substr(buf, pos), "<"); if (i == 0) break
        line += nl(substr(buf, pos, i - 1)); p = pos + i - 1
        if (substr(buf, p, 4) == "<%--") { e = index(substr(buf, p + 4), "--%>"); if (e == 0) break; line += nl(substr(buf, p, e + 7)); pos = p + e + 7; continue }
        if (substr(buf, p, 3) == "<%@") {
          e = index(substr(buf, p), "%>"); if (e == 0) break
          t = substr(buf, p + 3, e - 4); tl = line; line += nl(substr(buf, p, e + 1)); pos = p + e + 1
          if (!match(t, /^[ \t\n]*[A-Za-z]+/)) continue
          kind = tolower(substr(t, RSTART, RLENGTH)); gsub(/[ \t\n]/, "", kind)
          print "D\t" f "\t" tl "\t" kind attrs(substr(t, RSTART + RLENGTH)); continue
        }
        if (substr(buf, p, 2) == "<%") {
          e = index(substr(buf, p), "%>"); if (e == 0) break
          t = substr(buf, p + 2, e - 3)
          # <%= / <%: / <%# は式（表示・データバインド）。それ以外の <% ... %> は文のブロック（サーバーコード）
          if (t !~ /^[=:#$]/) print "I\t" f "\t" line "\tinline"
          # HTML の注釈の中の式（XC）は遷移に数えない（描画されるのは注釈の中で、ブラウザは表示しない）
          x = t; gsub(/[\t\n]/, " ", x); print ((p < hcend) ? "XC" : "X") "\t" f "\t" line "\t" x
          line += nl(substr(buf, p, e + 1)); pos = p + e + 1; continue
        }
        # HTML の注釈: 中のサーバーコントロールは生きているので読み続けるが、ふつうの HTML のリンク（H）はブラウザが表示しないので遷移にしない
        if (substr(buf, p, 4) == "<!--") { e = index(substr(buf, p), "-->"); hcend = (e > 0) ? p + e + 2 : L + 1; pos = p + 4; continue }
        if (!match(substr(buf, p + 1), /^[A-Za-z][A-Za-z0-9_:.-]*/)) { pos = p + 1; continue }
        name = substr(buf, p + 1, RLENGTH); q = ""; j = p + 1 + RLENGTH
        while (j <= L) {
          c = substr(buf, j, 1)
          if (c == "<" && substr(buf, j + 1, 1) == "%") { e = index(substr(buf, j), "%>"); if (e == 0) { j = L; break }
            x = substr(buf, j + 2, e - 3); gsub(/[\t\n]/, " ", x); print ((p < hcend) ? "XC" : "X") "\t" f "\t" (line + nl(substr(buf, p, j - p))) "\t" x; j = j + e + 1; continue }
          if (q != "") { if (c == q) q = "" }
          else if (c == "\"" || c == sq) q = c
          else if (c == ">") break
          j++
        }
        t = substr(buf, p, j - p + 1); tl = line; line += nl(t); pos = j + 1
        a = attrs(substr(t, 2 + length(name))); lname = tolower(name)
        if (lname == "script" && tolower(t) ~ /runat[ \t\n]*=[ \t\n]*["\047]?server/) print "I\t" f "\t" tl "\tscript"
        if (index(lname, ":") > 0 || tolower(t) ~ /runat[ \t\n]*=[ \t\n]*["\047]?server/) print "T\t" f "\t" tl "\t" lname a ((p < hcend) ? "\t@incomment=1" : "")
        else if (a ~ /\t(href|src|action)=/ && p >= hcend) print "H\t" f "\t" tl "\t" lname a
        # 【<script> / <style> の中身はタグとして読まない】`if (a<b)` の `<b` をタグの始まりと読むと、閉じない引用符（`don` + 引用符 + `t`）で
        #   以降のファイル全体が 1 つのタグに呑まれる（反証レビューで実証）。中身の遷移先はクライアントスクリプトの走査（list-refs の script）が拾う
        #   中の <% %>（サーバーのブロック・式。`<%= ResolveUrl("~/x.aspx") %>` 等）は読む
        #   自分で閉じた開きタグ（`<script src="a.js" />`）は中身を持たないので読み飛ばさない。HTML の注釈の中の `<script>` は、
        #   `</script` か注釈の終わりの早い方まで読み飛ばす（どちらかだけだと、注釈の後ろの生きたコントロールを呑む。反証レビューで実証）
        if ((lname == "script" || lname == "style") && t !~ /\/[ \t\n]*>$/) { e = index(tolower(substr(buf, pos)), "</" lname)
          if (p < hcend && (e == 0 || pos + e - 1 > hcend)) e = (hcend > pos) ? hcend - pos + 1 : 0
          if (e > 0) { body = substr(buf, pos, e - 1); bl = line
            while ((k = index(body, "<%")) > 0) { bl += nl(substr(body, 1, k - 1)); body = substr(body, k)
              if (substr(body, 1, 4) == "<%--") { z = index(body, "--%>"); if (z == 0) break; bl += nl(substr(body, 1, z + 3)); body = substr(body, z + 4); continue }
              z = index(body, "%>"); if (z == 0) break
              x = substr(body, 3, z - 3); if (x !~ /^[=:#$]/) print "I\t" f "\t" bl "\tinline"
              gsub(/[\t\n]/, " ", x); print "X\t" f "\t" bl "\t" x; bl += nl(substr(body, 1, z + 1)); body = substr(body, z + 2) }
            line += nl(substr(buf, pos, e - 1)); pos = pos + e - 1 } }
      }
    }'
}
MK="$TMPD/markup.tsv"
ensure_markup() {
  [ -f "$MK" ] && return 0
  list_files "${MARKUP_GLOBS[@]}" > "$TMPD/markup.list"
  lex_markup < "$TMPD/markup.list" > "$MK"
}

# -----------------------------------------------------------------------------
# 型宣言と基底型（C# と VB）: path<TAB>class名(小文字)<TAB>基底名(小文字・名前空間を除く)<TAB>class名(綴り)<TAB>基底名(綴り)
#   C#: `class X : Base` / 宣言が複数行に分かれる形。VB: `Class X` の後の `Inherits Y`（Partial の別ファイルにあることも）。
# -----------------------------------------------------------------------------
TYPES="$TMPD/types.tsv"
ensure_types() {
  [ -f "$TYPES" ] && return 0
  ensure_lex
  {
  awk -F '\t' '
    function flush_base(b,   n, parts) {
      sub(/^[ \t]*/, "", b)
      if (b ~ /^where([ \t]|$)/) b = ""
      sub(/[ \t,{<(].*$/, "", b)
      n = split(b, parts, "."); b = parts[n]
      print pf "\t" tolower(pn) "\t" tolower(b) "\t" pn "\t" b
      pending = 0
    }
    $1 != "C" || tolower($2) !~ /\.cs$/ { next }
    {
      t = $4
      if (pending == 1) {
        if (t ~ /^[ \t]*:/) { sub(/^[ \t]*:/, "", t); flush_base(t); next }
        flush_base("")
      } else if (pending == 2) { flush_base(t); next }
      while (match(t, /(^|[^A-Za-z0-9_.])class[ \t]+/)) {
        rest = substr(t, RSTART + RLENGTH)
        if (!match(rest, /^[^ \t:<{(,;]+/)) { t = rest; continue }
        name = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
        if (rest ~ /^[ \t]*</) { d = 0
          for (k = 1; k <= length(rest); k++) { ch = substr(rest, k, 1)
            if (ch == "<") d++; else if (ch == ">") { d--; if (d == 0) { rest = substr(rest, k + 1); break } } } }
        pf = $2; pn = name
        if (rest ~ /^[ \t]*:[ \t]*$/) { pending = 2 }
        else if (rest ~ /^[ \t]*:/) { sub(/^[ \t]*:/, "", rest); flush_base(rest) }
        else if (rest ~ /^[ \t]*(where|[{])/ ) { flush_base("") }
        else if (rest ~ /^[ \t]*$/) { pending = 1 }
        else { flush_base("") }
        t = rest
      }
    }
    END { if (pending) flush_base("") }' "$LEX"
  awk -F '\t' '
    $1 != "C" || tolower($2) !~ /\.vb$/ { next }
    $2 != pf { sp = 0; pf = $2 }
    {
      line = $4
      while (line ~ /^[ \t]*<[^>]*>/) sub(/^[ \t]*<[^>]*>/, "", line)
      gsub(/:=/, "\001", line)
      ns = split(line, st, ":")
      for (si = 1; si <= ns; si++) {
        s = st[si]
        while (s ~ /^[ \t]*<[^>]*>/) sub(/^[ \t]*<[^>]*>/, "", s)
        t = tolower(s)
        if (match(t, /^[ \t]*((partial|public|private|friend|protected|mustinherit|notinheritable|shadows)[ \t]+)*class[ \t]+/)) {
          rest = substr(s, RLENGTH + 1)
          if (match(rest, /^[^ \t(]+/)) { orig = substr(rest, 1, RLENGTH); name = tolower(orig); stk[++sp] = name; sto[sp] = orig; print $2 "\t" name "\t\t" orig "\t" }
          continue
        }
        if (t ~ /^[ \t]*end[ \t]+class([ \t]|$)/) { if (sp > 0) sp--; continue }
        if (sp > 0 && match(t, /^[ \t]*inherits[ \t]+/)) {
          b = substr(s, RLENGTH + 1); sub(/[ \t,(].*$/, "", b)
          n = split(b, parts, "."); b = parts[n]
          if (b != "") print $2 "\t" stk[sp] "\t" tolower(b) "\t" sto[sp] "\t" b
        }
      }
    }' "$LEX"
  } > "$TYPES"
}

# -----------------------------------------------------------------------------
# 画面と参照
#   アプリの根（~/ の解決先）: web.config・Global.asax・DNN のマニフェスト（*.dnn）があるディレクトリのうち、最も上のもの。
#   参照（REFS）: 種類<TAB>書かれた値<TAB>場所（path:line）<TAB>解決先（./ 始まり・小文字。解決できなければ空）<TAB>解決の仕方
#     種類: master（MasterPageFile）・embed（Register Src・Reference・MasterType・web.config の <controls> の src）・
#           nav（マークアップの属性・web.config・Web.sitemap・マニフェスト）・code（コードの文字列リテラル）
#     解決の仕方: exact（パスで一致）・basename（パスでは一致しないがファイル名が一意）・missing（ファイルが無い）・
#                ambiguous（ファイル名が複数）・dynamic（名前を組み立てている。`{0}.ascx`・"Pages/" + x + ".ascx" の断片）
# 【~/ と相対】`~/x.aspx` はアプリの根から、`x.aspx` / `../x.aspx` は書いたファイルのディレクトリから。
#   コードの文字列はコードビハインドの隣のマークアップから見た相対として読む（同じディレクトリ）。
# 【パスで一致しなければファイル名で引く】DNN のモジュールは `~/DesktopModules/<モジュール>/X.ascx` のように配備先の
#   パスで書く。リポジトリの中のパスとは一致しないので、ファイル名が一意なら basename で解決する（落とし穴 9）。
# -----------------------------------------------------------------------------
PAGE_EXT_RE='[.](aspx|ascx|ashx|asmx|master|svc)'
REFS="$TMPD/refs.tsv"
ROOTS="$TMPD/roots.txt"
ensure_refs() {
  [ -f "$REFS" ] && return 0
  ensure_markup; ensure_lex
  list_files 'web.config' 'global.asax' '*.dnn' '*.dnn5' '*.dnn6' '*.dnn7' | awk '{ d = tolower($0); sub(/\/[^\/]*$/, "", d); print d }' | sort -u > "$ROOTS"
  # 【メニューは XML にあることが多い】画面の一覧・遷移先が権限ごとのメニュー定義（XML）にあり、コードはファイル名を選ぶだけ
  #   （実測 ERPSYS: `RadMenu.LoadContentFile("~/Controls/resources/xml/menu/Sales.xml")` のように役割ごとの XML 12 本。
  #   読まないと画面の 3 分の 1 が「どこからも名指しされない」に出た。落とし穴 8）
  # 【変換ウィザードのログは遷移ではない】旧版の Visual Studio から変換したときの UpgradeWizardLog.xml / _UpgradeReport_Files/ は
  #   全ファイルの名前を並べる（実測 ERPSYS: 1 本で 1,541 件の参照。読むと全画面が「参照される」に化けた）。packages.config も除く
  list_files '*.config' '*.sitemap' '*.dnn' '*.dnn5' '*.dnn6' '*.dnn7' '*.xml' | grep -viE '(^|/)(upgradewizardlog\.xml|packages\.config)$|/_upgradereport_files/' > "$TMPD/cfg.list" || true
  awk -F '\t' '$1 != "M" { print tolower($2) }' "$MK" | sort -u > "$TMPD/mkfiles"
  {
    # マークアップ: ディレクティブと属性
    awk -F '\t' '
      # HTML の注釈の中のサーバーコントロール（@incomment）は、動く（データソース・配線は数える）が描画先が注釈の中なので遷移にしない
      ($1 == "D" || $1 == "T" || $1 == "H") && !($1 == "T" && $0 ~ /\t@incomment=1/) {
        for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v)
          kind = "nav"
          if ($1 == "D" && k == "masterpagefile") kind = "master"
          else if ($1 == "D" && ($4 == "register" || $4 == "reference" || $4 == "mastertype" || $4 == "previouspagetype")) kind = "embed"
          else if ($1 == "D") continue
          print kind "\t" v "\t" $2 ":" $3 }
      }
      # 式の中の遷移先（NavigateUrl に書いた <%# "~/ShowArticle.aspx?ID=" & Eval("ID") %> の形）。属性の値は @EXPR@ に置き換えてあるので式から拾う
      #   （実測 TheBeerHouse: 一覧から詳細への遷移の多くがデータバインド式で、拾わないと詳細画面が「どこからも名指しされない」に出た。落とし穴 8）
      #   （この awk はシェルの単引用符の中にあるので、注釈にも単引用符を書かない）
      $1 == "X" { print "nav\t" $4 "\t" $2 ":" $3 }' "$MK"
    # コードの文字列リテラル
    awk -F '\t' '$1 == "S" { print "code\t" $4 "\t" $2 ":" $3 }' "$LEX"
    # クライアント側のスクリプト（.js と、マークアップの runat の無い <script> の中）。ダイアログ・別窓の画面は JavaScript から開く
    #   （実測 ERPSYS: Controls/DialogBox/ の .aspx 20 本は window.open / RadWindow の URL でしか名指しされない。落とし穴 8）
    { list_files '*.js' | grep -viE '(\.min\.js$|/(scripts|lib|libs|vendor|jquery[^/]*|bootstrap[^/]*|fckeditor|ckeditor|tinymce)/)' || true; cat "$TMPD/markup.list"; } | read_many \
      | awk -F '\t' '$1 != pf { pf = $1; js = (tolower($1) ~ /\.js$/); ins = 0; incmt = 0 }
          # マークアップでは <script> の中の文字だけを出す。スクリプトの外の HTML の注釈は外す（注釈の中の <script> とリンクは数えない）。
          #   自分で閉じた <script ... /> とサーバーの <script runat="server"> はクライアントのスクリプトを始めない（反証レビューで実証）
          { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); gsub(/\t/, " ", t)
            if (js) { print "script\t" t "\t" $1 ":" $2; next }
            out = ""
            while (t != "") {
              if (ins) { i = index(tolower(t), "</script"); if (i == 0) { out = out " " t; break } out = out " " substr(t, 1, i - 1); t = substr(t, i + 8); ins = 0; continue }
              if (incmt) { i = index(t, "-->"); if (i == 0) break; t = substr(t, i + 3); incmt = 0; continue }
              a = index(t, "<!--"); b = index(tolower(t), "<script")
              if (a == 0 && b == 0) break
              if (a > 0 && (b == 0 || a < b)) { t = substr(t, a + 4); incmt = 1; continue }
              r = substr(t, b); g = index(r, ">"); if (g == 0) break
              tag = tolower(substr(r, 1, g)); t = substr(r, g + 1)
              if (tag ~ /runat[ \t]*=[ \t]*["\047]?server/ || tag ~ /\/[ \t]*>$/) continue
              ins = 1
            }
            if (out ~ /[^ ]/) print "script\t" out "\t" $1 ":" $2 }'
    # 設定ファイル・サイトマップ・DNN のマニフェスト（<controls> の src は埋め込み）
    # 【URL の対応づけは仮想の URL】web.config の <urlMappings> の url= は実在しない URL で、mappedUrl= が実在の画面
    #   （実測 TheBeerHouse: ~/articles/beer.aspx などの 6 件が「ファイルが無い」に出た。落とし穴 9）。url= は route として出し、突合から外す
    # 【注釈の中の項目は遷移ではない】XML の <!-- --> の中のメニュー項目は表示されない（実測 ERPSYS: 注釈にしたメニュー項目が
    #   画面 5 つを「名指しされる」側に入れ、存在しない画面 4 つを参照切れに見せていた。反証レビューで実証）。
    # 【DNN のマニフェストは <src> だけ】<files> の <name> は配布する全ファイルの一覧で、遷移ではない（変換ウィザードのログと同じ。
    #   読むと Property Agent の全画面が「名指しされる」に化けた）。<location path=> は設定の範囲で、遷移ではない
    read_many < "$TMPD/cfg.list" | awk -F '\t' "$AWK_XMLCMT"'
      $1 != pf { pf = $1; incmt = 0; dnn = (tolower($1) ~ /\.dnn[0-9]*$/) }
      { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); gsub(/\t/, " ", t); t = decomment(t); lt = tolower(t)
        if (dnn && lt !~ /<(src|controlsrc)>/) next
        if (lt ~ /<location[ \t]/) next
        if (lt ~ /mappedurl[ \t]*=/) {
          if (match(t, /[Mm][Aa][Pp][Pp][Ee][Dd][Uu][Rr][Ll][ \t]*=[ \t]*"[^"]*"/)) print "nav\t" substr(t, RSTART, RLENGTH) "\t" $1 ":" $2
          if (match(t, /[ \t][Uu][Rr][Ll][ \t]*=[ \t]*"[^"]*"/)) print "route\t" substr(t, RSTART, RLENGTH) "\t" $1 ":" $2
          next }
        k = (lt ~ /<add[ \t][^>]*tagprefix=/ && lt ~ /[ \t]src=/) ? "embed" : "nav"; print k "\t" t "\t" $1 ":" $2 }'
  } | awk -F '\t' -v mkf="$TMPD/mkfiles" -v rootf="$ROOTS" -v ext="$PAGE_EXT_RE" '
    FILENAME == mkf { have[$0] = 1; b = $0; sub(/^.*\//, "", b); nb[b]++; bpath[b] = $0; cand[b] = cand[b] SUBSEP $0; next }
    # 同じファイル名が複数あるとき: 書かれたパスの末尾（ディレクトリ名）と最も長く一致する候補が 1 つだけならそれに決める
    #   （実測 ERPSYS: ItemSearch.aspx が 4 か所にあり、BOM/ItemSearch.aspx のような相対参照を名前だけでは引けなかった）
    function bysuffix(lv, b,   n, c, i, best, bn, k, m, ra, ca, nr, nc, j) {
      nr = split(lv, ra, "/"); n = split(cand[b], c, SUBSEP); best = 0; bn = 0
      for (i = 2; i <= n; i++) { nc = split(c[i], ca, "/"); m = 0
        for (j = 0; j < nr && j < nc; j++) { if (ra[nr - j] == "" || ra[nr - j] == ".." || ra[nr - j] == "." || ra[nr - j] == "~") break; if (ra[nr - j] != ca[nc - j]) break; m++ }
        if (m > best) { best = m; bn = 1; k = c[i] } else if (m == best) bn++ }
      return (best >= 2 && bn == 1) ? k : ""
    }
    FILENAME == rootf { root[$0] = 1; next }
    function approot(p,   d, n, a, i, cur) {
      d = p; sub(/\/[^\/]*$/, "", d); n = split(d, a, "/"); cur = ""
      for (i = 1; i <= n; i++) { cur = (i == 1) ? a[1] : cur "/" a[i]; if (cur in root) return cur }
      return "."
    }
    function norm(path,   n, a, i, k, out) {
      n = split(path, a, "/"); k = 0
      for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue; if (a[i] == "..") { if (k > 0) k--; continue } st[++k] = a[i] }
      out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]; return out
    }
    function resolve(kind, raw, where,   from, v, lv, t, base, r, b, how, k, d) {
      from = where; sub(/:[0-9]+$/, "", from)
      lv = tolower(raw)
      if (lv ~ /^(https?|ftp|mailto|javascript):/ || lv ~ /^\/\// || lv ~ /^[a-z0-9-]+(\.[a-z0-9-]+)+\.(com|net|org|jp|io|co)\//) return
      # 名前を組み立てている断片（{0}.ascx・{x}/Header.ascx の {…} 部分・"Pages/" + p + ".ascx" の ".ascx"）と、
      #   URL の書き換え規則の正規表現・後方参照（`error\.aspx`・`~/$1Default.aspx`）は静的に決まらない
      #   （実測 YAF: URL 書き換えの設定の `~/$1Default.aspx` が 20 件「ファイルが無い」に出た）
      if (lv ~ /\$[0-9]|\\[.]|[\^*[]/) { print kind "\t" raw "\t" where "\t\tdynamic"; return }
      gsub(/\\/, "/", lv)
      gsub(/\{[^}]*\}/, "{}", lv)
      if (lv ~ /^[.](aspx|ascx|ashx|asmx|master|svc)$/ || lv ~ /(\{\}|^\})[.](aspx|ascx|ashx|asmx|master|svc)$/) { print kind "\t" raw "\t" where "\t\tdynamic"; return }
      sub(/^\{\}\/?/, "", lv)
      if (lv ~ /^~\//) base = approot(tolower(from)) "/" substr(lv, 3)
      else if (lv ~ /^\//) base = approot(tolower(from)) lv
      else { d = tolower(from); sub(/\/[^\/]*$/, "", d); base = d "/" lv }
      r = norm(base)
      if (r in have) { print kind "\t" raw "\t" where "\t" r "\texact"; return }
      b = lv; sub(/^.*\//, "", b)
      if (nb[b] == 1) { print kind "\t" raw "\t" where "\t" bpath[b] "\tbasename"; return }
      if (nb[b] > 1) { k = bysuffix(lv, b); if (k != "") { print kind "\t" raw "\t" where "\t" k "\tsuffix"; return } }
      how = (nb[b] > 1) ? "ambiguous" : "missing"
      print kind "\t" raw "\t" where "\t\t" how
    }
    {
      s = $2
      while (match(tolower(s), "[^ \t\"\047<>|,;()=*+]*" ext "([?#][^ \t\"\047<>]*)?([^a-z0-9_]|$)")) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        sub(/[^A-Za-z0-9_]$/, "", m); sub(/[?#].*$/, "", m)
        if (m ~ /^[.]?[A-Za-z]+$/ && tolower(m) !~ /^[.](aspx|ascx|ashx|asmx|master|svc)$/) continue
        resolve($1, m, $3)
      }
    }' "$TMPD/mkfiles" "$ROOTS" - > "$REFS"
}

# 画面の一覧（SCREENS）: 種類<TAB>キー（./ 始まり・小文字）<TAB>ファイル（綴りどおり）<TAB>コードビハインドのクラス<TAB>コードビハインドのファイル
#   page    : .aspx（Page ディレクティブ）
#   control-page : .ascx のうち、コードビハインドのクラスの基底が「〜Page」「〜ModuleBase」で終わるもの
#                  （ホストが画面として読み込むコントロール。実測: YAF の ForumPage、DNN の PortalModuleBase。落とし穴 7）
#   control : それ以外の .ascx（部品。画面には数えない。list-controls で扱いを確かめる）
#   master / handler（.ashx）/ service（.asmx・.svc）/ startup（Global.asax）
SCREENS="$TMPD/screens.tsv"
ensure_screens() {
  [ -f "$SCREENS" ] && return 0
  ensure_markup; ensure_types
  awk -F '\t' -v typesf="$TYPES" '
    FILENAME == typesf { if ($3 != "") { base[$2] = $3; bspell[$2] = $5 } decl[$2] = 1; next }
    function pagelike(c,   n, b) {
      n = 0
      while (c != "" && n < 20) { b = (c in base) ? base[c] : ""; if (b == "") return 0
        if (b ~ /(page|modulebase|settingsbase)$/ && b != "page" && b !~ /^(usercontrol|control)$/) return 1
        if (b == "usercontrol" || b == "page") return 0
        c = b; n++ }
      return 0
    }
    $1 == "M" { pre[tolower($2)] = 1; next }
    $1 == "D" && ($4 == "page" || $4 == "control" || $4 == "master" || $4 == "webhandler" || $4 == "webservice" || $4 == "servicehost" || $4 == "application") {
      key = tolower($2); if (key in done) next; done[key] = 1
      inh = ""; cb = ""
      for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v)
        if (k == "inherits" || k == "class") inh = v
        if (k == "codebehind" || k == "codefile") cb = v }
      n = split(inh, pp, "."); cls = pp[n]; sub(/,.*$/, "", cls); lc = tolower(cls)
      kind = $4
      if (kind == "control") kind = pagelike(lc) ? "control-page" : "control"
      else if (kind == "webhandler") kind = "handler"
      else if (kind == "webservice" || kind == "servicehost") kind = "service"
      else if (kind == "application") kind = "startup"
      if (cb != "") { d = $2; sub(/\/[^\/]*$/, "", d); cb = d "/" cb; gsub(/\\/, "/", cb) }
      print kind "\t" key "\t" $2 "\t" cls "\t" cb
    }' "$TYPES" "$MK" | sort -t "$TAB" -k2,2 > "$SCREENS"
}

# XML の注釈（<!-- -->）を外す awk の部品。複数行にまたがる注釈は incmt で次の行へ持ち越す（ファイルが変わったら呼び出し側で 0 にする）。
#   注釈の中に `/>` や `>` があっても切る（`<!--[^>]*-->` の正規表現は `/>` を含む注釈を外せない。反証レビューで実証）
AWK_XMLCMT='
  function decomment(s,   out, i) {
    out = ""
    while (s != "") {
      if (incmt) { i = index(s, "-->"); if (i == 0) return out; s = substr(s, i + 3); incmt = 0; continue }
      i = index(s, "<!--"); if (i == 0) { out = out s; break }
      out = out substr(s, 1, i - 1); s = substr(s, i + 4); incmt = 1
    }
    return out
  }'

# コードファーストの ORM が表にする型（CreateTable<T> / DbSet<T> / VB の (Of T)）: path:line<TAB>型名（綴りどおり）
orm_types_at() {
  ensure_lex
  awk -F '\t' '$1 == "C" { s = $4
      while (match(s, /(CreateTable|CreateTableIfNotExists|DropAndCreateTable|DbSet|IDbSet)[ \t]*(<[ \t]*[A-Za-z_][A-Za-z0-9_.]*|\(Of[ \t]+[A-Za-z_][A-Za-z0-9_.]*)/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); sub(/^[^<(]*(<|\(Of)[ \t]*/, "", m); n = split(m, pp, "."); print $2 ":" $3 "\t" pp[n] } }' "$LEX"
}
orm_types() { orm_types_at | cut -f2; }

# web.config のハンドラ登録（<httpHandlers> / <handlers> の <add path= type=>）。ASP.NET の組み込み（*.axd 等）も載る
config_handlers() {
  list_files 'web.config' | read_many | awk -F '\t' "$AWK_XMLCMT"'
      $1 != pf { pf = $1; incmt = 0; inh = 0 }
      { s = $0; sub(/^[^\t]*\t[^\t]*\t/, "", s); s = decomment(s); l = tolower(s) }
      l ~ /<(httphandlers|handlers)[ \t>]/ { inh = 1 }
      # 開きと閉じが同じ行にある形（`<httpHandlers><add ... /></httpHandlers>`）も読むので、閉じは <add> を読んだ後に見る
      inh && l ~ /<add[ \t]/ && match(s, /[ \t][Pp][Aa][Tt][Hh]="[^"]*"/) { p = substr(s, RSTART + 7, RLENGTH - 8); t = ""
        if (match(s, /[ \t][Tt][Yy][Pp][Ee]="[^",]*/)) t = substr(s, RSTART + 7, RLENGTH - 7)
        print "confighandler\t" p "\t" $1 ":" $2 "\t" t }
      l ~ /<\/(httphandlers|handlers)>/ { inh = 0 }'
}

case "$SUB" in
  ep)
    ensure_screens
    awk -F '\t' '$1 ~ /^(page|control-page|handler|service|startup)$/ { n++ } END { print (n ? n : "unknown") }' "$SCREENS"
    ;;
  list-ep)
    # 種類<TAB>名前（ファイル名）<TAB>場所<TAB>コードビハインドのクラス
    ensure_screens
    awk -F '\t' '$1 ~ /^(page|control-page|handler|service|startup)$/ { n = $3; sub(/^.*\//, "", n); print $1 "\t" n "\t" $3 "\t" $4 }' "$SCREENS"
    config_handlers | awk -F '\t' '{ print $1 "\t" $2 "\t" $3 "\t" $4 }'
    ;;
  list-refs)
    ensure_refs; cat "$REFS"
    ;;
  ep-diff)
    # 画面の 2 経路: 経路A = マークアップ（.aspx・画面として読み込まれる .ascx）/ 経路B = 参照される画面（遷移・設定・コードの文字列・マスター以外）
    ensure_screens; ensure_refs
    awk -F '\t' '$1 == "page" || $1 == "control-page" { print $2 }' "$SCREENS" | sort -u > "$TMPD/sa"
    awk -F '\t' -v sf="$SCREENS" 'FILENAME == sf { if ($1 == "page" || $1 == "control-page") s[$2] = 1; next }
      $4 != "" && $1 != "embed" && $1 != "master" && ($4 in s) { print $4 }' "$SCREENS" "$REFS" | sort -u > "$TMPD/sb"
    echo "== 経路A（マークアップの画面）$(grep -c . "$TMPD/sa" || true) 件 / 経路B（参照される画面）$(grep -c . "$TMPD/sb" || true) 件 =="
    echo "== 経路A のみ（どこからも名指しされない: 既定の文書・外部からの直リンク・名前を組み立てて読み込む・死蔵。人が確認する） =="
    comm -23 "$TMPD/sa" "$TMPD/sb" | awk -F "$TAB" -v sf="$SCREENS" 'FILENAME == sf { o[$2] = $3; next } { print "  " (($1 in o) ? o[$1] : $1) }' "$SCREENS" -
    echo "== 参照先のファイルが無い（★断面の取りこぼし・参照切れ・ホストが提供する画面やコントロール。名前で一意に引けたものは除く） =="
    awk -F '\t' '$5 == "missing" && $1 != "code" && $1 != "route" && tolower($2) !~ /[.](ashx|asmx|svc|axd)$/ { print "  " $2 "\t" $3 "\t" $1 }' "$REFS" | sort -u
    echo "== ハンドラ・サービスのファイルが無い参照（web.config の handlers にクラスで登録した仮想のハンドラか、断面外。list-ep の confighandler と照らす） =="
    awk -F '\t' '$5 == "missing" && tolower($2) ~ /[.](ashx|asmx|svc|axd)$/ { n = $2; sub(/^.*[\/}]/, "", n); c[tolower(n)]++ } END { for (k in c) print "  " k "\t" c[k] " 箇所" }' "$REFS" | sort
    echo "== 仮想の URL（web.config の urlMappings の url=。実在の画面は mappedUrl= の側） =="
    awk -F '\t' '$1 == "route" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    echo "== コードの文字列で、画面のファイルが無いもの（参照切れか、別の意味の文字列） =="
    awk -F '\t' '$5 == "missing" && $1 == "code" && tolower($2) !~ /[.](ashx|asmx|svc|axd)$/ { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    echo "== 名前を組み立てて読み込む箇所（静的に決まらない。読み込み側のコードを読んで画面を補う） =="
    awk -F '\t' '$5 == "dynamic" { print "  " $2 "\t" $3 "\t" $1 }' "$REFS" | sort -u
    echo "== 同じファイル名が複数ある参照（パスで解決できない） =="
    awk -F '\t' '$5 == "ambiguous" { print "  " $2 "\t" $3 }' "$REFS" | sort -u
    echo "== コードビハインドのファイルが無い画面（CodeBehind / CodeFile の指す先が断面に無い） =="
    awk -F '\t' '($1 == "page" || $1 == "control-page") && $5 != "" { print $5 "\t" $3 }' "$SCREENS" | while IFS="$TAB" read -r cb mk; do
      [ -f "$cb" ] || printf '  %s\t%s\n' "$mk" "$cb"
    done
    ;;
  list-controls)
    # ユーザーコントロールの扱い: 種類<TAB>ファイル<TAB>埋め込みの参照数<TAB>動的・その他の参照数<TAB>コードビハインドのクラス
    ensure_screens; ensure_refs
    awk -F '\t' -v rf="$REFS" 'FILENAME == rf { if ($4 != "") { if ($1 == "embed") em[$4]++; else if ($1 != "master") ot[$4]++ } next }
      $1 == "control" || $1 == "control-page" { print $1 "\t" $3 "\t" ($2 in em ? em[$2] : 0) "\t" ($2 in ot ? ot[$2] : 0) "\t" $4 }' "$REFS" "$SCREENS"
    ;;
  mod)
    bash "$SELF" list-mod "$SRC" | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-mod)
    # 種類（csproj|vbproj|website）<TAB>パス。website = プロジェクトファイルの無い Web サイト（web.config のある最上位のディレクトリ）
    # 【Web サイト プロジェクトにはプロジェクトファイルが無い】`CodeFile=` の Web サイトは .sln の Project 行だけが宣言で、
    #   ディレクトリ全体がプロジェクトになる（実測 TheBeerHouse の TBH_Web。落とし穴 5）。
    list_files '*.csproj' '*.vbproj' > "$TMPD/proj.list"
    # 浅いディレクトリから順に読む（Admin/web.config を親の Web サイトより先に読むと、別の Web サイトに数える）
    list_files 'web.config' | awk -F '/' '{ print NF "\t" $0 }' | sort -n | cut -f2- > "$TMPD/wc.list"
    awk -v pl="$TMPD/proj.list" '
      FILENAME == pl { d = tolower($0); sub(/\/[^\/]*$/, "", d); pd[d] = 1; e = tolower($0); sub(/^.*\./, "", e); print e "\t" $0; next }
      { d = $0; sub(/\/[^\/]*$/, "", d); ld = tolower(d)
        # プロジェクトのディレクトリ（とその下）・既に Web サイトにしたディレクトリの下は除く
        n = split(ld, a, "/"); cur = ""; skip = 0
        for (i = 1; i <= n; i++) { cur = (i == 1) ? a[1] : cur "/" a[i]; if ((cur in pd) || (cur in ws)) { skip = 1; break } }
        if (!skip) { ws[ld] = 1; print "website\t" d "/" } }' "$TMPD/proj.list" "$TMPD/wc.list"
    ;;
  mod-diff)
    # 経路A = 実在するプロジェクト・Web サイト / 経路B = .sln の Project 行・.slnx の <Project Path=>（C#・VB・Web サイト）
    bash "$SELF" list-mod "$SRC" | cut -f2 | awk '{ print tolower($0) }' | sort -u > "$TMPD/ma"
    list_files '*.sln' '*.slnx' > "$TMPD/sln.list"
    awk '
      function norm(p,   n, a, i, k, out) { gsub(/\\/, "/", p); n = split(p, a, "/"); k = 0
        for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue; if (a[i] == "..") { if (k > 0) k--; continue } st[++k] = a[i] }
        out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]; return tolower(out) }
      {
        sl = $0; dir = sl; sub(/\/[^\/]*$/, "", dir)
        while ((getline line < sl) > 0) {
          sub(/\r$/, "", line); rel = ""
          if (line ~ /^Project\(/) { n = split(line, q, "\""); rel = q[6] }
          else if (match(line, /<Project[ \t]+Path="[^"]+"/)) { rel = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", rel); sub(/"$/, "", rel) }
          if (rel == "") continue
          lr = tolower(rel)
          if (lr ~ /^https?:/) { print "web:" lr; continue }
          if (lr ~ /\.(csproj|vbproj)$/) print norm(dir "/" rel)
          else if (lr ~ /[\\\/]$/) print norm(dir "/" rel) "/"
        }
        close(sl)
      }' "$TMPD/sln.list" | sort -u > "$TMPD/mb"
    echo "== 実在 $(grep -c . "$TMPD/ma" || true) 件 / .sln・.slnx の宣言 $(grep -c . "$TMPD/mb" || true) 件（$(grep -c . "$TMPD/sln.list" || true) 本） =="
    echo "== 実在のみ（どのソリューションにも載らない: 別ソリューション管理・試作・配備用の写し） =="
    comm -23 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    echo "== 宣言のみ（ソリューションにあるがファイル・ディレクトリが無い。断面の取りこぼし・IIS 上の Web サイト（http://）） =="
    comm -13 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    ;;
  list-handlers)
    # イベント配線: 画面（マークアップのパス。コードビハインドならその画面へ寄せる）<TAB>イベント元<TAB>ハンドラ<TAB>系統
    #   系統: markup（`<asp:Button OnClick="Save_Click">`）・handles（VB の Handles 句）・code（C# の +=・VB の AddHandler）・
    #         auto（AutoEventWireup="true" の画面で Page_Load / Page_Init 等の名前で自動配線されるメソッド）
    # 【配線はマークアップにもコードにもある】Web フォームの C# はマークアップの On〜 属性で、VB は Handles 句で配線するのが
    #   既定（実測: ERPSYS は markup、TheBeerHouse VB は handles が主）。片方だけを数えると操作が半分消える（落とし穴 11）。
    # 【クライアント側の属性を数えない】OnClientClick・HTML の onclick（runat の無いタグ）はブラウザで動く。
    ensure_screens; ensure_lex
    awk -F '\t' '$5 != "" { print tolower($5) "\t" $3 "\t" $2 }' "$SCREENS" > "$TMPD/cbmap"
    awk -F '\t' '$1 == "D" && ($4 == "page" || $4 == "control" || $4 == "master") { a = 1; for (i = 5; i <= NF; i++) if (tolower($i) == "autoeventwireup=false") a = 0; print tolower($2) "\t" a }' "$MK" > "$TMPD/aew"
    {
      awk -F '\t' '$1 == "T" { id = ""
          for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v); if (k == "id") id = v }
          for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v)
            if (k ~ /^on[a-z]+$/ && k !~ /^onclient/ && v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print $2 "\t" (id != "" ? id : $4) "." substr(k, 3) "\t" v "\tmarkup\t" $2 ":" $3 } }' "$MK"
      awk -F '\t' -v cbf="$TMPD/cbmap" -v aewf="$TMPD/aew" '
        FILENAME == cbf { scr[$1] = $2; next }
        FILENAME == aewf { aew[$1] = $2; next }
        $1 != "C" { next }
        function key(p,   l) { l = tolower(p); return (l in scr) ? scr[l] : p }
        function out(k, e, h, kind, where,   le) { le = e; sub(/^(Me|this|MyBase|base)\./, "", le); sub(/^(Me|this)\./, "", h)
          if (!((k SUBSEP tolower(le) SUBSEP tolower(h)) in seen)) { seen[k SUBSEP tolower(le) SUBSEP tolower(h)] = 1; print k "\t" le "\t" h "\t" kind "\t" where } }
        {
          k = key($2); t = $4; lp = tolower($2)
          if (lp ~ /\.vb$/) {
            if ($2 == pk && cont != "") t = cont " " t
            cont = ""; pk = $2
            if (t ~ /[ \t]_[ \t]*$/) { sub(/[ \t]_[ \t]*$/, "", t); cont = t; next }
            lt = tolower(t)
            if (match(lt, /(^|[ \t])sub[ \t]+[^ \t(]+/)) {
              h = substr(t, RSTART, RLENGTH); sub(/^[ \t]*[Ss][Uu][Bb][ \t]+/, "", h)
              if (match(lt, /\)[ \t]*handles[ \t]+/)) { lst = substr(t, RSTART + RLENGTH); n = split(lst, ev, ",")
                for (i = 1; i <= n; i++) { e = ev[i]; gsub(/^[ \t]+|[ \t]+$/, "", e); if (e != "") out(k, e, h, "handles", $2 ":" $3) } }
              else if (tolower(h) ~ /^page_(preinit|init|initcomplete|preload|load|loadcomplete|prerender|prerendercomplete|savestatecomplete|unload|error|databind)$/ && aew[lp_mk(lp)] == 1) out(k, "Page." substr(h, 6), h, "auto", $2 ":" $3)
            }
            if (match(lt, /^[ \t]*addhandler[ \t]+/)) { r = substr(t, RLENGTH + 1); c = index(r, ","); if (c > 0) { e = substr(r, 1, c - 1); gsub(/^[ \t]+|[ \t]+$/, "", e)
                rest = substr(r, c + 1); h = "(lambda)"; if (match(tolower(rest), /addressof[ \t]+[^ \t)]+/)) { h = substr(rest, RSTART, RLENGTH); sub(/^[Aa][Dd][Dd][Rr][Ee][Ss][Ss][Oo][Ff][ \t]+/, "", h) }
                out(k, e, h, "code", $2 ":" $3) } }
            next
          }
          if (match(t, /(void|Task)[ \t]+Page_[A-Za-z]+[ \t]*\(/)) { h = substr(t, RSTART, RLENGTH); sub(/^(void|Task)[ \t]+/, "", h); sub(/[ \t]*\($/, "", h)
            if (tolower(h) ~ /^page_(preinit|init|initcomplete|preload|load|loadcomplete|prerender|prerendercomplete|savestatecomplete|unload|error|databind)$/ && aew[lp_mk(lp)] == 1) out(k, "Page." substr(h, 6), h, "auto", $2 ":" $3) }
          if (match(t, /(void|Task)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) { m = substr(t, RSTART, RLENGTH); sub(/^(void|Task)[ \t]+/, "", m); sub(/[ \t]*\($/, "", m); meth[k SUBSEP tolower(m)] = 1 }
          while (match(t, /[^ \t;{}()=+]+\.[^ \t;{}()=+.]+[ \t]*\+=/)) {
            src = substr(t, RSTART, RLENGTH); sub(/[ \t]*\+=$/, "", src)
            rhs = substr(t, RSTART + RLENGTH); sub(/^[ \t]*/, "", rhs); t = rhs
            if (rhs ~ /^new[ \t]+[^(;]*Handler(<[^>]*>)?[ \t]*\(/) { h = rhs; sub(/^new[ \t]+[^(]*\([ \t]*/, "", h); sub(/[ \t]*\).*$/, "", h); out(k, src, h, "code", $2 ":" $3) }
            else if (rhs ~ /^(async[ \t]+)?\([^()]*\)[ \t]*=>/ || rhs ~ /^(async[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=>/ || rhs ~ /^delegate([ \t(]|$)/) out(k, src, "(lambda)", "code", $2 ":" $3)
            # メソッド名を渡す形（`btn.Click += Save_Click;`）は、同じ画面のファイル群でメソッドとして宣言された名前に限る
            #   （`lblMsg.Text += msg;` / `newGroup.Quantity += qty;` は配線ではない。実測 ERPSYS で混入。反証レビューの指摘）。宣言は後に来ることがあるので最後に判定する
            else if (rhs ~ /^(this\.)?[A-Za-z_][A-Za-z0-9_]*[ \t]*;/) { h = rhs; sub(/[ \t]*;.*$/, "", h); sub(/^this\./, "", h); if (src ~ /^(this\.)?[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_]+$/) { ng++; gk[ng] = k; gs[ng] = src; gh[ng] = h; gw[ng] = $2 ":" $3 } }
          }
        }
        END { for (i = 1; i <= ng; i++) if ((gk[i] SUBSEP tolower(gh[i])) in meth) out(gk[i], gs[i], gh[i], "code", gw[i]) }
        # コードビハインド（x.aspx.cs / x.aspx.vb）→ マークアップ（x.aspx）
        function lp_mk(p) { sub(/\.(cs|vb)$/, "", p); sub(/\.designer$/, "", p); return p }' "$TMPD/cbmap" "$TMPD/aew" "$LEX"
    } | sort -u
    ;;
  list-datasources)
    # マークアップのデータソース: 画面<TAB>コントロール（タグ名#ID）<TAB>属性名<TAB>値<TAB>場所
    #   SqlDataSource の Select/Insert/Update/DeleteCommand（と CommandType）・ObjectDataSource の TypeName と 〜Method・
    #   EntityDataSource / LinqDataSource の EntitySetName / TableName・AccessDataSource の DataFile
    ensure_markup
    awk -F '\t' '$1 == "T" && $4 ~ /:(sqldatasource|objectdatasource|entitydatasource|linqdatasource|accessdatasource|xmldatasource)$/ { id = ""
        for (i = 5; i <= NF; i++) if ($i ~ /^id=/) { id = $i; sub(/^id=/, "", id) }
        for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v)
          if (k ~ /^(selectcommand|insertcommand|updatecommand|deletecommand|selectcommandtype|insertcommandtype|updatecommandtype|deletecommandtype|typename|dataobjecttypename|selectmethod|insertmethod|updatemethod|deletemethod|selectcountmethod|entitysetname|tablename|contexttypename|datafile|connectionstring)$/)
            print $2 "\t" $4 "#" id "\t" k "\t" v "\t" $2 ":" $3 } }' "$MK"
    ;;
  inline-code)
    ensure_markup
    awk -F '\t' '$1 == "I" { c[$2 "\t" $4]++ } END { for (k in c) print k "\t" c[k] }' "$MK" | sort
    ;;
  scope)
    # ディレクトリ（2 階層まで）ごとの件数: ディレクトリ<TAB>.cs<TAB>.vb<TAB>.aspx<TAB>.ascx<TAB>プロジェクト
    # 【同梱した第三者ライブラリ】ORM・検索エンジン等のソースを丸ごとリポジトリに入れていることがある（実測 YAF: ServiceStack と
    #   Lucene.Net のソースが .cs 3,438 のうち 2,056）。数えると型・表・SQL が桁で増える（落とし穴 3）。
    #   ここで見つけて SCAN_EXCLUDE に書き、ADR で処分する。
    find . \( -name .git -o -name .svn -o -iname bin -o -iname obj -o -name packages -o -name node_modules -o -name .vs \) -prune -o -type f -print 2>/dev/null \
      | awk '{ l = tolower($0); n = split($0, a, "/"); d = (n >= 4) ? a[1] "/" a[2] "/" a[3] : ((n == 3) ? a[1] "/" a[2] : ".")
          k = ""; if (l ~ /\.cs$/) k = "cs"; else if (l ~ /\.vb$/) k = "vb"; else if (l ~ /\.aspx$/) k = "aspx"; else if (l ~ /\.ascx$/) k = "ascx"; else if (l ~ /\.(csproj|vbproj)$/) k = "proj"
          if (k != "") { c[d SUBSEP k]++; ds[d] = 1 } }
          END { for (d in ds) print d "\t" c[d SUBSEP "cs"] + 0 "\t" c[d SUBSEP "vb"] + 0 "\t" c[d SUBSEP "aspx"] + 0 "\t" c[d SUBSEP "ascx"] + 0 "\t" c[d SUBSEP "proj"] + 0 }' \
      | sort -t "$TAB" -k2,2nr
    ;;
  bnd)
    bash "$SELF" list-bnd "$SRC" | cut -f1 | sort -u | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-bnd|bnd-idents)
    # 経路A: コードの SQL 文字列リテラル・マークアップの SqlDataSource の SQL・SQL ファイル（.sql・.SqlDataProvider・SQL_STORE_GLOBS）
    #   から参照される表名 ＋ コードファーストの ORM の型（bnd-schema の orm 行の型を、コードがジェネリック引数で使う箇所）
    # 【SQL リテラルの判定（コードのリテラルとマークアップの属性だけに掛ける）】SQL 句の語で**始まる**ものだけを SQL と見なす。
    #   先頭語が「先頭だけ大文字」（Select / From）なら英文と見なして除き、英文に特有の語を含む小文字のリテラルも除く（落とし穴 12）。
    ensure_lex; ensure_markup
    sql_stream > "$TMPD/sqls.tsv"
    orm_types | sort -u > "$TMPD/ormtypes"
    {
      awk -F '\t' '$1 == "S" { print "lit\t" $2 "\t" $3 "\t" $4 }' "$LEX"
      awk -F '\t' '$1 == "T" && $4 ~ /:(sqldatasource|accessdatasource)$/ { for (i = 5; i <= NF; i++) if ($i ~ /^(select|insert|update|delete)command=/) { v = $i; sub(/^[^=]*=/, "", v); print "lit\t" $2 "\t" $3 "\t" v } }' "$MK"
      awk -F '\t' '{ print "file\t" $1 "\t" $2 "\t" $3 }' "$TMPD/sqls.tsv"
    } | awk -F '\t' -v mode="$SUB" -v sq="'" '
      BEGIN {
        split("select from where join inner outer left right full cross on as set values into update delete insert table exists not null and or by order group having union all distinct top case when then else end in is like with nolock dual if begin declare exec execute cascade restrict no action", k, " ")
        for (i in k) kw[k[i]] = 1
        STRV = sq "[^" sq "]*" sq
        PART = "(\\[[^]]*\\]|`[^`]*`|[^] \t,;()=<>[`]+)"
        QNAME = "^" PART "(\\." PART ")*"
      }
      function emitname(raw, where,   c, part, o, n, br, nn) {
        if (raw ~ /[{}%\/:$]/ || index(raw, sq) > 0) return
        c = split(raw, part, "."); o = part[c]; br = (o ~ /^[[`]/)
        gsub(/[][`"]/, "", o); n = tolower(o)
        if (c > 1) { nn = tolower(part[c - 1]); gsub(/[][`"]/, "", nn); if (nn ~ /^(sys|information_schema)$/) return }
        if (n ~ /^sys(objects|columns|indexes|comments|users|databases|constraints|depends)$/) return
        if (n == "" || n ~ /^[@:?0-9#$.{+-]/) return
        if (!br && (n in kw)) return
        if (mode == "bnd-idents") print n "\t" o; else print n "\t" where "\t" o
      }
      {
        s = $4; where = $2 ":" $3
        # 【二重の引用符】SSMS の生成スクリプトは手続きの本体を sp_executesql に渡す文字列（N に続く引用符の中）に入れ、
        #   本体の中の文字列を引用符 2 個ずつで囲む（実測 TheBeerHouse: RAISERROR の文言 Update of poll failed の of が表に化けた）。
        #   行の中の「引用符 2 個で囲んだ部分」を先に消してから、ふつうの文字列を消す（awk が単引用符の中なので注釈に単引用符を書かない）
        if ($1 == "file") gsub(sq sq "[^" sq "]*" sq sq, sq sq, s)
        gsub(STRV, sq sq, s)
        if ($1 == "lit") {
          if (!match(s, /^[ \t]*\(?[ \t]*[A-Za-z]+/)) next
          w = substr(s, RSTART, RLENGTH); sub(/^[ \t]*\(?[ \t]*/, "", w); lw = tolower(w)
          if (lw !~ /^(select|insert|update|delete|with|merge|create|alter|drop|truncate|exec|execute|from|join|inner|left|right|full|cross|where|and|or|set|values|union|order|group)$/) next
          if (w ~ /^[A-Z][a-z]+$/) next
          if (tolower(s) ~ /(^|[ \t])(the|your|please|you)([ \t.,!?]|$)/) next
        } else {
          gsub(/\/[*][^*]*[*]\//, " ", s)
        }
        while (match(tolower(s), /(^|[^a-z0-9_])(from|join|into|update|delete[ \t]+from|delete|truncate[ \t]+table)[ \t]+/)) {
          kwm = tolower(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH)
          if (!match(s, QNAME)) continue
          raw = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
          if (kwm ~ /delete[ \t]+$/ && kwm !~ /from/ && tolower(rest) ~ /^[ \t]+from[ \t]/) continue
          if (kwm ~ /update[ \t]+$/ && tolower(rest) ~ /^[ \t]+set[ \t]/ && raw ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && \
              tolower(rest) ~ ("(^|[^a-z0-9_])from[ \t]+[^ \t,;()]+[ \t]+(as[ \t]+)?" tolower(raw) "([^a-z0-9_]|$)")) continue
          emitname(raw, where)
          if (kwm ~ /from[ \t]+$/) {
            while (1) {
              if (match(tolower(rest), /^[ \t]+(as[ \t]+)?[a-z_][a-z0-9_]*/)) {
                alen = RLENGTH; al = tolower(substr(rest, RSTART, RLENGTH)); sub(/^[ \t]+(as[ \t]+)?/, "", al)
                if (!(al in kw)) rest = substr(rest, alen + 1)
              }
              if (!match(rest, /^[ \t]*,[ \t]*/)) break
              rest = substr(rest, RLENGTH + 1)
              if (!match(rest, QNAME)) break
              emitname(substr(rest, 1, RLENGTH), where); rest = substr(rest, RLENGTH + 1)
            }
          }
        }
      }' > "$TMPD/bnd-sql"
    # コードファーストの ORM: 型がジェネリック引数として使われる箇所（`GetRepository<User>()`・`db.Select<Topic>(...)`）。
    #   定義（CreateTable<T> / DbSet<T>）そのものは除く（それは bnd-schema 側）
    awk -F '\t' -v otf="$TMPD/ormtypes" -v mode="$SUB" '
      FILENAME == otf { ot[tolower($0)] = $0; next }
      $1 != "C" { next }
      { t = $4
        while (match(t, /<[ \t]*[A-Za-z_][A-Za-z0-9_.]*[ \t]*>|\([ \t]*Of[ \t]+[A-Za-z_][A-Za-z0-9_.]*[ \t]*\)/)) { m = substr(t, RSTART + 1, RLENGTH - 2); pre = substr(t, 1, RSTART - 1); t = substr(t, RSTART + RLENGTH)
          sub(/^[ \t]*Of[ \t]+/, "", m); gsub(/[ \t]/, "", m); n = split(m, pp, "."); m = pp[n]; lm = tolower(m)
          if (!(lm in ot)) continue
          if (pre ~ /(CreateTable|CreateTableIfNotExists|DropTable|DropAndCreateTable|DbSet|IDbSet)[ \t]*$/) continue
          if (mode == "bnd-idents") print lm "\t" ot[lm]; else print lm "\t" $2 ":" $3 "\t" ot[lm] }
      }' "$TMPD/ormtypes" "$LEX" > "$TMPD/bnd-orm"
    if [ "$SUB" = "list-bnd" ]; then
      cat "$TMPD/bnd-sql" "$TMPD/bnd-orm" | sort -u -t "$TAB" -k1,1
    else
      cat "$TMPD/bnd-sql" "$TMPD/bnd-orm"
    fi
    ;;
  bnd-schema)
    # 経路B: スキーマ定義側の表名。系統: DDL（.sql・.SqlDataProvider・コード中の CREATE TABLE）・型付き DataSet（.xsd）・
    #   LINQ to SQL（.dbml）・Entity Framework（.edmx・[Table] 属性・DbSet<T>）・コードファーストの ORM（CreateTable<T>・[Alias] 属性）
    #   出力: キー（小文字）<TAB>系統と場所<TAB>綴り。一時表（`#work`）は表にしない。
    # 【コードファーストの ORM】表はクラスから作られ、DDL がソースに無い（実測 YAF: OrmLite の `CreateTable<User>()` が
    #   移行処理に並ぶ。表名はクラス名か、クラスの [Alias("...")]）。CreateTable<T> / DbSet<T> の型を表として数える（落とし穴 14）。
    ensure_lex
    sql_stream > "$TMPD/sqls.tsv"
    list_files '*.xsd' '*.dbml' '*.edmx' > "$TMPD/schema.list"
    {
      awk -F '\t' '$1 == "S" { print "code\t" $2 ":" $3 "\t" $4 }' "$LEX"
      awk -F '\t' '$1 == "C" && $4 ~ /[[<][ \t]*(System\.ComponentModel\.DataAnnotations\.Schema\.)?(Table|Alias)[ \t]*\(/ { print "attr\t" $2 ":" $3 "\t" $4 }' "$LEX"
      awk -F '\t' '$1 == "C" && $4 ~ /(CreateTable|CreateTableIfNotExists|DropAndCreateTable|DbSet|IDbSet)[ \t]*(<|\(Of)/ { print "orm\t" $2 ":" $3 "\t" $4 }' "$LEX"
      awk -F '\t' '{ print "file\t" $1 ":" $2 "\t" $3 }' "$TMPD/sqls.tsv"
      read_many < "$TMPD/schema.list" | awk -F '\t' '{ t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); gsub(/\t/, " ", t); print "file\t" $1 ":" $2 "\t" t }'
    } | awk -F '\t' '
      function out(n, where,   c, p) { gsub(/[][`"]/, "", n); c = split(n, p, "."); if (p[c] ~ /^[#@]/) return; n = tolower(p[c]); if (n != "") print n "\t" where "\t" p[c] }
      {
        t = $3; lt = tolower(t)
        if (match(lt, /create[ \t]+table[ \t]+(if[ \t]+not[ \t]+exists[ \t]+)?/)) {
          r = substr(t, RSTART + RLENGTH)
          if (match(r, /^(\[[^]]*\]|[^ \t(;[]+)(\.(\[[^]]*\]|[^ \t(;[]+))*/)) out(substr(r, 1, RLENGTH), "ddl " $2)
        }
        if (match(t, /DbObjectName="[^"]+"/)) { r = substr(t, RSTART + 14, RLENGTH - 15); out(r, "xsd " $2) }
        if ($2 ~ /\.dbml:/ && match(t, /<Table[ \t]+Name="[^"]+"/)) { r = substr(t, RSTART, RLENGTH); sub(/^[^"]*"/, "", r); sub(/"$/, "", r); out(r, "dbml " $2) }
        if ($2 ~ /\.edmx:/ && match(t, /store:Name="[^"]+"|[ \t]Table="[^"]+"/)) { r = substr(t, RSTART, RLENGTH); sub(/^[^"]*"/, "", r); sub(/"$/, "", r); out(r, "edmx " $2) }
        if ($1 == "orm") {
          s = t
          while (match(s, /(CreateTable|CreateTableIfNotExists|DropAndCreateTable|DbSet|IDbSet)[ \t]*(<[ \t]*[A-Za-z_][A-Za-z0-9_.]*|\(Of[ \t]+[A-Za-z_][A-Za-z0-9_.]*)/)) {
            m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH); sub(/^[^<(]*(<|\(Of)[ \t]*/, "", m); out(m, "orm " $2) }
        }
      }
      # [Table("X")] / [Alias("X")] は同じ行にクラスの宣言があるものだけ（列に付いた [Alias] を表にしない）
      $1 == "attr" && match($3, /(Table|Alias)[ \t]*\([ \t]*(Name[ \t]*:?=[ \t]*)?"[^"]+"/) && $3 ~ /(^|[ \t])[Cc]lass[ \t]/ { r = substr($3, RSTART, RLENGTH); sub(/^[^"]*"/, "", r); sub(/"$/, "", r); out(r, "attr " $2) }' \
      | sort -u -t "$TAB" -k1,1
    ;;
  bnd-diff)
    bash "$SELF" list-bnd "$SRC" | cut -f1 | sort -u > "$TMPD/ba"
    bash "$SELF" bnd-schema "$SRC" | cut -f1 | sort -u > "$TMPD/bb"
    echo "== 経路A（コード・マークアップ・SQL ファイルから参照）$(grep -c . "$TMPD/ba" || true) 件 / 経路B（スキーマ定義）$(grep -c . "$TMPD/bb" || true) 件 =="
    if [ ! -s "$TMPD/bb" ]; then
      echo "★経路B が 0 件。スキーマがソースに無い（.mdf 等のバイナリ・別リポジトリ・独自形式）。"
      echo "  sql-stores で独自形式のスキーマ/SQL 置き場を探し、見つからなければ enumeration.md の注記に従い経路B を書き換える"
    fi
    echo "== 経路A のみ（参照はあるが定義が無い: ビュー・一時表・システム表・別 DB・英文の混入・定義の取りこぼし） =="
    comm -23 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    echo "== 経路B のみ（定義はあるがコードから参照されない: 死蔵機能・動的 SQL・ストアドプロシージャの中からだけ使う表） =="
    comm -13 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    ;;
  list-sproc)
    # 呼び出し側: ① CommandType.StoredProcedure と同じ行・同じファイルの *Command( / CommandText = に渡す識別子だけのリテラル
    #             ② そのファイルが宣言する「先頭引数が文字列のメソッド」（DB ヘルパー）に渡す識別子だけのリテラル
    #             ③ DNN の `DatabaseOwner & ObjectQualifier & "名前"`（VB）/ `+ "名前"`（C#）の名前
    #             ④ マークアップの SqlDataSource の 〜CommandType="StoredProcedure" の 〜Command ⑤ EXEC <名前> のリテラル
    #   定義側: CREATE PROC(EDURE) <名前>（.sql・.SqlDataProvider・SQL_STORE_GLOBS）
    # 【DNN の名前は連結で書く】`ObjectQualifier & "Ventrian_PropertyAgent_AgentGet"` の名前は CommandType を書かない
    #   SqlHelper の呼び出しに渡る（実測 Property Agent: ①②では 0 件。落とし穴 13）。
    ensure_lex; ensure_markup
    awk -F '\t' '$1 == "C" && $4 ~ /CommandType\.StoredProcedure/ { print $2 }' "$LEX" | sort -u > "$TMPD/spf"
    awk -F '\t' '
      FILENAME == ARGV[1] { spf[$0] = 1; next }
      $1 == "C" { code[$2 SUBSEP $3] = $4 }
      $1 == "C" && ($2 in spf) {
        t = $4
        if (match(t, /[ \t][^ \t(]+[ \t]*\([ \t]*([Ss]tring|[Bb]y[Vv]al[ \t]+[^ \t]+[ \t]+[Aa]s[ \t]+[Ss]tring)[ \t]*/)) { m = substr(t, RSTART + 1, RLENGTH - 1); sub(/[ \t]*\(.*$/, "", m); if (m !~ /^(if|while|If|While)$/) wrap[m] = 1 }
      }
      $1 == "S" { k = $2 SUBSEP $3; nth[k]++; lit[k SUBSEP nth[k]] = $4; order[++n] = k SUBSEP nth[k] }
      # 手続き名は識別子だけのリテラル。`@id` のようなパラメータ名は手続きではない（反証レビューで実証）
      function ident(v) { return (v ~ /^[^ \t,;()=@]+$/) }
      function emitcall(v, where, via,   c, pp) { gsub(/[][`]/, "", v); c = split(v, pp, "."); v = pp[c]; print "call\t" v "\t" where (via != "" ? "\tvia " via : "") }
      END {
        for (i = 1; i <= n; i++) {
          split(order[i], a, SUBSEP); k = a[1] SUBSEP a[2]; idx = a[3]; v = lit[order[i]]; where = a[1] ":" a[2]
          if (match(tolower(v), /^[ \t]*exec(ute)?[ \t]+/)) { r = substr(v, RLENGTH + 1); sub(/[ \t(;].*$/, "", r); if (r != "") emitcall(r, where, ""); continue }
          if (!ident(v)) continue
          ctx = code[k]
          s = ctx; j = 0; pre = ""
          while ((p = index(s, "\"\"")) > 0) { j++; if (j == idx) { pre = substr(s, 1, p - 1); break } s = substr(s, p + 2) }
          if (pre ~ /[Oo]bject[Qq]ualifier[ \t]*[&+][ \t]*$/) { emitcall(v, where, "ObjectQualifier"); continue }
          if (!(a[1] in spf)) continue
          if (ctx ~ /CommandType\.StoredProcedure/ || ctx ~ /Command[ \t]*\(|CommandText[ \t]*=/) { emitcall(v, where, ""); continue }
          if (pre == "") continue
          if (match(pre, /[^ \t.(,=]+[ \t]*\([ \t]*$/)) { w = substr(pre, RSTART, RLENGTH); sub(/[ \t]*\([ \t]*$/, "", w); if (w in wrap) emitcall(v, where, w) }
        }
      }' "$TMPD/spf" "$LEX"
    awk -F '\t' '$1 == "T" && $4 ~ /:sqldatasource$/ { delete cmd; delete ty
        for (i = 5; i <= NF; i++) { k = $i; sub(/=.*$/, "", k); v = $i; sub(/^[^=]*=/, "", v)
          if (k ~ /^(select|insert|update|delete)command$/) cmd[substr(k, 1, length(k) - 7)] = v
          if (k ~ /^(select|insert|update|delete)commandtype$/) ty[substr(k, 1, length(k) - 11)] = tolower(v) }
        for (x in cmd) if (ty[x] == "storedprocedure") print "call\t" cmd[x] "\t" $2 ":" $3 "\tvia SqlDataSource" }' "$MK"
    sql_stream | awk -F '\t' '{ l = tolower($3)
        if (match(l, /create[ \t]+(or[ \t]+alter[ \t]+)?proc(edure)?[ \t]+/)) { r = substr($3, RSTART + RLENGTH); sub(/[ \t(;].*$/, "", r); gsub(/[][`]/, "", r); c = split(r, pp, "."); r = pp[c]; if (r != "") print "define\t" r "\t" $1 ":" $2 } }'
    ;;
  sql-stores)
    find . \( -name .git -o -name .svn -o -iname bin -o -iname obj -o -name packages -o -name node_modules -o -name .vs \) -prune \
      -o -type f ! -iname '*.cs' ! -iname '*.vb' ! -iname '*.dll' ! -iname '*.exe' ! -iname '*.pdb' ! -iname '*.png' ! -iname '*.jpg' \
      ! -iname '*.gif' ! -iname '*.ico' ! -iname '*.bmp' ! -iname '*.mdf' ! -iname '*.ldf' ! -iname '*.js' ! -iname '*.css' \
      ! -iname '*.zip' ! -iname '*.nupkg' ! -iname '*.resources' ! -iname '*.cache' ! -iname '*.vsidx' ! -iname '*.snk' ! -iname '*.pfx' \
      ! -iname '*.woff*' ! -iname '*.ttf' ! -iname '*.eot' ! -iname '*.pdf' ! -iname '*.webp' -print 2>/dev/null \
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
  idents-screen)
    # 画面のファイル名（綴りどおり。`ManageArticles.aspx` のように拡張子つきで仕様に書く）。同じ名前は 1 つ
    ensure_screens
    awk -F '\t' '$1 == "page" || $1 == "control-page" { n = $3; sub(/^.*\//, "", n); if (!seen[tolower(n)]++) print n }' "$SCREENS" | sort
    ;;
  idents-proc)
    # ストアドプロシージャ名（呼び出し側と定義側の和。綴りは最初に現れたもの）
    bash "$SELF" list-sproc "$SRC" | awk -F '\t' '$2 != "" && !seen[tolower($2)]++ { print $2 }' | sort
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-refs|list-controls|list-handlers|list-datasources|list-sproc|inline-code|scope|sql-stores|bnd-idents|idents-table|idents-screen|idents-proc} <source-path>" >&2
    exit 2
    ;;
esac
