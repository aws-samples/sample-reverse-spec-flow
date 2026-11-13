# Kiro IDE — セッションを開く前に済ませること

このリポジトリを Kiro IDE で開いて作業する前に、**人が 1 回だけ**行う手順。
根拠はフレームワーク側の `hosts/kiro-ide/MEASURED.md`（1.4.5 の実測と完走試験。このファイルは `HOST-SETUP.md` として生成先に写されるので、相対パスでは辿れない）。

> **なぜ要るか**: 何もしないと、数日かかる作業がシェルの実行・ファイルの読み書き・検証官の起動のたびに
> 承認ダイアログで止まる（完走試験で実用上の最大の問題だった）。承認はリポジトリの外に保存されるので、
> **リポジトリからは入れられない。人が自分のマシンで入れる。**

## 1. skill が配置されていることを確認する

```bash
ls .kiro/skills/
# density-verify / spec-adversarial-audit が見えること
```

**提示一覧はセッション開始時のスナップショットである。** 開く前に配置されている必要がある（`init.sh` が置く）。

## 2. 承認をまとめて入れる（推奨）

1. Kiro IDE でこのリポジトリを開き、**チャットを 1 回使ってから Kiro IDE を再起動し、閉じる**（承認の置き場所が作られる）。
   **開いて閉じるだけでは作られないことがある**（初めて Kiro を使う Windows の PC で実測。チャット 1 回と再起動の後に作られた）。
   作られたことは `ls ~/.kiro/workspace-roots` で確かめる（Windows は Git Bash で）。
2. ターミナルで次を走らせる（Kiro のエージェントからは走らせられない）。

   ```bash
   bash spec-extraction/03-audit/kiro-ide-allow.sh
   ```

   **Windows では Git Bash で走らせる（WSL の bash では動かない）。** このスクリプトだけの例外で、`gates.sh` などは `init.sh` を走らせた bash で使う（`HOST.md` §2）。Windows 版の Kiro IDE は承認を
   Windows 側のホーム（`%USERPROFILE%\.kiro\workspace-roots\`）に置くが、WSL の bash ではホームが
   `/home/<ユーザー>` になるため、`承認の置き場所が無い: /home/<ユーザー>/.kiro/workspace-roots` で止まる
   （**一度開いていても出る**。実測）。`KIRO_HOME=/mnt/<ドライブ>/…/.kiro` で場所を渡しても、承認の記録
   （`.trust-migration.json` の `root`）が `d:\…` の形なので WSL では照合できず、`このリポジトリ（…）の承認の置き場所が見つからない`
   で止まるはずである（**未実測**。スクリプトの照合の仕組みからの推論）。Git Bash ならホームも `d:\…` の形のパスもそのまま扱える（実測）。
   PowerShell からは次のように呼べる（`bash.exe` の場所は環境に合わせる。PowerShell の `bash` は WSL を指すことがある）:

   ```powershell
   cd <仕様リポジトリ>
   & "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe" spec-extraction/03-audit/kiro-ide-allow.sh   # ユーザー単位で入れた Git
   & "C:\Program Files\Git\bin\bash.exe" spec-extraction/03-audit/kiro-ide-allow.sh             # 全ユーザーに入れた Git
   ```

   `書いた: …/workspace-roots/<hash>/permissions.yaml` と出れば書き込みは済んでいる（ダイアログがどこまで減るかは別に確かめる。§4）。

3. Kiro IDE でもう一度開く。

**受け入れるリスク**: このワークスペースでは、エージェントがほぼどのシェルコマンドも**確認なしで**実行でき、ファイルも読める
（シェル経由なら解析対象の書き換えやネットワークへのアクセスもできる）。ファイル書き込みツールはこのリポジトリの中だけを許す
（解析対象への書き込みはダイアログが出る見込み。**未実測**。**出たら `Deny`**）。

- **対処は「起きたら気づいて戻す」。** `init.sh` が解析対象の全ファイルの中身の指紋を記録しており、
  変わっていれば `gates.sh` の `G-SOURCE-INTACT` が FAIL にする（比べるのはゲートを走らせた時点）。解析対象が git の複製なら `git checkout` で戻せる。
  **git でない解析対象（zip で配ったものなど）は戻す手段が無い**ので、開く前に複製を取っておく。
- 一部のコマンド（`sudo`・`git push`・`git reset --hard`・`git clean`・`rm -rf /`・`rm -rf ~`）は確認が出るようにしてあるが、
  **ベストエフォート**である（`git -C x push`・`/usr/bin/sudo`・`rm -fr ~`・`bash -c '…'` のように書き方を変えると素通りする）。
- 効くのはこのワークスペースだけで、他のプロジェクトには効かない。元に戻すには、スクリプトが残した `permissions.yaml.bak-<日時>` を戻す。
- 検証官（`spec-verifier`）の仕様リポジトリへの読み取りの deny は効く見込み（公式文書の記述では deny がどの allow より強い。この組み合わせの実測は無いが、崩れても確かめのスクリプトの C4 が FAIL にする）。

## 3. それでもダイアログが出たら

| ダイアログ | 押すもの |
|---|---|
| **Read File**（解析対象のパス。ワークスペースの外） | **`Always allow`** → Apply to は **This Session**、Path は原典の中のいちばん上の候補。**`**` と All Workspaces は選ばない**（他のプロジェクトにも効く）。セッションごとに 1 回出ることがある |
| `sudo`・`git push`・`git reset --hard`・`rm -rf /…` | 内容を読んで決める（ふつうは **`Deny`**） |
| **Write File**（解析対象のパス。ワークスペースの外） | **`Deny`**（生成物は仕様リポジトリの中に書く。SB-5） |
| それ以外 | **`Always allow`**（迷ったら。解析対象が変わっても `G-SOURCE-INTACT` で気づける） |

## 4. 確認

```bash
bash spec-extraction/03-audit/gates.sh session
```

承認ダイアログが出ずに完了すれば、セットアップは済んでいる。
