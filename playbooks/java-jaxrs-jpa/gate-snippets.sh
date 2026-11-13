#!/bin/bash
# =============================================================================
# gate-snippets.sh — 列挙コマンド（java-jaxrs-jpa / GP-105）
# =============================================================================
#
# gates.sh が「独立ソースの実数」を得るために呼ぶ。数え方はスタック依存なので
# コマンド本体をここに分離する（gates.sh 本体はスタック非依存に保つ）。
#
# 使い方: bash gate-snippets.sh <subcommand> <source-path>
#   ep | bnd | mod   → 数値 1 行を出力（数えられない場合は "unknown"）
#   list-ep | list-bnd → 一覧を出力（差分調査用）
#
# 実測検証: Apache Fineract 1.15.0（2026-08-10）。ep=169 / bnd=251
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

# 除外: ビルド生成物とテストコード（混入すると件数が壊れる）
exclude() { grep -v '/build/' | grep -v '/target/' | grep -v '/src/test/'; }

case "$SUB" in
  ep)
    # クラスレベル宣言のみ（行頭）。行内任意位置だと引数アノテーション・
    # コメント内文字列が混入する（実測: 169 → 171）。SB-2（宣言位置まで固定する）
    grep -rlE '^@(Path|RequestMapping)' "$SRC" --include='*.java' 2>/dev/null \
      | exclude | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  bnd)
    # @Table のリテラル値をユニーク化。定数参照は数え落とすため、
    # enumeration.md の落とし穴 2 に従い @Table 保持クラス数とも突合すること
    grep -rhoE '@Table\(name *= *"[^"]+"' "$SRC" --include='*.java' 2>/dev/null \
      | sort -u | awk 'END { print (NR ? NR : "unknown") }'
    ;;
  mod)
    if [ -f "$SRC/pom.xml" ]; then
      grep -c '<module>' "$SRC/pom.xml" 2>/dev/null | tr -d ' '
    elif [ -f "$SRC/settings.gradle" ] || [ -f "$SRC/settings.gradle.kts" ]; then
      grep -hcE "^[[:space:]]*include" "$SRC"/settings.gradle* 2>/dev/null | head -1 | tr -d ' '
    else
      echo "unknown"
    fi
    ;;
  list-ep)
    grep -rlE '^@(Path|RequestMapping)' "$SRC" --include='*.java' 2>/dev/null | exclude | sort
    ;;
  list-bnd)
    grep -rhoE '@Table\(name *= *"[^"]+"' "$SRC" --include='*.java' 2>/dev/null | sort -u
    ;;
  # 落とし穴の検出補助（enumeration.md の 3・6 に対応）
  extra-tables)
    # @Table 走査に含まれない中間表・副表
    grep -rn '@JoinTable\|@SecondaryTable' "$SRC" --include='*.java' 2>/dev/null | exclude
    ;;
  # 識別子の抽出（G-IDENT 用。GP-20 ルール5 / FB-11）
  # 出力を 01-code-graph/identifiers/<種別>.txt に保存する（1 行 1 識別子）。
  # 「ノード数の一致」では実装できるかを検査できない（257 表のうち 90 表が物理表名で
  # specs/ に一度も登場していなかった実例がある）。
  idents-table)
    # JPA 管理（@Table）＋ 管理外（マイグレーション定義のみ）の両系統を結合する
    { grep -rhoE '@Table\(name *= *"[^"]+"' "$SRC" --include='*.java' 2>/dev/null \
        | sed 's/.*"\([^"]*\)".*/\1/'
      grep -rhoE '<createTable[^>]*tableName="[^"]+"' "$SRC" --include='*.xml' 2>/dev/null \
        | sed 's/.*tableName="\([^"]*\)".*/\1/'
    } | sed '/^$/d' | sort -u
    ;;
  idents-endpoint)
    grep -rhoE '^@Path\("[^"]*"' "$SRC" --include='*.java' 2>/dev/null \
      | sed 's/^@Path("\(.*\)"/\1/' | sed '/^$/d' | sort -u
    ;;
  idents-entity)
    grep -rlE '^@Entity' "$SRC" --include='*.java' 2>/dev/null | exclude \
      | tr '\n' '\0' | xargs -0 -r -n1 basename 2>/dev/null | sed 's/\.java$//' | sort -u
    ;;
  *)
    echo "Usage: $0 {ep|bnd|mod|list-ep|list-bnd|extra-tables|idents-table|idents-endpoint|idents-entity} <source-path>" >&2
    exit 2
    ;;
esac
