# reverse-spec-flow

**既存のソースコードから、AI エージェントが使うための「AI フレンドリーな仕様書」を作るワークフロー**

バージョン: [2.2.1](docs/release-notes.md) ／ License: MIT-0

> English: [README.md](README.md)

---

## これは何か

仕様書が無い・古くなった、あるいは中身が分からなくなった（ブラックボックス化した）アプリケーションの
ソースコードから、**AI エージェントが読んで使うための仕様書**を作ります。ID と索引で必要な箇所だけを
引ける Markdown の仕様書です。作った仕様書は、たとえば次のように使います。

- **アプリケーションの再構築** — 仕様書を入力にした仕様駆動開発で、AI エージェントが新しい技術でアプリケーションを作り直す
- **現行システムの保守・発展** — AI エージェントが仕様書から動きや影響範囲を調べ、機能追加・仕様変更などの保守や、リファクタリング・移行に伴う改修の検討を支える

既存システムの再構築や保守を、AI エージェントを使って進めたい開発者・アーキテクト向けです。
人が読むこともできますが、主な読み手は AI エージェントです。仕様書を作る作業も AI エージェントが行います。
そのため reverse-spec-flow は、次の 2 つを AI エージェントの自己申告ではなく仕組みで担保することを、最も重視しています。

### 1. 記述が正しいこと — 根拠のない記述（ハルシネーション）を残さない仕組み

- **すべての記述に根拠を付ける** — 一文ごとに、根拠となるコードの位置（`path:line`）を付けます。
- **作った本人とは別に検証する** — 作成とは切り離した検証役の AI エージェントが、記述と解析対象のソースコードを突き合わせ、
  「位置が書いてある」だけでなく「その行が記述を裏付けている」ことを確かめます。
- **分からないことは「分からない」と書く** — コードから確かめられないことは推測で埋めず、`UNKNOWN` として残します。

### 2. 漏れがないこと — コードグラフの全要素を 100% 仕様化するまで完了にしない

- **先に「数える対象の一覧」（分母）を作る** — 最初に、モジュール・入口・外部接続とそのつながりを一覧にした
  構造マップ（コードグラフ）を作ります。
- **一覧を使い切るまで完了にしない** — コードグラフのすべての要素が仕様化されたかを数え、残りが 0 になるまで
  完了になりません。「主要な部分は見ました」で終わらせません。
- 一覧の正しさは、対象の技術に合わせた数え方（下の「Playbook」）で支えます。あわせて、設定ファイルなど
  別の手がかりからも数えて突き合わせ、取りこぼしを見つけます。

どちらについても、完了かどうかは AI エージェントの「終わりました」ではなく、点検スクリプト `gates.sh` が
合格（exit 0）を返すかで判定します。

### そのほかの特徴

- **AI エージェントが引きやすい形** — 仕様書のファイルや要求の一つひとつに、一意で変わらない ID（例: `REQ-F-01`）を付けます。
  仕様書どうしは ID で参照し合い、ID からファイルを引く索引と、ソースから仕様書を引く逆引き索引も作るので、
  AI エージェントは全体を読まずに必要な箇所だけを引けます。
  仕様書を使う側の AI エージェントが従うルール（`specs/AGENTS.md`）も同梱します。
- **作り直しに使える層を分ける** — 現行の技術に依存する部分と、どの技術で作り直しても必要な本質を分けて書けます。
- **大規模なコードも並列で進める** — コードの中身は業務のまとまりごとに読むので、コード全体を一度に読み込む必要はありません。
  AI ツールがサブエージェント（作業を分担して並行に動く AI エージェント）を使える場合は、まとまりごとに並列に進められます。
- **コンテキストがあふれても続けられる** — 進捗と次の作業をファイルに記録して git にコミットします。
  コンテキストがあふれたりセッションが切れたりしても、新しいセッションを開けば記録から再開できます。
- **実施で得た知見を次に活かす** — プロジェクトで得た知見を記録し、汎用的なものは reverse-spec-flow 自体に反映できます
  （手順は下の「ドキュメント」）。
