# 列挙の独立ソース表（java-struts1-ejb2 / GP-105）

<!--
Playbook が提供する「分母の定義」。init.sh が `spec-extraction/01-code-graph/enumeration.md` へ配置する。
汎用手順書（pipeline-procedure）は「この表に従う」と抽象で書き、具体はここに置く。
下記のコマンドと件数はすべて OSS 3 件で実測検証済み（2026-10-25）:
  xPetstore 3.1（Struts 1 ＋ EJB 2.0 CMP。struts-config.xml / ejb-jar.xml / web.xml はソースに無く、XDoclet のタグから生成する）
  Apache Struts 1.3.10 のサンプル（MailReader: ワイルドカード・extends・重複した path。examples: 5 モジュール・DispatchAction 系 4 種）
  Java Pet Store 1.3.2（手書きの ejb-jar.xml 18 本・CMP 2.0 と CMR・MDB 8・Sun の RI の記述子。Web 層は Struts でなく独自の MVC）
走査コマンドの実体は `03-audit/gate-snippets.sh`（この表の「全走査コマンド」はそのサブコマンド名）。
-->

- **対象スタック**: Struts 1.x（`struts-config.xml` ＋ JSP）と EJB 2.x（Session・Entity（CMP / BMP）・Message-Driven Bean）の J2EE アプリ。
  記述子は手書きの XML か、XDoclet の javadoc のタグから生成する。片方だけ（Struts 1 だけ・EJB だけ）のアプリにも使う。
- **適用判定**: 次のどれかが 1 件以上で、Struts 2 の `<struts>` が 0 件。
  `grep -rlE '<struts-config[ >]' <src> --include='*.xml' | head` ／
  `grep -rlE '@(struts|ejb)[.:](action|bean)' <src> --include='*.java' | head` ／
  `grep -rlE '<ejb-jar[ >]' <src> --include='*.xml' | head`

## 走査の前提（全コマンド共通。破ると件数が黙って狂う）

1. **生成物を外す（`GEN_EXCLUDE`）。** 既定で `build/` `target/` `dist/` `classes/` `bin/` `out/` を外す。XDoclet の出力をソースと一緒に数えると宣言が 2 倍になる（落とし穴 1）。
   **パスの最初の `/src/` か `/java/` より前の部分にだけ当てる**ので、Java のパッケージ名の `out` / `dist`（`com/acme/out/X.java`）は外れない。外れたファイルの数は `scope` の 5 列目に出る。
2. **アプリの境界を先に決める（Phase 0）。** 1 つのリポジトリに複数のアプリ（EAR）や別のフレームワークの版があると、同じ完全修飾名のクラスが重なる。
   `scope` でディレクトリを見て、アプリごとに `00-ingestion/gate-config.env` の `SCAN_EXCLUDE` で分ける（落とし穴 6）。テストコードを外すかもここで決める。
3. **バイト列で走査する（`LC_ALL=C`）。** 日本の旧資産は Shift_JIS / EUC-JP が多い。`gate-snippets.sh` は先頭で `LC_ALL=C` を固定し、BOM を外し、UTF-16 は NUL を落として読む。
4. **パスは解析対象からの相対（`./` 始まり）で出る。** そのまま `path:line` の引用に使える。

## 独立ソース表（ノード種別ごとの分母）

<!--
「独立ソース」= 仕様化作業とは独立に、コードから機械的に全数を数えられる情報源。
表内のコマンドは `bash 03-audit/gate-snippets.sh <サブコマンド> <解析対象パス>` の形で実行する。
-->

