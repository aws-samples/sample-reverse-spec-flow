# ドメイン知見（`DP-java-struts1-ejb2-N`）

Struts 1.x（`struts-config.xml` ＋ JSP）と EJB 2.x（Session・Entity（CMP / BMP）・Message-Driven Bean）の J2EE 業務アプリに固有の知見。
汎用知見（言語・スタックを問わないもの）はフレームワーク正本の `pipeline.md`（GP-N）/ `playbook.md`（SB-N）に属する。
実測値は xPetstore 3.1・Apache Struts 1.3.10 のサンプル（MailReader・examples）・Java Pet Store 1.3.2。

<!--
【ID 規約】`DP-java-struts1-ejb2-N`。ドメイン名を含めて構成上一意にする（GP-9 の永続 ID 原則）。
【追記ルール】末尾の `<!-- ENTRIES END -->` の直前に挿入。連番・番号の再利用禁止。
節構成: `### 目的` / `### ルール` / `### チェック方法` / `### アンチパターン`（任意で `### 実例`）。
サマリ表に行を追加する。汎用化できる知見はフレームワークへ還元する（dev/backport-procedure.md）。
-->

## サマリ

| ID | タイトル | 一言 |
|----|---------|------|
| DP-java-struts1-ejb2-1 | 記述子の正本を先に決める（XML か XDoclet のタグか）。生成物を数えない | XDoclet のアプリは struts-config.xml も ejb-jar.xml もソースに無い |
| DP-java-struts1-ejb2-2 | action は「解いた後の宣言」で数え、ワイルドカード・extends・重複・DispatchAction を別に書く | 宣言の数・URL の数・クラスの数・操作の数はどれも一致しない |
| DP-java-struts1-ejb2-3 | EJB は ejb-class と ejb-jar の組で数え、Session Bean を modules の単位にする | 同じ Entity Bean を複数の ejb-jar に重ねて宣言する構成がある |
| DP-java-struts1-ejb2-4 | 表は CMP の対応・SQL・DDL の 3 か所から取り、EJB-QL の名前を表と読まない | CMP の表は記述子にしか無く、DDL は配備時に作られることが多い |
| DP-java-struts1-ejb2-5 | トランザクション属性・権限・JNDI 名は記述子から仕様に写す | 業務ルールの一部がコードでなく配備記述子にある |

---

## DP-java-struts1-ejb2-1: 記述子の正本を先に決める（XML か XDoclet のタグか）。生成物を数えない

### 目的
J2EE 1.3〜1.4 世代のアプリは、配備記述子（`struts-config.xml` / `ejb-jar.xml` / `web.xml` / ベンダの記述子）を手で書くか、
**XDoclet で Java の javadoc のタグから生成する**かのどちらかで、生成する場合は**記述子がソースに無い**。
どちらを正本にするかを Phase 0 で決めないと、分母が 0 件か 2 倍になる。

### ルール
1. **ソースに記述子があるか、XDoclet のタグ（`@struts.action` / `@ejb.bean` / `@web.servlet`）があるかを先に数える**（README の適用判定）。
2. **XDoclet のアプリはタグを正本にする。** `gate-snippets.sh` はタグを読み、XDoclet の**マージ用の断片**（`mergedir` の `filter-mappings.xml` 等）も読む。
   ビルドの `fileset` が対象を絞ることがある（実測 xPetstore: `webdoclet` は名前が `*Action.java` / `*Form.java` / `*Tag.java` / `*Servlet.java` / `*Filter.java` のファイルだけを読む）
   ——タグがあっても名前が合わないクラスは記述子に入らない。`build.xml` の `fileset` を確かめ、外れるクラスは死蔵として書く。
3. **生成物は数えない。** 既定で `build/` `target/` `dist/` `classes/` `bin/` `out/` を外す（`GEN_EXCLUDE`）。生成した XML をソースに置いた構成は、
   `ep-diff` の「XML と XDoclet の両方で宣言された path」に出る。片方を `SCAN_EXCLUDE` で外し、ADR に書く。
4. **引用は正本の行に置く**（タグの行。生成した XML の行は再生成で動く）。

