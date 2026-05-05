#!/bin/bash
# Wrapper for /opt/google/chrome/google-chrome that strips arguments
# chromedriver injects which produce the "Chrome is being controlled
# by automated test software" infobar in jibri recordings.
#
# Why this exists:
#   Selenium ChromeDriver always passes --enable-automation (and a
#   few related flags) to the chrome binary it launches. The official
#   way to suppress this is to set
#       chromeOptions.setExperimentalOption("excludeSwitches",
#                                           ["enable-automation"])
#   on the Java side. Jibri (JibriSelenium.kt) does NOT do this, and
#   only reads `jibri.chrome.flags` from HOCON config -- not full
#   ChromeOptions.  So `--disable-infobars` alone is insufficient
#   because chrome treats the automation banner as a *separate*
#   infobar that ignores --disable-infobars.
#
# What it does:
#   Filters the argv we receive from chromedriver, dropping any
#   --enable-automation / --test-type=webdriver / similar switches,
#   then exec's the real chrome binary with the cleaned argv. This
#   is the same approach upstream chrome's wrapper script uses
#   (exec -a "$0" with the original argv preserved); we add a filter
#   step before the exec.
#
# We deliberately drop only switches known to trigger the infobar
# or expose the "automation" surface; everything else (including the
# kiosk, fake-ui, sandbox, and remote-debugging flags) is passed
# through unchanged.
set -e

# The real chrome binary lives in /opt/google/chrome/chrome; the
# upstream google-chrome wrapper sets up xdg paths and then exec's
# it. We replicate the relevant pieces of that wrapper here so any
# environment-variable dependencies (CHROME_WRAPPER, PATH for old
# xdg utilities) still work.

export CHROME_WRAPPER="$(readlink -f "$0")"
HERE="/opt/google/chrome"

if ! command -v xdg-settings >/dev/null 2>&1; then
    export PATH="$HERE:$PATH"
else
    xdg_app_dir="${XDG_DATA_HOME:-$HOME/.local/share/applications}"
    mkdir -p "$xdg_app_dir"
    [ -f "$xdg_app_dir/mimeapps.list" ] || touch "$xdg_app_dir/mimeapps.list"
fi

export CHROME_VERSION_EXTRA="stable"
export GNOME_DISABLE_CRASH_DIALOG=SET_BY_GOOGLE_CHROME

# Inherit DISPLAY from our jibri grand-parent if it's set.
#
# Why: jibri's JibriSelenium.kt hardcodes DISPLAY=":0" in the
# ChromeDriverService environment, so our parent (chromedriver)
# always passes DISPLAY=:0 to chrome regardless of what env our
# instance's run script set. With multiple jibri instances all
# rendering to display :0, only one instance's chrome is actually
# visible there; the others draw to a display they don't own
# (Xorg :1, :2, ... receive nothing) and the corresponding ffmpeg
# captures a black screen.
#
# Walk up the process tree from chromedriver to find the jibri
# java process; its -Dconfig.file=/etc/jitsi/jibri/jibri-N.conf
# tells us the instance index, from which we derive DISPLAY=:N.
detect_jibri_display() {
    local pid ppid cmdline
    pid="${PPID:-}"   # parent of our shell = chromedriver
    while [ -n "$pid" ] && [ "$pid" != "1" ]; do
        cmdline="$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)"
        case "$cmdline" in
            *jibri-0.conf*) echo ":0"; return 0 ;;
            *jibri-1.conf*) echo ":1"; return 0 ;;
            *jibri-2.conf*) echo ":2"; return 0 ;;
            *jibri-3.conf*) echo ":3"; return 0 ;;
            *jibri-4.conf*) echo ":4"; return 0 ;;
            *jibri-5.conf*) echo ":5"; return 0 ;;
        esac
        # walk one level up
        ppid="$(awk '/^PPid:/ {print $2}' /proc/$pid/status 2>/dev/null)"
        [ -z "$ppid" ] && return 1
        pid="$ppid"
    done
    return 1
}

if detected_display="$(detect_jibri_display)"; then
    export DISPLAY="$detected_display"
fi

# Filter chromedriver-injected automation switches. We only drop
# switches that are *purely* responsible for the automation infobar /
# automation surface; we deliberately leave --remote-debugging-port
# and --remote-debugging-pipe untouched (chromedriver uses one of
# those for its IPC channel; stripping them breaks the WebDriver
# session entirely).
filtered=()
for arg in "$@"; do
    case "$arg" in
        --enable-automation)            ;;
        --enable-automation=*)          ;;
        --test-type=webdriver)          ;;
        *)
            filtered+=("$arg")
            ;;
    esac
done

# Also append --no-default-browser-check / --no-first-run to be safe;
# these are normally passed by jibri.chrome.flags but if the operator
# overrides them we still want first-run popups suppressed.
filtered+=(--no-default-browser-check --no-first-run)

exec -a "$0" "$HERE/chrome" "${filtered[@]}"
