# Comparison: stay-on-sequoia vs stop-tahoe-update

A detailed comparison of [stay-on-sequoia](.) and [stop-tahoe-update](https://github.com/travisvn/stop-tahoe-update) (139 stars, MIT license, community-driven).

---

## Design Philosophy

| | stay-on-sequoia | stop-tahoe-update |
|---|---|---|
| **Architecture** | Single monolithic script (~440 lines) | Multi-file: separate install, uninstall, and status scripts + static profile template |
| **Target user** | Power users / sysadmins who want one command | Broader community with contribution in mind |
| **Approach** | Multi-layered defense (4 mechanisms) | Profile-only (1 mechanism implemented, more planned) |
| **Profile generation** | Dynamic — generated at runtime with fresh UUIDs, configurable days | Static template — UUID placeholders substituted via `sed` at install time |
| **Privilege model** | Self-escalates to root, runs multiple system-level operations | Narrow `sudo` usage only for `profiles install/remove` |

---

## Feature Comparison

### What stay-on-sequoia has that stop-tahoe-update doesn't

| Feature | Description |
|---|---|
| Software Update configuration | Enables auto-check, auto-download, and (optionally) auto-install for point updates and security responses |
| MajorOSUserNotificationDate suppression | Sets a far-future date to suppress the "Upgrade to Tahoe" nag beyond the 90-day profile limit |
| Installer purging | Finds and deletes "Install macOS Tahoe.app" from /Applications by checking both filename and `CFBundleDisplayName` |
| /Library/Updates cache clearing | Removes cached upgrade downloads |
| Multi-user support | `--all-users` flag applies nag suppression to all local users (UID >= 501) |
| Configurable deferral days | `--days N` flag (1–90) for dynamic profile generation |
| Manual install mode | `--manual` enables updates without auto-installing them |
| Undo mode | `--undo` reverses nag suppression |
| Input validation | Date format regex, integer range checks, required command checks (`need_cmd`) |
| Console user detection | Detects the GUI-logged-in user via `/dev/console` with fallbacks |

### What stop-tahoe-update has that stay-on-sequoia doesn't

| Feature | Description |
|---|---|
| Minor update deferral | Also defers minor OS updates (30 days) and non-OS updates (30 days) |
| Static auditable profile | Pre-built `.mobileconfig` template — easier to review without running the script |
| Profile uninstall script | Removes profile by identifier via `profiles remove` |
| CI/CD pipeline | GitHub Actions: shellcheck, plutil lint, SHA-256 checksums |
| Community governance | CONTRIBUTING.md, CODEOWNERS, RFC process for new features |
| Dock badge removal guide | Documentation for removing the System Settings red badge |
| Temp file cleanup | `trap 'rm -rf "$TEMP_DIR"' EXIT` in install script |
| CLI install attempt | Tries `profiles install` via CLI before falling back to UI `open` |
| MIT license | Explicit permissive licensing |
| Planned plugin system | Roadmap for installer-watcher and update-signal-monitor LaunchAgents (not yet implemented) |

---

## Profile Payload Comparison

This is the most consequential technical difference between the two projects.

### stay-on-sequoia

```xml
forceDelayedMajorSoftwareUpdates = true
enforcedSoftwareUpdateMajorOSDeferredInstallDelay = <N days, configurable>
forceDelayedSoftwareUpdates = false            <!-- explicitly preserves minor updates -->
forceDelayedAppSoftwareUpdates = false          <!-- explicitly preserves app updates -->
```

### stop-tahoe-update

```xml
forceDelayedMajorSoftwareUpdates = true
enforcedSoftwareUpdateMajorOSDeferredInstallDelay = 90
forceDelayedSoftwareUpdates = true              <!-- ALSO defers minor OS updates -->
enforcedSoftwareUpdateMinorOSDeferredInstallDelay = 30
enforcedSoftwareUpdateNonOSDeferredInstallDelay = 30
```

**Impact:** stop-tahoe-update's profile is more aggressive — it delays minor OS updates and non-OS updates by 30 days in addition to the 90-day major upgrade deferral. stay-on-sequoia's profile is more surgical, only deferring major upgrades and explicitly allowing minor and app updates to flow through immediately.

Users who want to stay current on security patches while avoiding the major upgrade should prefer stay-on-sequoia's approach.

---

## Code Quality Comparison

| Aspect | stay-on-sequoia | stop-tahoe-update |
|---|---|---|
| **Strict mode** | `set -euo pipefail` + `IFS=$'\n\t'` | `set -euo pipefail` |
| **Shebang** | `#!/bin/bash` | `#!/usr/bin/env bash` (more portable) |
| **Quoting** | Thorough and consistent throughout | Adequate for the scope |
| **Input validation** | Date format regex, integer ranges, command existence checks | File existence check only |
| **Error handling** | Granular `\|\| warn` / `\|\| true` patterns per operation | Minimal — relies on `set -e` |
| **Edge cases** | Bash 3.2 empty array handling, non-numeric comparisons, console user fallbacks | Not applicable (simpler scripts) |
| **Shellcheck** | Clean | Clean (CI-enforced) |
| **Temp file handling** | No temp files created | `mktemp -d` with `trap` cleanup |
| **Total lines** | ~440 | ~45 across 3 scripts |

---

## Effectiveness Analysis

Both projects share the same fundamental limitation: Apple's 90-day maximum deferral is a hard ceiling for the profile-based approach.

### Defense layers

| Layer | stay-on-sequoia | stop-tahoe-update |
|---|---|---|
| Deferral profile (Apple-supported, 90-day max) | Yes | Yes |
| Nag notification suppression (extends beyond 90 days) | Yes (`MajorOSUserNotificationDate`) | No |
| Installer purging (reactive cleanup) | Yes (checks name + `CFBundleDisplayName`) | Planned (not implemented) |
| Update cache clearing | Yes (`/Library/Updates`) | No |
| Software Update configuration | Yes (ensures point updates stay on) | No |
| Installer watcher (proactive detection) | No | Planned (not implemented) |
| Update signal monitoring | No | Planned (not implemented) |

stay-on-sequoia provides 4 active layers of defense today. stop-tahoe-update provides 1 active layer with 2 more on the roadmap.

The `MajorOSUserNotificationDate` trick is notable because it's the only mechanism that works beyond the 90-day profile limit, though Apple could patch it in any update.

---

## User Experience

| Aspect | stay-on-sequoia | stop-tahoe-update |
|---|---|---|
| **Setup** | Download one script, run it | Clone repo, chmod scripts, run install |
| **Typical invocation** | `./stay-on-sequoia.sh` (one command does everything) | `./scripts/install-profile.sh profiles/deferral-90days.mobileconfig` |
| **Status check** | `--status` (detailed: prefs, installers, cache) | `./scripts/status.sh` (focused: profiles and prefs) |
| **Undo** | `--undo` (nag suppression only; profile via System Settings) | `./scripts/uninstall-profile.sh` (removes profile by identifier) |
| **Customization** | Flags: `--days`, `--date`, `--manual`, `--all-users`, `--no-profile` | Edit the `.mobileconfig` XML manually |
| **Documentation** | Concise README with options table | Extensive README with roadmap, philosophy, guides |

---

## Project Maturity

| Aspect | stay-on-sequoia | stop-tahoe-update |
|---|---|---|
| **License** | None | MIT |
| **CI/CD** | None | GitHub Actions (shellcheck, plutil, SHA-256) |
| **Community** | Single-author | 139 stars, 8 forks, discussions, contributing guidelines |
| **Governance** | None | CODEOWNERS, RFC process, safety checklist |
| **Roadmap** | None (purpose-built) | Multi-phase with plugin architecture |
| **README mentions features that don't exist** | No | Yes (plugins/ directory listed but doesn't exist in repo) |