| ノード種別 | 独立ソース（分母） | 全走査コマンド | 突合の等式 |
|-----------|-----------------|--------------|-----------|
| NODE-MOD | 配備単位のビルド定義（Ant の `<project>` で jar / war / ear / javac / ejbdoclet / webdoclet を使うもの・Maven の `pom.xml`） | `mod` / 一覧 `list-mod` / 突合 `mod-diff`（配備記述子の持ち主と両方向） | ビルド単位のディレクトリ数 = MOD ノード数。共通ライブラリ・まとめ役のビルドの差は全件説明する |
| NODE-EP（画面・入口） | `struts-config*.xml` の `<action>`（モジュールの接頭辞つき）・XDoclet の `@struts.action`・`web.xml` の servlet-mapping（ActionServlet 以外）と filter-mapping・XDoclet の `@web.*-mapping`・Message-Driven Bean・`TimedObject` | `ep` / 一覧 `list-ep` / 突合 `ep-diff`（宣言が指すクラスと Java 側の派生クラスを両方向） | 入口数 = EP ノード数（土台の宣言・上書きされた重複は除く。ワイルドカードは宣言 1 つ） |
| NODE-BND（DB 表） | 参照側: CMP の対応（ベンダの記述子の `table-name`・XDoclet の `table-name`・RI の SQL）＋ Java の文字列・XML のテキスト・SQL ファイルの DML ／ 定義側: `CREATE TABLE` | `bnd` / 一覧 `list-bnd` / 定義側 `bnd-schema` / 突合 `bnd-diff` / CRUD `list-crud` | 参照表数 = BND 表ノード数。定義側との差は全件説明する（一時表は除く） |
| （業務層）EJB | `ejb-jar.xml` の session / entity / message-driven ＋ XDoclet の `@ejb.bean` | 一覧 `list-ejb` / 突合 `ejb-diff`（宣言の ejb-class と Bean の実装クラスを両方向） | 宣言の ejb-class 数 = 実装クラス数。重ねた宣言は ejb-class で 1 つに束ねる |
| （業務層）トランザクションと権限 | `container-transaction` / `method-permission`・XDoclet の `@ejb.transaction` / `@ejb.permission` | `list-tx` | modules 仕様の「トランザクションと権限」の分母 |
| （画面の子）フォームと検証 | `form-bean`（`form-property`）・XDoclet の `@struts.form`・`validation.xml` の `field` | `list-forms` / `list-validation` | 画面仕様の入力の分母 |
| （画面の子）操作 | DispatchAction 系の派生クラスの、要求を受ける public メソッド | `list-dispatch` | 画面仕様の操作の分母（EP ノードではない） |
| （エッジ）遷移 | action の `<forward>`・`global-forwards`・`input`・`forward` 属性・XDoclet の `@struts.action-forward`、JSP の `html:form` / `html:link` 等と `.do` のリンク | `list-forwards` / `list-refs` | 画面遷移の分母 |

## 目印の系統（1 目印で数え切れるかの判定。GP-2 ルール8 / FB-9）

<!--
系統は**役割を表す型**で括る（登録手段は同一系統内の 1 経路にすぎない）。
下表は xPetstore / Struts 1.3.10 のサンプル / Pet Store 1.3.2 の実測に基づく。系統が 1 つに見えても根拠欄は必ず埋める。
-->

| ノード種別 | 目印の系統（役割で括る。複数あれば全部列挙） | 単一系統である根拠 / 系統間の重複の扱い |
|-----------|------------------------------------|--------------------------------|
| NODE-EP | ① 画面の要求を受ける型: Struts の action（XML の `<action>` か XDoclet の `@struts.action`。type を持たない forward だけの宣言を含む）② Struts を通らない要求を受ける型: servlet / filter（XML か `@web.*`）③ 非同期の入口: Message-Driven Bean ④ 時刻で起動する入口: `TimedObject` | **4 系統。単一ではない。** ①は XML と XDoclet の 2 つの書き方があり、**片方しか見ないとアプリによって 0 件になる**（実測 xPetstore: XML 0・タグ 17）。①の基底の判定は **import で確かめる**——名前だけで見ると WebWork の `Action` が混ざる（実測 xPetstore の servlet 版）。②の拡張子の mapping（`*.do`）は独自のフロントコントローラのことがあり、その画面は別の対応表にある（実測 Pet Store: WAF の `mappings.xml`）。重複はアプリ・種類・キー・type で取る |
| NODE-BND | ① CMP の対応: ベンダの記述子の `table-name`・XDoclet の `table-name`・RI の SQL ② コードの SQL: BMP・DAO の Java の文字列（連結を解く）③ XML に置いた SQL（DAO の SQL 置き場）④ SQL ファイル（DML）⑤ スキーマ: `CREATE TABLE`（SQL ファイル・XML・Java の文字列） | **5 系統。単一ではない。** ①だけを見ると DAO の表を落とし（実測 Pet Store: カタログの 6 表は DAO にだけある）、②だけを見ると CMP の表が 0 件に見える（CMP は SQL を書かない）。EJB-QL の名前は抽象スキーマ名で、どの系統にも入れない。①〜④と⑤は表名（大小を区別しない）で `comm` を取り、両方向の差を全件説明する |

