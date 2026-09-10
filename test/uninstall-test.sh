#!/bin/bash
# Regression tests for the destructive paths in install.sh and uninstall.sh.
#
# Every case runs the real script, or the real venv-path.sh functions, against
# a throwaway HOME with a PATH that contains only the tools they need, so
# neither maestral nor the omarchy-plugin-* commands can be reached and nothing
# outside the sandbox is touched. Run: ./test/uninstall-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN="$PWD"
ID="io.github.ryankv.omarchy-maestral"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Minimal PATH: just what the scripts and venv-path.sh call.
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
  P="$H/.local/share/omarchy-maestral"
  mkdir -p "$H/Documents" "$H/.local/share/other-app" "$P/other" "$H/.local/bin" "$H/.cache"
  echo keep > "$H/Documents/thesis.txt"
  echo keep > "$H/.local/share/other-app/data"
  echo keep > "$P/other/data"
  echo keep > "$P/loose-file"
}

# Create a directory that looks exactly like a venv install.sh made at $1.
make_marked_venv() {
  mkdir -p "$1/bin" "$1/lib"
  echo "home = /usr/bin" > "$1/pyvenv.cfg"
  printf '%s\n%s\n' "$ID" "$1" > "$1/.omarchy-maestral-venv"
  echo '#!/bin/sh' > "$1/bin/maestral"
}

snapshot() { (cd "$H" && find . | sort); }

run_purge() {
  env -i HOME="$H" PATH="$sandbox/bin" MAESTRAL_VENV="$1" \
    bash "$PLUGIN/uninstall.sh" --purge >"$sandbox/out" 2>"$sandbox/err"
}

# Call one venv-path.sh function in the sandbox; prints its stdout.
venv_fn() {
  env -i HOME="$H" PATH="$sandbox/bin" bash -c "source '$PLUGIN/venv-path.sh'; $1" 2>"$sandbox/err"
}

# Sanity check the sandbox itself: the plugin/system commands must be unreachable.
if env -i PATH="$sandbox/bin" bash -c 'command -v omarchy-plugin-disable || command -v maestral' >/dev/null 2>&1; then
  echo "sandbox PATH leaks system commands; aborting" >&2
  exit 1
fi

# --- purge: paths that must be refused, with nothing deleted ----------------

make_home
make_marked_venv "$P/venv"
make_marked_venv "$H/.local/share/maestral-venv"          # pre-0.1.3 location
ln -s "$H"        "$P/link-to-home"
ln -s /           "$P/link-to-root"
ln -s "$P/venv"   "$P/link-to-venv"
before=$(snapshot)

refuse_cases=(
  "$H"
  "/"
  "$H/.local"
  "$H/.local/share"
  "$P"
  "$P/"
  "$P/."
  "$P/venv/.."
  "$P/../../../Documents"
  "$H/Documents"
  "$H/.local/share/other-app"          # sibling app data, outside the parent
  "$H/.local/share/maestral-venv"      # old default, outside the parent
  "$P/other"                           # exists, but no venv, no marker
  "$P/loose-file"                      # a file, not a directory
  "$P/does-not-exist"
  "$P/link-to-home"                    # symlink escaping the parent
  "$P/link-to-root"
  "venv"                               # relative
  "$P/venv/bin"                        # inside a venv but not the venv
)
for path in "${refuse_cases[@]}"; do
  if run_purge "$path"; then
    fail "purge accepted '$path'"
  elif [[ $(snapshot) != "$before" ]]; then
    fail "purge of '$path' was refused but files changed"
  elif ! grep -q "Nothing was removed" "$sandbox/err"; then
    fail "purge of '$path' gave no refusal message"
  else
    pass "purge refused '${path:-<empty>}'"
  fi
done

# A directory under the parent with a marker but no pyvenv.cfg is not a venv.
mkdir -p "$P/fake"
printf '%s\n%s\n' "$ID" "$P/fake" > "$P/fake/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$P/fake" || [[ $(snapshot) != "$before" ]]; then
  fail "marker without pyvenv.cfg was purged"
