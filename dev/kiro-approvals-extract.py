#!/usr/bin/env python3
"""kiro-approvals-extract.py — Kiro IDE で人が押した承認の記録を作る（開発用。読み取りしかしない）

Kiro IDE は承認のダイアログを **セッション記録** に残す（`messages.jsonl` の pending_interaction と
interaction_resolved）。`Always allow` で保存された規則は **ワークスペースの承認ファイル**
（`~/.kiro/workspace-roots/<hash>/permissions.yaml`）とユーザー全体の `~/.kiro/settings/permissions.yaml` に残る。
両方を 1 つの Markdown にまとめる。

使い方:
  python3 dev/kiro-approvals-extract.py <ワークスペースの絶対パス> [--source <解析対象の絶対パス>] [--out FILE]
    ワークスペースは Kiro で開いたフォルダ（session.json の workspacePaths と完全一致で照合する）。
    --source を付けると、解析対象の git の状態（変更が無いか）も書く。

注意: 1 つのコマンド列（`a; b | c`）は Kiro が部分ごとに承認を求める（consentRound）。記録には
**どの部分を聞かれたかが残らない**ので、ダイアログの行には列全体を出す。`Always allow` で
実際に保存された規則は「保存された規則」の節で見る。
"""
import argparse
import datetime
import glob
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
CHOICE = {"accept": "Allow", "always-accept": "Always allow", "reject": "Deny", "always-reject": "Always deny"}


def jst(ts):
    try:
        t = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
        return (t + datetime.timedelta(hours=9)).strftime("%m-%d %H:%M:%S")
    except ValueError:
        return ts


def sessions(ws):
    out = []
    for sj in glob.glob(os.path.join(HOME, ".kiro", "sessions", "*", "sess_*", "session.json")):
        try:
            meta = json.load(open(sj, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if ws in (meta.get("workspacePaths") or []):
            out.append((meta.get("createdAt") or "", os.path.dirname(sj), meta.get("id")))
    return sorted(out)


def dialogs(sdir):
    pend, rows = {}, []
    for line in open(os.path.join(sdir, "messages.jsonl"), encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        p = r.get("payload") or {}
        t = p.get("type")
        key = (p.get("toolCallId"), p.get("consentRound"))
        if t == "pending_interaction":
            pend[key] = (r.get("timestamp", ""), p.get("question") or "")
        elif t == "interaction_resolved":
            ts, q = pend.pop(key, (r.get("timestamp", ""), "?"))
            rows.append((ts, q, p.get("consentRound"), CHOICE.get(p.get("selectedOption"), p.get("selectedOption") or p.get("outcome"))))
    for (tid, rnd), (ts, q) in pend.items():
        rows.append((ts, q, rnd, "（未回答・待機中）"))
    return sorted(rows)


def kind(q):
    if q == "Read File":
        return "Read File"
    if q.startswith("Sub-agent:"):
        return "Sub-agent"
    return "Run Command"


def cell(s):
    return s.replace("|", "\\|").replace("\n", " ⏎ ")


def workspace_rules(ws):
    for d in glob.glob(os.path.join(HOME, ".kiro", "workspace-roots", "*")):
        try:
            if json.load(open(os.path.join(d, ".trust-migration.json"), encoding="utf-8")).get("root") == ws:
                f = os.path.join(d, "permissions.yaml")
                return f, (open(f, encoding="utf-8").read() if os.path.exists(f) else "（ファイルなし）")
        except (OSError, ValueError):
            continue
    return None, "（このワークスペースの承認の保存先が見つからない）"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace")
    ap.add_argument("--source", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    ws = os.path.abspath(a.workspace)
    L = [f"# Kiro IDE の承認の記録 — {ws.replace(HOME, '~')}", "",
         f"作成: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}（`dev/kiro-approvals-extract.py` が Kiro のセッション記録と承認ファイルから作った。手で編集しない）", ""]
    total = {}
    for created, sdir, sid in sessions(ws):
        rows = dialogs(sdir)
        L += [f"## セッション {sid}（開始 {jst(created)} JST）", ""]
        if not rows:
            L += ["ダイアログなし", ""]
            continue
        L += ["| 時刻（JST） | 種類 | 内容（コマンド列は全体。部分ごとに聞かれる） | 部分 | 押したもの |", "|---|---|---|--:|---|"]
        for ts, q, rnd, ch in rows:
            k = kind(q)
            total[(k, ch)] = total.get((k, ch), 0) + 1
            L.append(f"| {jst(ts)} | {k} | `{cell(q)}` | {rnd} | {ch} |")
        L.append("")
    L += ["## 集計", "", "| 種類 | 押したもの | 回数 |", "|---|---|--:|"]
    L += [f"| {k} | {ch} | {n} |" for (k, ch), n in sorted(total.items())] or ["| — | — | 0 |"]
    f, body = workspace_rules(ws)
    L += ["", "## 保存された規則（`Always allow` の結果）", "",
          f"ワークスペース（`{(f or '?').replace(HOME, '~')}`）:", "", "```yaml", body.rstrip(), "```", "",
          "Read File の This Session の許可は保存されない（セッションの間だけ有効）。", ""]
    up = os.path.join(HOME, ".kiro", "settings", "permissions.yaml")
    if os.path.exists(up):
        hits = [l.rstrip() for l in open(up, encoding="utf-8") if "_measure" in l or "r5-run" in l]
        L += ["ユーザー全体（`~/.kiro/settings/permissions.yaml`）のうち測定の置き場所を指す行: " + ("なし" if not hits else ""), ""]
        if hits:
            L += ["```", *hits, "```", ""]
    if a.source:
        def git(*args):
            return subprocess.run(["git", "-C", a.source, *args], capture_output=True, text=True).stdout.strip()
        st = git("status", "--porcelain")
        L += ["## 解析対象の状態（SB-5: 解析対象を変更しない）", "",
              f"- HEAD: `{git('rev-parse', 'HEAD')}`",
              f"- 未コミットの変更: {'**あり**' if st else 'なし'}", ""]
        if st:
            L += ["```", st, "```", ""]
    text = "\n".join(L) + "\n"
    if a.out:
        open(a.out, "w", encoding="utf-8").write(text)
        print(f"書いた: {a.out}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
