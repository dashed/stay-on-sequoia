#!/usr/bin/env bash
# stay-on-sequoia.sh
#
# What this does:
#   1) Keeps macOS Sequoia point updates & security responses enabled
#   2) Suppresses major-upgrade nags (e.g., "Upgrade to <UPGRADE_NAME>") for your user
#   3) Removes any downloaded "Install macOS <UPGRADE_NAME>" installer and clears /Library/Updates cache
#   4) (Optional) Creates a 90-day "defer MAJOR upgrades only" configuration profile and opens it
#
# Notes:
#   - Installing the profile requires a couple of clicks in System Settings (CLI install is not supported on recent macOS).
#   - This does NOT prevent you from manually upgrading if you deliberately run an installer later.
#   - Designed for Sequoia (macOS 15.x) but most parts are harmless on other macOS versions.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/${SCRIPT_NAME}"
MODE="apply"

# Defaults (override via flags)
UPGRADE_NAME="Tahoe"                      # name of the major upgrade to suppress (update for future releases)
FUTURE_DATE="2035-01-01 00:00:00 +0000"   # for MajorOSUserNotificationDate
DEFERRAL_DAYS=90                          # 1..90
AUTO_INSTALL=1                            # 1 = auto-install Sequoia updates, 0 = manual
MAKE_PROFILE=1                            # 1 = generate+open deferral profile, 0 = skip
ALL_USERS=0                               # 1 = set nag-suppression for all local users, 0 = just console user

PROFILE_IDENTIFIER="local.defer-major-upgrades.profile"
PAYLOAD_IDENTIFIER="local.defer-major-upgrades.restrictions"

ORIG_ARGS=("$@")

