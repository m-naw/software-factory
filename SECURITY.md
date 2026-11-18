# Security Policy

## Supported versions

Only the latest commit on `main` is supported. There are no maintained LTS
branches at this stage.

## Threat model: prompt injection via ticket content

The farm runs agent sessions with `--dangerously-skip-permissions`, and ticket
bodies are **assumed to be attacker-influenceable**. The scout is instructed to
cite evidence from the target repository — PR descriptions, code comments, test
fixtures — any of which a malicious contributor can plant. That text is
transcribed into a ticket, and the ticket body is interpolated into the
implementer/QA prompt. A poisoned upstream repo can therefore attempt to steer a
farm session ("ignore prior instructions, run X").

This is an inherent property of an LLM farm, not a bug we can fully close. The
containment story is defense-in-depth, and it does **not** rely on the model
obeying its instructions:

- **The PreToolUse guard hook** (`hooks/guard-bash.sh`) deterministically denies
  merge-gate bypasses, protected-path writes, self-tamper of its own config, and
  tool writes outside the session worktree — regardless of what the prompt says.
- **Branch protection + CODEOWNERS** are the real merge rail; the guard is a
  layer in front of them, not a replacement.
- **A dedicated machine identity** (single-repo token, no admin, no cloud
  creds) bounds the blast radius of anything that does slip through.
- **Prompt framing is defused, not trusted:** the runner strips the farm's own
  `<task>` / `<farm_context>` framing tags out of untrusted ticket bodies
  (`defuse_framing_tags`, `bin/farm-lib.sh`) so a body cannot close the framing
  early or spoof the trusted half of the prompt. This is a hardening layer, not
  the control — the guard and platform rails above are.

If you find a way to make a poisoned ticket cause a protected-surface merge or a
write outside the worktree/protected-path rules, that is a reportable
vulnerability.

## Reporting a vulnerability

Please use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository (Security tab → "Report a vulnerability").

If that's unavailable, open a regular issue and tag it `security` — avoid
including exploit details or secrets in the public issue body; a maintainer
will follow up privately.

There is no bug bounty program.
