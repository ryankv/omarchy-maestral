#!/bin/bash
# Regression tests for the destructive path in uninstall.sh --purge.
#
# Every case runs the real script against a throwaway HOME with a PATH that
# contains only the tools the script needs, so neither maestral nor the
# omarchy-plugin-* commands can be reached and nothing outside the sandbox is
# touched. Run: ./test/uninstall-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN="$PWD"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Minimal PATH: just what uninstall.sh and venv-path.sh call.
mkdir -p "$sandbox/bin"
for tool in bash realpath readlink dirname rm; do
  ln -s "$(command -v "$tool")" "$sandbox/bin/$tool"
done

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

# Build a fresh fake HOME with sentinel files everywhere a bad path could hit.
make_home() {
  rm -rf "$sandbox/home"
  H="$sandbox/home"
  mkdir -p "$H/Documents" "$H/.local/share/other-app" "$H/.local/bin" "$H/.cache"
  echo keep > "$H/Documents/thesis.txt"
  echo keep > "$H/.local/share/other-app/data"
  echo keep > "$H/.local/share/loose-file"
}

# Create a directory that looks exactly like a venv install.sh made.
make_marked_venv() {
  mkdir -p "$1/bin" "$1/lib"
  echo "home = /usr/bin" > "$1/pyvenv.cfg"
  echo "io.github.ryankv.omarchy-maestral" > "$1/.omarchy-maestral-venv"
  echo '#!/bin/sh' > "$1/bin/maestral"
}

snapshot() { (cd "$H" && find . | sort); }

run_purge() {
  env -i HOME="$H" PATH="$sandbox/bin" MAESTRAL_VENV="$1" \
    bash "$PLUGIN/uninstall.sh" --purge >"$sandbox/out" 2>"$sandbox/err"
}

# Sanity check the sandbox itself: the plugin/system commands must be unreachable.
if env -i PATH="$sandbox/bin" bash -c 'command -v omarchy-plugin-disable || command -v maestral' >/dev/null 2>&1; then
  echo "sandbox PATH leaks system commands; aborting" >&2
  exit 1
fi

# --- Paths that must be refused, with nothing deleted -----------------------

make_home
make_marked_venv "$H/.local/share/maestral-venv"
ln -s "$H"                   "$H/.local/share/link-to-home"
ln -s /                      "$H/.local/share/link-to-root"
ln -s "$H/.local/share/maestral-venv" "$H/.local/share/link-to-venv"
before=$(snapshot)

refuse_cases=(
  "$H"
  "/"
  "$H/.local"
  "$H/.local/share"
  "$H/.local/share/"
  "$H/.local/share/."
  "$H/.local/share/maestral-venv/.."
  "$H/.local/share/../../Documents"
  "$H/Documents"
  "$H/.local/share/other-app"          # exists, but no venv, no marker
  "$H/.local/share/loose-file"         # a file, not a directory
  "$H/.local/share/does-not-exist"
  "$H/.local/share/link-to-home"       # symlink escaping the parent
  "$H/.local/share/link-to-root"
  "maestral-venv"                      # relative
  "$H/.local/share/maestral-venv/bin"  # inside a venv but not the venv
)
for path in "${refuse_cases[@]}"; do
  if run_purge "$path"; then
    fail "purge accepted '$path'"
  elif [[ $(snapshot) != "$before" ]]; then
    fail "purge of '$path' was refused but files changed"
  elif ! grep -q "Nothing was removed" "$sandbox/err"; then
    fail "purge of '$path' gave no refusal message"
  else
    pass "refused '${path:-<empty>}'"
  fi
done

# A directory under the parent with a marker but no pyvenv.cfg is not a venv.
mkdir -p "$H/.local/share/fake"
echo "io.github.ryankv.omarchy-maestral" > "$H/.local/share/fake/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$H/.local/share/fake" || [[ $(snapshot) != "$before" ]]; then
  fail "marker without pyvenv.cfg was purged"
else
  pass "refused marker without pyvenv.cfg"
fi

# A venv whose marker holds the wrong plugin id is not ours.
make_marked_venv "$H/.local/share/someone-elses-venv"
echo "org.example.other" > "$H/.local/share/someone-elses-venv/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$H/.local/share/someone-elses-venv" || [[ $(snapshot) != "$before" ]]; then
  fail "venv with foreign marker was purged"
else
  pass "refused venv with foreign marker"
fi

# A venv without any marker (an install predating the marker) is refused.
make_marked_venv "$H/.local/share/unmarked-venv"
rm "$H/.local/share/unmarked-venv/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$H/.local/share/unmarked-venv" || [[ $(snapshot) != "$before" ]]; then
  fail "unmarked venv was purged"
elif ! grep -q "Re-run install.sh" "$sandbox/err"; then
  fail "unmarked venv refusal did not explain how to stamp it"