log()  { printf "%s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Default (no options): apply everything (enable Sequoia updates, suppress major-upgrade nag, purge ${UPGRADE_NAME} installer/cache, generate+open deferral profile)

Modes:
  --apply          Apply changes (default)
  --status         Show current status (no changes)
  --undo           Remove only the nag-suppression key (MajorOSUserNotificationDate) for the targeted user(s)
  --uninstall-profile
                   Remove the deferral profile installed by this script

Options:
  --manual         Keep updates enabled, but do NOT auto-install macOS updates (manual install)
  --no-profile     Skip generating/opening the 90-day major-upgrade deferral profile
  --profile-only   Only generate/open the deferral profile (no other changes)
  --days N         Deferral days for the profile (1..90). Default: ${DEFERRAL_DAYS}
  --date "YYYY-MM-DD HH:MM:SS +0000"
                  Date for MajorOSUserNotificationDate. Default: ${FUTURE_DATE}
  --all-users      Apply nag-suppression to all local users (UID >= 501)
  -h, --help       Show help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --manual --no-profile
  $SCRIPT_NAME --status
  $SCRIPT_NAME --profile-only --days 90
  $SCRIPT_NAME --uninstall-profile
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

is_int_between() {
  local v="$1" lo="$2" hi="$3"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  (( v >= lo && v <= hi )) || return 1
  return 0
}

get_console_user() {
  # Console user is the user logged into the GUI. Works well for typical desktop usage.
  local u=""
  u="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -z "$u" || "$u" == "root" ]]; then
    # Fallback to $SUDO_USER or $USER if no GUI user detected
    u="${SUDO_USER:-${USER:-}}"
  fi
  [[ -n "$u" ]] || die "Unable to determine target user."
  printf "%s" "$u"
}

get_user_home() {
  local u="$1"
  local home=""
  home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$home" ]] || die "Unable to determine home directory for user: $u (dscl lookup failed)"
  printf "%s" "$home"
}

run_as_user() {
  local u="$1"; shift
  if [[ "$u" == "$(id -un 2>/dev/null || true)" && "${EUID:-0}" -ne 0 ]]; then
    # already that user, non-root
    "$@"
  else
    sudo -u "$u" "$@"
  fi
}

list_local_users_uid_ge_501() {
  # Print usernames with UID >= 501 (typical local users)
  dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 {print $1}'
}

ensure_root_if_needed() {
  local needs_root="$1"
  if [[ "$needs_root" -eq 1 && "${EUID:-0}" -ne 0 ]]; then
    log "Re-running with sudo (admin password may be required)..."
    exec sudo bash "$SCRIPT_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
}

configure_updates() {
  local auto_bool="true"
  [[ "$AUTO_INSTALL" -eq 1 ]] || auto_bool="false"

  log "Configuring Software Update settings (Sequoia updates ON; auto-install=${auto_bool})..."

  # Ensure automatic schedule is ON (periodic checks)
  softwareupdate --schedule on >/dev/null 2>&1 || true

  # System-wide prefs
  defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true || true
  defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true || true
  defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool "$auto_bool" || true

  # Keep security responses & system files
  defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true || true
  defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true || true

  # Reload prefs daemon (best-effort)
  killall -HUP cfprefsd >/dev/null 2>&1 || true
}

purge_tahoe_installer_and_cache() {
  log "Purging any downloaded ${UPGRADE_NAME} installer + clearing /Library/Updates cache..."

  # Remove "Install macOS <UPGRADE_NAME>.app" (and any installer whose name or display name matches)
  shopt -s nullglob
  local removed_any=0
  for app in /Applications/Install\ macOS*.app; do
    [[ -d "$app" ]] || continue
    local base display combined
    base="$(basename "$app")"
    display="$(defaults read "$app/Contents/Info" CFBundleDisplayName 2>/dev/null || true)"
    combined="${base} ${display}"
    if printf "%s" "$combined" | grep -qi "$UPGRADE_NAME"; then
      log "  Removing: $app"
      rm -rf "$app" || warn "Failed to remove $app (check permissions/SIP)."
      removed_any=1
    fi
  done
  shopt -u nullglob
  [[ "$removed_any" -eq 1 ]] || log "  No ${UPGRADE_NAME} installer app found in /Applications."

  # Clear cached downloads (best-effort)
  if [[ -d /Library/Updates ]]; then
    if rm -rf /Library/Updates/* 2>/dev/null; then
      log "  Cleared: /Library/Updates/*"
    else
      warn "Could not fully clear /Library/Updates (some files may be protected/locked)."
    fi
  else
    log "  /Library/Updates does not exist (nothing to clear)."
  fi
}

suppress_major_upgrade_nag_for_user() {
  local u="$1"
  log "Suppressing major-upgrade notification for user: $u"
  run_as_user "$u" defaults write com.apple.SoftwareUpdate MajorOSUserNotificationDate -date "$FUTURE_DATE" || \
    warn "Failed to set MajorOSUserNotificationDate for $u."
}

unsuppress_major_upgrade_nag_for_user() {
  local u="$1"
  log "Removing major-upgrade notification suppression for user: $u"
  run_as_user "$u" defaults delete com.apple.SoftwareUpdate MajorOSUserNotificationDate >/dev/null 2>&1 || true
}

make_deferral_profile() {
  local target_user="$1"
  local home out profile_uuid payload_uuid

  is_int_between "$DEFERRAL_DAYS" 1 90 || die "--days must be an integer between 1 and 90."

  home="$(get_user_home "$target_user")"
  out="${home}/Downloads/defer-major-upgrades-${DEFERRAL_DAYS}days.mobileconfig"
  profile_uuid="$(uuidgen)"
  payload_uuid="$(uuidgen)"

  local tmp_profile="${WORK_DIR}/profile.mobileconfig"

  log "Generating deferral profile (major upgrades only, ${DEFERRAL_DAYS} days) at:"
  log "  $out"

  cat > "$tmp_profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.applicationaccess</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadIdentifier</key>
      <string>${PAYLOAD_IDENTIFIER}</string>
      <key>PayloadUUID</key>
      <string>${payload_uuid}</string>
      <key>PayloadEnabled</key>
      <true/>
      <key>PayloadDisplayName</key>
      <string>Defer Major macOS Upgrades</string>
      <key>PayloadScope</key>
      <string>System</string>

      <!-- Defer MAJOR OS upgrades only -->
      <key>forceDelayedMajorSoftwareUpdates</key>
      <true/>
      <key>enforcedSoftwareUpdateMajorOSDeferredInstallDelay</key>
      <integer>${DEFERRAL_DAYS}</integer>

      <!-- Ensure we are NOT deferring minor OS or app updates -->
      <key>forceDelayedSoftwareUpdates</key>
      <false/>
      <key>forceDelayedAppSoftwareUpdates</key>
      <false/>
    </dict>
  </array>

  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadIdentifier</key>
  <string>${PROFILE_IDENTIFIER}</string>
  <key>PayloadUUID</key>
  <string>${profile_uuid}</string>
  <key>PayloadDisplayName</key>
  <string>Defer Major macOS Upgrades (${DEFERRAL_DAYS} days)</string>
  <key>PayloadOrganization</key>
  <string>Local</string>
</dict>
</plist>
EOF

  # Validate profile format before copying to final location
  if plutil -lint "$tmp_profile" >/dev/null 2>&1; then
    log "  Profile validated (plutil -lint OK)."
  else
    warn "Profile did not validate with plutil. It may still work, but review the file."
  fi

  # Copy validated profile to final location
  cp "$tmp_profile" "$out" || die "Failed to write profile to $out"
  chown "$target_user" "$out" 2>/dev/null || true

  # Try CLI install first; fall back to UI if it fails (common on recent macOS for unsigned profiles)
  if /usr/bin/profiles install -type configuration -path "$out" 2>/dev/null; then
    log "  Profile installed via CLI. Verify in System Settings → Profiles."
  else
    log "  CLI install not available, opening for manual approval..."
    run_as_user "$target_user" open "$out" || warn "Could not open the profile automatically. Open it manually: $out"
    sleep 2
    run_as_user "$target_user" open "x-apple.systempreferences:com.apple.preferences.configurationprofiles" || true

    log ""
    log "Profile install reminder:"
    log "  System Settings → (Profile Downloaded / Device Management / Profiles) → Install"
    log "  Then return to System Settings → General → Software Update."
  fi
}

show_status() {
  local product_name product_version os_major console_user
  product_name="$(sw_vers -productName 2>/dev/null || echo "macOS")"
  product_version="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
  os_major="${product_version%%.*}"
  console_user="$(get_console_user)"

  log "=== Status ==="
  log "OS: ${product_name} ${product_version} (major ${os_major})"
  if [[ "$os_major" == "15" ]]; then
    log "Detected: Sequoia (15.x)"
  else
    warn "Not on macOS 15.x (Sequoia). Script still may work, but it was written for Sequoia."
  fi

  log ""
  log "Software Update schedule:"
  softwareupdate --schedule 2>/dev/null || warn "Could not query softwareupdate schedule."

  log ""
  log "System-wide SoftwareUpdate prefs (subset):"
  for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do
    local v
    v="$(defaults read /Library/Preferences/com.apple.SoftwareUpdate "$k" 2>/dev/null || echo "<unset>")"
    log "  $k = $v"
  done

  log ""
  log "User nag suppression (MajorOSUserNotificationDate) for console user: $console_user"
  run_as_user "$console_user" defaults read com.apple.SoftwareUpdate MajorOSUserNotificationDate 2>/dev/null \
    || log "  <unset>"

  log ""
  log "Installers in /Applications matching 'Install macOS*.app':"
  shopt -s nullglob
  local found=0
  for app in /Applications/Install\ macOS*.app; do
    [[ -d "$app" ]] || continue
    found=1
    log "  $(basename "$app")"
  done
  shopt -u nullglob
  [[ "$found" -eq 1 ]] || log "  <none>"

  log ""
  log "/Library/Updates contents:"
  if [[ -d /Library/Updates ]]; then
    find /Library/Updates -maxdepth 1 -ls 2>/dev/null | sed 's/^/  /' || true
  else
    log "  <no /Library/Updates directory>"
  fi
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --status) MODE="status" ;;
    --undo) MODE="undo" ;;
    --uninstall-profile) MODE="uninstall_profile" ;;
    --manual) AUTO_INSTALL=0 ;;
    --no-profile) MAKE_PROFILE=0 ;;
    --profile-only) MODE="profile_only" ;;
    --days)
      shift
      [[ $# -gt 0 ]] || die "--days requires a value"
      DEFERRAL_DAYS="$1"
      ;;
    --date)
      shift
      [[ $# -gt 0 ]] || die "--date requires a value"
      FUTURE_DATE="$1"
      ;;
    --all-users) ALL_USERS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

# ---- Validate inputs ----
[[ "$FUTURE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] || \
  die "Invalid --date format: '$FUTURE_DATE' (expected 'YYYY-MM-DD HH:MM:SS +0000')"

# ---- Requirements ----
need_cmd sw_vers
need_cmd defaults
need_cmd softwareupdate
need_cmd uuidgen
need_cmd plutil
need_cmd dscl
need_cmd stat
need_cmd rm
need_cmd open
need_cmd killall
need_cmd awk
need_cmd grep
need_cmd sudo

# Root needed for apply/undo/profile_only because we write /Library prefs and remove /Library/Updates and /Applications installers
if [[ "$MODE" == "status" ]]; then
  ensure_root_if_needed 0
else
  ensure_root_if_needed 1
fi

CONSOLE_USER="$(get_console_user)"

# ---- Temp directory with cleanup trap ----
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- Execute ----
case "$MODE" in
  status)
    show_status
    ;;
  undo)
    log "Undo: removing only MajorOSUserNotificationDate nag suppression."
    if [[ "$ALL_USERS" -eq 1 ]]; then
      while read -r u; do
        unsuppress_major_upgrade_nag_for_user "$u"
      done < <(list_local_users_uid_ge_501)
    else
      unsuppress_major_upgrade_nag_for_user "$CONSOLE_USER"
    fi
    log "Done."
    ;;
  profile_only)
    make_deferral_profile "$CONSOLE_USER"
    ;;
  uninstall_profile)
    log "Removing deferral profile (identifier: ${PROFILE_IDENTIFIER})..."
    if /usr/bin/profiles show -type configuration 2>/dev/null | grep -q "$PROFILE_IDENTIFIER"; then
      /usr/bin/profiles remove -identifier "$PROFILE_IDENTIFIER" 2>/dev/null || \
        warn "Failed to remove profile. Try removing it manually in System Settings → Profiles."
      log "Done."
    else
      log "Profile not found (identifier: ${PROFILE_IDENTIFIER}). Nothing to remove."
    fi
    ;;
  apply)
    # Warn if not Sequoia (15.x), but proceed
    PV="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
    OM="${PV%%.*}"
    if [[ "$OM" != "15" ]]; then
      warn "You are not on macOS 15.x (Sequoia). Continuing anyway."
    fi

    configure_updates
    purge_tahoe_installer_and_cache

    if [[ "$ALL_USERS" -eq 1 ]]; then
      log "Applying nag suppression for ALL local users (UID >= 501)..."
      while read -r u; do
        suppress_major_upgrade_nag_for_user "$u"
      done < <(list_local_users_uid_ge_501)
    else
      suppress_major_upgrade_nag_for_user "$CONSOLE_USER"
    fi

    if [[ "$MAKE_PROFILE" -eq 1 ]]; then
      make_deferral_profile "$CONSOLE_USER"
    else
      log "Skipping deferral profile (--no-profile)."
    fi

    log ""
    log "Done. Quick status:"
    show_status
    ;;
  *)
    die "Unknown mode: $MODE"
    ;;
esac
