#!/usr/bin/env python3
"""kiro-session-extract.py — Kiro IDE のセッション記録から測定結果を抜き出す（開発用）

Kiro IDE は会話を ~/.kiro/sessions/<ワークスペースのハッシュ>/<セッション ID>/ に自動で書く。
  messages.jsonl          メインの会話（発話・ツール呼び出しと結果・承認ダイアログ・注入された文書）
  sub-executions/*.jsonl  サブエージェントごとの会話（ファイル名 = sub_agent_start の subSessionId）

この記録は人がコピーした回答より強い。とくに steering_inclusion イベントは
**そのセッションに実際に注入された文書の一覧**で、モデルの自己申告ではない。

使い方:
  python3 dev/kiro-session-extract.py <ワークスペースの絶対パス> [--since 2026-10-22T00:00] [--out DIR]
    ワークスペースのパスは Kiro で開いたフォルダ（session.json の workspacePaths と完全一致で照合する）。
    --since はセッションの作成時刻（UTC）で絞る。--out を付けるとセッションごとの詳細を Markdown で書く。

依存は Python 3 の標準ライブラリだけ。読み取りしかしない。
"""
import argparse
import glob
import json
import os
import re
import sys

TOKEN = re.compile(r"KIROPROBE-[A-Z0-9-]+")
HOME = os.path.expanduser("~")

# 依頼文の目印 → 測定セッションの名前（dev/phase-b-instructions.md §4 の文面に含まれる語。同ファイルは e18ef00 時点にあり、削除済み）
MARKERS = [
    ("S4", "run-s4.sh"),
    ("S3", "10 の操作"),
    ("S2", "8 つの操作"),
    ("S1", "kp-steer-target"),
]