> **分母は 2 経路で計算して突合する。**下の「分母の 2 経路突合」表が正本（機械検査あり）。
> 実測（Pet Store 1.3.2）では EJB が「宣言 43 / ejb-class 32 / 実装 32」、表が「参照側 21 / 定義側 21」で集合まで一致した。
> **一致したのは継承を辿って Bean の実装を判定し、括弧で始まる FROM を読んだ後**で、素朴な `implements` の grep では実装が 31、
> 括弧を読まない版では DAO の表 `category` / `item` を Java 側で落としていた（落とし穴 9・13）。

## 分母の 2 経路突合（GP-2 ルール8-4 / ルール9。実数は Phase 1 で埋める）

<!--
【なぜ 2 経路か】単一経路で数えた合算値は**検算できない**。系統ごとの件数を足しただけでは、
系統の定義そのものが漏れていても気づけない。**独立に計算できる別経路**と突き合わせて初めて検算される。
【件数一致 ≠ 集合一致】ルール9。要素単位で突き合わせる（`comm -3` / `diff`）。`*-diff` サブコマンドが要素を出す。
差分が 0 件なら「0 件」と書く——空欄は「測っていない」と区別できない。
【定義は Playbook が提供・実数は解析対象ごと】下表の定義列はこのスタックの実測に基づく。
`gates.sh` の `G-ENUM-SOURCE` が定義・実数・差分の記入を検査する（`phase1` の完了条件）。
【列順の理由】**数値と差分を末尾に固めてある**。定義欄に `|` が入ると前から数えた列がずれるため、
検査は末尾から数えている。
【表の中にパイプを書かない】`\|` とエスケープしても表の解析では分割される（実測）。
とくに**差分欄にコマンドをそのまま貼らない**——**差分欄には結果（要素名の列挙）だけ**を書く。
-->

