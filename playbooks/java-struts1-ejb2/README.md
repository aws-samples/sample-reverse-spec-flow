# Playbook: `java-struts1-ejb2`

Struts 1.x（`struts-config.xml` ＋ JSP）と EJB 2.x（`ejb-jar.xml` の Session / Entity（CMP・BMP）/ Message-Driven Bean）の
J2EE 業務アプリを対象とする Playbook。**Struts 1 だけのアプリ・EJB 2.x だけのアプリにも使える**（無い側の行は 0 件として扱う）。
実測検証: xPetstore 3.1（Struts 1 ＋ EJB 2.0 CMP。記述子はすべて XDoclet で生成）・Apache Struts 1.3.10 のサンプル
（MailReader・examples。ワイルドカード・extends・モジュール・DispatchAction）・Java Pet Store 1.3.2（手書きの `ejb-jar.xml` 18 本。Web 層は独自の MVC）（2026-10-25）。

## 対象スタック

- **言語/実行基盤**: Java（1.3〜1.5 世代）/ J2EE 1.3〜1.4 のアプリケーションサーバ（WebLogic・WebSphere・JBoss・OC4J・Sun の RI 等）。ビルドは Ant（`build.xml`）か Maven
- **エントリポイント**: `struts-config*.xml` の `<action>`（XML か XDoclet の `@struts.action`）、`web.xml` の servlet / filter、Message-Driven Bean、`TimedObject`
- **業務層**: Session Bean（Stateless / Stateful）。Home / Remote / Local のインタフェースと、`ejb-jar.xml` のトランザクション属性・権限
- **永続化**: CMP の Entity Bean（ベンダの記述子・XDoclet の `table-name` で表に対応）、BMP・DAO の JDBC（Java の文字列の SQL）、XML に置いた SQL
- **画面**: JSP ＋ Struts のタグライブラリ（`html:form` / `html:link` 等）、Tiles、Validator（`validation.xml`）

## 適用判定（この Playbook を選ぶべきか）

```bash
grep -rlE '<struts-config[ >]' <source> --include='*.xml' | head            # Struts 1 の設定ファイル（名前は自由なのでルート要素で見る）
grep -rlE '@(struts|ejb)[.:](action|bean)' <source> --include='*.java' | head    # XDoclet で記述子を生成する形（記述子がソースに無い）
grep -rlE '<ejb-jar[ >]' <source> --include='*.xml' | head                   # EJB 2.x の配備記述子
grep -rlE '<struts[ >]' <source> --include='struts*.xml' | head              # Struts 2（あれば非該当）
```

- ✅ **該当**: 上の 3 つのどれかが 1 件以上で、4 つ目（Struts 2 の `<struts>`）が 0 件
- ❌ **非該当**:
  - Struts 2（`struts.xml` のルートが `<struts>`）→ **`java-struts-ormxml`**
  - JAX-RS / Spring MVC のアノテーション（`@Path` / `@RequestMapping`）・JPA（`@Entity` / `@Table`）→ **`java-jaxrs-jpa`**
  - EJB 3.x（`@Stateless` / `@Entity` のアノテーションだけで記述子が無い）→ **未対応**（入口と永続化の数え方が違う）
  - WebWork / 独自のフロントコントローラだけで Struts も EJB も無い → **未対応**（`ep-diff` の「Struts 以外のフロントコントローラ」に出るものを `enumeration.md` に行を足して数える）

> **`struts*.xml` というファイル名で Struts 2 と判定しない**: Struts 1 の `struts-config.xml` も `struts*.xml` に一致する。
> **ルート要素**（`<struts-config>` か `<struts>`）で見分ける。

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴（実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-java-struts1-ejb2-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（action の流れ・遷移・フォームと検証・EJB のトランザクションと権限・CMP の対応） | `../specs/_appendix-java-struts1-ejb2.md` |
| `gate-snippets.sh` | 列挙コマンド（`ep`/`bnd`/`mod`、`*-diff` の 2 経路突合、`list-ejb`/`ejb-diff`/`list-tx`、`list-forwards`/`list-forms`/`list-validation`/`list-dispatch`/`list-refs`/`list-crud`/`scope`、`idents-*`） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh` は bash ＋ awk / grep / sed / find / xargs / sort / comm / join のみで動く（追加のツールを要求しない）。
XML は自前の字句解析で読む（属性・子要素が複数行に分かれる・注釈の中の宣言・CDATA・単一引用符・属性値の `>`・名前空間の接頭辞・BOM・UTF-16 を扱う）。
DOCTYPE の内部サブセットと外部実体（`&extra;` で取り込む設定）は読まない。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **生成物と XDoclet（Phase 0）。** XDoclet のアプリは `struts-config.xml` / `ejb-jar.xml` / `web.xml` がソースに無く、ビルドの出力（`build/` 等）にだけある。
  既定では `build/` `target/` `dist/` `classes/` `bin/` `out/` を外し（最初の `/src/` `/java/` より前の部分にだけ当てる）、**ソースの XDoclet のタグ**を数える（`GEN_EXCLUDE`）。生成した XML をソースに置いている場合は
  `ep-diff` の「XML と XDoclet の両方で宣言された path」に出るので、片方を外す。
- **アプリの境界。** 1 つのリポジトリに複数のアプリ（EAR）があると、同じ完全修飾名のクラスが重なって派生の判定が潰れる
  （`ep-diff` / `ejb-diff` の最後の節に出る）。アプリごとに `SCAN_EXCLUDE` で分けて走査する。
- **Struts 以外のフロントコントローラ。** 拡張子・前方一致の `servlet-mapping`（`*.do` を独自のサーブレットが受ける等）は、画面の URL が別の対応表にある
  （実測 Pet Store 1.3.2: WAF の `mappings.xml`）。`enumeration.md` に行を足して数える。
- **テストコード・同梱ライブラリ。** `test/` の Servlet・EJB は入口に数えられる。分母から外すなら `SCAN_EXCLUDE` に書き、ADR で処分する。
- **スキーマの所在。** CMP の表は配備時にサーバが作ることが多く（JBoss の `create-table` 等）、ソースに `CREATE TABLE` が無い。`bnd-diff` が知らせる。
