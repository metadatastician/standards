#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# @a2ml-metadata begin
# (
#   id                   = "<app-name>-launcher"
#   type                 = "launcher"
#   version              = "1.0.0"
#   app-name             = "<app-name>"
#   app-display          = "<App Display Name>"
#   app-url              = "http://localhost:<port>"
#   standards-compliance = [
#     "launcher-standard.adoc"
#     "LM-LA-LIFECYCLE-STANDARD.adoc"
#     "cross-platform-system-integration-modes"
#   ]
#   modes = [
#     "--start"
#     "--stop"
#     "--status"
#     "--auto"
#     "--browser"
#     "--integ"
#     "--disinteg"
#     "--help"
#   ]
#   platforms = [
#     "linux"
#     "macos"
#     "windows"
#   ]
#   lifecycle-phases-covered = [
#     "install"
#     "run"
#     "stop"
#     "status"
#     "uninstall"
#   ]
#   lifecycle-phases-deferred = [
#     "warmup"
#     "configure"
#     "personalize"
#     "update"
#     "repair"
#   ]
#   desktop-file-permissions = 444
#   integrity-verification   = "verify-desktop-integrity.sh"
# )
# @a2ml-metadata end
#
# ============================================================================
# COMPREHENSIVE LAUNCHER TEMPLATE
# ============================================================================
#
# D-SIP-FV-MA Compliant: Dependable, Secure, Interoperable, Performant,
# Functional, Versatile, Metaiconic, Accessible
#
# Purpose: Provide a robust, self-healing launcher for desktop applications
# that handles process management, error recovery, user feedback, and full
# cross-platform system integration (Start Menu / Applications folder /
# Desktop shortcut, on Linux / macOS / Windows).
#
# Usage: Customize the CONFIGURATION section (and the A2ML header above) for
# each application. Everything else — integ, disinteg, error handling,
# platform detection — is generic and should not need editing.
#
# Integration Points:
#   • Feedback-o-tron: Automatic error reporting and telemetry
#   • Hypatia: LLM-assisted troubleshooting and exhausted support
#   • Dustfiles: Targeted automated repair
#   • verify-desktop-integrity.sh: LM-LA-LIFECYCLE integrity hashes
#
# ============================================================================

set -euo pipefail

# ============================================================================
# CONFIGURATION - Customize for each application
# ============================================================================
APP_NAME="TemplateApp"                    # Application name (command-line form, lowercase)
APP_DISPLAY="Template App"                # Human-readable display name
APP_DESC="Short one-liner shown in menus" # Description
APP_CATEGORIES="Development;Utility;"     # Freedesktop categories
REPO_DIR="/path/to/repo"                  # Repository directory
COMMAND="command to run"                  # Command to execute
URL="http://localhost:PORT"               # URL if web app (empty if not)
ICON_SOURCE="$REPO_DIR/assets/icon-256.png" # Source icon for --integ (optional)
# Never /tmp for pid/log (CWE-377: predictable shared path) — see launcher-standard.adoc
PID_FILE="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/launch-scaffolder/${APP_NAME,,}/server.pid"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/launch-scaffolder/${APP_NAME,,}/server.log"
MODE="${1:---auto}"                       # Default mode
FORCE="false"                             # --force flag (used by --integ)
[[ "${2:-}" == "--force" ]] && FORCE="true"

# ----------------------------------------------------------------------------
# PLATFORM DETECTION — required for --integ / --disinteg
# ----------------------------------------------------------------------------
case "$(uname -s)" in
    Linux*)                          PLATFORM="linux"   ;;
    Darwin*)                         PLATFORM="macos"   ;;
    CYGWIN*|MINGW*|MSYS*|Windows_NT) PLATFORM="windows" ;;
    *)                               PLATFORM="unknown" ;;
esac

