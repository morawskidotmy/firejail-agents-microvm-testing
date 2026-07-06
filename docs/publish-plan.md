# Publish Plan

Target repository: <https://github.com/morawskidotmy/firejail-agents-microvm-testing>

Status captured for later execution.

## Repository State

- Public GitHub repository.
- Empty at time of review: no commits, no default branch ref, no README.
- Current user appeared to have push/admin permissions.
- Secret scanning and push protection are enabled.

## Writing Guidance

Use the GitHub `awesome-copilot` `create-readme` skill style:

- Write an appealing, informative, concise README.
- Use GitHub Flavored Markdown.
- Use GitHub admonitions where useful.
- Do not include license, contributing, changelog, or similar dedicated-file sections.
- Include a logo/icon only if one exists in the project.

## Content To Publish

Recommended initial repository content:

```text
README.md
docs/findings.md
config.example.json
pyproject.toml
baseline-profiles/
host-profiles/
guest-profiles/
runners/
tests/
results/latest.md
results/latest.json
```

## Findings To Include

- Firejail-only baseline: `10 pass / 0 fail / 4 skip`.
- Firecracker layered stack: `11 pass / 0 fail / 3 skip`.
- kvmtool layered stack: `11 pass / 0 fail / 3 skip`.
- crosvm layered stack: `11 pass / 0 fail / 3 skip`.
- All tested profiles blocked sibling project files, home secret files, session D-Bus,
  raw disk access, tmpfs mount, and user namespace unshare.
- VMM binaries were successfully invoked under host Firejail.
- Real VM boot remains blocked until host KVM and guest images are available.

## Charts To Include

- Probe pass/fail/skip comparison.
- Startup latency comparison.
- Synthetic workload wall-time comparison.
- Synthetic workload RSS comparison.
- Security boundary matrix.
- Host readiness matrix.
- Architecture diagram.
Example ASCII chart:

```text
Probe Results
firejail-only  ##########  pass 10 | fail 0 | skip 4
firecracker    ########### pass 11 | fail 0 | skip 3
kvmtool        ########### pass 11 | fail 0 | skip 3
crosvm         ########### pass 11 | fail 0 | skip 3
```

## Execution Steps

1. Clone or initialize the empty GitHub repository locally.
2. Copy this lab into the repository.
3. Rewrite `README.md` as the polished project entry point.
4. Add `docs/findings.md` for the comprehensive review with charts.
5. Run `uv run ruff check --fix .`.
6. Run `uv run ruff format .`.
7. Run `PATH="$HOME/.local/bin:$PATH" uv run python tests/check_host.py`.
8. Run `PATH="$HOME/.local/bin:$PATH" uv run python tests/bench_security.py`.
9. Inspect `git status`, `git diff`, and recent log.
10. Commit the initial content.
11. Push `main` to the GitHub repository.

## Open Decision

Before publishing, decide whether the repository should contain the full runnable lab plus
report, or only the comprehensive README/report artifacts.
