# Security Policy

## Supported Versions

Security fixes are accepted for the current `main` branch until versioned
public releases exist. After the first public release, this file should list
the maintained release lines explicitly.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub Security
Advisories for this repository. If private advisories are unavailable, contact
the maintainers before filing a public issue.

Include:

- Affected commit or release.
- Platform and OS version.
- Steps to reproduce.
- Whether the issue requires a paired/trusted device, LAN access, local Mac
  account access, or physical access.

Do not include live credentials, pairing codes, private keys, or screen
recordings that expose third-party data.

## Security Scope

Screen Q is designed for consent-based LAN/VPN/Tailscale use. Public releases
must not expose native Screen Q listeners directly to the public internet, and
release builds must keep unfinished privileged admin actions disabled until
they have explicit hardening and review.
