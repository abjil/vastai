# Repository publication status

The HomeLAN-to-GitHub spinoff is complete. The canonical repository is:

`https://github.com/abjil/vastai`

Vast.ai instances can reach this repository without access to a private LAN
Git service. Development should occur in this repository rather than in a
second HomeLAN copy.

## Publication cleanup

The repository now has an MIT license, uses its canonical GitHub URL, keeps
Python bytecode out of version control, and provides an onstart template with
no HomeLAN or placeholder clone logic.

These release blockers remain:

1. Confirm the updated CI passes from a clean GitHub-hosted checkout.
2. Complete lifecycle, configuration, logging, and security hardening.
3. Publish the first reviewed release/tag only after the real Vast.ai
   stop/start test passes.

See [FIX_IMPLEMENTATION_PLAN.md](../FIX_IMPLEMENTATION_PLAN.md) for ownership,
order, and acceptance criteria.

## Canonical naming

- GitHub repository: `abjil/vastai`
- Product name: Vast.ai wakeup notifier
- Default installation path: `/workspace/vastai-wakeup`

The installation directory intentionally keeps the descriptive
`vastai-wakeup` name even though the GitHub repository is named `vastai`.

## Files that must never be published

- populated `wakeup.env` or other credential files;
- `ACK`, `session.id`, `started_at`, `wakeup.pid`, or lock state;
- `wakeup.log` and `runtime/`;
- editor/agent context or private HomeLAN configuration;
- Python bytecode and cache directories.

Before every release, inspect the complete tracked file list rather than
relying only on `.gitignore`.

## Release workflow

1. Complete the release phase in the implementation plan.
2. Confirm the working tree contains no secrets or generated runtime data.
3. Run CI from a clean checkout.
4. Run channel smoke tests with private test recipients.
5. Run the unattended Vast.ai stop/start and ACK lifecycle test.
6. Tag the exact reviewed commit.
7. Configure production instances to use that tag or commit.

Do not configure onstart to execute an unreviewed moving branch.

## Future development

Potential additions—external Vast.ai API monitoring, more providers, or daemon
supervision—belong in this repository. External API monitoring should remain a
separate component because its value comes from failing independently of the
in-instance notifier.