| ノード種別 | 経路A の定義 | 経路B の定義 | 経路A 実数 | 経路B 実数 | 要素差分（`comm -3` の出力。無ければ「0 件」） |
|-----------|------------|------------|----------|----------|--------------------------------|
| NODE-MOD | **ビルド単位**のディレクトリ（`mod-diff` 経路A） | **配備記述子の持ち主**: `ejb-jar.xml` / `web.xml` / `application.xml` を最も近い祖先のビルド定義に寄せたもの ＋ XDoclet で記述子を作るビルド単位（`mod-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: ディレクトリを全件（共通ライブラリの jar・クライアント・まとめ役のビルド・ビルド定義の無い記述子の別）>` |
| NODE-EP | **宣言が指すクラス**: action の type（extends を解いた後。上書きされた重複と `{N}` の type を除く）＋ MDB の ejb-class（`ep-diff` 経路A） | **Java 側の派生クラス**: Struts の Action（import で確かめる）か MessageDrivenBean の具象の派生クラス（`ep-diff` 経路B） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: クラスを全件（Struts 同梱・ワイルドカードの候補・上書きされた宣言・死蔵・XDoclet のタグ漏れの別）>` |
| NODE-BND | **DB 表・参照側**: CMP の対応 ＋ SQL の DML（`bnd-diff` 経路A） | **定義側**: `CREATE TABLE` の表名（`bnd-schema`。一時表を除く） | `<数値>` | `<数値>` | `<0 件 ／ 差分 N 件: 表名を全件（配備時に生成・別 DB・死蔵・EJB-QL の先の別）>` |

- **NODE-EP の経路A・B はクラスで突き合わせる**（入口の数 `ep` とは別の数になる）。type を持たない宣言・servlet / filter は経路の比較に入らないので、
  `ep-diff` の該当の節を読んで画面一覧に載せる。**EJB の 2 経路**（`ejb-diff`）は Session / Entity を含む全 Bean の突合で、modules の仕様の分母として別に記録する。
- **定義側（スキーマ）がソースに無い場合**（JBoss の `create-table` 等で配備時に作る・別リポジトリ）は、`NODE-BND` の経路B の定義欄を
  「単一経路（スキーマがソースに無い）」に書き換え、差分欄に理由を書く（`G-ENUM-SOURCE` が理由の記入を検査する）。
- **Struts 以外のフロントコントローラ**（`ep-diff` の節に出る拡張子・前方一致の servlet-mapping）がある場合は、その対応表（`mappings.xml` 等）の
  URL を数える行を独立ソース表に足す。

## 識別子の抽出（「実装できる粒度」の突合。GP-20 ルール5 / FB-11）

<!--
出力を `01-code-graph/identifiers/<種別>.txt`（1 行 1 識別子）に保存する。
`G-IDENT` が `specs/` 本文との差集合を自分で計算する（件数一致の自己申告では代替できない）。
このスタックは**入口・Bean・表の名前が Java のコードでなく記述子（か XDoclet のタグ）にある**ため、
「Action クラスは書いたが path は書いていない」「Bean のクラスは書いたが表は書いていない」状態が起きやすい。
-->

| 種別（ファイル名） | 仕様本文に実在すべき識別子 | 抽出コマンド |
|-----------------|----------------------|-----------|
| `endpoint` | **action の path**（モジュールの接頭辞つき。ワイルドカードは `/Save*` のまま。綴りどおり） | `bash 03-audit/gate-snippets.sh idents-endpoint <src>` |
| `ejb` | **ejb-name**（XDoclet は `@ejb.bean name=`） | `bash 03-audit/gate-snippets.sh idents-ejb <src>` |
| `table` | **物理テーブル名**（参照側 ∪ 定義側。表ごとに最初に見た綴り） | `bash 03-audit/gate-snippets.sh idents-table <src>` |

## 走査の落とし穴（このスタック固有。すべて実測で確認済み）

番号は `gate-snippets.sh` のコメントと対応する（「落とし穴 N」で検索できる）。

1. **XDoclet と生成物。** XDoclet のアプリは記述子がソースに無い（実測 xPetstore: `struts-config.xml` 0・`ejb-jar.xml` 0・`web.xml` 0、`@struts.action` 17・`@ejb.bean` 13）。
   記述子は `build.xml` の `ejbdoclet` / `webdoclet` がビルドの出力に作るので、**生成物を数えると宣言が 2 倍になる**（`GEN_EXCLUDE`）。
   `mergedir` の断片（`filter-mappings.xml` 等）は生成される `web.xml` に入るので読む。`webdoclet` の `fileset` は名前（`*Action.java` 等）で対象を絞る。
2. **XML の要素は複数行に分かれ、注釈の中にも宣言がある。** MailReader は `<action` の後で改行するので `grep -c '<action '` は **1**（正しくは 13）。
   examples の `/exercise` は注釈の中に `<action>` があり、素朴に数えると **101**（正しくは 100）。`gate-snippets.sh` は XML を字句解析して読む。
3. **モジュール。** `web.xml` の ActionServlet の `init-param` が `config/xxx` なら接頭辞 `/xxx` のモジュール。値はカンマ区切りで複数の設定ファイル
   （実測 examples: `/validator` は 5 本）。init-param が無ければ `/WEB-INF/struts-config.xml`。web.xml から参照されない設定ファイルは `ep-diff` に出る。
4. **XDoclet の属性の境界。** `type="..."` は `@ejb.bean` の Bean の種類だが、MDB の `destination-type=`・`@ejb.transaction` の `type=` にも一致する
   （実測 xPetstore: Java の `type="` の素朴な数え 161 のうち Bean の種類は 11）。`path=` も `@struts.action-forward` にある（素朴に 37 / action は 17）。
   属性名の前が英数字・`-`・`.` の位置では一致させない。