case "$PLATFORM" in
    linux)
        APPS_DIR="$HOME/.local/share/applications"
        ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
        DESKTOP_SHORTCUT_DIR="$HOME/Desktop"
        BIN_DIR="$HOME/.local/bin"
        DESKTOP_FILE_TARGET="$APPS_DIR/${APP_NAME}.desktop"
        DESKTOP_SHORTCUT_TARGET="$DESKTOP_SHORTCUT_DIR/${APP_NAME}.desktop"
        ICON_TARGET="$ICON_DIR/${APP_NAME}.png"
        LAUNCHER_TARGET="$BIN_DIR/${APP_NAME}-launcher"
        ;;
    macos)
        APPS_DIR="$HOME/Applications"
        DESKTOP_SHORTCUT_DIR="$HOME/Desktop"
        BIN_DIR="$HOME/.local/bin"
        DESKTOP_FILE_TARGET="$APPS_DIR/${APP_DISPLAY}.app"
        DESKTOP_SHORTCUT_TARGET="$DESKTOP_SHORTCUT_DIR/${APP_DISPLAY}.command"
        ICON_TARGET="$APPS_DIR/${APP_DISPLAY}.app/Contents/Resources/icon.png"
        LAUNCHER_TARGET="$BIN_DIR/${APP_NAME}-launcher"
        ;;
    windows)
        APPDATA_DIR="${APPDATA:-$HOME/AppData/Roaming}"
        START_MENU_DIR="$APPDATA_DIR/Microsoft/Windows/Start Menu/Programs"
        DESKTOP_SHORTCUT_DIR="$HOME/Desktop"
        BIN_DIR="$HOME/.local/bin"
        DESKTOP_FILE_TARGET="$START_MENU_DIR/${APP_DISPLAY}.lnk"
        DESKTOP_SHORTCUT_TARGET="$DESKTOP_SHORTCUT_DIR/${APP_DISPLAY}.lnk"
        ICON_TARGET="$BIN_DIR/${APP_NAME}.ico"
        LAUNCHER_TARGET="$BIN_DIR/${APP_NAME}-launcher.sh"
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log() {
  echo "[$APP_NAME] $1"
}

err() {
  echo "[$APP_NAME] ERROR: $1" >&2
}

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

wait_for_url() {
  local max_wait=$1
  local waited=0
  
  if [ -z "$URL" ]; then return 0; fi
  
  while [ $waited -lt $max_wait ]; do
    if curl -fsS "$URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  
  return 1
}

start_server() {
  if is_running; then
    log "Server already running (PID: $(cat "$PID_FILE"))"
    return 0
  fi
  
  log "Starting $APP_NAME server..."
  
  # Start in background with nohup to prevent process from being killed
  cd "$REPO_DIR"
  mkdir -p -m 0700 "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"
  nohup $COMMAND >"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  
  # Wait for server to be ready
  if ! wait_for_url 15; then
    err "Server did not start within 15 seconds"
    err "Check log: $LOG_FILE"
    err ""
    err "Troubleshooting steps:"
    err "  1. Check if port $APP_PORT is available: 'lsof -i :$APP_PORT'"
    err "  2. Review server logs: 'tail -50 $LOG_FILE'"
    err "  3. Verify dependencies: '$COMMAND --version'"
    err "  4. See documentation: https://github.com/metadatastician/standards/blob/main/docs/UX-standards/launcher-standard.adoc"
    err ""
    err "For LLM-assisted troubleshooting:"
    err "  hypatia diagnose --app $APP_NAME --log $LOG_FILE"
    
    # Soft-attach: Report failure to feedback-o-tron if available
    if command -v feedback-o-tron >/dev/null 2>&1; then
      feedback-o-tron --event "launcher:start_failed" \
        --app "$APP_NAME" --url "$URL" --log "$LOG_FILE" \
        --error "Timeout after 15 seconds" 2>/dev/null || true
    fi
    
    return 1
  fi
  
  log "Server started successfully"
  
  # Soft-attach: Try to integrate with feedback-o-tron if available
  if command -v feedback-o-tron >/dev/null 2>&1; then
    feedback-o-tron --event "launcher:server_started" \
      --app "$APP_NAME" --url "$URL" --pid "$(cat "$PID_FILE")" \
      --log "$LOG_FILE" 2>/dev/null || true
  fi
  
  return 0
}

stop_server() {
  if ! is_running; then
    log "No running server found"
    return 0
  fi
  
  log "Stopping $APP_NAME server..."
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
  log "Server stopped"
}

open_browser() {
  if [ -z "$URL" ]; then
    log "No URL configured for this application"
    return 1
  fi
  
  if ! is_running; then
    err "Server is not running"
    return 1
  fi
  
  log "Opening $APP_NAME at $URL..."
  
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" &
  elif command -v firefox >/dev/null 2>&1; then
    firefox "$URL" &
  elif command -v chromium >/dev/null 2>&1; then
    chromium "$URL" &
  else
    warn "No browser found - please manually open: $URL"
    warn ""
    warn "If you're on a headless system or minimal environment:"
    warn "  1. Install a browser: 'sudo dnf install firefox' or 'sudo apt install chromium'"
    warn "  2. Or use curl to test: 'curl -v $URL'"
    warn "  3. See: https://github.com/metadatastician/standards/blob/main/docs/UX-standards/launcher-standard.adoc#browser-issues"
  fi
  
  # Soft-attach: Report browser launch attempt
  if command -v feedback-o-tron >/dev/null 2>&1; then
    feedback-o-tron --event "launcher:browser_launch" \
      --app "$APP_NAME" --url "$URL" 2>/dev/null || true
  fi
}