else
  pass "purge refused marker without pyvenv.cfg"
fi

# A venv whose marker holds the wrong plugin id is not ours.
make_marked_venv "$P/foreign"
printf '%s\n%s\n' "org.example.other" "$P/foreign" > "$P/foreign/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$P/foreign" || [[ $(snapshot) != "$before" ]]; then
  fail "venv with foreign marker was purged"
else
  pass "purge refused venv with foreign marker"
fi

# A marker copied from a real venv into another directory names the wrong path.
make_marked_venv "$P/copied"
cp "$P/venv/.omarchy-maestral-venv" "$P/copied/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$P/copied" || [[ $(snapshot) != "$before" ]]; then
  fail "venv with a copied marker was purged"
else
  pass "purge refused venv whose marker names another path"
fi

# A one-line marker from an older release does not carry the path and is refused.
make_marked_venv "$P/oldstyle"
echo "$ID" > "$P/oldstyle/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$P/oldstyle" || [[ $(snapshot) != "$before" ]]; then
  fail "venv with an old one-line marker was purged"
else
  pass "purge refused old one-line marker"
fi

# A venv without any marker is refused.
make_marked_venv "$P/unmarked"
rm "$P/unmarked/.omarchy-maestral-venv"
before=$(snapshot)
if run_purge "$P/unmarked" || [[ $(snapshot) != "$before" ]]; then
  fail "unmarked venv was purged"
else
  pass "purge refused unmarked venv"
fi

# --- purge: the one path that must work -------------------------------------

make_home
make_marked_venv "$P/venv"
ln -s "$P/venv/bin/maestral" "$H/.local/bin/maestral"
mkdir -p "$H/.cache/omarchy-maestral"; echo '{}' > "$H/.cache/omarchy-maestral/space.json"
if ! run_purge "$P/venv"; then
  fail "purge of a stamped venv failed: $(cat "$sandbox/err")"
else
  [[ ! -e $P/venv ]]                          && pass "stamped venv removed"       || fail "stamped venv still present"
  [[ ! -L $H/.local/bin/maestral ]]           && pass "command link removed"       || fail "command link still present"
  [[ ! -e $H/.cache/omarchy-maestral ]]       && pass "cache removed"              || fail "cache still present"
  [[ -f $H/Documents/thesis.txt ]]            && pass "unrelated files intact"     || fail "unrelated files deleted"
  [[ -f $H/.local/share/other-app/data ]]     && pass "sibling data dir intact"    || fail "sibling data dir deleted"
  [[ -f $P/other/data ]]                      && pass "sibling under parent intact" || fail "sibling under parent deleted"
fi

# An empty MAESTRAL_VENV means "the default", exactly as in install.sh.
make_home
make_marked_venv "$P/venv"
if run_purge "" && [[ ! -e $P/venv ]] && [[ -f $H/Documents/thesis.txt ]]; then
  pass "empty MAESTRAL_VENV purges the default venv only"
else
  fail "empty MAESTRAL_VENV was not treated as the default"
fi

# Same, reached through a symlink inside the parent: resolves to the real venv.
make_home
make_marked_venv "$P/venv"
ln -s "$P/venv" "$P/link-to-venv"
if run_purge "$P/link-to-venv" && [[ ! -e $P/venv ]]; then
  pass "symlink to a stamped venv resolves and purges the real venv"
else
  fail "symlink to a stamped venv was not handled"
fi

# A command link that points somewhere else is left alone.
make_home
make_marked_venv "$P/venv"
ln -s /usr/bin/true "$H/.local/bin/maestral"
run_purge "$P/venv" || true
if [[ -L $H/.local/bin/maestral ]]; then
  pass "foreign command link kept"
else
  fail "foreign command link was removed"
fi

