# reverse-spec-flow

**A workflow that turns existing source code into "AI-friendly specifications" for AI agents to use**

Version: [2.2.1](docs/release-notes.md) / License: MIT-0

> 日本語版: [README_ja.md](README_ja.md)
>
> The documents under `docs/` and the rules the AI agent follows are currently written in Japanese.

---

## What is this?

reverse-spec-flow creates **specifications for AI agents to read and use** from the source code of an application
that has no specifications, has outdated ones, or has become a black box. The output is Markdown that lets an agent
look up only the parts it needs, through IDs and indexes. Typical uses of the generated specifications:

- **Reimagining the application** — an AI agent reimagines the application on a new technology stack through spec-driven development, using the specifications as input
- **Maintaining and evolving the current system** — an AI agent consults the specifications to explain how the current system behaves and what a change would affect, supporting maintenance (feature additions, specification changes) and the planning of refactoring or migration work

It is intended for developers and architects who want to use AI agents to reimagine or maintain existing systems.
People can read the specifications too, but the main readers are AI agents. The specifications are also written by AI agents.
For that reason, reverse-spec-flow puts the highest priority on guaranteeing the following two things by mechanism, not by the agent's self-report.

### 1. Correctness — a mechanism that leaves no unsupported statements (hallucinations)

- **Every statement cites its evidence** — each statement carries the location in the code that supports it (`path:line`).
- **Verified separately from the author** — a verifier AI agent, isolated from the one that wrote the specification,
  checks each statement against the source code under analysis. It confirms not just that a location is cited, but that the cited lines actually support the statement.
- **Unknowns are written as unknown** — anything that cannot be confirmed from the code is not filled in by guesswork; it is left as `UNKNOWN`.

### 2. Coverage — the work is not complete until 100% of the code graph is specified

- **Build the list to count against (the denominator) first** — the first step builds a structural map (the code graph)
  that lists the modules, entry points and external connections, and how they are connected.
- **Not complete until the list is used up** — the workflow counts whether every element of the code graph has been specified,
  and the work is not complete until nothing is left. It does not stop at "we looked at the main parts."
- The correctness of the list is supported by a counting method suited to the target technology (see "Playbooks" below),
  together with cross-checks against other sources such as configuration files to find anything missed.

For both, whether the work is complete is decided not by the agent saying "done," but by whether the gate script `gates.sh`
returns a pass (exit 0).

### Other features

- **Easy for AI agents to look up** — every specification file and requirement gets a unique, stable ID (for example `REQ-F-01`).
  Specifications refer to each other by ID, and the workflow also builds an index from ID to file and a reverse index from source file to specification,
  so an AI agent can look up only what it needs without reading everything.
  The rules that an AI agent using the specifications must follow (`specs/AGENTS.md`) are included.
- **Separate layer for reimagining** — what depends on the current technology and what any reimagined application would need regardless of technology can be written separately.
- **Large code bases in parallel** — the code is read one business area at a time, so the whole code base never has to be loaded at once.
  If the AI tool supports sub-agents (AI agents that split the work and run in parallel), business areas can be processed in parallel.
- **Survives context overflow** — progress and the next actions are written to files and committed to git.
  If the agent's context overflows or the session ends, opening a new session resumes from the record.
- **Lessons carry forward** — lessons learned in a project are recorded, and general ones can be fed back into reverse-spec-flow itself
  (see "Documentation" below).
- **The target is not modified** — the rules tell the AI agent not to modify the source code, and `gates.sh` detects changes to it. Specifications are written to a separate git repository. Analyze a git clone or a copy of the source.

Below, products such as Claude Code and Kiro are called **AI tools**, and the AI that works inside them is called an **AI agent**.

## Requirements

- **bash and git** (macOS / Linux. On Windows, WSL is recommended. Git Bash also works, but the checks take longer)
- **An AI tool** (see "Supported AI tools" below)
- **The source code you want to analyze**

No database or dedicated platform is needed.

## Quick start

```bash
# 1. Clone next to the folder you want to analyze (for example legacy-order-system/)
cd /path/to/workspace        # legacy-order-system/ is in here
git clone https://github.com/aws-samples/sample-reverse-spec-flow.git

# 2. Create the repository for the specifications
#    init.sh <target> <name (letters, digits, . _ -)> [purpose (asked interactively if omitted)]
./sample-reverse-spec-flow/init.sh ./legacy-order-system order-system rebuild

#    If there is a Playbook (a set of counting rules; see "Playbooks" below) for the target technology, you can specify it (optional; it works without one)
./sample-reverse-spec-flow/init.sh ./legacy-order-system order-system rebuild --playbook java-jaxrs-jpa
```