def load(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def short(p):
    return str(p).replace("file://", "").replace(HOME, "~")


def doc_name(d):
    if isinstance(d, dict):
        return short(d.get("id") or d.get("displayName") or "?")
    return short(d)


def doc_tokens(d):
    """注入された文書に含まれるトークン。

    記録に中身があればそれを使う（昇格した入れ子 AGENTS.md などは中身つきで記録される）。
    **パスしか無いとき**（セッション開始時の注入はこの形）は**ディスクのファイルを読み**、
    トークンの後ろに * を付けて区別する——記録の時点の中身ではなく、いまの中身だからである。
    測定中にファイルを書き換えない前提なら一致する。
    """
    if isinstance(d, dict) and d.get("content"):
        return sorted(set(TOKEN.findall(d.get("content") or "")))
    path = d.get("id") if isinstance(d, dict) else d
    path = str(path or "").replace("file://", "")
    try:
        with open(path, encoding="utf-8") as f:
            return [t + "*" for t in sorted(set(TOKEN.findall(f.read())))]
    except OSError:
        return []


def text_of(v):
    if isinstance(v, str):
        return v
    return json.dumps(v, ensure_ascii=False)


def norm(s):
    return re.sub(r"\s+", "", s or "")


def wrapped_prompt(user_text):
    """D-WRAP の 2 本の線（-----）の間の文を取り出す。無ければ None"""
    m = re.search(r"^-----\s*$(.*?)^-----\s*$", user_text or "", re.S | re.M)
    return m.group(1).strip() if m else None


def tool_line(p):
    a = p.get("args") or {}
    key = a.get("path") or a.get("command") or a.get("query") or a.get("targetFile") or ""
    extra = a.get("includePattern")
    s = f"`{p.get('toolName')}` {short(key)}"
    if extra:
        s += f" (includePattern={extra})"
    return s + f" → {p.get('status')}"


def find_sessions(workspace, since):
    out = []
    for sj in glob.glob(os.path.join(HOME, ".kiro", "sessions", "*", "sess_*", "session.json")):
        try:
            with open(sj, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError):
            continue
        if workspace not in (meta.get("workspacePaths") or []):
            continue
        if since and (meta.get("createdAt") or "") < since:
            continue
        out.append((meta.get("createdAt") or "", os.path.dirname(sj), meta))
    return sorted(out)


def classify(users, workspace):
    if workspace.rstrip("/").endswith("/specs"):
        return "S5"
    joined = "\n".join(users)
    for name, mark in MARKERS:
        if mark in joined:
            return name
    return "未分類"


def summarize_sub(sdir, sub_id):
    path = os.path.join(sdir, "sub-executions", sub_id + ".jsonl")
    if not os.path.exists(path):
        return {"missing": True}
    rows = load(path)
    inc, tools, results = [], [], {}
    for r in rows:
        p = r["payload"]
        t = p.get("type")
        if t == "steering_inclusion":
            for d in p.get("documents", []):
                inc.append((doc_name(d), doc_tokens(d)))
        elif t == "tool_call":
            tools.append(p)
        elif t == "tool_result":
            results[p.get("toolCallId")] = text_of(p.get("content"))[:200]
    return {"inclusion": inc, "tools": tools, "results": results}


def analyze(sdir):
    rows = load(os.path.join(sdir, "messages.jsonl"))
    turns, cur = [], None
    pending = {}
    for r in rows:
        p, ts = r["payload"], r.get("timestamp", "")
        t = p.get("type")
        if t == "user":
            cur = {"ts": ts, "user": text_of(p.get("content")), "inclusion": [], "tools": [],
                   "dialogs": [], "subs": [], "assistant": []}
            turns.append(cur)
            continue
        if cur is None:
            continue
        if t == "steering_inclusion":
            cur["inclusion"].append([(doc_name(d), doc_tokens(d)) for d in p.get("documents", [])])
        elif t == "tool_call":
            cur["tools"].append(p)
        elif t == "pending_interaction":
            pending[p.get("toolCallId")] = p.get("question")
        elif t == "interaction_resolved":
            cur["dialogs"].append((pending.get(p.get("toolCallId"), "?"), p.get("selectedOption") or p.get("outcome")))
        elif t == "sub_agent_start":
            cur["subs"].append({"name": p.get("subAgentName"), "id": p.get("subSessionId"),
                                "prompt": p.get("prompt") or "", "response": None})
        elif t == "sub_agent_complete":
            for s in cur["subs"]:
                if s["id"] == p.get("subSessionId"):
                    s["response"] = p.get("response") or ""
        elif t == "assistant":
            c = p.get("content")
            if isinstance(c, str) and c.strip():
                cur["assistant"].append(c)
    return turns


def render(meta, sdir, turns, label):
    sid = meta.get("id", os.path.basename(sdir))
    L = [f"# {label} — {sid}", "",
         f"- 作成: {meta.get('createdAt')} / 最終更新: {meta.get('lastModifiedAt')}",
         f"- ワークスペース: {short(', '.join(meta.get('workspacePaths') or []))}",
         f"- 記録: {short(sdir)}", ""]
    for i, t in enumerate(turns, 1):
        L += [f"## T{i:02d} — {t['ts']}", "", "**送った文**（先頭 200 字）:", "", "> " + t["user"][:200].replace("\n", "\n> "), ""]
        for j, inc in enumerate(t["inclusion"], 1):
            L.append(f"**注入された文書（steering_inclusion #{j}）**:")
            for name, toks in inc:
                L.append(f"- {name}" + (f" — {', '.join(toks)}" if toks else ""))
            L.append("")
        if t["tools"]:
            L.append("**メインのツール呼び出し**:")
            L += [f"- {tool_line(p)}" for p in t["tools"]]
            L.append("")
        if t["dialogs"]:
            L.append("**承認ダイアログ**:")
            L += [f"- {q} → {o}" for q, o in t["dialogs"]]
            L.append("")
        wp = wrapped_prompt(t["user"])
        for s in t["subs"]:
            same = "—" if wp is None else ("**一致**" if norm(wp) == norm(s["prompt"]) else "**不一致**")
            L += [f"### サブエージェント `{s['name']}`（{s['id']}）", "",
                  f"- 依頼文が D-WRAP の線の間と一致するか: {same}"]
            sub = summarize_sub(sdir, s["id"] or "")
            if sub.get("missing"):
                L.append("- 記録ファイルが無い")
            else:
                L.append("- 注入された文書:")
                L += [f"  - {n}" + (f" — {', '.join(tk)}" if tk else "") for n, tk in sub["inclusion"]] or ["  - なし"]
                L.append("- ツール呼び出し:")
                L += [f"  - {tool_line(p)}" + (f" ／ 結果: {sub['results'].get(p.get('toolCallId'), '')[:120]}" if p.get("status") not in ("completed", "approved") else "")
                      for p in sub["tools"]] or ["  - なし"]
            L += ["", "**回答**:", "", "```", (s["response"] or "（未完了）").strip(), "```", ""]
        if t["assistant"]:
            L += ["**メインの最後の発話**:", "", "```", t["assistant"][-1].strip(), "```", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workspace")
    ap.add_argument("--since", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    ws = os.path.abspath(os.path.expanduser(a.workspace))
    sessions = find_sessions(ws, a.since)
    if not sessions:
        print(f"セッションが見つからない: {ws}（--since={a.since or 'なし'}）", file=sys.stderr)
        return 1
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    print(f"| 作成（UTC） | 分類 | セッション | ターン | サブエージェント | 注入トークン（メイン / サブ） |")
    print(f"|---|---|---|--:|--:|---|")
    for created, sdir, meta in sessions:
        turns = analyze(sdir)
        label = classify([t["user"] for t in turns], ws)
        # 要約の表では * を外す（ファイルから読んだかどうかは詳細ファイルで見る）
        mt = sorted({tk.rstrip("*") for t in turns for inc in t["inclusion"] for _, tks in inc for tk in tks})
        st = set()
        for t in turns:
            for s in t["subs"]:
                sub = summarize_sub(sdir, s["id"] or "")
                for _, tks in sub.get("inclusion", []):
                    st.update(tk.rstrip("*") for tk in tks)
        nsub = sum(len(t["subs"]) for t in turns)
        print(f"| {created[:19]} | {label} | {meta.get('id','')[:13]} | {len(turns)} | {nsub} | {' '.join(mt) or '-'} / {' '.join(sorted(st)) or '-'} |")
        if a.out:
            name = f"{label}-{created[:19].replace(':', '')}-{meta.get('id','')[:13]}.md"
            with open(os.path.join(a.out, name), "w", encoding="utf-8") as f:
                f.write(render(meta, sdir, turns, label))
    return 0


if __name__ == "__main__":
    sys.exit(main())
