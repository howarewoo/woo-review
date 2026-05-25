# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in `woo-review`, please report it
privately by opening a [security advisory](https://github.com/howarewoo/woo-review/security/advisories/new)
on this repository. Do **not** open a public GitHub issue.

Please include:

- A description of the issue and its impact.
- Reproduction steps or a proof of concept.
- Affected versions / commit SHAs.

You can expect an initial acknowledgement within 7 days and a follow-up with a
remediation plan or further questions within 30 days.

## Threat Model

`woo-review` is an AI-powered code-review tool. Two surfaces matter:

1. **The skill** (`skills/woo-review/SKILL.md`) — runs inside a host coding
   agent (Claude Code, Cursor, Gemini CLI, opencode). The host's existing
   sandbox / permission model governs what the swarm can do locally.
2. **The GitHub Action** (`action.yml` + `.github/workflows/reusable-review.yml`) —
   runs in a consumer repo's CI. The agent is granted broad permissions
   (`Bash(*)`, `Read`, `Write`, `Edit`, `WebFetch(*)`, `WebSearch`) so it can
   execute the audit tooling (`gh`, `jq`, `npx impeccable`, `npx react-doctor`)
   and post a batched PR review.

## Hardening Guidance for Consumers

When you wire this action into your repository, follow these practices:

- **Pin to a full commit SHA**, not `@main` or a tag, to defend against
  supply-chain attacks. Example:
  ```yaml
  uses: howarewoo/woo-review/.github/workflows/reusable-review.yml@<full-sha>
  ```
- **Avoid `pull_request_target`** unless you understand the elevated token
  scope it grants. The default `pull_request` event is safer for untrusted
  forks.
- **Store provider credentials as GitHub Actions secrets**, never inline.
- **Review the action diff before bumping the pinned SHA.** Major-version
  bumps in particular may introduce new tool calls or providers.
- **Restrict the LLM's network egress** at the runner level if your provider
  supports it (e.g. private OpenRouter routes, allowlisted Anthropic API
  endpoints).
- **Scope the `GITHUB_TOKEN`** to the minimum needed. The reusable workflow
  needs `pull-requests: write` and `contents: read`; nothing else.

See GitHub's [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
for the broader baseline.

## Supported Versions

Only the latest `main` commit (or the latest tagged release, when one exists)
is supported. Older revisions will not receive security patches; rebase or
re-pin to the current SHA.
