# stay-on-sequoia

A bash script that keeps macOS Sequoia (15.x) point updates and security responses enabled while suppressing major-upgrade nags (e.g., "Upgrade to Tahoe").

## What It Does

1. **Enables Sequoia point updates** — automatic checks, downloads, and (optionally) installs for macOS 15.x updates and security responses
2. **Suppresses major-upgrade nags** — sets `MajorOSUserNotificationDate` to a far-future date so macOS stops prompting you to upgrade
3. **Purges downloaded installers** — removes any "Install macOS Tahoe.app" from `/Applications` and clears the `/Library/Updates` cache
4. **Generates a deferral profile** (optional) — creates and opens a `.mobileconfig` that defers major upgrades for up to 90 days

## Requirements

- macOS Sequoia (15.x) — most parts are harmless on other versions
- Administrator access (the script re-runs itself with `sudo` when needed)

## Usage

```bash
# Default: apply everything
./stay-on-sequoia.sh

# Check current status (no changes)
./stay-on-sequoia.sh --status

# Apply but don't auto-install updates (manual install)
./stay-on-sequoia.sh --manual

# Skip the deferral profile
./stay-on-sequoia.sh --no-profile

# Only generate the deferral profile
./stay-on-sequoia.sh --profile-only --days 90

# Apply to all local users
./stay-on-sequoia.sh --all-users

# Undo nag suppression
./stay-on-sequoia.sh --undo

# Remove the deferral profile
./stay-on-sequoia.sh --uninstall-profile
```

## Options

| Flag | Description |
|------|-------------|
| `--apply` | Apply changes (default) |
| `--status` | Show current status without making changes |
| `--undo` | Remove nag suppression for the targeted user(s) |
| `--uninstall-profile` | Remove the deferral profile installed by this script |
| `--manual` | Enable updates but don't auto-install them |
| `--no-profile` | Skip generating the deferral profile |
| `--profile-only` | Only generate and open the deferral profile |
| `--days N` | Deferral days for the profile (1–90, default: 90) |
| `--date "..."` | Custom date for `MajorOSUserNotificationDate` (format: `YYYY-MM-DD HH:MM:SS +0000`) |
| `--all-users` | Apply nag suppression to all local users (UID >= 501) |
| `-h`, `--help` | Show help |

## Deferral Profile

The generated `.mobileconfig` profile defers **major** OS upgrades only — minor updates and app updates are not affected. The script first attempts to install the profile via CLI (`profiles install`). If that fails (common on recent macOS for unsigned profiles), it falls back to opening the profile in System Settings for manual approval.

To remove a previously installed profile, run `--uninstall-profile`.

## Notes

- This does **not** prevent you from manually upgrading if you deliberately run an installer.
- To adapt for a future macOS release, change the `UPGRADE_NAME` variable at the top of the script.

## License

[MIT](LICENSE)