- **解析対象は変更しない** — 規範で AI エージェントに変更を禁じ、変更されたら `gates.sh` が検知します。仕様書は別の git リポジトリに出力します。解析対象は git の複製かコピーを使ってください。

以下、Claude Code・Kiro などの製品を **AI ツール**、その上で作業する AI を **AI エージェント**と呼びます。

## 必要なもの

- **bash と git**（macOS / Linux。Windows で使う場合は WSL を推奨します。Git Bash でも動きますが、点検に時間がかかります）
- **AI ツール**（下の「対応している AI ツール」）
- **解析したいソースコード**

データベースや専用の基盤は要りません。

## クイックスタート

```bash
# 1. 解析対象のフォルダ（例: legacy-order-system/）と同じ階層に取得する
cd /path/to/workspace        # この中に legacy-order-system/ がある
git clone https://github.com/aws-samples/sample-reverse-spec-flow.git

# 2. 仕様書用のリポジトリを作る
#    init.sh <解析対象> <名前（英数字・. _ -）> [purpose（省略すると対話で選択）]
./sample-reverse-spec-flow/init.sh ./legacy-order-system order-system rebuild

#    対象の技術に合う Playbook（数え方の定義集。下の「Playbook」）があれば指定できます（任意。無くても動きます）
./sample-reverse-spec-flow/init.sh ./legacy-order-system order-system rebuild --playbook java-jaxrs-jpa
```

隣に `legacy-order-system-spec/`（仕様書用のリポジトリ）ができます。
**以降の作業は、`legacy-order-system-spec/` を開いた新しいセッションで行ってください。**
`init.sh` を実行した `sample-reverse-spec-flow/` のセッションでは解析を始めないでください。
Kiro IDE を使う場合は、開く前に `legacy-order-system-spec/HOST-SETUP.md` を読んでください。

```
3. legacy-order-system-spec/ を AI ツールで開き、次のように指示する:

   spec-extraction/AGENTS.md を読んでください。
   解析対象のソースは /path/to/workspace/legacy-order-system/ にあります（参照専用・変更しない）。
   spec-extraction/AGENTS.md の <PLACEHOLDER> を埋めてから、Phase 0 から始めてください。
```

同じ内容の指示は、`init.sh` の実行結果の最後にも表示されます。

`init.sh` の主なオプション:

| 引数 | 意味 |
|---|---|
| `purpose`（第 3 引数・省略可） | 仕様書を何に使うか。`maintenance`（現行システムの保守・発展）／`evaluation`（作り直しの評価・見積もり）／`rebuild`（AI エージェントが作り直しを実装できる深さまで書く）。作る範囲と点検の厳しさが変わります。省略すると対話で選択します（既定は `rebuild`） |
| `--playbook <name>` | 任意。解析対象の技術に合わせた数え方（下の「Playbook」）。複数指定できます |
| `--host <name>` | 使う AI ツール（`claude-code`（既定）／`kiro-ide`／`kiro-cli`） |
| `--list-playbooks` ／ `--list-hosts` | 使える Playbook ／ AI ツールの一覧 |

## 作業の流れ

```
Phase 0  取り込み       解析対象のコミットを固定し、範囲を決める
Phase 1  コードグラフ   モジュール・入口・外部接続とそのつながりを一覧にする（＝網羅の分母）
Phase 2  分析           観点（構成・要求・API・データ・振る舞い・非機能）ごとに、根拠付きで分析する
Phase 3  仕様書の作成   ISO/IEC/IEEE 29148（要求仕様の国際規格）の章立てで、AI エージェントが引ける形の仕様書を書く
Phase 4  監査           網羅・引用・事実と推測の分離を、作成とは独立に点検する
```

各段階の区切りで、AI エージェントは人の確認を求めます（範囲の確定、数え方の判断など）。
点検の中身と、AI エージェントが止まって人に聞く条件は [docs/how-it-works.md](docs/how-it-works.md) にあります。

## 生成されるもの

