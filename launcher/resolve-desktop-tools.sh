#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# resolve-desktop-tools.sh — reference implementation of the path-resolution
# ladders declared in launcher/launcher-standard_praxis.deed (resolution).
#
# Downstream launchers SHOULD `source` this script and call
# `hp_resolve_desktop_tools` / `hp_resolve_standard` rather than rolling
# their own path-discovery logic — the standard's ladder will evolve, and
# centralising the implementation here keeps the estate aligned.
#
# Each function:
#   - Echoes the first existing matching path to stdout, exits 0.
#   - Echoes nothing and exits 1 if no candidate exists. The caller decides
#     whether that is fatal (e.g. missing keepopen.sh wrapper) or recoverable
#     (e.g. missing optional verify-desktop-integrity.sh).
#
# The ladders mirror (resolution (desktop-tools-search …)) and
# (resolution (standard-search …)) in the deed, whose :priority integers
# carry the order — not file position. They MUST stay in sync — see the
# CI gate referenced in launcher/README.adoc §Sync requirement.

# ---------------------------------------------------------------------------
# hp_resolve_desktop_tools [TOOL_NAME]
#
#   With no argument: echoes the first existing .desktop-tools/ directory.
#   With an argument: echoes the first existing .desktop-tools/<TOOL_NAME>.
# ---------------------------------------------------------------------------
hp_resolve_desktop_tools() {
    local tool="${1:-}"
    local -a candidates=(
        "${HP_DESKTOP_TOOLS:-}"
        "${HP_ESTATE_ROOT:+${HP_ESTATE_ROOT}/.desktop-tools}"
        "${XDG_DATA_HOME:-${HOME}/.local/share}/hyperpolymath/.desktop-tools"
        "/var/mnt/eclipse/repos/.desktop-tools"
        "${HOME}/developer/repos/.desktop-tools"
        "${HOME}/dev/repos/.desktop-tools"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -z "${candidate}" ]] && continue
        local target="${candidate}${tool:+/${tool}}"
        if [[ -e "${target}" ]]; then
            echo "${target}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# hp_resolve_standard
#
#   Echoes the first existing launcher-standard_praxis.deed found via the
#   (resolution (standard-search …)) ladder. Used by launch-scaffolder and any
#   other consumer that needs the canonical contract file.
# ---------------------------------------------------------------------------
hp_resolve_standard() {
    local -a candidates=(
        "${LAUNCH_SCAFFOLDER_STANDARD:-}"
        "${HP_ESTATE_ROOT:+${HP_ESTATE_ROOT}/standards/launcher/launcher-standard_praxis.deed}"
        "${XDG_DATA_HOME:-${HOME}/.local/share}/metadatastician/standards/launcher/launcher-standard_praxis.deed"
        "${XDG_DATA_HOME:-${HOME}/.local/share}/hyperpolymath/standards/launcher/launcher-standard_praxis.deed"  # former owner
        "/var/mnt/eclipse/repos/standards/launcher/launcher-standard_praxis.deed"
        "${HOME}/developer/repos/standards/launcher/launcher-standard_praxis.deed"
        "${HOME}/dev/repos/standards/launcher/launcher-standard_praxis.deed"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        [[ -z "${candidate}" ]] && continue
        if [[ -f "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

# When invoked directly (not sourced) act as a CLI that prints the resolved
# path for the requested tool, or all ladder candidates with --list.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --standard)
            hp_resolve_standard
            ;;
        --list)
            echo "desktop-tools-search:"
            printf '  %s\n' \
                "${HP_DESKTOP_TOOLS:-<unset>}" \
                "${HP_ESTATE_ROOT:+${HP_ESTATE_ROOT}/.desktop-tools}" \
                "${XDG_DATA_HOME:-${HOME}/.local/share}/hyperpolymath/.desktop-tools" \
                "/var/mnt/eclipse/repos/.desktop-tools" \
                "${HOME}/developer/repos/.desktop-tools" \
                "${HOME}/dev/repos/.desktop-tools"
            ;;
        "")
            hp_resolve_desktop_tools
            ;;
        *)
            hp_resolve_desktop_tools "$1"
            ;;
    esac
fi
