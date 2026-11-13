#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（vbnet-winforms-adonet / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod        → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd | list-mod → 一覧を出力（差分調査用。タブ区切り）
#   ep-diff               → 画面の 2 経路（継承閉包 / プロジェクトの SubType=Form）の要素差分
#   mod-diff              → プロジェクトの 2 経路（実ファイル / .sln の宣言）の要素差分
#   bnd-schema            → DB 表の経路B（スキーマ定義側）の一覧
#   bnd-diff              → DB 表の 2 経路（コード中の SQL / スキーマ定義）の要素差分
#   list-handlers         → イベント配線（Handles 句・AddHandler。4 列目が screen の行が画面の配線）
#   list-sproc            → ストアドプロシージャ名（呼び出し側 / 定義側）
#   sql-stores            → SQL を含むコード以外のファイル（外部 SQL 置き場の発見用）
#   bnd-idents            → 参照側の表名の全出現（idents-table の内部用。キー<TAB>綴り）
#   idents-table | idents-screen → 識別子の抽出（G-IDENT 用。出典の綴りで出す）
#
# 環境変数 SQL_STORE_GLOBS: 外部 SQL 置き場の -iname パターン（空白区切り。例: '*.sqld'）。
#   未設定なら生成先の 00-ingestion/gate-config.env の同名の行を読む（Phase 4 の再実行で付け忘れないように）。
#
# 実測検証（2026-10-22）: Apskaita5（VB.NET の会計システム。14 プロジェクト・.vb 1,118 本）、
#   School-Management-System（VB.NET ＋ DevExpress ＋ SQL Server の業務アプリ）。値は enumeration.md の検証記録を参照。
#
# 【VB は大文字小文字を区別しない】キーワード・識別子・ファイル名（`.Designer.vb` / `.designer.vb`）の
#   どれも大小が混在する。照合はすべて小文字化してから行う（落とし穴 3）。
#
# 【前提】走査はすべて LC_ALL=C のバイト列で行う。.NET の業務アプリは **UTF-8(BOM 有無)・
#   ANSI コードページ・UTF-16** が混在するのが普通で、UTF-8 ロケールの awk/grep は
#   不正バイトで黙って行を落とす（enumeration.md 落とし穴 1）。識別子は非 ASCII を許すため
#   ASCII の文字クラスで名前を切らない（落とし穴 2）。
#
# 【awk の 2 ファイル入力は FILENAME で分岐する】`FNR == NR` は**先に読むファイルが空だと
#   2 つ目の入力を全部 1 つ目として食う**（反証レビューで実証: ビルド対象外が 0 件・ストアド指定が 0 件の
#   構成で出力が黙って空になった）。このスクリプトでは `FILENAME == ARGV[1]` で分岐する。
#
# 【重要】このスクリプト自体の正しさを検証すること（GP-6（ゲートのコマンド自体を検証する））。
#   件数が期待と桁違いなら、データを疑う前にコマンドを疑う。
# =============================================================================
set -uo pipefail
export LC_ALL=C

SUB="${1:-}"
# 自分自身の絶対パス（後で解析対象へ cd するため。bnd-diff 等が自分を呼び直す）
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")"
SRC="${2:-}"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "unknown"; exit 0; }
# 【シンボリックリンクを物理パスに解決する（2026-09-21。実プロジェクトで踏んだ偽陰性）】
# 解析対象がシンボリックリンクで渡されると、**走査が黙って 0 件を返す**ことがある。
# `find` は引数のリンクを辿らず、`grep -r` は実装で違う（BSD grep は辿らない／ugrep は辿る）。
# ⇒ どの実装かに依存しないよう、入口で 1 度だけ物理パスに解決する。
# 【`CDPATH= cd --` で呼ぶ】`CDPATH` 経由で移動すると `cd` が移動先を標準出力に印字する。
SRC="$(CDPATH= cd -- "$SRC" 2>/dev/null && pwd -P)" || { echo "unknown"; exit 0; }
[ -n "$SRC" ] || { echo "unknown"; exit 0; }

