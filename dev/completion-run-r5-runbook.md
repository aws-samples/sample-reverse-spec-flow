# 完走試験 R5（Kiro IDE）— ユーザーの手順（貼るだけ）

> **このファイルを測定用のウィンドウで開かない。** 実施者（Kiro IDE のエージェント）にも渡さない。
> 実施者に渡すのは生成先に置いた指示書の写し（`spec-extraction/worklog/R5-instructions.md`）だけである。

## 準備（済んでいる）

`_measure/r5-run/` に解析対象 `jpetstore`（断面 `c9a37f22`）の複製と、`init.sh --host=kiro-ide` で作った生成先 `jpetstore-spec` を置いた。
指示書の写しは生成先の `spec-extraction/worklog/R5-instructions.md` にある。

## 1. 始める

1. Kiro IDE で `File > Open Folder…` から **`/Users/<user>/workspaces/_measure/r5-run/jpetstore-spec`** を開く（新しいウィンドウ）。
2. **新しいチャット**を開く。エージェントが **`Default`**、自律モードが **Autopilot** であることを確かめる。
3. 下を貼って送る。

```
spec-extraction/worklog/R5-instructions.md を読み、その指示書に従って作業を始めてください。最初に HOST.md と HOST-SETUP.md を読んでください。
```

## 2. ダイアログが出たら

| ダイアログ | 押すもの |
|---|---|
| **Read File**（パスが `/Users/<user>/workspaces/_measure/r5-run/jpetstore/` で始まる） | **`Always allow`** → Apply to は **This Session**、Path は**候補のうち `jpetstore/` にいちばん近い（上の）フォルダ**。**`**` と All Workspaces は選ばない** |
| **Sub-agent: spec-verifier** | **`Always allow`**（1 回目だけ出る） |
| **Load skill: density-verify** ／ **Load skill: spec-adversarial-audit** | **`Always allow`**（`init.sh` が `.kiro/skills/` に置いたフレームワークの skill。本文を読み込むだけ） |
| **Load skill:** で上の 2 つ以外 | **`Deny`**（ユーザー全体の skill。この試験では使わない）。そのあと私に知らせる |
| **Run Command**（`grep` / `find` / `wc` / `cat` / `ls` / `sort` などの読むだけのコマンド、`echo` / `date` / `uptime` / `sw_vers` / `locale` / `head` など**表示するだけ**のコマンド、`bash spec-extraction/03-audit/…`、生成先での `git status` / `add` / `commit` / `log`） | **`Always allow`**（保存先を聞かれたら This workspace）。つないだコマンドは 1 つずつ聞かれる（まだ承認していないものだけが出る） |
| **Run Command** で、`r5-run/jpetstore/`（解析対象）に書き込むもの・`rm -rf`・`sudo`・`git push` / `reset` / `rebase` | **`Deny`**。そのあと 4 の「それ以外」として私に知らせる |
| **Write / Edit** で、生成先（`jpetstore-spec/`）の外を書き換えるもの | **`Deny`** |
| 上のどれにも当たらない | **`Allow`**（`Always allow` ではない）。迷ったら止めて私に知らせる |

Read File のダイアログは、**新しいセッションになるたびにまた出る**（Kiro IDE の仕様。測定で確かめた）。そのたびに同じように選ぶ。

**Run Command の `Always allow` は「先頭の語 ＋ `*`」で保存される**（例: `bash --version` を許すと `bash *` が保存される＝`bash -c '…'` で何でも通る）。
**先頭が `bash` / `sh` / `zsh` / `python3` / `env` / `xargs` / `eval` のときは `Always allow` を押さず `Allow`（1 回だけ）にする**（中身が毎回違うので、1 回ずつ見る）。
すでに保存されたものは下の記録で見られる。

**何を承認したかの記録**（いつでも作り直せる。フレームワーク側のウィンドウで私に「承認の記録を作って」と言えばよい）:

```bash
python3 dev/kiro-approvals-extract.py ~/workspaces/_measure/r5-run/jpetstore-spec \
  --source ~/workspaces/_measure/r5-run/jpetstore --out ~/workspaces/_measure/r5-run/approvals.md
```

セッションごとのダイアログ（時刻・コマンド・押したもの）、保存された規則、解析対象に変更が無いかが `_measure/r5-run/approvals.md` に出る。

## 3. 実施者が判断を求めてきたら

| 求められたこと | 返す文 |
|---|---|
| HOLD-9（密度 Verify が収束しない。同じ主張の 2 回目・「外して partial」の承認） | `手順書の推奨どおりに進めてください。` |
| Phase の境界の確認（次の Phase に進んでよいか） | `手順書どおりに次の Phase に進んでください。` |
| **HOLD-1（分母を縮める）**／**レディ・監査完了の宣言の確認** | **貼らずに、実施者の文面をそのまま私（フレームワーク側のウィンドウ）に貼る。** 私が返す文を作るので、それを貼る |
| それ以外の質問 | 実施者の文面をそのまま私に貼る |

## 4. 止まったとき

| 起きたこと | すること |
|---|---|
| チャットが応答しなくなった・コンテキストが尽きたと言われた | **新しいチャット**を開き、下を貼る（Read File のダイアログはまた出る） |
| エラーで止まった・手順書と矛盾すると言われた | 実施者の文面をそのまま私に貼る |

```
spec-extraction/worklog/R5-instructions.md と spec-extraction/worklog/session-context.md を読み、作業を再開してください。
```

## 5. 終わったら

実施者が `gates.sh phase4` の出力と終了コードを報告したら、フレームワーク側のウィンドウで「R5 が終わった」と伝える。
**合否はこちらで判定する**（実施者の「完了しました」をそのまま受け取らない）。

**設計側が行うこと（この順）**:
1. 承認の記録を作り直す（上の `kiro-approvals-extract.py`。`_measure/r5-run/approvals.md` を上書きする）。全セッションのダイアログ・保存された規則と、
   解析対象の `git status` を見る（**変わっていたら記録して `git checkout` で戻す**。止める仕組みは作らない＝2026-10-23 の方針）。
   凍結記録の §結果 と `R5-run-log.md` の #20 に突き合わせる。
2. 判定（一次・二次 A〜E）。
3. `hosts/kiro-ide/setup.md` の承認の節を新しい方針で短くする（`dev/host-adapter-plan.md` の Phase F の項）。