This creates `legacy-order-system-spec/` (the repository for the specifications) next to the target.
**Do all further work in a new session opened on `legacy-order-system-spec/`.**
Do not start the analysis in the `sample-reverse-spec-flow/` session where you ran `init.sh`.
If you use Kiro IDE, read `legacy-order-system-spec/HOST-SETUP.md` before opening the repository in Kiro IDE.

```
3. Open legacy-order-system-spec/ in your AI tool and give an instruction such as:

   Read spec-extraction/AGENTS.md.
   The source to analyze is in /path/to/workspace/legacy-order-system/ (read-only; do not modify it).
   Fill in the <PLACEHOLDER> values in spec-extraction/AGENTS.md, then start from Phase 0.
```

The same instruction is also shown at the end of the `init.sh` output.

Main `init.sh` options:

| Argument | Meaning |
|---|---|
| `purpose` (3rd argument, optional) | What the specifications are for. `maintenance` (maintaining and evolving the current system) / `evaluation` (assessing and estimating a reimagine effort) / `rebuild` (deep enough for an AI agent to implement the reimagined application). It changes what is produced and how strict the checks are. If omitted, you choose interactively (default `rebuild`) |
| `--playbook <name>` | Optional. Counting rules for the target technology (see "Playbooks" below). Can be given more than once |
| `--host <name>` | The AI tool to use (`claude-code` (default) / `kiro-ide` / `kiro-cli`) |
| `--list-playbooks` / `--list-hosts` | List the available Playbooks / AI tools |

## How the work proceeds

```
Phase 0  Ingestion      Pin the commit of the target and decide the scope
Phase 1  Code graph     List the modules, entry points, external connections and how they connect (the coverage denominator)
Phase 2  Analysis       Analyze from each viewpoint (architecture, requirements, API, data, behavior, non-functional), with evidence
Phase 3  Specification  Write specifications that AI agents can look up, structured after ISO/IEC/IEEE 29148 (the international standard for requirements specifications)
Phase 4  Audit          Check coverage, citations and the separation of fact from guesswork, independently of the authoring
```

At the boundaries between phases, the AI agent asks a person to confirm (for example, the scope or how to count).
What is checked, and when the AI agent stops to ask a person, is described in [docs/how-it-works.md](docs/how-it-works.md) (Japanese).

## What gets generated

```
legacy-order-system-spec/            ← independent git repository created by init.sh
├── AGENTS.md                        ← entry point
├── specs/                           ← output (specifications handed to AI agents)
│   ├── AGENTS.md                    ←   rules for the agent that uses the specifications
│   ├── overview.md                  ←   overview of the whole system
│   ├── source-index.md              ←   reverse index from source to specifications (used for impact analysis)
│   ├── modules/ api/ data/ behavior/
│   └── rebuild/                     ←   technology-independent specifications for reimagining (when purpose is rebuild / evaluation)
└── spec-extraction/                 ← working records (procedures, intermediate artifacts, check results)
    ├── AGENTS.md                    ←   rules for the agent that writes the specifications
    └── 03-audit/gates.sh            ←   gate script that decides completion
```

The rules the AI agent follows are split into an entry point and two sets of rules.

| Location | Role |
|---|---|
| `AGENTS.md` (root) | Entry point. Points to one of the two below depending on the task |
| `specs/AGENTS.md` | Rules for the side that uses the specifications (the agent that reimagines the application or investigates it) |
| `spec-extraction/AGENTS.md` | Rules for the side that writes the specifications |

Which files an AI tool loads automatically differs by tool and version. So the workflow does not depend on automatic loading: the agent reads the rules it needs, starting from the entry point.

### Using the generated specifications

When you hand the specifications to an AI agent, give it `specs/` as is and have it read `specs/AGENTS.md` first.
If you also give it the source code under analysis, the agent can check statements against the source code.
If you do not, the agent says so and answers only what the specifications themselves support.

## Supported AI tools

AI tools that can be used to write the specifications:

| AI tool | Status | Option |
|---|---|---|
| Claude Code | Verified (run end to end) | `--host claude-code` (default). `CLAUDE.md` (root) is also placed as a pointer to the entry point |
| Kiro IDE | Verified (run end to end on a small target; scope in [hosts/README.md](hosts/README.md)) | `--host kiro-ide` (read the generated `HOST-SETUP.md` before opening) |
| Kiro CLI | Not verified (only some functions checked; not run end to end) | `--host kiro-cli` |

For writing the specifications, AI tools not in this table are not supported. (The generated specifications can be handed to any AI agent.)
Support status and measurement records are in [hosts/README.md](hosts/README.md) (Japanese).

## Playbooks (optional)