---

## Strengths and Weaknesses Summary

### stay-on-sequoia

**Strengths:**
- More comprehensive and immediately effective (4 active defense layers)
- Single-command simplicity
- Robust code with extensive validation and edge case handling
- Configurable (deferral days, auto/manual, per-user or all-users)
- Surgical profile that preserves minor update flow

**Weaknesses:**
- No license
- No CI/CD
- No profile uninstall mechanism
- Monolithic — harder for others to audit specific parts
- No temp file cleanup (`trap`)
- Broader root privilege scope than necessary

### stop-tahoe-update

**Strengths:**
- Community infrastructure (CI, governance, contributions)
- Static profile template is more auditable
- Clean separation of install/uninstall/status
- Profile uninstall by identifier
- MIT licensed with SHA-256 checksums
- Ambitious vision with plugin roadmap

**Weaknesses:**
- Much less comprehensive (only 1 of 3 planned layers implemented)
- Also defers minor updates by default (may delay security patches)
- Minimal input validation and error handling
- No multi-user support or configurable deferral days
- README advertises features (plugins) that don't exist in the repository
- No nag suppression or installer purging

---

## What Each Project Could Adopt From the Other

### stay-on-sequoia could adopt

1. **MIT license** — enable reuse and contribution
2. **CI pipeline** — automated shellcheck + plutil validation on push
3. **Profile uninstall mode** — `--uninstall-profile` using `profiles remove -identifier`
4. **`trap` cleanup** — for any future temporary state
5. **CLI profile install attempt** — try `profiles install` before falling back to `open`
6. **`#!/usr/bin/env bash`** — marginally more portable shebang

### stop-tahoe-update could adopt

1. **MajorOSUserNotificationDate suppression** — extends protection beyond the 90-day limit
2. **Installer purging** — active defense instead of waiting for the planned plugin
3. **Software Update configuration** — ensure point updates and security responses stay enabled
4. **Input validation** — command existence checks, parameter validation
5. **Configurable deferral days** — avoid requiring users to edit XML
6. **Don't defer minor updates by default** — explicitly set `forceDelayedSoftwareUpdates` to false to preserve security patch flow
