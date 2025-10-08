#!/usr/bin/env python3
"""
Robust directory watcher that:
 - catches created AND moved-to (rename) events (handles rsync)
 - enqueues events and processes them in a worker thread
 - waits until the file stops growing (stable) with timeout
 - records processed filenames in logs/processed to avoid duplicates
 - logs errors/unstable files
 - uses PollingObserver automatically for remote mounts (NFS/CIFS)
"""

import os
import time
import subprocess
import fnmatch
import threading
import queue
from datetime import datetime, UTC

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
from watchdog.observers.polling import PollingObserver  # fallback for NFS

# -------- CONFIG ----------
DATA_DIR = '/home/data'
WATCH_DIR = f"{DATA_DIR}/raw"
ROOT_DIR = f"{DATA_DIR}/GrandRoot"
LOG_DIR = f"{DATA_DIR}/logs"
STABLE_DELAY = 3       # seconds the file size must remain unchanged
STABLE_TIMEOUT = 300   # max seconds to wait for a file to appear/stabilize
QUEUE_POLL_SLEEP = 0.1 # small sleep when queue empty
PATTERN = "GP80*_MD_*-10s-*"  # filename pattern to consider
# ---------------------------

# Ensure directories exist
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(WATCH_DIR, exist_ok=True)
os.makedirs(ROOT_DIR, exist_ok=True)

def now_str():
    return datetime.now(UTC).isoformat(timespec='seconds')

def is_remote_fs(path):
    """Heuristic: parse /proc/mounts and see if mount fs type is 'nfs' or similar."""
    path = os.path.realpath(path)
    best_mp = ""
    best_fs = None
    try:
        with open("/proc/mounts", "r") as m:
            for line in m:
                parts = line.split()
                if len(parts) >= 3:
                    mp = parts[1]
                    fs = parts[2]
                    if path.startswith(mp) and len(mp) > len(best_mp):
                        best_mp = mp
                        best_fs = fs
        if best_fs:
            f = best_fs.lower()
            if any(x in f for x in ("nfs", "cifs", "smb", "sshfs", "fuse")):
                return True
    except Exception:
        pass
    return False

class StableFileHandler(FileSystemEventHandler):
    def __init__(self, watch_dir):
        super().__init__()
        self.watch_dir = watch_dir
        self.q = queue.Queue()
        self.queued = set()           # paths currently queued
        self.queued_lock = threading.Lock()
        self.processed = self._load_processed_set()
        self.processed_lock = threading.Lock()
        # start worker thread
        t = threading.Thread(target=self._worker, daemon=True)
        t.start()

    # ---------------- event handlers ----------------
    def on_created(self, event):
        if not event.is_directory:
            self._enqueue(event.src_path, reason="created")

    def on_moved(self, event):
        # event.dest_path is the final path after rename
        if not event.is_directory:
            self._enqueue(event.dest_path, reason="moved")

    # optional: you can log modifications but don't enqueue here to avoid duplicates
    def on_modified(self, event):
        pass

    # ---------------- queue / worker ----------------
    def _enqueue(self, filepath, reason="unknown"):
        filename = os.path.basename(filepath)
        # ignore hidden temp files that start with '.' or end with partial suffixes
        if filename.startswith('.'):
            return
        with self.processed_lock:
            if filename in self.processed:
                # already processed, skip quickly
                # (no need to queue)
                print(f"[INFO] {filename} already processed -> skipping enqueue")
                return

        with self.queued_lock:
            if filepath in self.queued:
                # already queued
                return
            self.queued.add(filepath)
            self.q.put(filepath)
            print(f"[DEBUG] Enqueued {filepath} ({reason})")

    def _worker(self):
        while True:
            try:
                filepath = self.q.get(timeout=1)
            except queue.Empty:
                time.sleep(QUEUE_POLL_SLEEP)
                continue

            # remove from queued set (so subsequent events can re-enqueue if needed)
            with self.queued_lock:
                self.queued.discard(filepath)

            try:
                self._process_path(filepath)
            except Exception as e:
                # ensure worker doesn't die
                print(f"[ERROR] Worker exception for {filepath}: {e}")
                self._log_error(filepath, f"Worker exception: {e}")
            finally:
                self.q.task_done()

    # ---------------- processing ----------------
    def _process_path(self, filepath):
        print(f"[INFO] Processing queued path: {filepath}")
        # Wait until stable (exists and stops growing)
        stable = self._wait_until_stable(filepath, STABLE_DELAY, STABLE_TIMEOUT)
        if not stable:
            print(f"[WARN] {filepath} did not stabilize -> logged and skipped")
            self._log_unstable(filepath)
            return

        # now try trigger logic
        try:
            self._trigger_script(filepath)
        except Exception as e:
            print(f"[ERROR] Error in _trigger_script for {filepath}: {e}")
            self._log_error(filepath, str(e))

    def _wait_until_stable(self, filepath, stable_delay, timeout):
        """Wait until file exists and size unchanged for stable_delay seconds or until timeout.
           Return True if stable, False on timeout/never appears."""
        start = time.time()
        last_size = -1
        stable_count = 0

        while True:
            elapsed = time.time() - start
            if elapsed > timeout:
                return False

            if not os.path.exists(filepath):
                # may be in rename/creation - wait a bit
                time.sleep(1)
                continue

            try:
                size = os.path.getsize(filepath)
            except OSError:
                time.sleep(1)
                continue

            if size == last_size:
                stable_count += 1
            else:
                stable_count = 0
                last_size = size

            if stable_count >= stable_delay:
                return True

            time.sleep(1)

    def _trigger_script(self, filepath):
        """Main decision: if filename matches PATTERN and not already processed -> run SCRIPT (if provided)
           and log processed filenames (basename)."""
        filename = os.path.basename(filepath)
        print(f"[INFO] File is stable: {filepath} (basename={filename})")

        if not fnmatch.fnmatch(filename, PATTERN):
            # log as not processed
            with open(os.path.join(LOG_DIR, "notprocessed"), "a") as f:
                f.write(f"{now_str()} | {filename}\n")
            print(f"[DEBUG] {filename} does not match pattern -> notprocessed logged")
            return

        # check processed set + append atomically
        with self.processed_lock:
            if filename in self.processed:
                print(f"[INFO] {filename} already marked processed -> skip")
                return

            # Now process files
            roottfile=gtot_convert(filename)
            launch_monitoring(roottfile)
            # Once files are processed we remove them
            remove_files(filename)
            # append to processed file and memory set
            processed_path = os.path.join(LOG_DIR, "processed")
            try:
                with open(processed_path, "a") as pf:
                    pf.write(filename + "\n")
                self.processed.add(filename)
                print(f"[INFO] Marked {filename} as processed")
            except Exception as e:
                self._log_error(filepath, f"Failed to write processed file: {e}")
                print(f"[ERROR] Could not write to processed log: {e}")

    # ---------------- logging helpers ----------------
    def _log_error(self, filepath, message):
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "error.log"), "a") as err:
            err.write(f"{now_str()} | {filepath} | ERROR: {message}\n")

    def _log_unstable(self, filepath):
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(os.path.join(LOG_DIR, "unstable.log"), "a") as f:
            f.write(f"{now_str()} | {filepath} | Unstable/timeout\n")

    def _load_processed_set(self):
        """Load processed basenames into a set (fast checks)."""
        processed_path = os.path.join(LOG_DIR, "processed")
        if not os.path.exists(processed_path):
            return set()
        try:
            with open(processed_path, "r") as f:
                return set(line.strip() for line in f if line.strip())
        except Exception:
            return set()


