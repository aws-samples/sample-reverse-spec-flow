#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（java-struts-ormxml / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod   → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd → 一覧を出力（差分調査用）
#   orm-diff         → *.orm.xml の実体と persistence.xml 宣言の両方向差集合（SB-2（両方向の差集合））
#
# 実測検証: Apache Roller 6.x / app モジュール（2026-08-10）。ep=59 / bnd=31
#
# 【重要】このスクリプト自体の正しさを検証すること（GP-6（ゲートのコマンド自体を検証する））。
#   件数が期待と桁違いなら、データを疑う前にコマンドを疑う。
# =============================================================================
set -uo pipefail

SUB="${1:-}"
SRC="${2:-}"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "unknown"; exit 0; }
# 【シンボリックリンクを物理パスに解決する（2026-09-21。実プロジェクトで踏んだ偽陰性）】
# 解析対象がシンボリックリンクで渡されると、**走査が黙って 0 件を返す**ことがある。
# 実測: `ep=unknown` / `bnd=0` / `mod=0`（本来 59/31/5）になり、
# **分母が空のまま `G-ENUM-SOURCE` が緑になった**——分母を空にして通す最悪の形である。
# 【原因は実装差にある】`find` は引数のリンクを辿らない。`grep -r` も**実装で違う**——
# 実測（同じ機で）: BSD grep 2.6.0 は**辿らない**／ugrep 7.8.4 は**辿る**。
# ⇒ **どの実装かに依存しないよう、入口で 1 度だけ物理パスに解決する**
# （個々の `find` に `-L` を足す形は、次に書く人が忘れる）。
# 見分け方: `ls <path>/<file>` は成功するのに `find <path> -name <file>` が無出力。
# 【`CDPATH= cd --` で呼ぶ】`cd` は `CDPATH` 経由で移動すると**移動先を標準出力に印字する**ため、
# `CDPATH` が設定された環境では代入値が 2 行になり、かつ別の場所を指す（実測: 正しく数えられる
# 入力が `unknown` になった）。`--` はパスが `-` で始まる場合の保険。
SRC="$(CDPATH= cd -- "$SRC" 2>/dev/null && pwd -P)" || { echo "unknown"; exit 0; }
[ -n "$SRC" ] || { echo "unknown"; exit 0; }

