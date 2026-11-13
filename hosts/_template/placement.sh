#!/bin/bash
# placement.sh — <ホスト名> 向けの配置処理（GP-107 ルール1）
#
# 【この層の意味】**ホスト名・ホスト固有パスを知ってよい唯一のコード**である。
# `init.sh` 本体と汎用テンプレートにホスト固有の分岐を書かない。
#
# 【呼ばれ方】`init.sh` が `git add -A` の前に 1 回だけ source する。
#   次の変数が設定済みで渡る（読み取りのみ。書き換えない）:
#     FW_DIR      フレームワーク本体のルート（init.sh の所在）
#     HOST_DIR    この harness のディレクトリ（= このファイルの所在）
#     SPEC_REPO   生成先リポジトリのルート
#     WROOT       作業アセットのルート（$SPEC_REPO/spec-extraction）
#     SKILLS_SRC  本体の skills/ ディレクトリ（存在しない場合もある）
#
# 【規律】
#   - 解析対象ソースに触らない（SB-5）。
#   - 置いたものは `init.sh` の初期コミットに含まれる。**追跡されない場所に置かない**
#     （実運用で、無視された入口文書が引き継がれず入口が死んだ）。
#   - 置いたファイルは 1 行ずつ `echo` で報告する（何が置かれたか記録に残る）。
set -euo pipefail

# --- 入口文書（ホスト固有のものがあれば）---
# 例: ベンダ固有の入口ファイルを置く
#   cp "$HOST_DIR/root-VENDOR.md.template" "$SPEC_REPO/VENDOR.md"
#   echo "  placed   : VENDOR.md（入口への導線）"

# --- skill（ホストの機構が native に読む場所へ）---
# 例:
#   if [ -d "$SKILLS_SRC" ]; then
#     mkdir -p "$SPEC_REPO/.vendor/skills"
#     cp -R "$SKILLS_SRC/." "$SPEC_REPO/.vendor/skills/"
#     echo "  placed   : .vendor/skills/（skill 2 件）"
#   fi

# --- 何も置かないホストなら、そう宣言する（空ファイルにしない）---
echo "  placed   : （ホスト固有の配置はなし）"
