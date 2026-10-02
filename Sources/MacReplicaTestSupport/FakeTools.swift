import Foundation

/// Stand-ins for `brew`, `mas`, `xcode-select`, `pkgutil` and `mdls`.
///
/// They mimic the output formats MacReplica parses and keep all state in
/// `<root>/state`, so integration tests run the real `ProcessCommandRunner`,
/// real parsing and real verification, but never change the actual Mac.
/// Failures (offline, unknown package, App Store sign-in, broken Homebrew …)
/// are switched on by creating files in the state folder.
enum FakeTools {
    static let library = #"""
    #!/bin/bash
    # Shared helpers for MacReplica's simulated tools.
    ROOT="${MACREPLICA_SIMULATION_ROOT:?MACREPLICA_SIMULATION_ROOT is not set}"
    S="$ROOT/state"

    sim_delay() {
      if [ -f "$S/delay" ]; then sleep "$(cat "$S/delay")"; fi
      return 0
    }

    json_value() { # file key
      sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
    }

    make_app() { # path bundle_id version
      mkdir -p "$1/Contents/MacOS"
      local exe
      exe="$(basename "$1" .app | tr -d ' ')"
      cat > "$1/Contents/Info.plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleShortVersionString</key><string>$3</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    </dict></plist>
    PLIST
      printf 'simulated' > "$1/Contents/MacOS/$exe"
    }

    fail_if_needed() { # package
      if [ -f "$S/offline" ]; then
        echo "curl: (6) Could not resolve host: formulae.brew.sh" >&2
        echo "Error: Download failed" >&2
        exit 1
      fi
      if [ -f "$S/fail-once/$1" ]; then
        cat "$S/fail-once/$1" >&2
        rm -f "$S/fail-once/$1"
        exit 1
      fi
      if [ -f "$S/fail/$1" ]; then
        cat "$S/fail/$1" >&2
        exit 1
      fi
      return 0
    }

