# VerdictUI — External Services

| Service | Purpose | Credentials | Renewal |
|---------|---------|-------------|---------|
| GitHub (medlars/verdictui) | Source + CI | gh CLI (system keychain) | n/a |
| Homebrew tap (Wave 10) | CLI distribution | none (public tap) | n/a |
| GitHub (medlars/verdictui-releases) | Public assets-only host for the notarized CLI archive the tap installs | gh CLI (system keychain) | n/a |
| Apple notary service | Notarizes the CLI and desktop archives | `vohux-notary` keychain profile | Apple Developer Program, yearly |
| *(no runtime services — local-first by design)* | | | |

## Dependency Health

Run: `python3.14 contracts/validate-contracts.py`
