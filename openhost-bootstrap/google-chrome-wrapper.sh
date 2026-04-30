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