**reverse-spec-flow works with any language or technology stack. It works as is, even when there is no Playbook for your technology.**

A Playbook is a shortcut: it records in advance, for a specific technology, what to count so that the whole system is covered
(for example, how to count screens, APIs and tables). If you do not specify a Playbook, at the start of Phase 1 the AI agent
examines the target code and decides how to count, based on its knowledge of the technology stack. The procedure is the same and the same checks run
(if the agent moves on without deciding how to count, the checks stop it).

Playbooks currently available:

| Playbook | Target |
|---|---|
| `java-jaxrs-jpa` | Java (JAX-RS / Spring MVC + JPA annotations) |
| `java-struts-ormxml` | Java (Struts 2 + JPA XML mapping) |
| `java-struts1-ejb2` | Java (Struts 1 / EJB 2.x) |
| `aspnet-webforms` | ASP.NET Web Forms (C# / VB.NET) |
| `csharp-winforms-adonet` | C# Windows Forms + ADO.NET |
| `vbnet-winforms-adonet` | VB.NET Windows Forms + ADO.NET |
| `vb6` | Visual Basic 6.0 |
| `php-procedural-mysql` | Procedural PHP + MySQL and similar |
| `cobol-cics-batch` | COBOL (CICS / JCL batch / DB2 and VSAM) |
| `oracle-plsql` | Oracle PL/SQL (used together with the Playbook for the application side) |

If you work with a technology often, you can write and add a Playbook ([docs/authoring-playbook.md](docs/authoring-playbook.md), Japanese).

## Cautions

- **The specifications may still contain errors.** The checks reduce errors, but cannot eliminate them completely.
  If you reimagine an application from the specifications, separately confirm through UAT, regression testing and similar means that it behaves like the current system.
  The quality measured in verification runs is in [docs/release-notes.md](docs/release-notes.md) (Japanese).
- **The AI tool reads the source code under analysis.** If the code is confidential,
  follow the terms of the AI tool you use and the rules of your organization.
- **Instructions and secrets inside the analyzed code.** The rules tell AI agents to treat comments, strings and documents in the source code as data, not as instructions,
  and not to copy secret values (passwords, keys, tokens, personal data) into the specifications; only where they are and what kind they are is recorded.
  Even so, check the specifications for secrets before sharing them.
- **Analyze untrusted code in an isolated environment.** The AI agent runs shell commands with your permissions, and the rules above are instructions to the AI, not enforcement.
  For code you do not trust, use an isolated environment without production credentials (a VM, a container or a disposable machine), and do not use auto-approval
  (Always allow, `kiro-ide-allow.sh`). Use Playbooks and `hosts/` files only from sources you trust.
- **Handle the spec repository like the source code.** It contains excerpts of the analyzed code and local absolute paths. Do not push it to a public remote,
  and check it with a secret scanner (for example git-secrets or gitleaks) before sharing it. If you receive a spec repository from someone else,
  review `.claude/` and `.kiro/` before you trust the workspace in your AI tool.
- **No dynamic checks such as starting the application or operating its screens.** Anything that cannot be confirmed from the code is left as `UNKNOWN`.
- This repository is a sample. Before using it for production work, verify it thoroughly at your own responsibility.

## Documentation

The documents below are in Japanese.

| What you want to know | Document |
|---|---|
| **How to use it and how it works** (what happens, what is checked, what to do when it stops) | [docs/how-it-works.md](docs/how-it-works.md) |
| Explanation for non-engineers | [docs/overview-for-business.md](docs/overview-for-business.md) |
| Design ideas, the problems it addresses, examples of output | [docs/overview-for-engineers.md](docs/overview-for-engineers.md) |
| Changes by version | [docs/release-notes.md](docs/release-notes.md) |
| How to write a new Playbook | [docs/authoring-playbook.md](docs/authoring-playbook.md) |
| Design document (verifier isolation) | [docs/designs/verifier-isolation.md](docs/designs/verifier-isolation.md) |
| How AI tool support works | [hosts/README.md](hosts/README.md) |
| Generation rules and quality rules (documents the AI agent refers to; people do not need to read them) | [pipeline.md](pipeline.md) / [playbook.md](playbook.md) |

### For those modifying reverse-spec-flow itself

- How to make changes and run the selftest: [CONTRIBUTING.md](CONTRIBUTING.md)
- Pitfalls when modifying the framework: [dev/developing-the-framework.md](dev/developing-the-framework.md)
- How to feed lessons from a project back into reverse-spec-flow: [dev/backport-procedure.md](dev/backport-procedure.md)
- `dev/` also contains records of tests run during development (you do not need to read them just to use the workflow).

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