5. **extends・ワイルドカード・土台・重複・DispatchAction。** Struts 1.3 の `extends` は type と parameter を受け継ぐ（実測 MailReader: `/Delete*` の type は `//BaseAction` の
   `{1}Action`）。`//` で始まる path は extends の土台で要求を受けない。同じモジュールの同じ path は後の宣言が勝つ（実測 MailReader: `/Welcome` が 2 つ。
   前の宣言の `WelcomeAction` は要求を受けない）。DispatchAction 系は宣言 1 つが `parameter` でメソッドに分かれる（実測 examples: 4 クラス × 2 操作）。
6. **同じ名前の別物。** WebWork にも `Action` / `ActionSupport` / 独自の `ActionServlet` がある（実測 xPetstore の servlet 版: `extends Action` 20 件はすべて WebWork）。
   基底は **import か完全修飾名で Struts と確かめる**。1 つのリポジトリに 2 つの版があると同じ完全修飾名のクラスが 2 つになり（実測 xPetstore: `xpetstore.web.servlet.ActionServlet`）、
   派生の判定が 1 つに潰れる。`ep-diff` / `ejb-diff` の最後の節に出るので、アプリごとに分けて走査する。
7. **同じ Bean を複数の ejb-jar に重ねて宣言する。** CMR は同じ ejb-jar の中でしか張れない（実測 Pet Store 1.3.2: 宣言 43 / ejb-class 32。`AddressEJB` は 5 つの ejb-jar）。
   `ejb-name` の数で数えない。ejb-class で束ね、配備先を列挙する。
8. **表の名前の出どころと EJB-QL。** CMP の表はベンダの記述子（`jbosscmp-jdbc.xml` / `weblogic-cmp-rdbms-jar.xml` の `table-name`・Orion の `table=`・RI の SQL）か
   XDoclet の `table-name` にしかない。EJB-QL（`SELECT OBJECT(a) FROM Inventory a`）の名前は抽象スキーマ名で表ではない（実測 Pet Store: finder 6 本）。
   **JBoss / WebLogic の記述子の読み方は合成の入力でしか確かめていない**（実測した 3 件は RI と XDoclet だった）。
9. **Java の SQL の連結と括弧の FROM。** DAO は `"select a " + " from (category a join category_details b on ...)"` のように文字列を連結し、結合を括弧で囲む
   （実測 Pet Store の `CloudscapeCatalogDAO`）。文ごとに文字列をつなぎ、`from (` の後の表も読む。SQL の句の語で始まる文字列だけを SQL とみなす
   （`"Could not delete from database"` の `database` を表にしない）。`StringBuffer` で継ぎ足す `" from t"` は読む。
10. **文字コード。** 日本の旧資産の Shift_JIS / EUC-JP は `LC_ALL=C` でバイト列として読む（前提 3）。**実測した 3 件は ASCII / UTF-8 だった**ので、
    Shift_JIS の資産で件数が変わらないことは合成の入力でしか確かめていない。
11. **Struts 以外のフロントコントローラ。** `*.do` を独自のサーブレットが受けることがある（実測 Pet Store 1.3.2: WAF の `MainServlet`。画面の URL は
    `mappings.xml` の `url-mapping` 7 件・`requestmappings.xml` 26 件）。`ep-diff` の「Struts 以外のフロントコントローラ」に出る。
12. **スキーマがソースに無い。** CMP の表をサーバが配備時に作る（実測 xPetstore: JBoss の `create-table`。`data.sql` は INSERT だけ）。`bnd-diff` が「定義側 0 件」を知らせる。
13. **継承した Bean クラス。** 基底の Bean クラスを継承するだけで `implements SessionBean` を書かないクラスがある（実測 Pet Store: `ShoppingControllerEJB extends EJBControllerLocalEJB`。
    素朴な `implements` の grep では 31 / 正しくは 32）。宣言の `extends` / `implements` を継承を辿って判定する。複数行の宣言（`public class X\n    extends Y\n{`）も読む。