else
  pass "refused unmarked venv"
fi

# --- The one path that must work -------------------------------------------

make_home
make_marked_venv "$H/.local/share/maestral-venv"
ln -s "$H/.local/share/maestral-venv/bin/maestral" "$H/.local/bin/maestral"
mkdir -p "$H/.cache/omarchy-maestral"; echo '{}' > "$H/.cache/omarchy-maestral/space.json"
if ! run_purge "$H/.local/share/maestral-venv"; then
  fail "purge of a stamped venv failed: $(cat "$sandbox/err")"
else
  [[ ! -e $H/.local/share/maestral-venv ]]   && pass "stamped venv removed"       || fail "stamped venv still present"
  [[ ! -L $H/.local/bin/maestral ]]          && pass "command link removed"       || fail "command link still present"
  [[ ! -e $H/.cache/omarchy-maestral ]]      && pass "cache removed"              || fail "cache still present"
  [[ -f $H/Documents/thesis.txt ]]           && pass "unrelated files intact"     || fail "unrelated files deleted"
  [[ -f $H/.local/share/other-app/data ]]    && pass "sibling data dir intact"    || fail "sibling data dir deleted"
fi

# An empty MAESTRAL_VENV means "the default", exactly as in install.sh.
make_home
make_marked_venv "$H/.local/share/maestral-venv"
if run_purge "" && [[ ! -e $H/.local/share/maestral-venv ]] && [[ -f $H/Documents/thesis.txt ]]; then
  pass "empty MAESTRAL_VENV purges the default venv only"
else
  fail "empty MAESTRAL_VENV was not treated as the default"
fi

# Same, reached through a symlink inside the parent: resolves to the real venv.
make_home
make_marked_venv "$H/.local/share/maestral-venv"
ln -s "$H/.local/share/maestral-venv" "$H/.local/share/link-to-venv"
if run_purge "$H/.local/share/link-to-venv" && [[ ! -e $H/.local/share/maestral-venv ]]; then
  pass "symlink to a stamped venv resolves and purges the real venv"
else
  fail "symlink to a stamped venv was not handled"
fi

# A command link that points somewhere else is left alone.
make_home
make_marked_venv "$H/.local/share/maestral-venv"
ln -s /usr/bin/true "$H/.local/bin/maestral"
run_purge "$H/.local/share/maestral-venv" || true
if [[ -L $H/.local/bin/maestral ]]; then
  pass "foreign command link kept"
else
  fail "foreign command link was removed"
fi

# Default path with no venv installed: refused, nothing else affected.
make_home
before=$(snapshot)
if env -i HOME="$H" PATH="$sandbox/bin" bash "$PLUGIN/uninstall.sh" --purge >/dev/null 2>"$sandbox/err"; then
  fail "purge with nothing installed succeeded"
elif [[ $(snapshot) != "$before" ]]; then
  fail "purge with nothing installed changed files"
else
  pass "nothing installed: refused cleanly"
fi

# Plain uninstall (no --purge) never deletes anything, whatever MAESTRAL_VENV says.
make_home
make_marked_venv "$H/.local/share/maestral-venv"
before=$(snapshot)
if env -i HOME="$H" PATH="$sandbox/bin" MAESTRAL_VENV="$H" bash "$PLUGIN/uninstall.sh" >/dev/null 2>&1 \
   && [[ $(snapshot) == "$before" ]]; then
  pass "non-purge run deletes nothing"
else
  fail "non-purge run failed or deleted files"
fi

# --- resolve_venv_dir on its own, as install.sh uses it --------------------

make_home
for path in "$H/.local/share/maestral-venv" "$H/.local/share/venvs/maestral" "$H/.local/share/link-to-venv"; do
  if out=$(env -i HOME="$H" PATH="$sandbox/bin" bash -c "source '$PLUGIN/venv-path.sh'; resolve_venv_dir '$path'" 2>/dev/null) \
     && [[ $out == "$H/.local/share/"?* ]]; then
    pass "install accepts '$path'"
  else
    fail "install rejected '$path'"
  fi
done
for path in "$H" "/" "$H/.local/share" "/tmp/maestral-venv" "relative"; do
  if env -i HOME="$H" PATH="$sandbox/bin" bash -c "source '$PLUGIN/venv-path.sh'; resolve_venv_dir '$path'" >/dev/null 2>&1; then
    fail "install accepted '$path'"
  else
    pass "install rejects '$path'"
  fi
done
# Unset or relative HOME is refused too.
if env -i PATH="$sandbox/bin" bash -c "source '$PLUGIN/venv-path.sh'; resolve_venv_dir /x/y" >/dev/null 2>&1; then
  fail "missing HOME accepted"
else
  pass "missing HOME rejected"
fi

echo
if (( failures )); then
  echo "$failures uninstall test(s) failed"
  exit 1
fi
echo "uninstall tests passed"
