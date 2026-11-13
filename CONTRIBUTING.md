# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.


## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The version of our code being used (the release tag, e.g. `v2.1.0`, or the commit)
* Your environment: OS (macOS / Linux / Windows with WSL or Git Bash), `bash --version`, `grep --version`,
  `awk --version` (or `awk -V`), and the AI coding tool and its version (see `hosts/README.md`)
* The Playbook and `purpose` you used (`spec-extraction/00-ingestion/gate-config.env` of the generated repository)
* The full output of the failing check (`gates.sh` or `selftest.sh`) and its exit code
* Any modifications you've made relevant to the bug

**Do not paste proprietary source code, customer names, or identifiers from your business domain into an issue.**
A minimal, anonymized reproduction is far more useful than a copy of a real project.


## Repository Layout and Conventions

This repository is a **framework**, not an application: `init.sh`, templates, and procedures (bash and Markdown only)
that make an AI coding agent reverse-engineer an existing code base into specifications. Its documentation is
written in **Japanese**; please keep that language when editing existing documents. Issues and pull requests may be
written in Japanese or English.

| Path | Role |
|------|------|
| `init.sh` | Creates a separate spec repository next to the analysis target and places everything below into it |
| `templates/` | Assets copied into generated repositories. `templates/pipeline-procedure.md.template` is the **runtime contract**: the only document an agent follows at run time. `templates/gates.sh` implements the executable checks |
| `pipeline.md` (`GP-N`), `playbook.md` (`SB-N`, `FB-N`) | Reference documents explaining *why* each rule exists |
| `playbooks/<name>/` | Knowledge for one technology stack (how to enumerate entry points, tables, modules). See `docs/authoring-playbook.md` |
| `hosts/<name>/` | Placement and vocabulary for each AI coding tool. See `hosts/README.md` |
| `skills/` | Optional skills for hosts that support them |
| `docs/` | User-facing documents (`docs/release-notes.md` is customer-facing and must not contain internal IDs) |
| `dev/` | Framework development records: completion-test records, lessons learned (`dev/developing-the-framework.md`), and the backport procedure |

Please follow these conventions; most of them are enforced by `selftest.sh`:

* **Keep the generic procedure stack-neutral and host-neutral.** Do not write markers of a particular stack (annotation names,
  configuration file names) into `templates/`, `pipeline.md`, or `playbook.md`; put them into a Playbook.
  Do not write AI coding tool names or paths used by a particular tool outside `hosts/`.
* **A rule that is not in the runtime contract does not exist at run time.** When you add or change a `GP-N` or `SB-N`
  entry, reflect it in the corresponding Step of `templates/pipeline-procedure.md.template` in the same change.
* **Prefer executable checks to prose.** If a rule can be checked mechanically, add it to `templates/gates.sh`, and add a
  `selftest.sh` case that injects the defect and confirms the check fails (a check that is never seen to fail is not trusted).
* **Number new `GP-N` / `SB-N` / `FB-N` entries with `./next-id.sh`** (the framework uses 100 and above). Never reuse a
  retired number. Insert new entries immediately before the `<!-- ENTRIES END -->` marker. `FB-N` entries are append-only.
* **Never put confidential information into distributed files.** Customer names, business-domain terms, and identifiers
  taken from real projects must be anonymized (see step 2b of `dev/backport-procedure.md` and `dev/backport-sources.allow`).
* Placeholders such as `<PRODUCT_NAME>` in `*.template` files are intentional; do not fill them in this repository.


## Contributing via Pull Requests
Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.
4. **`./selftest.sh` exits with 0** (`PASS N / FAIL 0`). It takes 10 to 30 minutes depending on the environment.
   If your change touches text processing (non-ASCII characters, locale, `grep` / `awk` / `sed` behavior) or shell
   portability, please run it on both a GNU environment (Linux or WSL) and macOS (BSD tools, bash 3.2), or say in the
   pull request which environment you could not test. The two have behaved differently in the past.
5. Your change follows "Repository Layout and Conventions" above.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local tests pass.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).


## Finding contributions to work on
Looking at the existing issues is a great way to find something to contribute on. As our projects, by default, use the default GitHub issue labels (enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any 'help wanted' issues is a great place to start.

Playbooks for additional technology stacks are especially welcome. Start from `playbooks/_template/` and follow
`docs/authoring-playbook.md`; please state in the Playbook's `README.md` which code bases you measured it on.


## Code of Conduct
This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.


## Security issue notifications
If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public github issue.


## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.
