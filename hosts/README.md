# hosts/ — ホストアダプタ層（GP-107）

ホスト（AI コーディングツール）固有の配置・語彙・任意のフックを閉じ込める層。
`playbooks/`（スタック軸、GP-105）と**同型の軸違い**であり、**互いを知らない**
（`enumeration.md` はホストを知らない／`profile.env` はスタックを知らない）。

`./init.sh <source> <spec-name> [purpose] [--host <name>] [--playbook <name>]`
`./init.sh --list-hosts` で一覧を表示する。

## 対応表

**`SUPPORT_LEVEL` は `MEASURED.md` を根拠にしか名乗れない**（GP-107 ルール8 / SB-12 と同型）。

| ホスト | 軸（ホスト × 機構世代） | SUPPORT_LEVEL | 実測 | 備考 |
|---|---|---|---|---|
| `claude-code` | Claude Code 2.1.x | `verified-full` | 教訓 38（2 環境 × 3 回）＋ 完走試験 R1〜R4 | **既定**。`--host` 省略時はこれ |
| `kiro-ide` | Kiro IDE 1.x | `verified-full` | `kiro-ide/MEASURED.md`（1.4.5 / 2026-10-21）＋ 完走試験 R5（1.4.5→1.4.26 / 2026-10-26） | R5 は jpetstore・Playbook なし・**小規模**（ノード 176・密度ブロック 329。R4 の約 4 分の 1）。Playbook の経路と HOLD-9 の (B)・(C) は試していない。329 ブロックのうち 82 は隔離の確かめを実施者が保存した出力に拠る（`kiro-ide/MEASURED.md` の R5 節）。**承認ダイアログが長時間の作業を止める**（手当ての `kiro-ide-allow.sh` は R5 の後に作り、未実測） |
| `kiro-cli` | Kiro CLI 2.33.0（V2 / V3 エンジン。検証官の起動は V3 専用） | `placed-unverified` | `kiro-cli/MEASURED.md`（2.33.0 / 2026-10-21） | **測ったのは検証官の隔離と skill の読み込みだけ**。生成パイプライン全体は未実施 |

**ここに無いホストは「未対応」である。** 「置いてみたが測っていない」ものを足す場合は
`SUPPORT_LEVEL=placed-unverified` と**明示**し、`MEASURED.md` に未測定であることを書く
——`SB-12` の「未検証を隠して名乗らない」をこの表に写したものである。

## 1 つの harness の中身

| ファイル | 役割 | 必須 |
|---|---|---|
| `profile.env` | **能力宣言の正本。** 読むのは `init.sh` と手順書の記入者だけ。**ゲートは読まない**（GP-107 ルール4）。`PLACED_PATHS=` に `placement.sh` が置くもののリポジトリ相対パスを宣言する（`apply-host.sh` が「前のホストの残り」を報告するのに使う。selftest が宣言と配置を突合する） | ✅ |
| `entry.md` | 規範の読ませ方 ＋ **ツール名対応表** ＋ ホスト固有の禁止事項 ＋ **検証官の隔離**（§5）。**配置時に生成先のルートへ `HOST.md` として写す**（手順書・skill は「`HOST.md` に従う」と役割で書くので、写さないと実行時に正本が無い） | ✅ |
| `placement.sh` | **ホストを知る唯一のコード。** `init.sh` / `apply-host.sh` が呼ぶ配置処理。HOST.md・HOST-SETUP.md・残置物の報告はホストを知らずに行えるので `hosts/_place-common.sh`（共通部分の正本）が行い、ホストの解決は `hosts/_resolve.sh` が行う | ✅ |
| `MEASURED.md` | 実測記録（版・日付・回数）＝`SUPPORT_LEVEL` の根拠 | ✅ |
| `setup.md` | セッションを開く**前**に人が済ませる手順（承認・skill の配置など）。**あれば共通部分が生成先のルートへ `HOST-SETUP.md` として写す**（`placement.sh` には書かない） | 任意 |
| `skills/` | サーフェス native 形式の skill（本体の `skills/` と形式が違う場合） | 任意 |
| `hooks/` | ホスト固有のフック。**合否の根拠にしない**（GP-107 ルール7。縮退経路を対で書く） | 任意 |
| その他の配置物 | `placement.sh` が置く harness 固有のファイル（例: `claude-code/agents/`＝検証官の定義、`kiro-cli/kiro-verify.sh`＝検証官を別セッションで起動するスクリプト、`kiro-ide/kiro-ide-verify-check.sh`＝検証官の隔離をセッション記録で確かめるスクリプト）。**置くパスは `profile.env` の `PLACED_PATHS` に申告する**（`apply-host.sh` がホストを切り替えたとき、前のホストの残りとして示す） | 任意 |

## 新しいホストを足す手順

1. `cp -R hosts/_template hosts/<surface>` して `profile.env` を埋める（分からない項目は `unknown` と書く。推測を書かない）。
2. `placement.sh` にそのホストの配置を書き、置くものを `profile.env` の `PLACED_PATHS` に宣言する。**ここ以外にホスト名・ホスト固有のパスを書かない**（`init.sh` / `apply-host.sh` / `hosts/_*.sh` は selftest がホスト固有の名前を持たないことを検査する）。
3. **実測する。** `MEASURED.md` に版・日付・回数を残す。**判定が揺れた項目は複数回、1 回で確定した項目は 1 回**でよいが、**回数を項目ごとに明記する**。
4. `entry.md` にツール名対応表と禁止事項を書く。
5. `hosts/README.md` の対応表に行を足す（`SUPPORT_LEVEL` は実測の範囲でしか名乗らない）。
6. **`hosts/` 以外に差分が出たら層の切り方が間違っている**（`templates/` に出たら層の誤り／`playbooks/` に出たら直交性の破れ）。
