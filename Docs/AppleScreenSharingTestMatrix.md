# Apple Screen Sharing Test Matrix

Screen Q cannot connect to a Mac that has no remote access service enabled. For Macs without Screen Q installed, the supported path is Apple Screen Sharing or Remote Management on port 5900.

## Probe Before Manual Tests

Run the RFB security-type probe before entering credentials:

```sh
Scripts/probe_apple_screen_sharing.rb --require-apple-dh 192.168.1.20:5900
```

Expected for modern macOS Screen Sharing or Remote Management:

- `apple_dh_offered: true`
- security type `30` / `AppleDH`
- VNC password type `2` may also be present when legacy VNC access is enabled

The probe does not authenticate and does not send usernames or passwords.

## Manual Matrix

| Case | Target Setup | Credential Input | Expected Screen Q Behavior |
| --- | --- | --- | --- |
| Screen Sharing, allowed user | System Settings > General > Sharing > Screen Sharing enabled, user allowed | macOS username/password | Chooses Apple DH, connects, labels as Mac Screen Sharing, credentials may be saved in Keychain with local-auth reuse |
| Screen Sharing, denied user | Screen Sharing enabled, user not allowed | valid macOS username/password | Fails with Mac account credential rejection, does not silently fall back to VNC password |
| Wrong password | Screen Sharing enabled | allowed username, wrong password | Prompts again, clears bad in-memory credential, no credential logging |
| Remote Management | Remote Management enabled instead of Screen Sharing | allowed management user | Chooses Apple DH when offered, labels as Mac Screen Sharing |
| Legacy VNC fallback | "VNC viewers may control screen with password" enabled, Apple DH unavailable or no username supplied | separate VNC password | Labels fallback as legacy VNC password; never calls it admin login |
| Generic VNC | Non-Apple VNC server | VNC password | Uses Generic VNC profile and weak/compatibility security label |
| Tailscale/VPN | Target reachable by Tailscale IP/name | same as above | Connects over private overlay but still labels RFB security honestly |

## Regression Checks

- Saved Mac Screen Sharing, VNC, and RDP credentials should be stored only in Keychain.
- When "Require Touch ID / Face ID / passcode before reuse" is enabled, reconnecting with saved credentials must trigger the platform authentication prompt before credentials are read.
- Cancelling local authentication must leave the session at the credential prompt.
- Apple DH failures must show Mac account guidance rather than falling through to legacy VNC password without user choice.
- Legacy VNC password prompts must warn that this is not a macOS admin/user password.

## Versions To Cover

Record results for current supported macOS releases and both sharing services:

- macOS 13 Ventura: Screen Sharing, Remote Management
- macOS 14 Sonoma: Screen Sharing, Remote Management
- macOS 15 Sequoia: Screen Sharing, Remote Management
- macOS 26 or later if available in the test lab

For each run, capture:

- target macOS version/build
- sharing service enabled
- `probe_apple_screen_sharing.rb` JSON output
- Screen Q protocol badge/security label
- credential result
- whether local-auth Keychain reuse was required
