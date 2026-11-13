#!/bin/bash
# placement.sh — Claude Code 向けの配置（GP-107 ルール1）
#
# ホスト固有パス（`.claude/`）とベンダ固有の入口ファイル名（`CLAUDE.md`）を知ってよいのは
# この層だけである。`init.sh` 本体と汎用テンプレートには書かない。
set -euo pipefail

# --- 入口への導線（`@AGENTS.md` の 1 行だけ）---
# 【なぜ 2 つ要るか（両環境で実測。教訓 38 / entry.md）】
#   ルート直下の AGENTS.md / CLAUDE.md は起動時に自動読込される。ただし両方あるときの扱いは
#   実装と版に依存する: macOS / 2.1.267 は CLAUDE.md を優先し **AGENTS.md を読み込まない**、
#   Windows / 2.1.265 は **両方読み込む**（3/3 で再現）。
#   したがって「入口はベンダ中立な AGENTS.md ／ CLAUDE.md は @AGENTS.md で確定的に読み込ませる」
#   形にする。**`@AGENTS.md` は両環境で 3/3 成功した唯一の形**である。
#   CLAUDE.md を置かないと、環境によっては後から /init 等で作られた時点で入口が無効化される。
# 【既にある中身の違う CLAUDE.md は退避してから置く】apply-host.sh で後から適用すると、/init で作った CLAUDE.md を
# 黙って上書きしていた（古い生成先は .gitignore で CLAUDE.md を無視しており、未コミットの検査でも止まらない。独立レビュー）
if [ -f "$SPEC_REPO/CLAUDE.md" ] && ! cmp -s "$HOST_DIR/root-CLAUDE.md.template" "$SPEC_REPO/CLAUDE.md"; then
  _bak="$SPEC_REPO/CLAUDE.md.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$SPEC_REPO/CLAUDE.md" "$_bak"
  echo "  kept     : 既存の CLAUDE.md を ${_bak##*/} に退避した。中身を確かめ（要るものは AGENTS.md へ移す）、**消す**（未追跡のまま残すと次の apply-host.sh が未コミットの変更で止まり、git add -A で一緒にコミットされやすい）"
  unset _bak
fi
cp "$HOST_DIR/root-CLAUDE.md.template" "$SPEC_REPO/CLAUDE.md"
echo "  placed   : CLAUDE.md（@AGENTS.md の 1 行。入口への導線）"

# --- オプション skill ---
# skill が無くても手順書の段階的縮退で同じ結果に到達できる（＝ツール非依存を保つ）。
# 【他ホストで無視されるとは限らない】Kiro CLI 2.33.0 の V2 エンジンは `.claude/skills/` も読む
# （`hosts/kiro-cli/MEASURED.md`）。skill の本文をホストを知らない書き方に保つのはこのため。
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$SPEC_REPO/.claude/skills"
  cp -R "$SKILLS_SRC/." "$SPEC_REPO/.claude/skills/"
  echo "  placed   : .claude/skills/（$(find "$SKILLS_SRC" -name 'SKILL.md' | wc -l | tr -d ' ') 件）"
fi

# --- 検証官の隔離（GP-16 ルール2）を機械で強制する定義と hook ---
# skill は「読み取りを解析対象ソースの配下に機械で制限する起動手段」を役割で書き、
# その実体（`spec-verifier` と、読み取りを `SOURCE_PATH` の配下に制限する PreToolUse hook）はここで置く。
# 起動方法と隔離の確かめ方は entry.md（生成先では HOST.md）の「検証官の隔離」節が正本。
mkdir -p "$SPEC_REPO/.claude/agents" "$SPEC_REPO/.claude/hooks"
cp "$HOST_DIR/agents/spec-verifier.md" "$SPEC_REPO/.claude/agents/spec-verifier.md"
cp "$HOST_DIR/hooks/verifier-guard.sh" "$SPEC_REPO/.claude/hooks/verifier-guard.sh"
chmod +x "$SPEC_REPO/.claude/hooks/verifier-guard.sh"
echo "  placed   : .claude/agents/spec-verifier.md・.claude/hooks/verifier-guard.sh（検証官の隔離）"
# 隔離の確かめ方（entry.md §5）: 終わった後にセッション記録を 1 回読む。起動ごとの照合はしない
cp "$HOST_DIR/claude-verify-check.sh" "$WROOT/03-audit/claude-verify-check.sh"
chmod +x "$WROOT/03-audit/claude-verify-check.sh"
echo "  placed   : spec-extraction/03-audit/claude-verify-check.sh（検証官の隔離をセッション記録で確かめる）"