# General functions for processing
def gtot_convert(filename):
    input_file=f"{WATCH_DIR}/{filename}"
    basename = os.path.basename(input_file)
    output_file = os.path.join(ROOT_DIR, os.path.splitext(basename)[0] + ".root")
    script_path = "/opt/grandlib/softs/gtot/cmake-build-release/gtot"
    cmd = [
    script_path,
    "-g1",
    "-os",
    "-i", input_file,
    "-o", output_file
    ]

    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        print(f"[INFO] gtot finished successfully.")
        print("stdout:", result.stdout)
        print("stderr:", result.stderr)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] gtot failed with exit code {e.returncode}")
        print("stdout:", e.stdout)
        print("stderr:", e.stderr)
        output_file=""
    finally:
        return output_file

def launch_monitoring(filepath):
    script_path = "/opt/grandlib/softs/grand/granddb/monitoring_site.py"

    cmd = ["python3",
    script_path,
    "-f",
    filepath
    ]
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        print(f"[INFO] monitoring_site.py finished successfully for {filepath}")
        print("stdout:", result.stdout)
        print("stderr:", result.stderr)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] monitoring_site.py failed for {filepath} (exit code {e.returncode})")
        print("stdout:", e.stdout)
        print("stderr:", e.stderr)

def remove_files(filename):
    raw_file = os.path.join(WATCH_DIR, filename)
    basename = os.path.basename(raw_file)
    root_file = os.path.join(ROOT_DIR, os.path.splitext(basename)[0] + ".root")
    delete_file(raw_file)
    delete_file(root_file)

def delete_file(file):
    try:
        os.remove(file)
        print(f"[INFO] Removed source file: {file}")
    except FileNotFoundError:
        print(f"[WARN] File already removed: {file}")
    except PermissionError:
        print(f"[ERROR] Permission denied removing {file}")
    except Exception as e:
        print(f"[ERROR] Unexpected error removing {file}: {e}")



# ---------------- main ----------------
if __name__ == "__main__":
    # choose observer based on mount type
    use_polling = is_remote_fs(WATCH_DIR)
    if use_polling:
        observer = PollingObserver(timeout=5)
        print("[INFO] Using PollingObserver (suitable for NFS/CIFS/remote mounts).")
    else:
        observer = Observer()
        print("[INFO] Using inotify-based Observer (local filesystem).")

    handler = StableFileHandler(WATCH_DIR)
    observer.schedule(handler, WATCH_DIR, recursive=False)
    observer.start()

    print(f"[INFO] Watching {WATCH_DIR} for completed files... (pattern={PATTERN})")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[INFO] Stopping...")
        observer.stop()
    observer.join()