# A relative XDG_CACHE_HOME is ignored, as the XDG spec requires.
make_home
make_marked_venv "$P/venv"
mkdir -p "$H/omarchy-maestral"; echo keep > "$H/omarchy-maestral/not-a-cache"
if (cd "$H" && env -i HOME="$H" PATH="$sandbox/bin" XDG_CACHE_HOME=. bash "$PLUGIN/uninstall.sh" --purge >/dev/null 2>&1) \
   && [[ -f $H/omarchy-maestral/not-a-cache ]]; then
  pass "relative XDG_CACHE_HOME ignored"
else
  fail "relative XDG_CACHE_HOME was honoured"
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
make_marked_venv "$P/venv"
before=$(snapshot)
if env -i HOME="$H" PATH="$sandbox/bin" MAESTRAL_VENV="$H" bash "$PLUGIN/uninstall.sh" >/dev/null 2>&1 \
   && [[ $(snapshot) == "$before" ]]; then
  pass "non-purge run deletes nothing"
else
  fail "non-purge run failed or deleted files"
fi

# --- install_target, as install.sh uses it ---------------------------------

make_home
make_marked_venv "$P/venv"
mkdir -p "$P/empty"
ln -s "$P/venv" "$P/link-to-venv"
for path in "$P/venv" "$P/new" "$P/deeper/new" "$P/empty" "$P/link-to-venv"; do
  if out=$(venv_fn "install_target '$path'") && [[ $out == "$P/"?* ]]; then
    pass "install accepts '$path'"
  else
    fail "install rejected '$path'"
  fi
done

# A stamped venv whose marker names another directory is not adopted either.
make_marked_venv "$P/copied"
cp "$P/venv/.omarchy-maestral-venv" "$P/copied/.omarchy-maestral-venv"
mkdir -p "$P/unmarked-full"; echo keep > "$P/unmarked-full/data"
for path in \
  "$H" "/" "$H/.local/share" "$P" "/tmp/x" "relative" \
  "$H/.local/share/other-app"   \
  "$H/.local/share/maestral-venv" \
  "$P/other"                    \
  "$P/unmarked-full"            \
  "$P/loose-file"               \
  "$P/copied"                   \
  "$P/link-to-home"; do
  ln -sfn "$H" "$P/link-to-home"
  if venv_fn "install_target '$path'" >/dev/null; then
    fail "install accepted '$path'"
  else
    pass "install rejects '$path'"
  fi
done

# Unset or relative HOME is refused too.
if env -i PATH="$sandbox/bin" bash -c "source '$PLUGIN/venv-path.sh'; install_target /x/y" >/dev/null 2>&1; then
  fail "missing HOME accepted"
else
  pass "missing HOME rejected"
fi

# --- command_link_replaceable, as install.sh uses it -------------------------

make_home
make_marked_venv "$P/venv"
L="$H/.local/bin/maestral"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then pass "link: absent path is replaceable"; else fail "link: absent path refused"; fi
ln -s "$P/venv/bin/maestral" "$L"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then pass "link: our own symlink is replaceable"; else fail "link: our own symlink refused"; fi
rm "$L"; ln -s /usr/bin/true "$L"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then fail "link: foreign symlink accepted"; else pass "link: foreign symlink refused"; fi
rm "$L"; printf '#!/bin/sh\necho mine\n' > "$L"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then fail "link: user's own script accepted"; else pass "link: user's own script refused"; fi
make_marked_venv "$H/.local/share/maestral-venv"
rm "$L"; ln -s "$H/.local/share/maestral-venv/bin/maestral" "$L"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then fail "link: symlink into a different venv accepted"; else pass "link: symlink into a different venv refused"; fi
rm -rf "$H/.local/share/maestral-venv"
if venv_fn "command_link_replaceable '$L' '$P/venv'"; then pass "link: dangling symlink is replaceable"; else fail "link: dangling symlink refused"; fi

echo
if (( failures )); then
  echo "$failures test(s) failed"
  exit 1
fi
echo "uninstall and install guard tests passed"
