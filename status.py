"""Status helper for the Omarchy "Dropbox via Maestral" bar widget.

Prints a single JSON object describing the Maestral daemon, the linked Dropbox
account, storage usage, and recently synced files. Service.qml runs it on a
timer, so it must be quick and must never raise: every failure degrades to a
readable statusText instead.

Maestral is usually installed into its own virtualenv (see install.sh). When
this script is started with the system interpreter and cannot import maestral,
it re-executes itself with the interpreter that sits next to the maestral
executable on PATH.
"""

import heapq
import json
import os
import shutil
import sys
import time
from pathlib import Path

CONFIG_NAME = os.environ.get("MAESTRAL_CONFIG_NAME", "maestral")
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "omarchy-maestral"
SPACE_CACHE = CACHE_DIR / "space.json"
SPACE_CACHE_TTL_SEC = 900
REEXEC_FLAG = "OMARCHY_MAESTRAL_REEXEC"

EXTRA_BIN_DIRS = [
  Path.home() / ".local" / "bin",
  Path.home() / ".local" / "share" / "maestral-venv" / "bin",
]


def find_maestral():
  found = shutil.which("maestral")
  if found:
    return found
  for directory in EXTRA_BIN_DIRS:
    candidate = directory / "maestral"
    if candidate.is_file() and os.access(candidate, os.X_OK):
      return str(candidate)
  return None


def ensure_maestral_importable(executable):
  try:
    import maestral  # noqa: F401
    return True
  except ImportError:
    pass
  if os.environ.get(REEXEC_FLAG):
    return False
  interpreter = Path(os.path.realpath(executable)).parent / "python"
  if not interpreter.is_file():
    return False
  env = dict(os.environ, **{REEXEC_FLAG: "1"})
  os.execve(str(interpreter), [str(interpreter), os.path.abspath(__file__), *sys.argv[1:]], env)
  return False  # unreachable


def base_payload(executable):
  return {
    "ok": True,
    "installed": executable is not None,
    "executable": executable or "",
    "daemonRunning": False,
    "running": False,
    "paused": False,
    "authenticated": False,
    "statusText": "Not installed",
    "accountPath": "",
    "email": "",
    "plan": "",
    "syncErrors": 0,
    "usedBytes": 0,
    "quotaBytes": 0,
    "usagePercent": 0,
    "quotaKnown": False,
    "files": [],
  }


def emit(payload):
  print(json.dumps(payload))


def read_space_cache():
  try:
    with SPACE_CACHE.open("r", encoding="utf-8") as handle:
      data = json.load(handle)
    return data if isinstance(data, dict) else None
  except (OSError, ValueError):
    return None


def write_space_cache(used, allocated):
  try:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with SPACE_CACHE.open("w", encoding="utf-8") as handle:
      json.dump({"used": used, "allocated": allocated, "ts": time.time()}, handle)
  except OSError:
    pass


def space_usage(m, online):
  """Return (used, allocated). Hits the Dropbox API at most every 15 minutes."""
  cached = read_space_cache()
  fresh = cached and time.time() - float(cached.get("ts", 0)) < SPACE_CACHE_TTL_SEC
  if fresh or not online:
    if cached:
      return int(cached.get("used", 0)), int(cached.get("allocated", 0))
    return 0, 0
  try:
    usage = m.get_space_usage()
    used = int(getattr(usage, "used", 0) or 0)
    allocated = int(getattr(usage, "allocated", 0) or 0)
    write_space_cache(used, allocated)
    return used, allocated
  except Exception:
    if cached:
      return int(cached.get("used", 0)), int(cached.get("allocated", 0))
    return 0, 0


def file_row(local_path, root, modified_ts, size):
  rel = os.path.relpath(local_path, root)
  folder = os.path.dirname(rel)
  return {
    "name": os.path.basename(local_path),
    "path": local_path,
    "folder": "/" if folder in ("", ".") else folder,
    "modifiedTs": int(modified_ts),
    "sizeBytes": int(size or 0),
  }


def recent_from_history(m, root, limit):
  """Recently synced files from Maestral's sync history, newest first."""
  try:
    events = m.get_history(limit=max(limit * 4, 50))
  except Exception:
    return []
  seen = set()
  rows = []
  for event in sorted(events, key=lambda e: float(getattr(e, "change_time_or_sync_time", 0) or 0), reverse=True):
    if not getattr(event, "is_file", False) or getattr(event, "is_deleted", False):
      continue
    local_path = str(getattr(event, "local_path", "") or "")
    if not local_path or local_path in seen:
      continue
    if not os.path.isfile(local_path):
      continue
    seen.add(local_path)
    rows.append(file_row(local_path, root, getattr(event, "change_time_or_sync_time", 0) or 0, getattr(event, "size", 0)))
    if len(rows) >= limit:
      break
  return rows


