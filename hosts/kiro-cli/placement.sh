#!/bin/bash
# placement.sh — Kiro CLI 向けの配置（GP-107 ルール1）
#
# ホスト固有パス（`.kiro/`）と kiro-cli の起動方法を知ってよいのはこの層だけである。
# 【IDE とは別の harness】Kiro IDE（`hosts/kiro-ide/`）とは別製品で、実測を流用しない（GP-107 ルール2）。
set -euo pipefail

# --- 入口への導線 ---
# ルートの AGENTS.md を起動時に注入するので、ベンダ固有の入口ファイルは置かない。
# 【.kiro/steering/ を作らない】V3 は起動時に steering を注入する。規範は AGENTS.md に一本化し、
# 生成物が steering 経由で検証官に入る経路（MEASURED.md 項目 1）を構造的に無くす。

# --- skill ---
# 【.kiro/skills/ に置く】V3 は .claude/skills/ を読まない。V2 は .kiro/skills/ も読む（MEASURED.md 項目 2）。
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$SPEC_REPO/.kiro/skills"
  cp -R "$SKILLS_SRC/." "$SPEC_REPO/.kiro/skills/"
  echo "  placed   : .kiro/skills/（$(find "$SKILLS_SRC" -name 'SKILL.md' | wc -l | tr -d ' ') 件）"
fi

# --- 検証官の隔離（GP-16 ルール2）---
# サブエージェントでは隔離を強制できない（入れ子 AGENTS.md の注入・deny がワークスペースの外に効かない）ので、
# **解析対象ソースをワークスペースにした別セッション**で検証官を起動するスクリプトを置く（entry.md §5）。
# hook と同じく gate-config.env の SOURCE_PATH を読むので、置き場所は spec-extraction/03-audit/ に固定する。
cp "$HOST_DIR/kiro-verify.sh" "$WROOT/03-audit/kiro-verify.sh"
chmod +x "$WROOT/03-audit/kiro-verify.sh"
echo "  placed   : spec-extraction/03-audit/kiro-verify.sh（検証官の隔離）"