# ============================================================================
# SYSTEM INTEGRATION — --integ / --disinteg
# ============================================================================
# See launcher-standard.adoc §System Integration Modes for the full spec.
# This implementation is cross-platform: linux / macos / windows (Git Bash).

already_integrated() {
    [ -f "$DESKTOP_FILE_TARGET" ] || [ -f "$LAUNCHER_TARGET" ]
}

write_linux_desktop_file() {
    local target="$1"
    # Pick the icon: custom if --integ installed one, otherwise fall back to
    # a freedesktop named icon that every standard theme provides. Suggested
    # fallbacks by app category:
    #   • Development tools      → applications-development
    #   • Container / package    → package-x-generic
    #   • System tool            → applications-system
    #   • Graphics / design      → applications-graphics
    #   • Games                  → applications-games
    #   • Generic app            → applications-other
    local icon_name
    if [ -f "$ICON_TARGET" ]; then
        icon_name="$APP_NAME"
    else
        icon_name="applications-other"  # safest generic fallback
    fi

    cat > "$target" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_DISPLAY
Comment=$APP_DESC
Exec=$LAUNCHER_TARGET --auto
Icon=$icon_name
Terminal=false
Categories=$APP_CATEGORIES
StartupNotify=true
StartupWMClass=$APP_NAME
Actions=stop;status;

[Desktop Action stop]
Name=Stop Server
Exec=$LAUNCHER_TARGET --stop

[Desktop Action status]
Name=Server Status
Exec=$LAUNCHER_TARGET --status
EOF
    # Per LM-LA-LIFECYCLE-STANDARD §LM/LA-INSTALL: desktop files are 444
    # (read-only for all) so they cannot be silently tampered with. To edit,
    # `chmod +w` first or re-run `--integ --force`.
    chmod 444 "$target"
}

do_integ_linux() {
    mkdir -p "$APPS_DIR" "$ICON_DIR" "$BIN_DIR" "$DESKTOP_SHORTCUT_DIR"
    cp "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$LAUNCHER_TARGET"
    chmod +x "$LAUNCHER_TARGET"
    [ -f "$ICON_SOURCE" ] && cp "$ICON_SOURCE" "$ICON_TARGET"

    # Desktop files are written 444 by write_linux_desktop_file. Deliberately
    # NOT chmod +x on .desktop files — modern KDE/GNOME don't require it and
    # the LM-LA-LIFECYCLE spec mandates 444 for tamper-resistance.
    write_linux_desktop_file "$DESKTOP_FILE_TARGET"
    write_linux_desktop_file "$DESKTOP_SHORTCUT_TARGET"

    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$APPS_DIR" 2>/dev/null || true

    # KDE Plasma trust metadata — suppresses "this is an untrusted .desktop
    # file" prompts on double-click.
    if command -v gio >/dev/null 2>&1; then
        gio set "$DESKTOP_FILE_TARGET" "metadata::trusted" true 2>/dev/null || true
        gio set "$DESKTOP_SHORTCUT_TARGET" "metadata::trusted" true 2>/dev/null || true
    fi

    # Integrity verification per LM-LA-LIFECYCLE §LM/LA-INSTALL. Soft-attach.
    if command -v verify-desktop-integrity.sh >/dev/null 2>&1; then
        verify-desktop-integrity.sh --generate 2>/dev/null || true
    fi
}

do_integ_macos() {
    mkdir -p "$APPS_DIR" "$BIN_DIR" "$DESKTOP_SHORTCUT_DIR"
    cp "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$LAUNCHER_TARGET"
    chmod +x "$LAUNCHER_TARGET"
    local bundle="$DESKTOP_FILE_TARGET"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_DISPLAY</string>
<key>CFBundleIdentifier</key><string>org.hyperpolymath.$APP_NAME</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>icon</string>
</dict></plist>
PLIST
    cat > "$bundle/Contents/MacOS/$APP_NAME" <<EOF
#!/usr/bin/env bash
exec "$LAUNCHER_TARGET" --auto
EOF
    chmod +x "$bundle/Contents/MacOS/$APP_NAME"
    [ -f "$ICON_SOURCE" ] && cp "$ICON_SOURCE" "$ICON_TARGET"
    cat > "$DESKTOP_SHORTCUT_TARGET" <<EOF
#!/usr/bin/env bash
exec "$LAUNCHER_TARGET" --auto
EOF
    chmod +x "$DESKTOP_SHORTCUT_TARGET"
}