```
legacy-order-system-spec/            ← init.sh が作る独立 git リポジトリ
├── AGENTS.md                        ← 入口
├── specs/                           ← 成果物（AI エージェントに渡す仕様書）
│   ├── AGENTS.md                    ←   消費側の規範（仕様書を使う AI エージェントが従うルール）
│   ├── overview.md                  ←   システム全体像
│   ├── source-index.md              ←   ソースから仕様書を引く逆引き索引（影響範囲の調査に使う）
│   ├── modules/ api/ data/ behavior/
│   └── rebuild/                     ←   技術に依存しない本質の仕様書（purpose が rebuild / evaluation のとき）
└── spec-extraction/                 ← 作業記録（手順書・中間生成物・点検結果）
    ├── AGENTS.md                    ←   生成側の規範（仕様書を作る AI エージェントが従うルール）
    └── 03-audit/gates.sh            ←   完了を判定する点検スクリプト
```

AI エージェントに読ませる規範（AI エージェントが従うルール）は、入口と 2 つの規範に分けて置きます。

| 置き場所 | 役割 |
|---|---|
| `AGENTS.md`（ルート） | 入口。目的に応じて下の 2 つへ案内する |
| `specs/AGENTS.md` | 仕様書を使う側（再構築・調査をする AI エージェント）の規範 |
| `spec-extraction/AGENTS.md` | 仕様書を作る側の規範 |

AI ツールが自動で読み込むファイルは、ツールや版によって違います。そのため、ツールの自動読込に依存しないよう、入口から必要な規範を読みに行く構成にしています。

### 作った仕様書を使うとき

仕様書を AI エージェントに渡すときは、`specs/` をそのまま渡し、最初に `specs/AGENTS.md` を読ませてください。
解析対象のソースコードも一緒に渡せば、AI エージェントは記述をソースコードと突き合わせられます。
ソースコードを渡さない場合、AI エージェントはその旨を宣言したうえで、仕様書から言える範囲だけを答えます。

## 対応している AI ツール

仕様書を作る側で使える AI ツールです。

| AI ツール | 状態 | 指定 |
|---|---|---|
| Claude Code | 検証済み（最後まで完走） | `--host claude-code`（既定）。入口への導線として `CLAUDE.md`（ルート）も置きます |
| Kiro IDE | 検証済み（小規模な対象で完走。範囲は [hosts/README.md](hosts/README.md)） | `--host kiro-ide`（開く前に、生成される `HOST-SETUP.md` を読んでください） |
| Kiro CLI | 未検証（一部の機能のみ確認。全工程は未実施） | `--host kiro-cli` |

仕様書を作る側で、表に無い AI ツールは未対応です（作った仕様書は、どの AI エージェントにも渡せます）。
対応状況と測定の記録は [hosts/README.md](hosts/README.md) にあります。

## Playbook（任意）

**reverse-spec-flow は、言語や技術スタックを問わず使えます。Playbook が無い技術でもそのまま動きます。**

Playbook は、特定の技術について「何を数えれば全体を網羅したことになるか」（画面・API・テーブルの数え方など）を
あらかじめまとめた手順の短縮です。Playbook を指定しない場合は、Phase 1 の最初に AI エージェントが
技術スタックの知識をもとに対象のコードを調べて数え方を決めます。手順は同じで、点検も同じように行われます
（数え方を決めないまま先に進むと、点検で止まります）。

現在用意している Playbook は次のとおりです。

| Playbook | 対象 |
|---|---|
| `java-jaxrs-jpa` | Java（JAX-RS / Spring MVC ＋ JPA アノテーション） |
| `java-struts-ormxml` | Java（Struts 2 ＋ JPA の XML マッピング） |
| `java-struts1-ejb2` | Java（Struts 1 ／ EJB 2.x） |
| `aspnet-webforms` | ASP.NET Web Forms（C# / VB.NET） |
| `csharp-winforms-adonet` | C# Windows Forms ＋ ADO.NET |
| `vbnet-winforms-adonet` | VB.NET Windows Forms ＋ ADO.NET |
| `vb6` | Visual Basic 6.0 |
| `php-procedural-mysql` | 手続き型 PHP ＋ MySQL など |
| `cobol-cics-batch` | COBOL（CICS ／ JCL バッチ ／ DB2・VSAM） |
| `oracle-plsql` | Oracle PL/SQL（アプリ側の Playbook と併用） |

