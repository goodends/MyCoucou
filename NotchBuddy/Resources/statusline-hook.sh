#!/bin/bash
# Statusline wrapper — sits between Claude Code and whatever statusline you
# already had.
#
# Claude Code's `StatusLine` hook is the only integration point that reports
# live context-window usage; no other hook carries token counts and `/context`
# has no scriptable form. This saves the payload so NotchBuddy can read
# `context_window.used_percentage` and `context_window_size` without having to
# guess the window size from a model name — which it cannot do in general,
# since a gateway may map one model name to a 200k or a 1M backend.
#
# Usage:  pipe a statusline JSON payload into this script.
# Install: point `statusLine.command` in ~/.claude/settings.json at this file.
#          NotchBuddy's settings do that, and save the command they replaced.
#
# Three things it deliberately does:
#   - Only save while NotchBuddy's setting is on. The flag is a file, not a
#     preference: Claude Code runs this without the app being open, and a
#     bash script cannot read the app's defaults.
#   - Skip the write when the payload is unchanged. Claude Code redraws a
#     statusline roughly every 300ms, and rewriting an identical file that often
#     wakes the filesystem for nothing.
#   - Hand the original payload to the saved statusline and pass its exit
#     status straight through. A statusline that breaks is worse than one that
#     is missing, and this script is in its path.

set -uo pipefail

support_dir="$HOME/Library/Application Support/NotchBuddy"
payload=$(cat)

if [ -f "$support_dir/statusline-enabled" ]; then
    # `session_id` is the payload's own field; fall back to Claude Code's env
    # var for the rare case the field is missing.
    sid=$(printf '%s' "$payload" | /usr/bin/python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("session_id") or "")' 2>/dev/null || true)
    [ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-unknown}"

    out_dir="$support_dir/statusline"
    out="$out_dir/$sid.json"

    if /bin/mkdir -p "$out_dir" 2>/dev/null; then
        # Compare before writing so an unchanged payload costs no write at all.
        if ! /bin/cmp -s "$out" <(printf '%s' "$payload") 2>/dev/null; then
            # Write to a temp file and rename, so NotchBuddy never reads a
            # half-written payload.
            tmp="$out_dir/.$sid.$$.tmp"
            if printf '%s' "$payload" > "$tmp" 2>/dev/null; then
                /bin/mv -f "$tmp" "$out" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null
            fi
        fi
    fi
fi

# Hand off to the statusline this one replaced. NotchBuddy saves the original
# command at install time, so whatever the user ran before — claude-hud, a
# shell script of their own, anything — keeps working untouched. Without that
# file the wrapper is pointed at something it did not install; say nothing and
# let Claude Code draw a blank statusline, which is what a broken one looks
# like anyway.
statusline_command=""
[ -f "$support_dir/statusline-original" ] && statusline_command=$(cat "$support_dir/statusline-original")

[ -n "$statusline_command" ] || exit 0

printf '%s' "$payload" | /bin/bash -c "$statusline_command"