do_integ_windows() {
    mkdir -p "$BIN_DIR" "$(dirname "$DESKTOP_FILE_TARGET")" "$DESKTOP_SHORTCUT_DIR"
    cp "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$LAUNCHER_TARGET"
    chmod +x "$LAUNCHER_TARGET"
    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -NonInteractive -Command "
            \$ws = New-Object -ComObject WScript.Shell
            \$sc = \$ws.CreateShortcut('$DESKTOP_FILE_TARGET')
            \$sc.TargetPath = 'bash.exe'
            \$sc.Arguments = '$LAUNCHER_TARGET --auto'
            \$sc.Save()
            \$sc2 = \$ws.CreateShortcut('$DESKTOP_SHORTCUT_TARGET')
            \$sc2.TargetPath = 'bash.exe'
            \$sc2.Arguments = '$LAUNCHER_TARGET --auto'
            \$sc2.Save()
        " 2>/dev/null
    else
        cat > "${DESKTOP_FILE_TARGET%.lnk}.bat" <<EOF
@echo off
bash.exe "$LAUNCHER_TARGET" --auto
EOF
        cat > "${DESKTOP_SHORTCUT_TARGET%.lnk}.bat" <<EOF
@echo off
bash.exe "$LAUNCHER_TARGET" --auto
EOF
    fi
}

do_integ() {
    if already_integrated && [ "$FORCE" != "true" ]; then
        warn "$APP_DISPLAY is already integrated with the system."
        read -rp "Reinstall? [y/N] " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { log "Nothing changed."; return 0; }
    fi
    log "Integrating $APP_DISPLAY with the $PLATFORM desktop..."
    case "$PLATFORM" in
        linux)   do_integ_linux   ;;
        macos)   do_integ_macos   ;;
        windows) do_integ_windows ;;
        *)       err "Unsupported platform: $PLATFORM"; return 1 ;;
    esac
    log "✓ $APP_DISPLAY integrated. Remove with: $LAUNCHER_TARGET --disinteg"
}

do_disinteg() {
    log "Removing $APP_DISPLAY system integration..."
    is_running && stop_server
    local targets=(
        "$DESKTOP_FILE_TARGET" "$DESKTOP_SHORTCUT_TARGET"
        "$ICON_TARGET" "$LAUNCHER_TARGET"
        "${DESKTOP_FILE_TARGET%.lnk}.bat" "${DESKTOP_SHORTCUT_TARGET%.lnk}.bat"
    )
    local removed="false"
    for t in "${targets[@]}"; do
        [ -z "$t" ] && continue
        if [ -e "$t" ] || [ -L "$t" ]; then
            [ -d "$t" ] && rm -rf "$t" || rm -f "$t"
            log "  - $t"
            removed="true"
        fi
    done
    [ "$PLATFORM" = "linux" ] && command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$APPS_DIR" 2>/dev/null || true
    rm -f "$PID_FILE"
    if [ "$removed" = "true" ]; then
        log "✓ $APP_DISPLAY removed. Config in ~/.config/$APP_NAME left in place."
    else
        log "Nothing to remove."
    fi
}

# Missing helper in the original template — needed by do_integ's prompt
warn() {
    echo "[$APP_NAME] WARN: $1" >&2
}

# ============================================================================
# MAIN SWITCH
# ============================================================================

case "$MODE" in
  --start)              start_server ;;
  --stop)               stop_server ;;
  --status)
    if is_running; then
      log "Server is running (PID: $(cat "$PID_FILE"))"
      [ -n "$URL" ] && log "URL: $URL"
    else
      log "Server is not running"
    fi
    ;;
  --browser|--web)      start_server && open_browser ;;
  --integ)              do_integ ;;
  --disinteg)           do_disinteg ;;
  --help|-h)
    cat <<EOF
$APP_DISPLAY launcher

Runtime modes:
  --start / --stop / --status / --auto (default) / --browser

System integration modes:
  --integ      Install as desktop app (cross-platform, idempotent)
  --disinteg   Remove everything --integ installed
  --integ --force   Reinstall without prompting

See: launcher-standard.adoc in the standards repo.
EOF
    ;;
  --auto|*)             start_server && open_browser ;;
esac