# SQL_STORE_GLOBS が環境に無ければ gate-config.env から読む（source しない。値だけを取り出す）
if [ -z "${SQL_STORE_GLOBS+x}" ]; then
  _gc="$(dirname -- "$SELF")/../00-ingestion/gate-config.env"
  if [ -f "$_gc" ]; then
    # 引用符つき・`export` つき・行末コメントつきのどれでも値だけを取り出す（最後の行が勝つ。source と同じ）
    SQL_STORE_GLOBS=$(tr -d '\r' < "$_gc" | awk -v q="'" '
      /^[ \t]*(export[ \t]+)?SQL_STORE_GLOBS=/ {
        v = $0; sub(/^[ \t]*(export[ \t]+)?SQL_STORE_GLOBS=/, "", v); c = substr(v, 1, 1)
        if (c == q || c == "\"") { v = substr(v, 2); i = index(v, c); if (i > 0) v = substr(v, 1, i - 1) }
        else sub(/[ \t#].*$/, "", v)
        last = v }
      END { printf "%s", last }')
  fi
fi
export SQL_STORE_GLOBS="${SQL_STORE_GLOBS:-}"

TMPD="$(mktemp -d)" || { echo "unknown"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
# 出力のパスは解析対象からの相対（`./` 始まり）にする。引用（path:line）にそのまま使えるように。
cd "$SRC" || { echo "unknown"; exit 0; }
TAB="$(printf '\t')"
BOM="$(printf '\357\273\277')"

# 走査対象のファイル一覧（1 行 1 パス）。ビルド出力と VCS 管理領域を除く。
# 【大文字小文字を区別しない】Windows で作られたリポジトリは `.VB` / `.Designer.vb` / `.designer.vb` が混在する
# （実測: School に小文字の `frmlogin.designer.vb` がある）。`-name '*.Designer.vb'` では落ちる（落とし穴 3）。
list_files() { # $@ = -iname のパターン
  local first=1
  local args=()
  for p in "$@"; do
    if [ "$first" -eq 1 ]; then args+=(-iname "$p"); first=0; else args+=(-o -iname "$p"); fi
  done
  find . \( -name .git -o -name .svn -o -name bin -o -name obj -o -name packages -o -name node_modules -o -name .vs \) -prune \
    -o -type f \( "${args[@]}" \) -print 2>/dev/null | sort
}

# テキストとして読む。UTF-16（BOM 付き）は NUL を落として ASCII 部分を読めるようにする。
# 【UTF-16 の .sql / .xml を読む】SSMS の「スクリプト生成」や VS が保存した XML は UTF-16 LE のことがある。
#   素の grep / awk は 1 件も拾わない（実測 School: .sql の CREATE TABLE 13 件が 0 件に見えた。
#   Apskaita5: スキーマ定義 XML が UTF-16。落とし穴 10）。非 ASCII の名前は崩れるので一覧で確認する。
read_text() { # $1 = ファイル
  # 【od の空白に依存しない】BSD の od は 1 バイトごとの区切りの空白数が GNU と違う（反証レビューの指摘）ので、空白を消して比べる
  case "$(head -c 2 "$1" | od -An -tx1 | tr -d ' \n')" in
    fffe|feff) tr -d '\000' < "$1" ;;
    *) cat "$1" ;;
  esac
}

# SQL ファイル: *.sql ＋ SQL_STORE_GLOBS（空白区切りの -iname パターン。例: '*.sqld *.sqlx'）
# 【外部 SQL 置き場】名前付き SQL を XML / 独自拡張子のファイルに置き、コードは名前で引く設計がある
#   （実測 VB.NET の Apskaita5: コード中のリテラルから見える表は 3、`.sqld` を加えると 76。落とし穴 11）。
#   `sql-stores` で見つけた拡張子を Phase 0 で gate-config.env に `SQL_STORE_GLOBS='*.sqld'` の形で書く。
list_sql_files() {
  local globs=('*.sql')
  local g
  set -f
  for g in ${SQL_STORE_GLOBS:-}; do globs+=("$g"); done
  set +f
  list_files "${globs[@]}"
}

# -----------------------------------------------------------------------------
# 字句解析（VB.NET）: コメントを除去し、コード行（C）と文字列リテラル（S）を分けて出す。
#   出力: C<TAB>path<TAB>行番号<TAB>コード（リテラルは "" に置換・小文字化しない）
#         S<TAB>path<TAB>行番号<TAB>リテラルの中身（"" は " に戻す）
# 【なぜ字句解析が要るか】`'` 以降はコメントだが、文字列 "...'..." の中の `'` はコメントではない。
#   素の grep では、コメントアウトされた旧 SQL・旧ハンドラを数え、文字列中の `'`（SQL の文字列値）で
#   後半を切り落とす（落とし穴 4）。`REM` は行頭だけでなく `:` の後（`x = 1 : REM ...`）でもコメント。
# 【`#If False Then` の中は捨てる】無効化された旧コードもコメントと同じく数えない（`#Else` 以降は生きる）。
# -----------------------------------------------------------------------------
lex_vb() { # stdin = ファイル一覧
  awk -v sq="'" -v bom="$BOM" '
    function emit(t) { gsub(/\t/, " ", t); print "S\t" f "\t" ln "\t" t }
    function remcut(seg,   l) {
      # seg の中の「行頭または : の後の REM」以降を落とす。落としたら remhit=1
      l = tolower(seg)
      if (match(l, /(^|:)[ \t]*rem([ \t]|$)/)) { remhit = 1; return substr(seg, 1, RSTART - 1) }
      return seg
    }
    function lexline(line,   out, c, i, lit, seg, at) {
      out = ""; remhit = 0
      while (length(line) > 0) {
        if (!match(line, "[\"" sq "]")) { out = out remcut(line); break }
        # 【RSTART を先に退避する】remcut の中の match() が RSTART を上書きする
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

# 生成済みの字句解析結果をキャッシュする（同じ実行内で何度も使う）
LEX="$TMPD/lex.tsv"
ensure_lex() {
  [ -f "$LEX" ] && return 0
  list_files '*.vb' > "$TMPD/vb.list"
  lex_vb < "$TMPD/vb.list" > "$LEX"
}

# プロジェクトファイルの一覧
PROJ="$TMPD/proj.list"
ensure_proj() {
  [ -f "$PROJ" ] && return 0
  list_files '*.vbproj' > "$PROJ"
}

# -----------------------------------------------------------------------------
# 型宣言と基底型（VB.NET）:
#   path<TAB>class名(小文字)<TAB>基底名(小文字・名前空間を除く。無ければ空)<TAB>class名(宣言の綴り)<TAB>基底名(宣言の綴り)
# 【基底は別の行・別のファイルに書かれる】VB は `Class X` の次の行の `Inherits Y` で継承を宣言し、
#   フォームでは `Inherits` が **Designer.vb 側の Partial Class にだけ**あることが多い。
#   クラス名で束ねて（Partial の全ファイルを 1 つの型として）基底を引く。
# 【1 行に複数の文】`Public Class F1 : Inherits Form` のように `:` で区切った文を順に読む。
# 【行頭の属性】`<Serializable()> Public Class F2` の `<...>` を読み飛ばす（反証レビューで実証: クラスごと消えた）。
# 【名前は非 ASCII を許す】日本語・中国語のクラス名を ASCII の文字クラスで切らない（落とし穴 2）。
# 【入れ子の型】`End Class` までを 1 つの型の範囲とし、入れ子はスタックで追う。
# -----------------------------------------------------------------------------
TYPES="$TMPD/types.tsv"
ensure_types() {
  [ -f "$TYPES" ] && return 0
  ensure_lex
  awk -F '\t' '
    $1 != "C" { next }
    $2 != pf { sp = 0; pf = $2 }
    {
      # 【属性を先に外し、名前付き引数の := を退避してから : で分ける】`<Description(Name:="x")> Public Class F2` が
      #  `:` で割れて宣言ごと消えた（反証レビューで実証）
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
          if (match(rest, /^[^ \t(]+/)) {
            orig = substr(rest, 1, RLENGTH); name = tolower(orig); stk[++sp] = name; sto[sp] = orig
            print $2 "\t" name "\t\t" orig "\t"
          }
          continue
        }
        if (t ~ /^[ \t]*end[ \t]+class([ \t]|$)/) { if (sp > 0) sp--; continue }
        if (sp > 0 && match(t, /^[ \t]*inherits[ \t]+/)) {
          b = substr(s, RLENGTH + 1); sub(/[ \t,(].*$/, "", b)
          n = split(b, parts, "."); b = parts[n]
          if (b != "") print $2 "\t" stk[sp] "\t" tolower(b) "\t" sto[sp] "\t" b
        }
      }
    }' "$LEX" > "$TYPES"
}

# 画面＝Form 派生クラス（経路A。継承閉包）。単位は**クラス**（partial で複数ファイルに分かれても 1 画面）。
#   出力: キー（ディレクトリ/クラス名。小文字）<TAB>クラス名（宣言の綴り）<TAB>代表ファイル（最初の非 Designer）<TAB>全ファイル（; 区切り）
# 根: `Form`、および**ソースに宣言が無い基底**で、宣言の綴りが `Form` で終わるもの（外部部品の基底フォーム）。
#   インタフェース（`I` ＋大文字で始まる名前）と、`Transform` / `Platform` のような小文字の `form` は根にしない
#   （反証レビューで実証: `ICryptoTransform` を実装したクラスが画面に数えられた）。
# 【外部基底を根に入れる理由】実測（VB.NET の School）: 全 30 画面が DevExpress の `XtraForm` を継承し、
#   `Form` からの閉包では 0 件だった（落とし穴 5）。根に入れたものは ep-diff が列挙する（人が確認する）。
# 【partial の分割ファイルを 1 画面に数える】実測 C# の OpenDental: `FormOpenDental` は 3 ファイル、`FormPerio` は 2 ファイルに
#   分かれ、ファイル単位で数えると 967、クラス単位で 964 だった（反証レビューの指摘）。
FORMS_A="$TMPD/forms_a.tsv"
ISF="$TMPD/isf.txt"
ensure_forms_a() {
  [ -f "$FORMS_A" ] && return 0
  ensure_types
  awk -F '\t' -v isf="$ISF" -v roots="$TMPD/roots.txt" '
    { decl[$2] = 1; cls[NR] = $2; bs[NR] = $3; fl[NR] = $1; on[NR] = $4; ob[NR] = $5 }
    END {
      for (i = 1; i <= NR; i++)
        if (bs[i] != "" && !(bs[i] in decl) && ob[i] ~ /Form$/ && ob[i] !~ /^I[A-Z]/) root[bs[i]] = 1
      root["form"] = 1
      changed = 1
      while (changed) { changed = 0
        for (i = 1; i <= NR; i++) if (!(cls[i] in isf_) && bs[i] != "" && ((bs[i] in root) || (bs[i] in isf_))) { isf_[cls[i]] = 1; changed = 1 } }
      for (c in isf_) print c > isf
      for (r in root) if (r != "form") print r > roots
      # 【同名の別クラスを巻き込まない】閉包はクラス名で取るので、別ディレクトリの同名クラス（基底なし）まで
      #  画面になる（反証レビューで実証: A/Options と B/Options : Form で 2 画面）。キーごとに、そのキーの行が
      #  Form 系の基底を持つものだけを出す。
      for (i = 1; i <= NR; i++) {
        p = fl[i]; dir = tolower(p); sub(/\/[^\/]*$/, "", dir)
        if (bs[i] != "" && ((bs[i] in root) || (bs[i] in isf_))) okkey[dir "/" cls[i]] = 1
      }
      for (i = 1; i <= NR; i++) if (cls[i] in isf_) {
        p = fl[i]; dir = tolower(p); sub(/\/[^\/]*$/, "", dir); key = dir "/" cls[i]
        if (!(key in okkey)) continue
        if ((key SUBSEP p) in seenf) continue
        seenf[key SUBSEP p] = 1
        all[key] = (key in all) ? all[key] ";" p : p
        if (tolower(p) !~ /\.designer\.vb$/ && !(key in rep)) { rep[key] = p; nm[key] = on[i] }
        if (!(key in nm)) nm[key] = on[i]
      }
      for (key in all) { r = (key in rep) ? rep[key] : all[key]; sub(/;.*$/, "", r); print key "\t" nm[key] "\t" r "\t" all[key] }
    }' "$TYPES" | sort > "$FORMS_A"
  [ -f "$ISF" ] || : > "$ISF"
  [ -f "$TMPD/roots.txt" ] || : > "$TMPD/roots.txt"
}

# プロジェクトに宣言された Compile 項目（経路B と「コンパイル対象か」の判定に使う）
#   出力: compile|form<TAB>正規化したパス（./ 始まり・小文字）<TAB>プロジェクト ／ proj<TAB>ディレクトリ<TAB>プロジェクト<TAB>SDK 形式なら 1
# 【旧形式と SDK 形式で意味が逆】旧形式（ToolsVersion）は `<Compile Include>` の列挙＝コンパイル対象の全数。
#   SDK 形式（`<Project Sdk=`）は既定で全 .vb を含み、`Include` は明示の追加、`Remove` は除外。
#   実測（C# の OpenDental）: 旧形式の .csproj に無い Form 派生クラスが 21 件あり、
#   ファイルはあるがビルドされない死蔵だった（落とし穴 6）。
COMPILE="$TMPD/compile.tsv"
ensure_compile() {
  [ -f "$COMPILE" ] && return 0
  ensure_proj
  awk '
    function norm(dir, rel,   n, i, out, a, k) {
      gsub(/\\/, "/", rel); gsub(/%20/, " ", rel)
      n = split(dir "/" rel, a, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "" && i > 1) continue
        if (a[i] == ".") continue
        if (a[i] == "..") { if (k > 0) k--; continue }
        st[++k] = a[i]
      }
      out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]
      return tolower(out)
    }
    {
      pj = $0; dir = pj; sub(/\/[^\/]*$/, "", dir); sdk = 0; inc = ""
      while ((getline line < pj) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /<Project[ \t]+Sdk=/) sdk = 1
        if (match(line, /<Compile[ \t]+(Include|Update)="[^"]+"/)) {
          s = substr(line, RSTART, RLENGTH); upd = (s ~ /Update=/)
          sub(/^[^"]*"/, "", s); sub(/"$/, "", s); inc = norm(dir, s)
          if (!upd) print "compile\t" inc "\t" pj
          if (line ~ /\/>[ \t]*$/) inc = ""
        }
        if (inc != "" && line ~ /<SubType>Form<\/SubType>/) print "form\t" inc "\t" pj
        if (line ~ /<\/Compile>/) inc = ""
      }
      close(pj)
      print "proj\t" tolower(dir) "\t" pj "\t" sdk
    }' "$PROJ" > "$COMPILE"
}

# 経路B: プロジェクトの SubType=Form（VS のデザイナが付ける宣言）をクラスのキーに直す
#   ファイルが宣言する Form 派生クラスのキーへ寄せる（Designer 側・partial の分割ファイルに付いた SubType も 1 画面に寄る。
#   実測 VB.NET の Apskaita5: `MainForm.Designer.vb` に SubType=Form があり、寄せないと 1 件多く数えた）。
#   クラス宣言を解析できなかったファイルは `?` ＋パスのキーで出す（経路B のみに出て人が確認する）。
forms_b() {
  ensure_compile; ensure_forms_a
  awk -F '\t' -v isff="$ISF" '
    FILENAME == isff { isf[$0] = 1; next }
    FILENAME == ARGV[2] { lp = tolower($1); dir = lp; sub(/\/[^\/]*$/, "", dir)
      if ($2 in isf) fk[lp] = dir "/" $2; else if (!(lp in any)) any[lp] = dir "/" $2; next }
    $1 == "form" { p = $2; q = p; sub(/\.designer\.vb$/, ".vb", q)
      if (p in fk) print fk[p]; else if (q in fk) print fk[q]; else print "?" p }' "$ISF" "$TYPES" "$COMPILE" | sort -u
}

# コンパイル対象外の .vb（旧形式プロジェクト配下で Compile に無いもの）・どのプロジェクトにも属さないもの
uncompiled() {
  ensure_compile; list_files '*.vb' > "$TMPD/vb.list"
  awk -F '\t' '
    FILENAME == ARGV[1] {
      if ($1 == "compile") c[$2] = 1
      if ($1 == "proj") { pd[++np] = $2; sdk[$2] = $4 }
      next
    }
    {
      lp = tolower($0); best = ""; found = 0
      for (i = 1; i <= np; i++) if (index(lp, pd[i] "/") == 1 && (!found || length(pd[i]) > length(best))) { best = pd[i]; found = 1 }
      if (!found) { print "noproj\t" $0; next }
      if (sdk[best] == 1) next
      if (!(lp in c)) print "uncompiled\t" $0
    }' "$COMPILE" "$TMPD/vb.list"
}

# 実行ファイルのプロジェクト（OutputType が WinExe / Exe）＝プロセス起動点
#   出力: OutputType<TAB>プロジェクト<TAB>起動対象（StartupObject、無ければ My Project/Application.myapp の MainForm）
# 【`Sub Main` を数えても起動点にならない】VB のアプリケーションフレームワークでは起動フォームを
#   `Application.myapp` の `<MainForm>` で宣言し、ソースに `Sub Main` が無い
#   （実測 Apskaita5: 実行ファイル 3 件のうち `Sub Main` を持つのは Windows サービスの 1 件だけ。落とし穴 7）。
#   逆に `Application.myapp` はライブラリにも置かれる（同 12 件・MainForm は空）ので、myapp の数も起動点の数ではない。
exe_projects() {
  ensure_proj
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue
    ot=$(tr -d '\r' < "$pj" | grep -oE '<OutputType>[^<]+' | head -1 | sed 's/<OutputType>//')
    case "$ot" in
      WinExe|Exe|winexe|exe)
        so=$(tr -d '\r' < "$pj" | grep -oE '<StartupObject>[^<]+' | head -1 | sed 's/<StartupObject>//')
        mf=""
        my="$(dirname "$pj")/My Project/Application.myapp"
        [ -f "$my" ] && mf=$(tr -d '\r' < "$my" | grep -oE '<MainForm>[^<]+' | head -1 | sed 's/<MainForm>//')
        printf '%s\t%s\t%s\n' "$ot" "$pj" "${so:-}${mf:+ MainForm=$mf}"
        ;;
    esac
  done < "$PROJ"
}

# サービス入口（画面以外で外部から呼ばれる型）: Windows サービス・Remoting・ASMX・WCF・Web API
service_files() {
  ensure_types; ensure_lex
  {
    awk -F '\t' '$3 ~ /^(servicebase|marshalbyrefobject|webservice|apicontroller|controllerbase)$/ { print $1 "\t" $3 }' "$TYPES"
    awk -F '\t' '$1 == "C" { t = tolower($4) } $1 == "C" && t ~ /<[ \t]*(system\.web\.services\.)?(webmethod|servicecontract|operationcontract)/ { print $2 "\tattribute" }' "$LEX"
  } | awk -F '\t' '{ p = $1; if (tolower(p) ~ /\.designer\.vb$/) p = substr(p, 1, length(p) - 12) ".vb"
      if (!seen[tolower(p)]++) print p "\t" $2 }' | sort
}

case "$SUB" in
  ep)
    ensure_forms_a
    nf=$(grep -c . "$FORMS_A" || true)
    ne=$(exe_projects | grep -c . || true)
    ns=$(service_files | grep -c . || true)
    awk -v a="${nf:-0}" -v b="${ne:-0}" -v c="${ns:-0}" 'BEGIN { s = a + b + c; print (s ? s : "unknown") }'
    ;;
  list-ep)
    ensure_forms_a
    awk -F '\t' '{ print "screen\t" $2 "\t" $3 }' "$FORMS_A"
    exe_projects | awk -F '\t' '{ print "startup\t" $1 "\t" $2 "\t" $3 }'
    service_files | awk -F '\t' '{ print "service\t" $2 "\t" $1 }'
    ;;
  ep-diff)
    # 画面の 2 経路突合。突合キーは「ディレクトリ/クラス名」（小文字。Windows は大文字小文字を区別しない）
    ensure_forms_a
    cut -f1 "$FORMS_A" | sort -u > "$TMPD/fa"
    forms_b > "$TMPD/fb"
    uncompiled | awk -F '\t' '{ print tolower($2) "\t" $1 }' | sort -u > "$TMPD/unc"
    echo "== 経路A（継承閉包）$(grep -c . "$TMPD/fa" || true) 件 / 経路B（SubType=Form）$(grep -c . "$TMPD/fb" || true) 件 =="
    echo "== 閉包の根に入れた外部基底（ソースに宣言が無く綴りが Form で終わる基底。人が妥当性を確認する） =="
    sort -u "$TMPD/roots.txt" | awk '{ print "  " $0 }'
    echo "== 経路A のみ（Form 派生だが SubType=Form の宣言が無い） =="
    comm -23 "$TMPD/fa" "$TMPD/fb" > "$TMPD/aonly"
    awk -F '\t' -v uncf="$TMPD/unc" -v aof="$TMPD/aonly" '
      FILENAME == uncf { u[$1] = $2; next }
      FILENAME == aof { want[$1] = 1; next }
      ($1 in want) {
        n = split($4, fs, ";"); nunc = 0; nnp = 0
        for (i = 1; i <= n; i++) { lp = tolower(fs[i]); if (u[lp] == "uncompiled") nunc++; else if (u[lp] == "noproj") nnp++ }
        r = "（SDK 形式・デザイナで開かない画面・抽象基底など。人が確認する）"
        if (nunc == n) r = "★ビルド対象外（Compile に無い＝死蔵の疑い）"
        else if (nnp == n) r = "★どのプロジェクトにも属さない"
        print "  " $3 "\t" $2 "\t" r }' "$TMPD/unc" "$TMPD/aonly" "$FORMS_A"
    echo "== 経路B のみ（SubType=Form だが継承閉包に入らない） =="
    comm -13 "$TMPD/fa" "$TMPD/fb" | awk '{ print "  " $0 "\t（基底がソース外で綴りが Form で終わらない・ファイル不在・宣言の解析漏れ。人が確認する）" }'
    ;;
  mod)
    ensure_proj
    awk 'END { print (NR ? NR : "unknown") }' "$PROJ"
    ;;
  list-mod)
    ensure_compile
    awk -F '\t' '$1 == "proj" { print ($4 == 1 ? "sdk" : "legacy") "\t" $3 }' "$COMPILE"
    ;;
  mod-diff)
    # 経路A = 実在する .vbproj / 経路B = .sln の Project(...) 宣言（VB のプロジェクト種別のみ）
    # 【.sln にはコード以外の項目も載る】ソリューションフォルダ・セットアップ（.vdproj）・Web サイト等（落とし穴 12）。
    #   拡張子で絞る（GUID で絞ると SDK 形式の新 GUID を落とす）。
    ensure_proj
    awk '{ print tolower($0) }' "$PROJ" | sort -u > "$TMPD/ma"
    list_files '*.sln' > "$TMPD/sln.list"
    awk '
      {
        sl = $0; dir = sl; sub(/\/[^\/]*$/, "", dir)
        while ((getline line < sl) > 0) {
          sub(/\r$/, "", line)
          if (line !~ /^Project\(/) continue
          n = split(line, q, "\""); rel = q[6]
          if (tolower(rel) !~ /\.vbproj$/) continue
          gsub(/\\/, "/", rel)
          m = split(dir "/" rel, a, "/"); k = 0
          for (i = 1; i <= m; i++) { if (a[i] == "" && i > 1) continue; if (a[i] == ".") continue
            if (a[i] == "..") { if (k > 0) k--; continue } st[++k] = a[i] }
          out = "."; for (i = 1; i <= k; i++) out = out "/" st[i]
          print tolower(out)
        }
        close(sl)
      }' "$TMPD/sln.list" | sort -u > "$TMPD/mb"
    echo "== 実在 $(grep -c . "$TMPD/ma" || true) 件 / .sln 宣言 $(grep -c . "$TMPD/mb" || true) 件（.sln $(grep -c . "$TMPD/sln.list" || true) 本） =="
    echo "== 実在のみ（どの .sln にも載らない。変換ウィザードの Backup・試作・別ソリューション管理の可能性） =="
    comm -23 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    echo "== 宣言のみ（.sln にあるがファイルが無い。断面の取りこぼし・参照切れ） =="
    comm -13 "$TMPD/ma" "$TMPD/mb" | sed 's/^/  /'
    ;;
  list-handlers)
    # イベント配線: ファイル（.designer を寄せたパス）<TAB>イベント元<TAB>ハンドラ<TAB>screen|other
    #   4 列目が screen の行が「画面の配線」（画面仕様の操作の分母）。other はユーザーコントロール・業務クラス等。
    #   イベント元の `Me.` / `MyBase.` は外して小文字で出す（`Handles Me.Startup` → `startup`、`MyBase.Load` → `mybase.load`）。
    # 系統: ① `Sub X(...) Handles a.Click, b.Click`（1 つのハンドラが複数のイベントを受ける。対ごとに出す）
    #       ② `AddHandler a.Click, AddressOf X` / `AddHandler a.Click, Sub(s, e) ...`（実行時の配線）
    # 【画面ごとに数える】画面を跨いで sort -u すると `Form_Load` のような同名ハンドラが潰れる
    #   （実測 School の画面の配線: 対 299 がハンドラ名だけの sort -u で 180 に減った。enumeration.md 落とし穴 8）。
    # 【行継続】` _` で終わる行は次の行と連結してから読む（Handles 句が次の行に来る）。
    ensure_lex; ensure_forms_a
    awk -F '\t' -v faf="$FORMS_A" '
      FILENAME == faf { n = split($4, fs, ";"); for (i = 1; i <= n; i++) { p = fs[i]; sub(/\.[Dd][Ee][Ss][Ii][Gg][Nn][Ee][Rr]\.[Vv][Bb]$/, ".vb", p); scr[tolower(p)] = 1 } next }
      $1 != "C" { next }
      {
        key = $2; sub(/\.[Dd][Ee][Ss][Ii][Gg][Nn][Ee][Rr]\.[Vv][Bb]$/, ".vb", key)
        t = $4
        if (key == pk && cont != "") { t = cont " " t }
        cont = ""; pk = key
        if (t ~ /[ \t]_[ \t]*$/) { sub(/[ \t]_[ \t]*$/, "", t); cont = t; next }
        lt = tolower(t)
        if (match(lt, /(^|[ \t])sub[ \t]+[^ \t(]+/) && match(lt, /\)[ \t]*handles[ \t]+/)) {
          hs = lt; match(hs, /(^|[ \t])sub[ \t]+[^ \t(]+/); h = substr(hs, RSTART, RLENGTH); sub(/^[ \t]*sub[ \t]+/, "", h)
          match(lt, /\)[ \t]*handles[ \t]+/); lst = substr(t, RSTART + RLENGTH)
          n = split(lst, ev, ",")
          for (i = 1; i <= n; i++) { e = ev[i]; gsub(/^[ \t]+|[ \t]+$/, "", e); if (e != "") out(key, e, h) }
          next
        }
        # AddHandler は `:` で並べた 2 つ目以降も読む（`AddHandler a.Click, AddressOf H1 : AddHandler b.Click, AddressOf H2`）
        tt = t; gsub(/:=/, "\001", tt); nst = split(tt, sts, ":")
        for (si = 1; si <= nst; si++) {
          u = sts[si]; lu = tolower(u)
          if (!match(lu, /^[ \t]*addhandler[ \t]+/)) continue
          r = substr(u, RLENGTH + 1); c = index(r, ",")
          if (c == 0) continue
          e = substr(r, 1, c - 1); gsub(/^[ \t]+|[ \t]+$/, "", e)
          rest = tolower(substr(r, c + 1))
          if (match(rest, /addressof[ \t]+[^ \t)]+/)) { h = substr(rest, RSTART, RLENGTH); sub(/^addressof[ \t]+/, "", h) }
          else h = "(lambda)"
          out(key, e, h)
        }
      }
      function out(k, e, h,   le) {
        le = tolower(e); sub(/^me\./, "", le)
        sub(/^me\./, "", h)
        if (!((k SUBSEP le SUBSEP h) in seen)) { seen[k SUBSEP le SUBSEP h] = 1; print k "\t" le "\t" h "\t" ((tolower(k) in scr) ? "screen" : "other") }
      }' "$FORMS_A" "$LEX" | sort
    ;;
  bnd|list-bnd|bnd-idents)
    # 経路A: コード中の SQL 文字列リテラルと .sql ファイル（＋ SQL_STORE_GLOBS）から参照される表名
    # 【SQL リテラルの判定（コード中のリテラルだけに掛ける）】SQL 句の語で**始まる**リテラルだけを SQL と見なす。
    #   語を含むだけで判定すると英文メッセージが混入する（実測 C# の OpenDental: 930 → 544。
    #   "Select the item ... from the list" の `the` / `list` が表名に化ける。落とし穴 9）。
    #   先頭語が「先頭だけ大文字」（Select / From）なら英文と見なして除き、英文に特有の語（the / your / please / you）を含む
    #   小文字のリテラルも除く。.sql・外部 SQL 置き場の行には掛けない（`FROM` 句が継続行に来るため）が、`--` コメントは除く。
    # 【SQL の文字列値は先に消す】`'...From your friends'` の `your`（実測 C# の OpenDental）を表名にしない。
    # 【別名・カンマ結合・角括弧】`DELETE a FROM t a` の `a` は別名（表は FROM の後）。`FROM t1 a, t2 b` の t2 も拾う。
    #   `[Order Details]` / `[Order]` のように角括弧で囲んだ名前は空白・予約語でもそのまま表名にする（落とし穴 16）。
    ensure_lex
    list_sql_files > "$TMPD/sql.list"
    {
      awk -F '\t' '$1 == "S" { print "lit\t" $2 "\t" $3 "\t" $4 }' "$LEX"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        read_text "$f" | awk -v f="$f" '{ sub(/\r$/, ""); print "file\t" f "\t" NR "\t" $0 }'
      done < "$TMPD/sql.list"
    } | awk -F '\t' -v mode="$SUB" -v sq="'" '
      BEGIN {
        split("select from where join inner outer left right full cross on as set values into update delete insert table exists not null and or by order group having union all distinct top case when then else end in is like with nolock dual if begin declare exec execute cascade restrict no action", k, " ")
        for (i in k) kw[k[i]] = 1
        STRV = sq "[^" sq "]*" sq
        PART = "(\\[[^]]*\\]|`[^`]*`|[^] \t,;()=<>[`]+)"
        QNAME = "^" PART "(\\." PART ")*"
      }
      function emitname(raw, where,   c, part, o, n, br, nn) {
        # 文字列値の残り・補間式（{GetTableName()}）・URL・LIKE パターンは表名ではない（実測 C# の OpenDental で混入）
        if (raw ~ /[{}%\/:$]/ || index(raw, sq) > 0) return
        c = split(raw, part, "."); o = part[c]; br = (o ~ /^[[`]/)
        gsub(/[][`"]/, "", o); n = tolower(o)
        # 【システムカタログは業務の表ではない】SSMS の生成スクリプトは sys.objects / sys.foreign_keys を参照する。
        #   `ON DELETE CASCADE` の CASCADE も delete の後に来る（実測 School で混入。落とし穴 13）。
        if (c > 1) { nn = tolower(part[c - 1]); gsub(/[][`"]/, "", nn); if (nn ~ /^(sys|information_schema)$/) return }
        if (n ~ /^sys(objects|columns|indexes|comments|users|databases|constraints|depends)$/) return
        if (n == "" || n ~ /^[@:?0-9#$.{+-]/) return
        if (!br && (n in kw)) return
        if (mode == "bnd") seen[n] = 1; else if (mode == "bnd-idents") print n "\t" o; else print n "\t" where "\t" o
      }
      {
        s = $4; where = $2 ":" $3
        gsub(STRV, sq sq, s)
        if ($1 == "lit") {
          if (!match(s, /^[ \t]*\(?[ \t]*[A-Za-z]+/)) next
          w = substr(s, RSTART, RLENGTH); sub(/^[ \t]*\(?[ \t]*/, "", w); lw = tolower(w)
          if (lw !~ /^(select|insert|update|delete|with|merge|create|alter|drop|truncate|exec|execute|from|join|inner|left|right|full|cross|where|and|or|set|values|union|order|group)$/) next
          if (w ~ /^[A-Z][a-z]+$/) next
          if (tolower(s) ~ /(^|[ \t])(the|your|please|you)([ \t.,!?]|$)/) next
        } else {
          sub(/--.*$/, "", s); gsub(/\/[*][^*]*[*]\//, " ", s)
        }
        while (match(tolower(s), /(^|[^a-z0-9_])(from|join|into|update|delete[ \t]+from|delete|truncate[ \t]+table)[ \t]+/)) {
          kwm = tolower(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH)
          if (!match(s, QNAME)) continue
          raw = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
          # DELETE <別名> FROM <表> の別名は表ではない（表は続く FROM の後で拾う）
          if (kwm ~ /delete[ \t]+$/ && kwm !~ /from/ && tolower(rest) ~ /^[ \t]+from[ \t]/) continue
          # T-SQL の UPDATE <別名> SET ... FROM <表> <別名> の別名も表ではない（反証レビューで実証）
          if (kwm ~ /update[ \t]+$/ && tolower(rest) ~ /^[ \t]+set[ \t]/ && raw ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && \
              tolower(rest) ~ ("(^|[^a-z0-9_])from[ \t]+[^ \t,;()]+[ \t]+(as[ \t]+)?" tolower(raw) "([^a-z0-9_]|$)")) continue
          emitname(raw, where)
          # FROM の後のカンマ区切りの結合（FROM t1 a, t2 b）
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
      }
      END { if (mode == "bnd") { for (n in seen) c2++; print (c2 ? c2 : "unknown") } }' \
      | if [ "$SUB" = "list-bnd" ]; then sort -u -t "$TAB" -k1,1 ; else cat; fi
    ;;
  bnd-schema)
    # 経路B: スキーマ定義側の表名。系統: DDL（.sql / コード中の CREATE TABLE）・型付き DataSet（.xsd の DbObjectName）・
    #   LINQ to SQL（.dbml）・Entity Framework（.edmx の Store 側 / <Table> 属性）
    #   出力: キー（小文字）<TAB>系統と場所<TAB>綴り。一時表（`#work`）は表にしない。
    ensure_lex
    list_files '*.sql' '*.xsd' '*.dbml' '*.edmx' > "$TMPD/schema.list"
    {
      awk -F '\t' '$1 == "S" { print "code\t" $2 ":" $3 "\t" $4 }' "$LEX"
      awk -F '\t' '$1 == "C" && tolower($4) ~ /<[ \t]*(system\.componentmodel\.dataannotations\.schema\.)?table[ \t]*\(/ { print "attr\t" $2 ":" $3 "\t" $4 }' "$LEX"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        read_text "$f" | awk -v f="$f" '{ sub(/\r$/, ""); if (f ~ /\.[Ss][Qq][Ll]$/) sub(/--.*$/, ""); print "file\t" f ":" NR "\t" $0 }'
      done < "$TMPD/schema.list"
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
        if ($1 == "attr" && match(t, /Table[ \t]*\([ \t]*(Name[ \t]*=[ \t]*)?"[^"]+"/)) { r = substr(t, RSTART, RLENGTH); sub(/^[^"]*"/, "", r); sub(/"$/, "", r); out(r, "attr " $2) }
      }' | sort -u -t "$TAB" -k1,1
    ;;
  bnd-diff)
    bash "$SELF" list-bnd "$SRC" | cut -f1 | sort -u > "$TMPD/ba"
    bash "$SELF" bnd-schema "$SRC" | cut -f1 | sort -u > "$TMPD/bb"
    echo "== 経路A（コード・.sql から参照）$(grep -c . "$TMPD/ba" || true) 件 / 経路B（スキーマ定義）$(grep -c . "$TMPD/bb" || true) 件 =="
    if [ ! -s "$TMPD/bb" ]; then
      echo "★経路B が 0 件。スキーマがソースに無い（.mdf 等のバイナリ・別リポジトリ・独自形式・自作 ORM）。"
      echo "  sql-stores で独自形式のスキーマ/SQL 置き場を探し、見つからなければ enumeration.md の注記に従い経路B を書き換える"
    fi
    echo "== 経路A のみ（参照はあるが定義が無い: ビュー・一時表・システム表・別 DB・英文の混入・定義の取りこぼし） =="
    comm -23 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    echo "== 経路B のみ（定義はあるがコードから参照されない: 死蔵機能・動的 SQL・外部 SQL 置き場からの参照） =="
    comm -13 "$TMPD/ba" "$TMPD/bb" | sed 's/^/  /'
    ;;
  list-sproc)
    # 呼び出し側: ① CommandType.StoredProcedure を使うファイル内で *Command( / CommandText = に渡す識別子だけのリテラル
    #             ② そのファイルが宣言する「先頭引数が String の Sub / Function」（DB ヘルパー）に渡す識別子だけのリテラル
    #             ③ EXEC <名前> のリテラル（どのファイルでも）。定義側: CREATE PROC(EDURE) <名前>（.sql ＋ SQL_STORE_GLOBS）
    # 【DB ヘルパー越しに呼ばれる】業務アプリは `DBHelper.Exec("proc", ...)` のように手続き名を引数で渡し、
    #   CommandType を設定するファイルには名前のリテラルが無い（実測 C# の Estate: ①だけでは呼び出し 0 件。落とし穴 14）。
    ensure_lex
    awk -F '\t' '$1 == "C" && tolower($4) ~ /commandtype\.storedprocedure/ { print $2 }' "$LEX" | sort -u > "$TMPD/spf"
    awk -F '\t' '
      FILENAME == ARGV[1] { spf[$0] = 1; next }
      $1 == "C" { code[$2 SUBSEP $3] = tolower($4) }
      $1 == "C" && ($2 in spf) {
        t = tolower($4)
        if (match(t, /(sub|function)[ \t]+[^ \t(]+[ \t]*\([ \t]*(byval[ \t]+|byref[ \t]+)?[^ \t,()]+[ \t]+as[ \t]+string/)) {
          m = substr(t, RSTART, RLENGTH); sub(/^(sub|function)[ \t]+/, "", m); sub(/[ \t]*\(.*$/, "", m); wrap[m] = 1 }
      }
      $1 == "S" { k = $2 SUBSEP $3; nth[k]++; lit[k SUBSEP nth[k]] = $4; order[++n] = k SUBSEP nth[k] }
      function ident(v) { return (v ~ /^[^ \t,;()=]+$/) }
      function emitcall(v, where, via,   c, pp) { gsub(/[][`]/, "", v); c = split(v, pp, "."); v = pp[c]; print "call\t" v "\t" where (via != "" ? "\tvia " via : "") }
      END {
        for (i = 1; i <= n; i++) {
          split(order[i], a, SUBSEP); k = a[1] SUBSEP a[2]; idx = a[3]; v = lit[order[i]]; where = a[1] ":" a[2]
          if (match(tolower(v), /^[ \t]*exec(ute)?[ \t]+/)) { r = substr(v, RLENGTH + 1); sub(/[ \t(;].*$/, "", r); if (r != "") emitcall(r, where, ""); continue }
          if (!ident(v)) continue
          ctx = code[k]
          if ((a[1] in spf) && ctx ~ /command[ \t]*\(|commandtext[ \t]*=/) { emitcall(v, where, ""); continue }
          # ② ヘルパー呼び出し: idx 番目の "" の直前がヘルパー名 + ( であること
          s = ctx; j = 0; pre = ""
          while ((p = index(s, "\"\"")) > 0) { j++; if (j == idx) { pre = substr(s, 1, p - 1); break } s = substr(s, p + 2) }
          if (pre == "") continue
          if (match(pre, /[^ \t.(,=]+[ \t]*\([ \t]*$/)) { w = substr(pre, RSTART, RLENGTH); sub(/[ \t]*\([ \t]*$/, "", w); if (w in wrap) emitcall(v, where, w) }
        }
      }' "$TMPD/spf" "$LEX"
    list_sql_files > "$TMPD/sql.list"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      read_text "$f" \
        | awk -v f="$f" '{ sub(/\r$/, ""); sub(/--.*$/, ""); l = tolower($0)
            if (match(l, /create[ \t]+(or[ \t]+alter[ \t]+)?proc(edure)?[ \t]+/)) { r = substr($0, RSTART + RLENGTH); sub(/[ \t(;].*$/, "", r); gsub(/[][`]/, "", r); c = split(r, pp, "."); r = pp[c]; print "define\t" r "\t" f ":" NR } }'
    done < "$TMPD/sql.list"
    ;;
  sql-stores)
    # コード（.vb）以外で SQL を含むファイルを数える。.resx（リソース文字列）・.xml・独自拡張子の
    # 「名前付き SQL 置き場」を発見するため（実測 VB.NET の Apskaita5: コード中のリテラルから見える表は 3、
    # 独自拡張子の .sqld を加えると 76。落とし穴 11）
    find . \( -name .git -o -name .svn -o -name bin -o -name obj -o -name packages -o -name node_modules -o -name .vs \) -prune \
      -o -type f ! -iname '*.vb' ! -iname '*.dll' ! -iname '*.exe' ! -iname '*.pdb' ! -iname '*.png' ! -iname '*.jpg' \
      ! -iname '*.gif' ! -iname '*.ico' ! -iname '*.bmp' ! -iname '*.mdf' ! -iname '*.ldf' -print 2>/dev/null \
      | while IFS= read -r f; do
          n=$(tr -d '\000' < "$f" | grep -ciE '(select[[:space:]].*[[:space:]]from|insert[[:space:]]+into|update[[:space:]].*[[:space:]]set|create[[:space:]]+table)' || true)
          [ "${n:-0}" -gt 0 ] && printf '%s\t%s\n' "$n" "$f"
        done | sort -rn
    ;;
  idents-table)
    # 【綴りは出現の多い方に寄せる】SQL は表名の大小を区別しないので、同じ表が複数の綴りで書かれる
    #   （実測 C# の OpenDental: 2 通り以上の綴りで現れる表が 18）。G-IDENT は大小を区別して
    #   specs/ 本文と突合するので、小文字に揃えて出すと `T_ORDER` と書いた仕様が「未記載」になる。
    #   表ごとに最も多く現れた綴りを 1 つ出す（同数なら辞書順で先）。仕様はこの綴りで書く（落とし穴 15）。
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
    ensure_forms_a
    # 【宣言どおりの綴りで出す】G-IDENT は大小を区別して specs/ 本文と突合するので、小文字化した名前を
    #   出すと `FrmVendor` と書いた仕様が「未記載」になる。同じ名前が複数の綴りで宣言されていれば先の 1 つ。
    cut -f2 "$FORMS_A" | sed '/^$/d' | awk '!seen[tolower($0)]++' | sort
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|list-mod|ep-diff|mod-diff|bnd-schema|bnd-diff|list-handlers|list-sproc|sql-stores|bnd-idents|idents-table|idents-screen} <source-path>" >&2
    exit 2
    ;;
esac
