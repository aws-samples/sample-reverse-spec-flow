#!/bin/bash
# _resolve.sh — ホストアダプタの解決（GP-107）
#
# 【なぜ切り出すか】解決を使う側が 2 つある（`init.sh` の新規生成と `apply-host.sh` の後付け適用）。
# 2 箇所に書くと必ずずれる——片方だけが外部パスを許したり、片方だけが必須ファイルを検査したりする
# （進捗状態の正本を 1 つに決める GP-101 と同じ理由）。**解決の正本はこのファイルである。**
#
# 【呼ばれ方】source する。次を設定済みで渡すこと:
#   HOSTS_DIR  本体の hosts/ ディレクトリ
#   HOST_ARG   --host の値（空なら既定の claude-code に倒す）
# 次を設定して返す:
#   HOST_DIR HOST_NAME HOST_LEVEL
#
# 【crlf_guard】定義済みなら呼ぶ（`init.sh` は持つ・`apply-host.sh` は持たない）。
#   外部 harness の CRLF をそのまま生成先へ入れないため。
#
# 【既定は claude-code】省略時の挙動を従来と同一に保つ（既存利用者の出力が変わらない）。

HOST_ARG="${HOST_ARG:-claude-code}"
if [ -d "$HOSTS_DIR/$HOST_ARG" ]; then
  HOST_DIR="$HOSTS_DIR/$HOST_ARG"
elif [ -d "$HOST_ARG" ]; then
  HOST_DIR="$(cd "$HOST_ARG" && pwd)"   # リポジトリ外のプライベート harness も許可
else
  echo "Error: ホストが見つかりません: $HOST_ARG" >&2
  # ディレクトリだけを出す（`ls` だと README.md が候補に見えてしまう）
  echo "  利用可能: $(find "$HOSTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '_template' \
    -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')" >&2
  echo "  --list-hosts で対応レベルつきの一覧を表示できます" >&2
  exit 1
fi
HOST_NAME="$(basename "$HOST_DIR")"
if command -v crlf_guard >/dev/null 2>&1; then crlf_guard "$HOST_DIR"; fi
# 必須ファイルの検査。**欠けたまま進むとホスト固有の配置が黙って行われない**
for _hf in placement.sh profile.env entry.md; do
  [ -f "$HOST_DIR/$_hf" ] || {
    echo "Error: ホストに $_hf がありません: $HOST_DIR" >&2
    echo "  placement.sh は配置処理、profile.env は能力宣言、entry.md は生成先の HOST.md の元で、どれも省略できません（GP-107）" >&2
    exit 1; }
done
# 【対応レベルを呼び出し側に渡す】未検証のホストを黙って使わせない（SB-12 の明示格下げと同型）
# 【`|| true` を外さない】呼び出し側は `set -euo pipefail`。SUPPORT_LEVEL の行が無いと grep が 1 を返してパイプが失敗し、
# エラー文なしに初期化が止まっていた（独立レビューで再現）。無ければ空にして、呼び出し側の「不明」の表示に任せる
HOST_LEVEL="$(grep -E '^SUPPORT_LEVEL=' "$HOST_DIR/profile.env" | head -1 | cut -d= -f2 | awk '{print $1}' || true)"