14. **javac だけのビルド。** 依存する CMP の Bean は自分で jar を作らず、使う側の ejb-jar に入る（実測 Pet Store: `lineitem` は javac と `<ant>` だけ）。
    jar / war / ear の有無だけでビルド単位を判定しない。
15. **Struts 同梱の Action。** `org.apache.struts.actions.ForwardAction` 等は経路A のみに出る（実測 examples: 1 件）。ソースに無いのは正しい。
16. **テストコードの入口。** `test/` の Servlet（実測 xPetstore: `EJBTestServlet` の `/TestServlet/*`）は入口に数えられる。外すなら `SCAN_EXCLUDE` に書き、ADR で処分する。

以下 17〜22 は反証レビュー（2026-10-25）が合成の入力で示した形で、**実測した 3 件には無かった**。`gate-snippets.sh` は対応済みで、selftest の 2 つ目のフィクスチャが確かめる。

17. **別のアプリの同じ path。** 管理用と利用者用の 2 つの WAR に `/login` があるのは重複ではない。重複と `extends` は**アプリ（最も近い祖先のビルド定義）の中で**解く。
18. **web.xml の置き場所とモジュールの既定。** `conf/web.xml` を build で `WEB-INF` にコピーする構成では、`/WEB-INF/...` を web.xml の位置から解けない——書かれた値の後方一致で設定ファイルを探す
    （候補が 1 つのときだけ。`configs.tsv` に「後方一致」と出る）。`config/xxx` だけを書いて `config` を書かないときも、既定のモジュールは `/WEB-INF/struts-config.xml`。
19. **XDoclet の書き方の揺れ。** 1.1 のコロン形式（`@ejb:bean` / `@struts:action`）も読む。マージ用の断片は servlet と mapping が別ファイルのことがあり、同じディレクトリの servlet を引いて ActionServlet の受け口を見分ける。
20. **Struts 1 の後期の基底。** Tiles の `TilesAction`、Spring の Struts 連携（`ActionSupport` / `DispatchActionSupport` 系・`DelegatingActionProxy`）を Struts の Action の基底に含める。
    `DelegatingActionProxy` を type に書く構成は、実体が Spring の Bean 定義にある（`ep-diff` の経路A のみに出る）。
21. **SQL の揺れ。** `CREATE TABLE IF NOT EXISTS`・Java の文字列のエスケープした引用符（`\"T\"`）・FROM / INTO を省略した DELETE / INSERT・`MERGE INTO` を読み、
    スキーマ修飾（`s1.t`）は外して表名で突き合わせる（スキーマの違いは仕様本文に書く）。**`MERGE` の `USING` の表と、`JOIN ... USING (列)` は区別できないので読まない。**
22. **Hibernate と Ant の import。** `*.hbm.xml` の `class` / 多対多の `set` 等の `table=` を表に数える。**HQL（`"from Customer c"`）は SQL と区別できず、エンティティ名を表として拾う**——
    Hibernate を使う対象では `bnd-diff` の「経路A のみ」にエンティティ名が出るので、`.hbm.xml` の `name=` と突き合わせて外す。
    Ant の `<import>` と `<macrodef>` の中のタスクを辿ってビルド単位を判定する（2 段まで）。

### 作成時の検証記録（このファイルのコマンドを OSS で走らせた結果。プロジェクトの実行記録ではない）

