# Playbook: `java-jaxrs-jpa`

Java のアノテーション宣言型スタック（JAX-RS / Spring MVC ＋ JPA アノテーション ＋ 宣言的 DB マイグレーション）を
対象とする Playbook。実測検証: Apache Fineract 1.15.0（2026-08-10）。

## 対象スタック

- **言語/実行基盤**: Java 11 以降 / Jakarta EE または Spring Boot
- **エントリポイント**: JAX-RS（`@Path`）または Spring MVC（`@RequestMapping`）。**両者が併存しうる**
- **永続化**: JPA アノテーション方式（`@Entity` / `@Table` / `@JoinTable`）
- **スキーマ**: 宣言的マイグレーション（Liquibase / Flyway 等の changelog）

## 適用判定（この Playbook を選ぶべきか）

```bash
grep -rlE '^@Path|^@RequestMapping' <source> --include='*.java' | head
```

- ✅ **該当**: 上記が 1 件以上ヒットする（アノテーションでルーティングを宣言している）
- ❌ **非該当**: 0 件で、代わりに `struts*.xml` / `*.orm.xml` がある
  → **`java-struts-ormxml` Playbook を使う**（同じ Java でも独立ソースが全く違う）。
  ルートが `<struts-config>` の Struts 1、または `ejb-jar.xml` の EJB 2.x なら **`java-struts1-ejb2`**

> **同じ「Java」で Playbook が分かれる理由**: 実測で、Roller は `@Path` も `@Table` も **0 件**だった。
> アノテーションを独立ソースにする手順はこのスタックでのみ成立する。
> 「言語が同じ」は「分母の数え方が同じ」を意味しない（GP-105 の設計根拠）。

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴 7 件（すべて実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-java-jaxrs-jpa-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（宣言的マイグレーション・権限モデル等） | `../specs/_appendix-java-jaxrs-jpa.md` |
| `gate-snippets.sh` | `gates.sh` から呼ぶ列挙コマンド（`ep`/`bnd`/`mod`/`extra-tables`） | `03-audit/gate-snippets.sh` |

## 利用者が明示的に判断すべき項目（このスタック固有）

- **マルチテナント構成の場合、テナント管理 DB を分母に含めるか。**
  実測（Fineract）: テナントレジストリの 4 テーブルは JPA 管理外で `@Table` 走査に入らなかった。
  含めないなら ADR で「対象外」と確定する（暗黙の対象外にしない）。
- **`@JoinTable` の中間表を独立したデータ仕様にするか。**
  実測: 中間表 2 件が分母から漏れていた。仕様化しないなら理由を ADR に残す。
- **到達不能なマイグレーション定義ファイルの扱い。**
  実測: どの changelog からも include されないディレクトリが存在した（分母外が正しい）。
  「ファイルがあるから対象」と機械的に含めない。
- **自動生成される API クライアント・DTO を分母に含めるか**（含めない場合は生成元を仕様化対象にする）。
