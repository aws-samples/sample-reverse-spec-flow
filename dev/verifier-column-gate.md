# 設計: 台帳の `verifier` 欄をゲートで見る（本体の不整合 #2）

**状態**: **L1 ＋ L2 を実装済み**（2026-10-22。ユーザー判断「L1+L2、なるべくシンプルに」）。L3 は**やめる**（2026-10-23 ユーザー判断。ガードレールを足し続けず、起きたら対処する方針。`host-adapter-plan.md` の Phase F の項）。`fresh-context` は弱い側として件数を開示する。
**出所**: [host-adapter-plan.md](host-adapter-plan.md) §8 の #2。

## 1. 何が足りないか

`GP-16` ルール2 は「隔離が働いたことを機械の記録で確認できた結果だけを採用する。手段が無いホストでは台帳に明示格下げを残す」と
要求し、台帳の `verifier` 欄（`subagent-isolated | prompt-isolated | fresh-context | human`）がその記録の場所である。
**ところが `templates/gates.sh` にこの欄を読むゲートが 1 つも無い**（`verifier` の出現 0 件。`verified_at` も同じ）。
記録はできるが、何を書いても検出しない。

### 実データ（`_measure/` の 8 リポジトリの台帳）

| リポジトリ | `verified` 行の `verifier` | 読み方 |
|---|---|---|
| roller-r2 / r3 / r4 | `subagent-isolated` 2,061 / 1,263 / 1,424 | 語彙どおり。**ただし隔離の機械的手段（hook のカナリア）が入る前の実行**で、`verify-log/` に `guard-canary.tsv` は無い＝**機械の根拠なしに書かれた値** |
| roller-r1 | `subagent-isolated` 578、**`v2-agent2` 40** | **語彙外**が素通り |
| roller-spec | **`fresh-context-same-session` 29** | **語彙外**。しかも中身は `SB-12` が「独立性を満たさない」と明記した**同一セッションの切り直し** |
| roller-e2 | `fresh-context` 32 | 語彙内。ただし `fresh-context` の定義が無い（不整合 #1） |

## 2. 案（3 段。下の段ほど強く、費用も大きい）

| 段 | 何を見るか | 変える場所 | 既存リポジトリへの影響 |
|---|---|---|---|
| **L1 語彙** | `verify_status` が `verified` / `repairing` の行の `verifier` が語彙内か。`unverified` / `verifying` の行は `-` を許す | `gates.sh` に `G-VERIFIER` を足す | r1・roller-spec が落ちる（**正しく落ちる**）。r2〜r4 は通る |
| **L2 開示** | `verified` 行のうち `subagent-isolated` 以外の件数を、`rebuild-readiness.md` の新しい欄に**台帳と同じ数で**書いたか（扱い β を core の規則にする） | `G-VERIFIER` ＋ 雛形 `rebuild-readiness.md.template` に 1 欄 | 新しい欄を持たない既存の `rebuild-readiness.md` は未記入になる（purpose=rebuild のときだけ） |
| **L3 証跡** | `subagent-isolated` の行ごとに、隔離を確かめた**機械の記録**がリポジトリの中にあるか（ホスト中立の書式 `verify-log/isolation-evidence.tsv` を各 harness の手段が書く） | `G-VERIFIER` ＋ **3 つの harness**（CC の hook・kiro-cli の `kiro-verify.sh`・kiro-ide の確かめ）＋ 書式の規約 | 既存の全リポジトリが落ちる（記録が無い）→ 移行措置が要る。kiro-cli は共同開発者の担当 |

- **ゲートはホストを知らない**（`GP-107` ルール4）。L3 でも、ゲートが見るのはリポジトリの中の TSV だけで、ホストの記録（`~/.kiro/sessions/` 等）は読まない。
  「ホストに依存する運用値は、ゲートが見る成果物に記入された内容として現れさせる」（`GP-107` ルール4 の後段）の形そのものになる。
- 判定の強さ（実装）: `DENSITY_GATES=on` で L1 の語彙外は **FAIL**（記録の誤り）、L2 の欄の不在・数の食い違いはどちらも **INCOMPLETE**
  （簡素にするため 1 種にまとめた）。`warn` では WARN、`off` では走らせない（`run_density` の `on|warn` に置く）。
  L2 は `REBUILD_LAYER=full`（purpose=rebuild）のときだけ見る。弱い verified が 0 件なら欄は要求しない（既存の宣言を壊さない）。

## 3. 推奨

**L1 ＋ L2 を今やり、L3 は別の作業にする。**

- L1・L2 は core だけで閉じ、harness に触らない。実データで既に 2 リポジトリの語彙外を捕まえる。
- L3 は 3 つの harness の書き込み口と書式の規約を同時に決める必要があり、kiro-cli は共同開発者の担当なので、相談してから決める。
  L3 が無い間は、`subagent-isolated` が機械の根拠に支えられているかは **各 harness の手順（`HOST.md` §5）の規律**のままである（今と同じ）。

## 4. 決めてほしいこと

1. **範囲**: L1 ＋ L2（推奨）／ L1 だけ／ L3 まで。
2. **`fresh-context` の扱い**（不整合 #1 と絡む）: L2 の開示では `subagent-isolated` 以外を数えるので、`fresh-context` は**弱い側として件数を開示する**
   扱いを推奨する（定義そのものは #1 で決める。ここでは決めない）。

## 5. 変える場所（L1 ＋ L2 の場合）

| 場所 | 変更 |
|---|---|
| `templates/gates.sh` | `gate_verifier_column`（`G-VERIFIER`）。列は**見出しの名前で探す**（既存ゲートは位置で読むが、この欄は後から足された列なので位置を決め打ちしない）。`run_density` の `on|warn` に登録 |
| `templates/rebuild-readiness.md.template` | `- **検証手段の内訳（台帳の verifier 列。SB-12）**: subagent-isolated <N> / prompt-isolated <N> / fresh-context <N> / human <N>` の欄 |
| `templates/density-ledger.tsv` | `verifier` の説明に「`verified` / `repairing` の行は必須。語彙外は G-VERIFIER が落とす」を足す |
| `pipeline.md` | `GP-16` ルール2 の後段に、台帳の値をゲートが見ることと開示の要求を 1 文。ゲートの追加履歴の表 |
| `templates/pipeline-procedure.md.template` / `docs/how-it-works.md` | ゲートの一覧に 1 行 |
| `hosts/kiro-ide/entry.md` §5 | 縮退（β）の「完了宣言に書き写す」を、新しい欄を指す形に直す |
| `selftest.sh` | 語彙外・`-`・開示の欠落・数の食い違い・正当な場合の注入。既存のフィクスチャの `verifier=p` を語彙内に直す |