    log_call() { echo "$*" >> "$S/calls.log"; }
    """#

    static let brew = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "brew $*"
    if [ -f "$S/brew-broken" ]; then echo "Error: Homebrew is broken (simulated)" >&2; exit 1; fi
    mkdir -p "$S/brew/formulae" "$S/brew/casks" "$S/brew/taps"

    case "${1:-}" in
      --version)
        echo "Homebrew 4.4.0"
        exit 0 ;;
      info)
        if [ -f "$S/scan-delay" ]; then sleep "$(cat "$S/scan-delay")"; fi
        printf '{"formulae":['
        first=1
        for f in "$S"/brew/formulae/*; do
          [ -e "$f" ] || continue
          n="$(basename "$f")"; v="$(cat "$f")"
          req=true; [ -f "$S/brew/dependency/$n" ] && req=false
          tap="homebrew/core"; [ -f "$S/brew/formula-tap/$n" ] && tap="$(cat "$S/brew/formula-tap/$n")"
          [ $first = 1 ] || printf ','
          first=0
          printf '{"name":"%s","full_name":"%s","tap":"%s","installed":[{"version":"%s","installed_on_request":%s}]}' "$n" "$n" "$tap" "$v" "$req"
        done
        printf '],"casks":['
        first=1
        for f in "$S"/brew/casks/*; do
          [ -e "$f" ] || continue
          t="$(basename "$f")"; v="$(cat "$f")"
          spec="$S/brew/available/casks/$t.json"; app=""
          [ -f "$spec" ] && app="$(json_value "$spec" app)"
          artifacts='[]'
          [ -n "$app" ] && artifacts="[{\"app\":[\"$app\"]}]"
          [ $first = 1 ] || printf ','
          first=0
          printf '{"token":"%s","full_token":"%s","tap":"homebrew/cask","installed":"%s","artifacts":%s}' "$t" "$t" "$v" "$artifacts"
        done
        printf ']}\n'
        exit 0 ;;
      tap-info)
        printf '['
        first=1
        for f in "$S"/brew/taps/*; do
          [ -e "$f" ] || continue
          n="$(basename "$f" | sed 's#__#/#')"; r="$(cat "$f")"
          [ $first = 1 ] || printf ','
          first=0
          printf '{"name":"%s","remote":"%s","installed":true}' "$n" "$r"
        done
        printf ']\n'
        exit 0 ;;
      tap)
        if [ $# -ge 2 ]; then
          sim_delay
          fail_if_needed "tap-$2"
          printf '%s' "${3:-https://github.com/$2}" > "$S/brew/taps/$(echo "$2" | sed 's#/#__#')"
          echo "==> Tapping $2"
          exit 0
        fi
        for f in "$S"/brew/taps/*; do
          [ -e "$f" ] || continue
          basename "$f" | sed 's#__#/#' | tr '[:upper:]' '[:lower:]'
        done
        exit 0 ;;
      list)
        kind="${2:-}"; name="${4:-}"
        if [ "$kind" = "--formula" ]; then f="$S/brew/formulae/$name"; else f="$S/brew/casks/$name"; fi
        if [ -n "$name" ] && [ -f "$f" ]; then echo "$name $(cat "$f")"; exit 0; fi
        echo "Error: No such keg or cask: $name" >&2
        exit 1 ;;
      install)
        kind="${2:-}"; name="${3:-}"
        sim_delay
        fail_if_needed "$name"
        if [ "$kind" = "--formula" ]; then
          case "$name" in python@*)
            minor="${name#python@}"
            if [ -f "$S/brew/available/formulae/$name" ]; then
              prefix="$(cd "$(dirname "$0")/.." && pwd)"
              mkdir -p "$prefix/opt/$name/bin" "$prefix/Cellar/$name/$(cat "$S/brew/available/formulae/$name")"
              cp "$ROOT/tools/python" "$prefix/opt/$name/bin/python$minor"
              chmod 755 "$prefix/opt/$name/bin/python$minor"
            fi ;;
          esac
          spec="$S/brew/available/formulae/$name"
          [ -f "$spec" ] || { echo "Error: No available formula with the name \"$name\"." >&2; exit 1; }
          cp "$spec" "$S/brew/formulae/$name"
          if [ "$name" = "mas" ]; then
            prefix="$(cd "$(dirname "$0")/.." && pwd)"
            cp "$ROOT/tools/mas" "$prefix/bin/mas"
            chmod 755 "$prefix/bin/mas"
          fi
          echo "==> Pouring $name"
          exit 0
        fi
        spec="$S/brew/available/casks/$name.json"
        [ -f "$spec" ] || { echo "Error: Cask '$name' is unavailable: No Cask with this name exists." >&2; exit 1; }
        version="$(json_value "$spec" version)"; app="$(json_value "$spec" app)"; bid="$(json_value "$spec" bundle_id)"
        if [ -f "$S/needs-admin/$name" ]; then
          if [ -z "${SUDO_ASKPASS:-}" ]; then echo "sudo: a terminal is required to read the password" >&2; exit 1; fi
        fi
        if [ -n "$app" ]; then
          appdir="$(cat "$S/appdir")"
          if [ -e "$appdir/$app" ]; then echo "Error: It seems there is already an App at '$appdir/$app'." >&2; exit 1; fi
          make_app "$appdir/$app" "$bid" "$version"
        fi
        printf '%s' "$version" > "$S/brew/casks/$name"
        echo "==> Installing Cask $name"
        exit 0 ;;
    esac
    echo "Error: Unknown command: $*" >&2
    exit 1
    """#

