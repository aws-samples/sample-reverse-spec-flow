# Playbook: `java-struts-ormxml`

Java の XML 宣言型スタック（Struts 2 ＋ JPA `*.orm.xml` マッピングファイル方式）を対象とする Playbook。
実測検証: Apache Roller 6.x / `app` モジュール（2026-08-10）。

## 対象スタック

- **言語/実行基盤**: Java / サーブレットコンテナ
- **エントリポイント**: Struts 2（`struts*.xml` の `<action>` 宣言）＋ `web.xml` の servlet/filter
- **永続化**: JPA の**マッピングファイル方式**（`*.orm.xml` ＋ `persistence.xml` の `<mapping-file>`）
- **画面**: Velocity テンプレート（`*.vm`）

## 適用判定（この Playbook を選ぶべきか）

```bash
grep -rlE '<struts[ >]' <source> --include='struts*.xml' | head    # 1 件以上ヒット（ルートが <struts> = Struts 2）
grep -rl '@Path' <source> --include='*.java' | head                 # 0 件
```

- ✅ **該当**: ルートが `<struts>` の `struts*.xml` が存在し、`@Path` が 0 件（XML 側で宣言している）
- ❌ **非該当**: `@Path` / `@RequestMapping` がある → **`java-jaxrs-jpa` Playbook を使う**
- ❌ **非該当**: ルートが `<struts-config>`（Struts 1）→ **`java-struts1-ejb2` Playbook を使う**。
  Struts 1 の `struts-config.xml` も名前は `struts*.xml` に一致するので、**ファイル名では見分けない**（2026-10-25 に実測で判明。
  Struts 1.3.10 の MailReader が旧判定の `find -name 'struts*.xml'` で該当になった）

> **同じ「Java」で Playbook が分かれる理由**: 実測で Roller は `@Path` **0 件**・`@Table` **0 件**だった。
> 汎用手順書が `@Path` / `@Table` を独立ソースに指定していたため、**分母突合が計算不能**になり、
> roller-spec は独自に代替源を発明していた（記録も再利用もされない形で）。
> 「言語が同じ」は「分母の数え方が同じ」を意味しない（GP-105 の設計根拠）。

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** 独立ソース表 ＋ 走査の落とし穴 6 件（すべて実測） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-java-struts-ormxml-N`） | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへの追補（画面遷移・テンプレート分岐等） | `../specs/_appendix-java-struts-ormxml.md` |
| `gate-snippets.sh` | `gates.sh` から呼ぶ列挙コマンド（`ep`/`bnd`/`mod`/**`orm-diff`**） | `03-audit/gate-snippets.sh` |

`gate-snippets.sh orm-diff` は `*.orm.xml` の実体と `persistence.xml` 宣言の**両方向差集合**を出す
（SB-2（両方向の差集合））。**突合キーはクラスパスルート相対のフルパス**で、basename に落とさない
（落とすと件数が合ったまま同一性が壊れる）。実測（Roller）では実体 31 / 宣言 30 で、
`org/apache/roller/planet/pojos/RuntimeConfigProperty.orm.xml` が宣言されていない。
**さらにこれは「宣言漏れ」ではなく「死蔵ファイル」だった**（2026-09-23 に再実測して是正）
——マップ先クラスが宣言されたパッケージに存在しない（同名クラスは別パッケージに実在するため、
クラス名だけで探すと見逃す）。`orm-diff` は差分を**死蔵の疑い / 宣言漏れ**に切り分けて出す。
突合キーを削れないレイアウト・宣言を 1 件も抽出できない場合は**突合不能として rc=1 で止まる**
（削り残しを黙って差分に数えない）。

## 利用者が明示的に判断すべき項目（このスタック固有）

- **`persistence.xml` に宣言されていない `*.orm.xml` の扱い。**
  実測で 1 件実在した。「エンティティ定義はあるが永続化されない」状態だが、
  **対処は 2 通りに分かれる**——マップ先クラスが実在すれば**宣言漏れ**（宣言を足す）、
  存在しなければ**死蔵ファイル**（ファイルを消す）。実測の 1 件は後者だった。
  いずれも現行の事実として仕様に書くか、実装バグ候補（`observed-anomalies`）として
  記録するかを判断する（SB-13）。**`orm-diff` の判定は「死蔵の疑い」までで、
  jar 提供・内部クラスの可能性は人が確認する。**
- **Velocity テンプレート（`*.vm`）を仕様化の分母に含めるか。**
  画面の条件表示・繰り返しはテンプレート側にあるため、アクションクラスだけでは画面仕様が埋まらない（SB-8）。
- **`struts.xml` の `<package extends="...">` による継承で有効になる URL の扱い。**
  `<action>` の件数だけでは実際に到達可能な URL 集合と一致しない。
- **DDL（スキーマ生成テンプレート）とエンティティ定義の差の扱い。**
  ORM 管理外のテーブル（ログ・キャッシュ等）を分母に含めるか。