| 対象 | MOD（ビルド単位 / 記述子の持ち主） | 入口 `ep`（経路A / 経路B のクラス） | EJB（宣言 / ejb-class / 実装） | 表（参照 / 定義） | 備考 |
|---|---|---|---|---|---|
| MailReader（Struts 1.3.10） | 1 / 1 | 11（5 / 7） | 0（EJB を使わない） | 0 / 0（DB を使わない。DAO は XML のファイル） | 宣言 13（土台 1・上書きされた `/Welcome` 1 を除く）・ワイルドカード 4。経路B のみ 2（`RegistrationAction`＝`{1}Action` の候補、`WelcomeAction`＝上書きされた宣言の type）。DispatchAction 系の操作 5 |
| examples（Struts 1.3.10） | 1 / 1 | 100（17 / 16） | 0 | 0 / 0 | 5 モジュール・設定ファイル 9 本。type を持たない宣言 41。経路A のみ 1（`ForwardAction`＝Struts 同梱）。DispatchAction 系 4 クラス × 2 操作。素朴な `<action` の数え 101（注釈の中 1） |
| xPetstore 3.1（`xpetstore-ejb`） | 1 / 1 | 22（19 / 19） | 13 / 13 / 13 | 8 / 0（配備時に JBoss が作る） | 記述子はすべて XDoclet。action 17・filter 2・MDB 2・テストの servlet 1。`*.jspa` は ActionServlet の派生が受ける。servlet 版（WebWork）を同じ走査に入れると同じ完全修飾名のクラスが 2 つ出る |
| Pet Store 1.3.2 | 23 / 19（A のみ 4＝共通ライブラリ） | 19（8 / 8＝MDB だけ） | 43 / 32 / 32 | 21 / 21 | Web 層は Struts でなく WAF（`*.do` / `*.screen` を独自のサーブレットが受ける 2 アプリ。`mappings.xml` の `url-mapping` 7・`requestmappings.xml` 26 は別に数える）。CMP の 15 表は RI の SQL・カタログの 6 表は DAO |

### 逆引き索引の分母（`SOURCE_EXCLUDE`）

`gate-config.env` の `SOURCE_EXCLUDE`（POSIX ERE）は、逆引き索引（`GP-4` ルール7〜8）が
**引用を実ファイルへ解決するときの分母**から除くパスを決める。**Phase 0 で設定する。**

```sh
# ビルドの生成物（XDoclet の出力を含む）を除く（この Playbook の GEN_EXCLUDE と同じ除外にそろえる）
SOURCE_EXCLUDE='(^|/)(target|build|dist|classes|bin|out)/'
```

**入れないとどうなるか**: XDoclet の出力と生成した記述子に同名の `struts-config.xml` / `ejb-jar.xml` / `web.xml` があり、basename の引用が「候補複数」で解決できなくなる。
`SCAN_EXCLUDE` に入れたディレクトリも `SOURCE_EXCLUDE` にそろえる。

**値は必ず引用符で囲む**（囲まないと `gate-config.env` が bash の構文エラーになり `gates.sh` が中断する）。

## 実行記録（Phase 1 で埋める。Phase 4 で再実行して突合する）

<!--
【「独立ソースの実数」は**集約前**の実数を書く（GP-2 ルール8-7）】
役割で束ねてノード登録する場合（例: 100 の action を 12 の業務単位にまとめる）、
**独立ソース側には 100 を書き、ノード登録数に 12 を書く**。集約はここで差分として現れる。
集約した数をそのまま独立ソース欄に書くと差分が 0 になり、**粒度の粗さが記録から消える**。
差分に説明があるだけでは完了にしない——**完了を宣言する前に差分には ADR 参照が必要**である
（説明＝観察／ADR＝決定。決定のない粒度で完了させない。分母の粒度の処分は `G-ENUM-SOURCE` が検査する）。
-->

| ノード種別 | 独立ソースの実数 | ノード登録数 | 差分の説明 | 実行日 |
|-----------|--------------|-----------|----------|-------|
| NODE-MOD | `<N>` | `<M>` | `<差分がある場合は全件の理由。共通ライブラリ・まとめ役のビルドを明示>` | `<YYYY-MM-DD>` |
| NODE-EP（画面・入口） | `<N>` | `<M>` | `<同上。ワイルドカード・forward だけの宣言・servlet / filter・MDB・テストを明示>` | `<YYYY-MM-DD>` |
| NODE-BND（DB 表） | `<N>` | `<M>` | `<同上。一時表・配備時に生成・別 DB・未使用の表を明示>` | `<YYYY-MM-DD>` |

> **差分を「だいたい合っている」で閉じない。** 1 件でも説明できない差があれば列挙が不完全である
> （FB-1: 狙い撃ち grep で 48 ファイルを丸ごと見落とし、reconciliation は取りこぼしゼロと出た）。