    static let mas = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "mas $*"
    mkdir -p "$S/mas/installed"
    case "${1:-}" in
      version) echo "1.8.7"; exit 0 ;;
      list)
        for f in "$S"/mas/installed/*; do
          [ -e "$f" ] || continue
          printf '%s  %s\n' "$(basename "$f")" "$(cat "$f")"
        done
        exit 0 ;;
      install)
        id="${2:-}"
        sim_delay
        if [ -f "$S/mas/signed-out" ]; then echo "Error: Not signed in" >&2; exit 1; fi
        fail_if_needed "mas-$id"
        spec="$S/mas/available/$id.json"
        [ -f "$spec" ] || { echo "Error: No apps found in the Mac App Store for app ID $id" >&2; exit 1; }
        name="$(json_value "$spec" name)"; version="$(json_value "$spec" version)"; bid="$(json_value "$spec" bundle_id)"; app="$(json_value "$spec" app)"
        make_app "$(cat "$S/appdir")/$app" "$bid" "$version"
        printf '%s  (%s)' "$name" "$version" > "$S/mas/installed/$id"
        echo "==> Installed $name"
        exit 0 ;;
    esac
    echo "Error: Unknown command" >&2
    exit 1
    """#

    /// A stand-in for Homebrew's Python: supports `-m venv` and `-m pip --python <env> install`.
    static let python = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "python $*"
    self="$0"
    minor="$(basename "$self" | sed 's/^python//')"
    full="$(cat "$S/python-full-version" 2>/dev/null || echo "$minor.7")"
    if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
      env="${3:?}"
      sim_delay
      mkdir -p "$env/bin" "$env/lib/python$minor/site-packages"
      printf 'home = %s\ninclude-system-site-packages = false\nversion = %s\n' "$(dirname "$self")" "$full" > "$env/pyvenv.cfg"
      printf 'simulated' > "$env/bin/python"
      for p in pip:24.2 setuptools:75.1.0; do
        n="${p%%:*}"; v="${p##*:}"
        mkdir -p "$env/lib/python$minor/site-packages/$n-$v.dist-info"
        printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$n" "$v" > "$env/lib/python$minor/site-packages/$n-$v.dist-info/METADATA"
      done
      exit 0
    fi
    if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ] && [ "${3:-}" = "--python" ]; then
      env="${4:?}"; shift 5
      site="$env/lib/python$minor/site-packages"
      [ -d "$site" ] || { echo "ERROR: not a virtual environment" >&2; exit 1; }
      sim_delay
      if [ -f "$S/offline" ]; then
        echo "WARNING: Retrying after connection broken by 'NewConnectionError: Failed to establish a new connection'" >&2
        echo "ERROR: Could not find a version that satisfies the requirement (from versions: none)" >&2
        exit 1
      fi
      requests=()
      for a in "$@"; do case "$a" in -*) ;; *) requests+=("$a") ;; esac; done
      for r in "${requests[@]}"; do
        n="${r%%==*}"; v=""; [ "$r" != "$n" ] && v="${r#*==}"
        if [ -f "$S/pip/missing/$n" ]; then echo "ERROR: No matching distribution found for $r" >&2; exit 1; fi
        if [ -n "$v" ] && [ -f "$S/pip/latest/$n" ] && [ "$(cat "$S/pip/latest/$n")" != "$v" ]; then
          echo "ERROR: Could not find a version that satisfies the requirement $r" >&2
          echo "ERROR: No matching distribution found for $r" >&2
          exit 1
        fi
      done
      for r in "${requests[@]}"; do
        n="${r%%==*}"; v=""; [ "$r" != "$n" ] && v="${r#*==}"
        [ -z "$v" ] && v="$(cat "$S/pip/latest/$n" 2>/dev/null || echo 1.0.0)"
        rm -rf "$site/$n"-*.dist-info
        mkdir -p "$site/$n-$v.dist-info"
        printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$n" "$v" > "$site/$n-$v.dist-info/METADATA"
        echo "Successfully installed $n-$v"
      done
      exit 0
    fi
    echo "Python $full (simulated)"
    exit 0
    """#


    static let xcodeSelect = #"""
    #!/bin/bash
    set -u
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "xcode-select $*"
    marker="$ROOT/CommandLineTools/usr/bin/git"
    case "${1:-}" in
      -p)
        if [ -f "$marker" ]; then echo "$ROOT/CommandLineTools"; exit 0; fi
        echo "xcode-select: error: unable to get active developer directory" >&2
        exit 2 ;;
      --install)
        wait="1"; [ -f "$S/clt-delay" ] && wait="$(cat "$S/clt-delay")"
        if [ -f "$S/clt-never" ]; then echo "xcode-select: note: install requested"; exit 0; fi
        ( sleep "$wait"; mkdir -p "$ROOT/CommandLineTools/usr/bin"; printf 'git' > "$marker"; printf 'clang' > "$ROOT/CommandLineTools/usr/bin/clang" ) >/dev/null 2>&1 &
        echo "xcode-select: note: install requested for command line developer tools"
        exit 0 ;;
    esac
    exit 1
    """#

    static let pkgutil = #"""
    #!/bin/bash
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "pkgutil $*"
    if [ "${1:-}" = "--file-info" ]; then
      echo "volume: /"
      echo "path: ${2:-}"
      name="$(basename "${2:-}")"
      if [ -f "$S/pkg/$name" ]; then echo ""; echo "pkgid: $(cat "$S/pkg/$name")"; echo "pkg-version: 1.0"; fi
      exit 0
    fi
    exit 1
    """#

    static let mdls = #"""
    #!/bin/bash
    . "${MACREPLICA_SIMULATION_ROOT:?}/tools/lib.sh"
    log_call "mdls $*"
    name="$(basename "${4:-}")"
    if [ -f "$S/adam/$name" ]; then cat "$S/adam/$name"; else printf '(null)'; fi
    exit 0
    """#
}