よく使う技術がある場合は、Playbook を作って追加できます（[docs/authoring-playbook.md](docs/authoring-playbook.md)）。

## ご利用にあたっての注意

- **仕様書には誤りが残ることがあります。** 点検の仕組みで誤りを減らしていますが、完全になくすことはできません。
  仕様書をもとに再構築したアプリケーションは、UAT やリグレッションテストなどで、現行システムと同じように動くことを別途確認してください。
  検証で確かめた品質は [docs/release-notes.md](docs/release-notes.md) にあります。
- **AI ツールに解析対象のソースコードを読ませます。** 機密性のあるコードを扱う場合は、
  使う AI ツールの利用条件と、所属組織のルールに従ってください。
- **解析対象の中の指示文と秘密の値に注意してください。** 規範では、ソースコードのコメント・文字列・文書の中の指示に AI エージェントが従わないこと、
  パスワード・キー・トークン・個人情報などの秘密の値を仕様書に書き写さず、在りかと種類だけを書くことを定めています。
  それでも、仕様書を共有する前に、秘密が含まれていないか確認してください。
- **信頼できないコードは、隔離した環境で解析してください。** AI エージェントは利用者の権限でシェルを実行します。上の決まりは AI への指示であって、強制する仕組みではありません。
  信頼できないコードは、本番の認証情報が無い隔離した環境（VM・コンテナ・使い捨ての開発機）で解析し、承認の自動化
  （Always allow・`kiro-ide-allow.sh`）は使わないでください。Playbook や `hosts/` のファイルも、信頼できる出所のものだけを使ってください。
- **仕様リポジトリは解析対象と同じ扱いにしてください。** 解析対象のコードの抜粋と、手元の絶対パスが含まれます。公開の場所へ push せず、
  共有する前に秘密の検出ツール（例: git-secrets・gitleaks）で確かめてください。他人から受け取った仕様リポジトリは、
  AI ツールでワークスペースとして信頼する前に `.claude/` と `.kiro/` の中身を確かめてください。
- **起動や画面操作などの動的な確認はしません。** コードから確かめられないことは `UNKNOWN`（未確定）として残ります。
- 本リポジトリはサンプルです。本番の業務に使う前に、利用者の責任で十分に検証してください。

## ドキュメント

| 読みたいこと | ドキュメント |
|---|---|
| **使い方と仕組み**（何が起きるか・何が点検されるか・止まったときどうするか） | [docs/how-it-works.md](docs/how-it-works.md) |
| 非エンジニア向けの説明 | [docs/overview-for-business.md](docs/overview-for-business.md) |
| 設計の考え方・解こうとしている課題・成果物の例 | [docs/overview-for-engineers.md](docs/overview-for-engineers.md) |
| 版ごとの変更 | [docs/release-notes.md](docs/release-notes.md) |
| 新しい Playbook の作り方 | [docs/authoring-playbook.md](docs/authoring-playbook.md) |
| 設計文書（検証役の隔離） | [docs/designs/verifier-isolation.md](docs/designs/verifier-isolation.md) |
| AI ツール対応の仕組み | [hosts/README.md](hosts/README.md) |
| 生成の規約・品質の決まり（AI エージェントが参照する文書。人が読む必要はありません） | [pipeline.md](pipeline.md) ・ [playbook.md](playbook.md) |

### reverse-spec-flow 自体を改造する方へ

- 変更の手順と selftest の実行: [CONTRIBUTING.md](CONTRIBUTING.md)
- 改造するときの落とし穴（教訓 1〜66）: [dev/developing-the-framework.md](dev/developing-the-framework.md)
- プロジェクトで得た知見を reverse-spec-flow に反映する手順: [dev/backport-procedure.md](dev/backport-procedure.md)
- `dev/` には開発時の試験記録なども置いています（利用するだけなら読む必要はありません）。

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
