# Playbook: `<domain-name>`

<!--
Playbook = 特定の技術スタックに固有の知識を汎用フローから分離した層（GP-105）。
新規作成手順は `docs/authoring-playbook.md` を参照。
このディレクトリを `playbooks/<domain-name>/` にコピーして各ファイルを埋める。
-->

## 対象スタック

- `<言語・フレームワーク・永続化方式・UI 方式を具体的に。例: Java 11 / Jakarta EE / JAX-RS / JPA アノテーション>`

## 適用判定（この Playbook を選ぶべきか）

<!-- 機械的に判定できる形で書く。「〜のような」ではなく実行可能なコマンドで。 -->

```bash
# 例: 以下が 1 件以上ヒットすればこの Playbook が該当
grep -rl '<目印>' <source> --include='<拡張子>' | head
```

- ✅ 該当: `<条件>`
- ❌ 非該当: `<条件。別の Playbook を使うべきケースを名指しする>`

## 構成（init.sh が配置する先）

| ファイル | 役割 | プロジェクトへのコピー先 |
|---------|------|----------------------|
| `enumeration.md` | **最重要。** ノード種別ごとの独立ソース・全走査コマンド・分母突合の等式（GP-105, SB-2 ルール8） | `01-code-graph/enumeration.md` |
| `practices.md` | ドメイン知見（`DP-<domain>-N`）。このスタックで密度が落ちる箇所・静的読解が効かない箇所 | `docs/knowledge/practices.md` |
| `spec-appendix.md` | 29148 章立てへのドメイン固有の追補 | `../specs/_appendix-<domain>.md` |
| `gate-snippets.sh` | `gates.sh` から呼ぶドメイン別の列挙コマンド | `03-audit/gate-snippets.sh` |

## 利用者が明示的に判断すべき項目（このスタック固有）

<!--
Playbook が自動では決めない項目。プロジェクト開始時に目を通し、暗黙のままにしない。
多くは Phase 0 で ADR として記録される。
-->

- `<例: 自動生成コードを分母に含めるか（含めない場合は生成元を仕様化対象にするか）>`
- `<例: フレームワーク既定値に依存している箇所を仕様に書くか（書く場合は一次情報の確認方法）>`