### 実例
- xPetstore 3.1: `struts-config.xml` 0 件・`ejb-jar.xml` 0 件・`@struts.action` 17・`@ejb.bean` 13。記述子は `build.xml` の `ejbdoclet` / `webdoclet` が作る。
- Pet Store 1.3.2: XDoclet を使わず、`ejb-jar.xml` 18 本を手書きする。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh scope <src>       # 生成物の置き場（GEN_EXCLUDE で外れるディレクトリ）を見る
bash 03-audit/gate-snippets.sh ep-diff <src>     # 最後の節に XML と XDoclet の重複・同じ完全修飾名のクラス
```

### アンチパターン
- `find -name struts-config.xml` が 0 件だったので「Struts の画面は無い」と書く（XDoclet のタグにある）。
- `build/` の生成物を含めて数え、宣言を 2 倍にする。

---

## DP-java-struts1-ejb2-2: action は「解いた後の宣言」で数え、ワイルドカード・extends・重複・DispatchAction を別に書く

### 目的
Struts 1 の `<action>` の数は、URL の数とも、Action クラスの数とも、操作の数とも一致しない。
1.3 の `extends` は type と parameter を受け継ぎ、ワイルドカード（`/Save*`）は宣言 1 つで複数の URL を受け、
DispatchAction は宣言 1 つが `parameter` の値で複数のメソッドに分かれる。

### ルール
1. **経路A（宣言が指すクラス）と経路B（Java 側の Action の派生クラス）を突き合わせる**（`ep-diff`）。基底の判定は **import で確かめる**
   （WebWork / XWork にも `Action` / `ActionServlet` がある）。
2. **宣言の種類を分けて書く**:
   | 種類 | 典型 | 書き方 |
   |---|---|---|
   | type を持たない宣言 | `forward="/x.jsp"`・`include=` | 画面を返すだけの入口として画面一覧に載せる（Action クラスは無い） |
   | ワイルドカード | `path="/Edit*"`・`type="...{1}Action"` | 宣言 1 つとして数え、候補のクラス（`ep-diff`）と JSP のリンク（`list-refs`）から実際の URL を書く |
   | 土台 | `path="//BaseAction"`（extends で使う） | 入口に数えない |
   | 重複 | 同じモジュールに同じ path が 2 つ | 後の宣言が勝つ。前の宣言の type は要求を受けない（死蔵として書く） |
   | DispatchAction 系 | `parameter="method"` | 操作（メソッド）を `list-dispatch` で全数書く |
3. **モジュールの接頭辞を付ける。** `web.xml` の ActionServlet の `config/xxx` が `/xxx` のモジュールを作る。値はカンマ区切りで複数の設定ファイルを持てる。
4. **Struts 同梱の Action**（`org.apache.struts.actions.ForwardAction` 等）は経路A のみに出る。ソースが無いのは正しい。

### 実例
- MailReader: 宣言 13 → 入口 11（土台 1・上書きされた `/Welcome` 1 を除く）。ワイルドカード 4（`/*` `/Delete*` `/Edit*` `/Save*`）。
  `RegistrationAction` は `{1}Action` の候補としてだけ指され、`WelcomeAction` は上書きされた宣言の type だった。
- examples: 5 モジュール（既定・`/exercise`・`/upload`・`/validator`（設定ファイル 5 本）・`/dispatch`）で入口 100。DispatchAction 系 4 クラス × 2 操作。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-ep <src>
bash 03-audit/gate-snippets.sh ep-diff <src>
bash 03-audit/gate-snippets.sh list-dispatch <src>
```

### アンチパターン
- `grep -c '<action '` で数える（`<action` の後で改行する書き方を落とす。実測 MailReader: 1 件 / 正しくは 13）。
- 注釈の中の `<action>` を数える（実測 examples: 素朴な数え方で 101 / 正しくは 100）。
- DispatchAction の宣言を 1 画面 1 操作として仕様にする。

---

## DP-java-struts1-ejb2-3: EJB は ejb-class と ejb-jar の組で数え、Session Bean を modules の単位にする

### 目的
`ejb-name` は ejb-jar ごとの名前で、アプリ全体で一意ではない。CMR（コンテナ管理の関連）は同じ ejb-jar の中でしか張れないので、
**依存する Entity Bean を使う側の ejb-jar ごとに重ねて宣言する**構成がある。宣言の数で数えると Bean が増え、名前で数えると配備の実体が減る。

### ルール
1. **経路A（宣言の ejb-class）と経路B（SessionBean / EntityBean / MessageDrivenBean の実装クラス）を突き合わせる**（`ejb-diff`）。
   実装は継承を辿って判定する（基底の Bean クラスを継承するだけで `implements` を書かないクラスがある）。
2. **重ねて宣言された Bean**は `ejb-diff` の「複数の ejb-jar で宣言された ejb-class」に出る。仕様は ejb-class で 1 つに書き、配備先の ejb-jar を列挙する。
3. **Session Bean を modules の単位にする。** remote のビューを持つ Session Bean は別のアプリ・クライアントからの入口でもある（呼び出し元を書く）。
4. **MDB は入口（NODE-EP）に数える**（`list-ep` の `mdb`）。宛先（キュー / トピック）とメッセージの形を書く。

### 実例
- Pet Store 1.3.2: 宣言 43 / ejb-class 32 / 実装 32（差 0）。`AddressEJB` は 5 つの ejb-jar に、`ContactInfoEJB` は 4 つに出る。
  `ShoppingControllerEJB` は `EJBControllerLocalEJB` を継承するだけで `SessionBean` を書かない（素朴な `implements` の grep では 31 になる）。
- xPetstore: `@ejb.bean` 13 = 実装 13（CMP 8・Stateful 1・Stateless 2・MDB 2）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-ejb <src>
bash 03-audit/gate-snippets.sh ejb-diff <src>
```

### アンチパターン
- `grep -c '<session>'` 等で Bean を数える（重ねた宣言を別の Bean と数える）。
- Home / Remote のインタフェースを Bean と別のモジュールとして仕様にする（Bean 1 つに束ねて書く）。

---

## DP-java-struts1-ejb2-4: 表は CMP の対応・SQL・DDL の 3 か所から取り、EJB-QL の名前を表と読まない

### 目的
CMP の Entity Bean は SQL を書かないので、表の名前は**ベンダの記述子**（`jbosscmp-jdbc.xml` の `table-name`・`weblogic-cmp-rdbms-jar.xml`・
RI の `sun-j2ee-ri.xml` の SQL）か **XDoclet の `table-name`** にしかない。BMP・DAO は Java の文字列を連結して SQL を組む。
EJB-QL（`SELECT OBJECT(a) FROM Inventory a`）の `Inventory` は**抽象スキーマ名**で、表ではない。

### ルール
1. **経路A（参照側）= CMP の対応 ＋ SQL の DML、経路B（定義側）= `CREATE TABLE`** で突き合わせる（`bnd-diff`）。
2. **定義側が 0 件のとき**（配備時にサーバが表を作る・別リポジトリに DDL がある）は、経路B を単一経路として理由を書く。
3. **EJB-QL は表に数えない**（`gate-snippets.sh` は `ejb-ql` の要素・`OBJECT(` を含む文字列を読まない）。finder は data の「EJB-QL の finder」の節に書く。
4. **Java の SQL は連結を解いて読む**（`"select a " + "from (t1 a join t2 b ...)"`）。括弧で始まる FROM（結合を括弧で囲む書き方）も表を取る。

### 実例
- Pet Store 1.3.2: 参照側 21 / 定義側 21（差 0）。CMP の 15 表は RI の SQL、カタログの 6 表は DAO（Java の文字列と `CatalogDAOSQL.xml`）。
  EJB-QL の finder 6 本は抽象スキーマ名で書かれる。
- xPetstore: 参照側 8（XDoclet の `table-name` 8・`data.sql` の INSERT・DAO の SQL）/ 定義側 0（JBoss の `create-table` が配備時に作る）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh bnd-diff <src>
bash 03-audit/gate-snippets.sh list-crud <src>
```

### アンチパターン
- `grep -i 'from '` の語を表に数える（EJB-QL の抽象スキーマ名・文言の英単語が混ざる）。
- CMP の Entity Bean のクラス名を表名として仕様に書く（`CustomerEJB` の表は `CustomerEJBTable` 等、記述子で決まる）。

---

## DP-java-struts1-ejb2-5: トランザクション属性・権限・JNDI 名は記述子から仕様に写す

### 目的
EJB 2.x では、**トランザクションの境界**（`container-transaction` の `trans-attribute`）・**メソッドの権限**（`method-permission`）・
**JNDI 名と Bean の対応**（ベンダの記述子）がコードでなく記述子にある。コードだけを読むと、どの操作が 1 トランザクションか・誰が呼べるかが書けない。

### ルール
1. **`list-tx` でメソッドごとの属性と役割を出し、modules の「トランザクションと権限」の節に写す。** `method-name` の `*` は Bean の全メソッドに展開して書く。
2. **XDoclet のアプリ**は `@ejb.transaction` / `@ejb.permission` がクラスかメソッドに付く（クラスに付いたものはメソッドの既定値）。
3. **JNDI 名**は `ejb-ref` / `ejb-local-ref`（呼び出し側）とベンダの記述子（配備側）の両方を見て、呼び出し関係（コードグラフのエッジ）にする。
4. **記述子に無い設定**（分離レベル・データソース・役割の割り当て）は、配備の設定として UNKNOWN に起票する（推測で書かない。SB-4）。

### チェック方法
```bash
bash 03-audit/gate-snippets.sh list-tx <src>
grep -rnE '<(ejb-ref|ejb-local-ref)>' <src> --include='*.xml'   # 呼び出し側の参照
```

### アンチパターン
- トランザクション属性を書かずに「更新は 1 トランザクションで行う」と推測で書く。
- `Required` と `RequiresNew` を区別せずに書く（失敗時に何が巻き戻るかが逆になる）。

---

<!-- ENTRIES END -->