case "$SUB" in
  ep)
    # struts*.xml の <action> 宣言。target/ の生成コピーを除外しないと倍になる
    # 【`-r` を付けた効果（2026-09-12。意図した変更）】対象 0 件のとき、GNU では以前
    # `grep` が標準入力を読んで `0` を出していたが、`-r` を付けると grep を起動しないので
    # `unknown` になる（BSD は元から `unknown`）。**両環境で一致し、かつ fail-closed 側**
    # ——`unknown` は `G-ENUM-SOURCE` が未記入として弾くので、対象 0 件を「本当に 0」と
    # 誤って分母に入れずに人の判断へ回せる。
    find "$SRC" -name 'struts*.xml' -not -path '*/target/*' -print0 2>/dev/null \
      | xargs -0 -r grep -ch '<action ' 2>/dev/null | awk '{s+=$1} END {print (NR?s:"unknown")}'
    ;;
  bnd)
    # *.orm.xml の entity を class 属性でユニーク化。
    # `grep -c '<entity'` はルート要素 <entity-mappings> を含み過大計上する（実測 186 vs 正 31）。
    # 属性は複数行に分かれるため class= を直接数える（SB-2（宣言位置まで固定する）: 宣言位置まで固定する）
    grep -rhoE 'class="[a-zA-Z0-9_.]*\.pojos\.[A-Za-z0-9_]+"' "$SRC" --include='*.orm.xml' 2>/dev/null \
      | sort -u | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  mod)
    # 【対象 0 件を「本当に 0」として通さない（2026-09-23 是正。効果測定 E2 が発見）】
    # `ep` は fail-closed（unknown）なのに、ここは `wc -l` で 0 を返していた＝同ファイル内で非対称。
    find "$SRC" -name 'pom.xml' -not -path '*/target/*' 2>/dev/null \
      | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  list-ep)
    find "$SRC" -name 'struts*.xml' -not -path '*/target/*' -print0 2>/dev/null \
      | xargs -0 -r grep -h '<action ' 2>/dev/null | sed 's/^[[:space:]]*//' | sort
    ;;
  list-bnd)
    grep -rhoE 'class="[a-zA-Z0-9_.]*\.pojos\.[A-Za-z0-9_]+"' "$SRC" --include='*.orm.xml' 2>/dev/null \
      | sed 's/class="//;s/"$//' | sort -u
    ;;
  orm-diff)
    # 両方向の差集合（SB-2（両方向の差集合））。実測（Roller）: 実体 31 / 宣言 30 で
    # 差分 1 件は org/apache/roller/planet/pojos/RuntimeConfigProperty.orm.xml。
    # 【是正 2026-09-23】これを当初「実体はあるが宣言されていない（宣言漏れ）」と結論したが、
    # 再実測で **マップ先クラスが宣言されたパッケージに存在しない死蔵ファイル** だった。
    # 差分の対処は「宣言を足す」と「ファイルを消す」で逆向きなので、結論を単一化しない。
    P="$(find "$SRC" -name persistence.xml -not -path '*/target/*' 2>/dev/null | head -1)"
    [ -n "$P" ] || { echo "persistence.xml が見つからない"; exit 0; }
    D="$(mktemp)"; A="$(mktemp)"; KEYS="$(mktemp)"
    trap 'rm -f "$D" "$A" "$KEYS"' EXIT
    # 【basename で突合してはいけない（2026-09-23 是正。実運用で誤誘導した）】
    # 同名ファイルが複数モジュールに存在する構成では、**件数が合ったまま同一性が壊れる**。
    # ⇒ **クラスパスルート相対のフルパス**で突合する。
    # 【ルート一覧はここが正本】文書側に値を再掲しない（実測で target/classes の有無が食い違った）。
    ORM_ROOTS='src/main/resources|src/main/java|src/test/resources|src/test/java|src/main/webapp/WEB-INF/classes'
    grep -oE '<mapping-file>[^<]+' "$P" | sed 's#<mapping-file>##' \
      | sed 's#^[[:space:]]*##; s#[[:space:]]*$##' | sed '/^$/d' | sort > "$D"
    # 【宣言が 0 件なら突合不能】`<mapping-file>` と値が別行に分かれた persistence.xml では
    # 上の grep が 1 件も取れない。0 件のまま進めると実体 M 件が全部「宣言漏れ」に見える。
    if [ ! -s "$D" ]; then
      echo "★<mapping-file> 宣言を 1 件も抽出できない（値が別行に分かれている可能性）。突合不能"
      exit 1
    fi
    find "$SRC" -name '*.orm.xml' -not -path '*/target/*' 2>/dev/null \
      | sed -E "s#^.*/($ORM_ROOTS)/##" | sort > "$A"
    # 【削り残しを fail-closed にする（2026-09-23）】上のルート一覧に当たらないレイアウト
    # （Ant の WEB-INF/classes、独自 resources ディレクトリ、別ビルドツール）では
    # パスが絶対のまま残り、**全件が差分として出るだけの無意味な出力**になる。しかも
    # 後段の死蔵判定は `*//Users/...` という必ず無マッチのパターンになり「死蔵 0 件」と読める。
    # ⇒ 削り残しが 1 件でもあれば突合不能として止める（黙って差分に数えない）。
    unstripped="$(grep -c '^/' "$A" || true)"
    if [ "${unstripped:-0}" -gt 0 ]; then
      echo "★クラスパスルートを削れないパスが ${unstripped} 件ある（このレイアウトは ORM_ROOTS 未対応）。突合不能"
      grep '^/' "$A" | head -5 | sed 's/^/    /'
      echo "    ⇒ ORM_ROOTS にルートを追加してから再実行する"
      exit 1
    fi
    # 【キーの衝突を検出する】マルチモジュールで同じクラスパス相対パスが 2 つ以上あると、
    # 正規化後に同一キーへ潰れ、**宣言済みのファイルが「実体のみ」として出る偽陽性**になる。
    # JPA のクラスパス上でも実際に事故になる状態なので、差分より先に報告する。
    uniq -d "$A" > "$KEYS" || true
    if [ -s "$KEYS" ]; then
      echo "== ★クラスパス相対パスの衝突（同一キーが複数モジュールにある。JPA 上でも事故） =="
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        printf '  %s\n' "$k"
        find "$SRC" -path "*/$k" -not -path '*/target/*' 2>/dev/null | sed 's/^/      /'
      done < "$KEYS"
    fi
    echo "== 宣言のみ（persistence.xml にあるがファイルが無い） =="; comm -23 "$D" <(sort -u "$A")
    echo "== 実体のみ（宣言されず JPA が読み込まない。宣言漏れ／死蔵のどちらかは次節で切り分け） =="
    comm -13 "$D" <(sort -u "$A")
    # 【差分は「死蔵」と「宣言漏れ」を切り分ける（2026-09-23 追加）】
    # 実体のみに出たファイルは、**マップ先クラスが実在しない死蔵ファイル**のことがある
    # （対処が逆になる: 宣言を足すのではなくファイルを消す判断になる）。
    echo "== 実体のみの内訳（死蔵の疑い / 宣言漏れ。★実ファイルのフルパスを添える） =="
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      f="$(find "$SRC" -path "*/$rel" -not -path '*/target/*' 2>/dev/null | head -1)"
      # 【無言スキップしない】再発見できないのは正規化かパスの想定が崩れた印
      [ -n "$f" ] || { printf '  %s -> ★実ファイルを再発見できない（正規化の想定崩れ）\n' "$rel"; continue; }
      # 【class= は全件見る】1 ファイルに複数 entity がある構成では head -1 だと
      # 2 件目以降のマップ先クラスを一切検査せず、死蔵を見逃す。
      cls_list="$(grep -oE 'class="[^"]+"' "$f" 2>/dev/null | sed 's/class="//; s/"//' | sort -u)"
      [ -n "$cls_list" ] || { printf '  %s (%s) -> ★class 属性が無い\n' "$rel" "$f"; continue; }
      while IFS= read -r cls; do
        [ -n "$cls" ] || continue
        # 【クラス名だけで探さない（2026-09-23。実測で見逃した）】同名クラスが別パッケージに
        # 存在する構成では、**クラス名だけの検索は「実在する」と誤判定する**。
        # 実測: 宣言は `…planet.pojos.RuntimeConfigProperty` だが実体は `…weblogger.pojos` 側に
        # しかなく、クラス名だけで探すと死蔵を見逃した。**パッケージまで含めたパスで存在を見る。**
        relpath="$(printf '%s' "$cls" | tr '.' '/').java"
        if [ -z "$(find "$SRC" -path "*/${relpath}" -not -path '*/target/*' 2>/dev/null | head -1)" ]; then
          # 【「疑い」に留める理由】依存 jar 側で提供されるエンティティ・内部クラス（ドル記号区切りの入れ子クラス）・
          # Java 以外で定義されたクラスもソースに .java が無い。出力は破壊的な対処を示唆するので
          # 断定しない（observed-anomalies.md に落として確認する。SB-13）。
          printf '  %s (%s) -> %s ★マップ先クラス不在＝死蔵の疑い（宣言を足すのではなくファイルを消す判断。jar 提供・内部クラスの可能性を確認する）\n' "$rel" "$f" "$cls"
        else
          printf '  %s (%s) -> %s 宣言漏れ（クラスは実在。persistence.xml に宣言を足す判断）\n' "$rel" "$f" "$cls"
        fi
      done <<EOF
$cls_list
EOF
    done < <(comm -13 "$D" <(sort -u "$A"))
    ;;
  # 識別子の抽出（G-IDENT 用。GP-20 ルール5 / FB-11）
  # 出力を 01-code-graph/identifiers/<種別>.txt に保存する（1 行 1 識別子）。
  # このスタックは**物理表名が Java コードに無く ORM XML / DDL 側にある**ため、
  # 「エンティティクラス名は書いたが表名は書いていない」状態が起きやすい。
  idents-table)
    # 【`<table>` だけでは足りない（実運用で踏んだ）】ORM 側のテーブル集合には
    # `<join-table>`（多対多の結合表）と `<secondary-table>`（1 エンティティ複数表）も含まれる。
    # 拾わないと**結合表を「ORM 管理外の孤児表」と誤分類**する。
    # 実測（Apache Roller・2026-09-03）: `<table>` のみ 30 件 → 3 種の和集合 31 件（`<join-table>` 1 件の取りこぼし）。
    { grep -rhoE '<(table|join-table|secondary-table) +name="[^"]+"' "$SRC" --include='*.orm.xml' 2>/dev/null \
        | sed 's/.*name="\([^"]*\)".*/\1/'
      grep -rhoiE 'create table +[a-z0-9_]+' "$SRC" --include='*.vm' 2>/dev/null \
        | awk '{print tolower($3)}'
    } | sed '/^$/d' | sort -u
    ;;
  idents-endpoint)
    grep -rhoE '<action +name="[^"]+"' "$SRC" --include='struts*.xml' 2>/dev/null \
      | sed 's/.*name="\([^"]*\)".*/\1/' | sed '/^$/d' | sort -u
    ;;
  idents-entity)
    grep -rhoE 'class="[a-z0-9.]*\.[A-Za-z]+"' "$SRC" --include='*.orm.xml' 2>/dev/null \
      | sed 's/.*\.\([A-Za-z]*\)"/\1/' | sed '/^$/d' | sort -u
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|orm-diff|idents-table|idents-endpoint|idents-entity} <source-path>" >&2
    exit 2
    ;;
esac