def scan_folder(path, limit):
  """Fallback used before any history exists: walk the folder for size and newest files."""
  total = 0
  counter = 0
  recent = []
  try:
    for root, dirs, files in os.walk(path):
      dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(root, name)) and name != ".mignore"]
      for name in files:
        file_path = os.path.join(root, name)
        if os.path.islink(file_path):
          continue
        try:
          stat = os.stat(file_path)
        except OSError:
          continue
        total += stat.st_size
        counter += 1
        entry = (stat.st_mtime, counter, file_row(file_path, path, stat.st_mtime, stat.st_size))
        if len(recent) < limit:
          heapq.heappush(recent, entry)
        else:
          heapq.heappushpop(recent, entry)
  except OSError:
    return 0, []
  return total, [entry[2] for entry in sorted(recent, reverse=True)]


def collect(m, executable, daemon_running, limit):
  payload = base_payload(executable)
  payload["daemonRunning"] = daemon_running

  pending_link = bool(m.pending_link)
  pending_folder = bool(m.pending_dropbox_folder) if not pending_link else True
  root = str(m.dropbox_path or "") if not pending_link else ""
  authenticated = not pending_link and not pending_folder and root != "" and os.path.isdir(root)
  payload["authenticated"] = authenticated
  payload["accountPath"] = root if authenticated else ""

  if not pending_link:
    try:
      payload["email"] = str(m.get_state("account", "email") or "")
      payload["plan"] = str(m.get_state("account", "type") or "")
    except Exception:
      pass

  if pending_link:
    payload["statusText"] = "Not linked"
  elif pending_folder or not authenticated:
    payload["statusText"] = "Dropbox folder not set up"
  elif not daemon_running:
    payload["statusText"] = "Maestral stopped"
  else:
    paused = bool(m.paused)
    syncing = bool(m.running) and not paused
    payload["paused"] = paused
    payload["running"] = syncing
    try:
      payload["syncErrors"] = len(m.sync_errors)
    except Exception:
      payload["syncErrors"] = 0
    status = str(m.status or "").strip()
    if not status:
      status = "Paused" if paused else "Up to date"
    if payload["syncErrors"] > 0:
      status = f"{status} · {payload['syncErrors']} sync error{'s' if payload['syncErrors'] != 1 else ''}"
    payload["statusText"] = status

  if not authenticated:
    return payload

  online = daemon_running and bool(getattr(m, "connected", False))
  used, allocated = space_usage(m, online)
  files = recent_from_history(m, root, limit)
  if not files or used <= 0:
    walked_total, walked_files = scan_folder(root, limit)
    if not files:
      files = walked_files
    if used <= 0:
      used = walked_total

  payload["files"] = files
  payload["usedBytes"] = used
  payload["quotaBytes"] = allocated
  payload["quotaKnown"] = allocated > 0
  payload["usagePercent"] = (used / allocated * 100) if allocated > 0 else 0
  return payload


def main():
  limit = 25
  if len(sys.argv) > 1:
    try:
      limit = max(1, min(100, int(sys.argv[1])))
    except ValueError:
      limit = 25

  executable = find_maestral()
  if executable is None:
    emit(base_payload(None))
    return

  if not ensure_maestral_importable(executable):
    payload = base_payload(executable)
    payload["statusText"] = "Maestral found but its Python module is not importable"
    emit(payload)
    return

  try:
    from maestral.daemon import MaestralProxy, is_running
  except Exception as error:  # pragma: no cover - defensive
    payload = base_payload(executable)
    payload["statusText"] = f"Maestral import failed: {error}"
    emit(payload)
    return

  try:
    daemon_running = bool(is_running(CONFIG_NAME))
  except Exception:
    daemon_running = False

  try:
    with MaestralProxy(CONFIG_NAME, fallback=True) as m:
      emit(collect(m, executable, daemon_running, limit))
  except Exception as error:
    payload = base_payload(executable)
    payload["daemonRunning"] = daemon_running
    payload["statusText"] = f"Cannot read Maestral state: {type(error).__name__}"
    emit(payload)


if __name__ == "__main__":
  main()
