#!/bin/bash
# placement.sh — Kiro IDE 向けの配置（GP-107 ルール1）
#
# ホスト固有パス（`.kiro/`）を知ってよいのはこの層だけである。
set -euo pipefail

# --- 入口への導線 ---
# このホストは **ルート `AGENTS.md` を直接拾う**（A-2a）ので、ベンダ固有の入口ファイルは置かない。
# `CLAUDE.md` は注入されないので置いても無駄である。

# --- skill ---
# 【`.claude/skills/` は黙って無視される（A-3-1）】提示された skill 集合と `~/.kiro/skills` が
# 完全一致したことで確認した。したがって `.kiro/skills/` に置き直す必要がある。
# 【配置はセッションを開く前（A-3-2 / A-3-5）】提示一覧は**セッション開始時のスナップショット**で、
# セッション中に置いたものは一覧に載らない。`init.sh` の時点で置くのでこの条件は満たされる。
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$SPEC_REPO/.kiro/skills"
  cp -R "$SKILLS_SRC/." "$SPEC_REPO/.kiro/skills/"
  echo "  placed   : .kiro/skills/（$(find "$SKILLS_SRC" -name 'SKILL.md' | wc -l | tr -d ' ') 件）"
fi

# --- 検証官の隔離（GP-16 ルール2。設計は dev/kiro-ide-verifier-isolation.md）---
# 【防ぐ】カスタムエージェント spec-verifier（tools: read）で、仕様リポジトリへの読み取りを deny する（経路 3）。
# 拒否されても入れ子 AGENTS.md は注入される（Phase B の B-2）ので、**これだけでは隔離にならない**。
# 【確かめる】kiro-ide-verify-check.sh がセッション記録で C1〜C5 を確かめ、合格した結果だけを採用させる（entry.md §5）。
# deny は**ワークスペース基点の相対パスだけ**で書く（直下の項目ごとに `<名前>` と `<名前>/**`、加えて `**/AGENTS.md`）。
# 【絶対パスを書かない（2026-10-22 決定）】仕様リポジトリはコピーして持ち運ぶ前提なので、定義にマシンのパスを焼き込まない。
# 相対の規則が実際に当たるかは V-4 で測る。**当たらなくても漏れはしない**: 読めた・注入された記録が残り、
# 確かめが FAIL にする（fail-closed）。配置の後に増えた直下の項目も deny されないが、読めば C3 で FAIL になる。
# 【`**/specs/**` 形を使わない】Phase B で効いた形だが、解析対象ソースの中の specs/ まで拒否してしまう。
_pats="\"**/AGENTS.md\""
_seen="|"
for _e in AGENTS.md HOST.md HOST-SETUP.md specs spec-extraction .kiro .git "$SPEC_REPO"/* "$SPEC_REPO"/.[!.]*; do
  _e=$(basename "$_e")
  case "$_e" in '*'|'.[!.]*') continue ;; *'"'*|*'\'*|*'|'*) continue ;; esac
  case "$_seen" in *"|$_e|"*) continue ;; esac
  _seen="$_seen$_e|"
  _pats="$_pats, \"$_e\", \"$_e/**\""
done
mkdir -p "$SPEC_REPO/.kiro/agents"
# 置換は文字列の切り貼りで行う（sed や ${//} は & / を特別扱いしうる）
while IFS= read -r _l || [ -n "$_l" ]; do
  case "$_l" in
    *__SPEC_REPO_DENY__*) printf '%s%s%s\n' "${_l%%__SPEC_REPO_DENY__*}" "$_pats" "${_l#*__SPEC_REPO_DENY__}" ;;
    *) printf '%s\n' "$_l" ;;
  esac
done < "$HOST_DIR/agents/spec-verifier.md" > "$SPEC_REPO/.kiro/agents/spec-verifier.md"
echo "  placed   : .kiro/agents/spec-verifier.md（検証官。仕様リポジトリへの読み取りを deny）"
cp "$HOST_DIR/kiro-ide-verify-check.sh" "$WROOT/03-audit/kiro-ide-verify-check.sh"
chmod +x "$WROOT/03-audit/kiro-ide-verify-check.sh"
echo "  placed   : spec-extraction/03-audit/kiro-ide-verify-check.sh（検証官の隔離をセッション記録で確かめる）"
# 【承認をまとめて入れるスクリプト】承認ファイルはリポジトリの外にあり、リポジトリからは入れられない（Kiro の設計）。
# 人が HOST-SETUP.md を読んで 1 回走らせる（完走試験で、承認ダイアログが長時間の作業を止めると分かった）。
cp "$HOST_DIR/kiro-ide-allow.sh" "$WROOT/03-audit/kiro-ide-allow.sh"
chmod +x "$WROOT/03-audit/kiro-ide-allow.sh"
echo "  placed   : spec-extraction/03-audit/kiro-ide-allow.sh（承認をまとめて入れる。人が 1 回走らせる）"

# --- セットアップ手順（setup.md → HOST-SETUP.md）は共通部分（hosts/_place-common.sh）が置く ---
# 承認の恒久化はリポジトリ外（`~/.kiro/workspace-roots/<hash>/permissions.yaml`）に残るので
# `gates.sh` から検査できない。**人が開く前に読む手順**として生成先に置かれる（この harness は setup.md を持つ）。
