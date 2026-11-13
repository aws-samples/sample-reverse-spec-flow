#!/bin/bash
# =============================================================================
# kiro-ide-allow.sh — この仕様リポジトリのワークスペースで、承認ダイアログをほぼ出さなくする（人が 1 回走らせる）
# =============================================================================
#
# 使い方:  bash spec-extraction/03-audit/kiro-ide-allow.sh
#   1. Kiro IDE でこのリポジトリを一度開いてから閉じる（ワークスペースの承認ファイルの置き場所が作られる）
#   2. ターミナルでこのスクリプトを走らせる（Kiro のエージェントからは走らせられない。承認ファイルへの書き込みは Kiro が常に拒む）
#   3. Kiro IDE でもう一度開く
#
# 何をするか: ワークスペースの承認ファイル（~/.kiro/workspace-roots/<hash>/permissions.yaml）を下の規則に置き換える。
#   元のファイルは同じ場所に permissions.yaml.bak-<日時> として残す。効くのはこのワークスペースだけで、他のプロジェクトには効かない。
#
# 受け入れるリスク: このワークスペースでは、エージェントがほぼどのシェルコマンドも確認なしで実行でき、ファイルも読める
#   （シェル経由なら解析対象の書き換えやネットワークへのアクセスもできる）。対処は「起きたら気づいて戻す」——
#   init.sh が記録した解析対象の状態と違えば gates.sh の G-SOURCE-INTACT が FAIL にする。解析対象が git の複製なら `git checkout` で戻せる。
#   - ファイル書き込みツール（fs_write）はワークスペース（この仕様リポジトリ）の中だけを許す（`./**`）。外への書き込みはダイアログが出る見込み（未実測。次の試験で見る）。
#   - 下の exclude は**ベストエフォート**である。書き方を変えれば素通りする（`git -C x push`・`/usr/bin/sudo`・`rm -fr ~`・
#     `bash -c '...'` など）。「これだけは必ず止まる」とは読まない。
#   - 検証官（spec-verifier）の仕様リポジトリへの deny は効く見込み（公式文書では deny がどの allow より強い。この組み合わせの実測は無く、
#     崩れても kiro-ide-verify-check.sh の C4 が FAIL にする）。
#
# 元に戻す: 上の .bak-<日時> を permissions.yaml に戻す（Kiro IDE を閉じてから）。
# =============================================================================
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
spec_root=$(cd "$here/../.." && pwd -P)
store_root="${KIRO_HOME:-$HOME/.kiro}/workspace-roots"

[ -d "$store_root" ] || { echo "承認の置き場所が無い: ${store_root}（Kiro IDE でこのリポジトリを開き、チャットを 1 回使ってから再起動して閉じた後に走らせる。HOST-SETUP.md §2）" >&2; exit 2; }
dir=""
for d in "$store_root"/*/; do
  f="$d.trust-migration.json"
  [ -f "$f" ] || continue
  # "root": "<パス>" を読む（パスに " は含まれない前提。含まれたら一致しないので止まる）
  r=$(sed -n 's/^[[:space:]]*"root":[[:space:]]*"\(.*\)",*[[:space:]]*$/\1/p' "$f" | head -1)
  [ -n "$r" ] && [ -d "$r" ] && [ "$(cd "$r" && pwd -P)" = "$spec_root" ] && { dir=${d%/}; break; }
done
[ -n "$dir" ] || { echo "このリポジトリ（${spec_root}）の承認の置き場所が見つからない（Kiro IDE でこのリポジトリを開き、チャットを 1 回使ってから再起動して閉じた後に走らせる。HOST-SETUP.md §2）" >&2; exit 2; }

target="$dir/permissions.yaml"
if [ -f "$target" ]; then
  bak="$target.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$target" "$bak" || { echo "元のファイルを残せない: $bak" >&2; exit 2; }
  echo "元のファイルを残した: $bak"
fi
umask 077
cat > "$target" <<'YAML'
# reverse-spec-flow の kiro-ide-allow.sh が書いた（承認ダイアログをほぼ出さなくする。HOST-SETUP.md）
rules:
  - capability: shell
    effect: allow
    match: ["*"]
    exclude: ["sudo *", "git push*", "git reset --hard*", "git clean*", "rm -rf /*", "rm -rf ~*"]
  - capability: fs_read
    effect: allow
  - capability: fs_write
    effect: allow
    match: ["./**"]
  - capability: skill
    effect: allow
    match: ["density-verify", "spec-adversarial-audit"]
  - capability: subagent
    effect: allow
    match: ["spec-verifier"]
YAML
echo "書いた: $target"
echo "Kiro IDE でこのリポジトリを開き直すと効く（開いたまま書き換えた場合も、開き直す）。"
