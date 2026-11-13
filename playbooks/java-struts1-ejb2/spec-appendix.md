# 仕様章立ての追補（java-struts1-ejb2）

ISO/IEC/IEEE 29148 準拠の章立て（GP-8）に対する、このスタック固有の追補。
汎用テンプレート（`specs/*/_template.md`）の節では表現しきれない要素だけを扱う。

- **対象スタック**: Struts 1.x（`struts-config.xml` ＋ JSP）／ EJB 2.x（Session・Entity（CMP / BMP）・Message-Driven Bean）

## 追加すべき節（カテゴリ別）

| カテゴリ | 追加する節 | 理由（このスタックで必要になるもの） | 密度の判定基準 |
|---------|----------|--------------------------------|--------------|
| api | action の一覧（モジュールの接頭辞つきの path） | 入口は Java のコードでなく `struts-config.xml`（か XDoclet のタグ）に宣言される。モジュールの接頭辞・ワイルドカード・`extends` で実際の URL が決まる | action 1 つにつき path・type・フォーム・scope・validate・input・parameter |
| behavior | action の処理の流れ | `execute`（または DispatchAction のメソッド）が「フォームの受け取り → 業務の呼び出し（Session Bean の Home の lookup → create → 業務メソッド）→ forward の名前を返す」を行う。どの forward を返すかの条件が仕様 | action 1 つにつき返す forward の名前ごとの条件 |
| behavior | DispatchAction の操作 | 1 つの宣言が `parameter` の値でメソッドに分かれる（`list-dispatch`。DP-java-struts1-ejb2-2） | 宣言 1 つにつき操作（メソッド）の全数と、操作を選ぶ要求の引数の名前 |
| behavior | 画面遷移 | 遷移は forward の名前で間接に書かれ、宣言（`<forward>`・`global-forwards`・`input`）と JSP のリンク（`html:link` / `html:form`）に分かれる（`list-forwards` / `list-refs`） | 遷移元の action・forward の名前・遷移先（JSP / 別の action）・redirect の有無 |
| behavior | 入力と検証 | フォーム Bean（`form-bean` / DynaActionForm の `form-property`）と Validator（`validation.xml` の `field` / `depends`）・`validate()` の実装に分かれる | フォーム 1 つにつき項目・型・検証規則（`depends` と `var`）・エラーメッセージのキー |
| modules | EJB コンポーネント | Session Bean が業務の単位。Home / Remote / Local のインタフェース・JNDI 名・`ejb-ref` で呼び出し関係が決まる（`list-ejb`） | Bean 1 つにつき種類・ビュー（remote / local）・業務メソッドの全数・呼び出し元 |
| modules | トランザクションと権限 | `container-transaction` の `trans-attribute`（`Required` / `RequiresNew` 等）と `method-permission` の役割が、コードでなく記述子にある（`list-tx`） | Bean 1 つにつきメソッドごとの属性と役割（`*` の指定を展開する） |
| data | CMP の対応（Entity Bean × 表 × 列・CMR） | 表と列の対応がベンダの記述子（`jbosscmp-jdbc.xml` / `weblogic-cmp-rdbms-jar.xml` / RI の SQL）か XDoclet の `table-name` / `column-name` にある。CMR（関連）は `ejb-relation` に書かれる | Entity Bean 1 つにつき表・主キー・CMP のフィールドと列・関連の多重度と結合の列 |
| data | ファイル × 表 × 操作（CRUD） | CMP は SQL を書かず、BMP・DAO は Java の文字列で SQL を組む（`list-crud`）。CMP の操作は Home の `create` / `remove` と finder（EJB-QL）で決まる | Bean・DAO 1 つにつき参照・更新する全表と操作 |
| data | EJB-QL の finder | finder は抽象スキーマ名で書かれ、表名ではない（`ejb-ql` / XDoclet の `@ejb.finder query=`） | finder 1 つにつきシグネチャ・EJB-QL・解いた表 |
| nfr | 非同期の処理 | Message-Driven Bean が JMS のキュー / トピックから受ける。宛先は記述子とベンダの記述子（JNDI 名）にある | MDB 1 つにつき宛先・メッセージの形・失敗時の扱い（再送・トランザクション） |

## 記述方式の指定

同じ対象を複数の書き方で書くと横断突合ができなくなるため、方式を固定する。

- **画面 ID（`SCR-NN`）は action と 1 対 1 に対応させ、本文にモジュールの接頭辞つきの path を必ず書く**
  （`/dispatch/mapping-foo`。`idents-endpoint` の出力と `G-IDENT` で突合する。ワイルドカードの宣言は `/Save*` のまま書く）。
- **EJB は ejb-name で書く**（`idents-ejb`。複数の ejb-jar に同じ名前があるときはモジュールを添える）。
- **表は物理名で書き、綴りは `idents-table` の出力に合わせる**（`G-IDENT` は大小を区別して突合する）。
- **引用は `path:line` で書く**（`struts-config.xml:127`）。XDoclet のアプリはタグの行（`CartAction.java:13`）を引く——生成した XML の行は引かない。
- **画面遷移は mermaid `stateDiagram` で書き、ノード ID を画面 ID と一致させる**（統合画面遷移図のノード数 = 画面数の突合。GP-14 ルール6）。

## このスタックで静的読解が効かない箇所（SB-6 の具体化）

- **ワイルドカードの action と `{N}` の type**: `/Save*` ＋ `type="...{1}Action"` は要求の path で呼ばれるクラスが決まる。
  候補は `ep-diff` の「ワイルドカードの type の候補」。どの URL が実際に要求されるかは JSP のリンク（`list-refs`）を読む。
- **DispatchAction の `parameter`**: 操作を選ぶ値が要求の引数（`?method=save`）か宣言の固定値（MappingDispatchAction）かで、操作の決まり方が違う。
  LookupDispatchAction はボタンのラベルのリソース キーからメソッドを引く（`getKeyMethodMap`）ので、リソース ファイルも読む。
- **JNDI の lookup**: `ServiceLocator` 等が JNDI 名で Home を引く。JNDI 名と Bean の対応はベンダの記述子（`jboss.xml` / `weblogic-ejb-jar.xml` / `sun-j2ee-ri.xml`）にある。
- **CMP の SQL**: CMP の Entity Bean の SQL はサーバが作る。finder の EJB-QL と、ベンダの記述子の追加の設定（遅延読み込み・楽観ロック）で振る舞いが変わる。
- **配備時の設定**: トランザクションの分離レベル・データソース・JMS の宛先・セキュリティの役割の割り当ては、配備の設定（サーバの管理画面・配備計画）にあり、ソースに無いことがある。
- **独自のフロントコントローラ**: Struts の上に独自の RequestProcessor（`processPreprocess` 等）を被せると、全 action の前後に共通の処理が入る。
  `controller` 要素の `processorClass` と、`RequestProcessor` の派生クラスを読む。
