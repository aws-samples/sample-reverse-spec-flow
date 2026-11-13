# ドメイン知見（`DP-java-jaxrs-jpa-N`）

Java のアノテーション宣言型スタック（JAX-RS/Spring MVC ＋ JPA ＋ 宣言的マイグレーション）に固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。

<!--
【ID 規約】`DP-java-jaxrs-jpa-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-java-jaxrs-jpa-1 | 宣言的マイグレーションの「定義の集合」は実行時のテーブル集合ではない | createTable を数えても drop/rename と到達可能性で最終状態は変わる |
| DP-java-jaxrs-jpa-2 | ルーティング宣言は 1 方式では確定しない（JAX-RS と Spring MVC の併存） | @Path だけを分母にすると別方式の EP が無音で落ちる |

---

## DP-java-jaxrs-jpa-1: 宣言的マイグレーションの「定義の集合」は実行時のテーブル集合ではない

### 目的
Liquibase/Flyway 等の changelog は**追記型の変更履歴**であり、そこに現れる `createTable` の集合は
「現在存在するテーブルの集合」ではない。数えたものを分母にすると、実在しないテーブルを仕様化し、
逆に改名後の実体を落とす。

### ルール
1. **同一対象への削除・改名・変更定義まで追う。** `<createTable>` だけでなく `<dropTable>` /
   `<renameTable>` / `<addColumn>` を同じ対象名で突合し、**最終状態**を求める。
2. **到達可能性を確認する。** どの changelog からも `include` されない定義ファイルは実行されないため
   分母外である（実測: `tenant/upgrades/` は参照ゼロ）。
   `grep -rn '<include file=' <src> --include='*.xml'` で参照グラフを辿る。
3. **適用順序を確認する。** 同じテーブルへの定義が複数ある場合、順序で最終形が決まる。
4. **JPA 側（`@Table`）と DDL 側の両方向の差集合を取る**（SB-2（両方向の差集合））。差は必ず全件分類する:
   JPA 管理外テーブル（ログ・キャッシュ等）／宣言のみで未使用／改名後の旧名。
5. **行番号を引用するときは注意する。** 初期定義と後続変更が離れたファイルにあるため、
   `path:line` が壊れやすい（実測: data カテゴリの誤り率 41.7% の主因）。
   **テーブル名で引用し、行番号は定義箇所を指す**（変更履歴の途中を指さない）。

### チェック方法
```bash
# 1. createTable の一覧
grep -rhoE '<createTable[^>]*tableName="[^"]+"' <src> --include='*.xml' | sed 's/.*tableName="//;s/"//' | sort -u > /tmp/ddl.txt
# 2. dropTable / renameTable の一覧（最終状態から引く）
grep -rhoE '<(drop|rename)Table[^>]*(old)?[tT]ableName="[^"]+"' <src> --include='*.xml' | sort -u
# 3. @Table との両方向差集合
grep -rhoE '@Table\(name *= *"[^"]+"' <src> --include='*.java' | sed 's/.*"\(.*\)"/\1/' | sort -u > /tmp/jpa.txt
comm -23 /tmp/ddl.txt /tmp/jpa.txt   # DDL のみ（JPA 管理外）
comm -13 /tmp/ddl.txt /tmp/jpa.txt   # JPA のみ（DDL に無い＝別経路で作られる）
```

### アンチパターン
- `<createTable>` の件数をそのままテーブル数として仕様に書く。
- 到達不能な定義ファイルを「ファイルがあるから対象」と分母に含める。
- 差分を「だいたい合っている」で閉じる（1 件でも説明できなければ列挙が不完全）。

---

## DP-java-jaxrs-jpa-2: ルーティング宣言は 1 方式では確定しない（JAX-RS と Spring MVC の併存）

### 目的
同一リポジトリに JAX-RS（`@Path`）と Spring MVC（`@RequestMapping`）が併存する。
片方だけを独立ソースにすると、もう片方の EP が**無音で分母から落ちる**（列挙漏れは
`not_accounted_for=0` の偽の安心を生む＝FB-1 と同型）。

### ルール
1. **両方式を同時に走査する**（`^@(Path|RequestMapping)`）。宣言位置は行頭に固定する（SB-2（宣言位置まで固定する））。
2. **別アダプタを別途探す。** REST 以外に Batch API・CLI（`main()`）・メッセージングリスナ・
   スケジュールタスクが EP になりうる。「REST の分母 = 全 EP の分母」と早合点しない。
3. **1 つ見つけたら他も探す。** 同一機能の別バージョン API（v1/v2、`/api` と別プレフィクス）は
   別ディレクトリに置かれることが多く、狙い撃ちでは落ちる。
4. **除外は理由付きで記録する。** テスト用コントローラ・サンプルモジュールを除外するなら
   ADR で「対象外」と確定する（暗黙の対象外にしない）。

### 実例
実測（Fineract 1.15.0）: クラスレベル `@Path` = **169**、`@RequestMapping` = **1**
（`DummyApiController`、テスト用サンプルモジュール）。合計 **170**。
`@Path` のみを分母にした場合、この 1 件は列挙されず、しかも
「全 `@Path` 数 = 仕様化済み + 対象外」の等式は**成立してしまう**（分母自体が誤っているため）。

### チェック方法
```bash
grep -rlE '^@(Path|RequestMapping)' <src> --include='*.java' | grep -v '/build/' | grep -v '/src/test/' | wc -l
grep -rl '@JmsListener\|@Scheduled\|implements CommandLineRunner' <src> --include='*.java' | grep -v '/src/test/'
grep -rlE 'public static void main\(' <src> --include='*.java' | grep -v '/src/test/'
```

### アンチパターン
- `@Path` だけを走査して「全 EP を列挙した」と記録する。
- 除外した EP を分母から静かに落とす（ADR なし）。

<!-- ENTRIES END -->
