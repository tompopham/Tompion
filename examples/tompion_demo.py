#!/usr/bin/env python3
"""Call Tompion from Python: a create, read and delete round trip.

    python3 examples/tompion_demo.py                  lists your calendars, changes nothing
    python3 examples/tompion_demo.py "tompion test"   WRITES to that calendar

Named, it lists your calendars, then in that one it creates one event ("tompion demo",
tomorrow 10:00 to 10:30, alert ten minutes before), reads it back and deletes it.
If the delete cannot be confirmed, it says exactly which event may be left behind.
Use a throwaway calendar made for the purpose.

Build first (sh build.sh), or set TOMPION_APP to the path of a Tompion.app built
elsewhere. The first run makes macOS ask for calendar access.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.realpath(__file__))
APP = os.path.abspath(os.environ.get("TOMPION_APP") or os.path.join(HERE, "..", "build", "Tompion.app"))
TITLE = "tompion demo"


def tompion(*args, spec=None, timeout=120):
    """Run Tompion as its own app through `open` and return its JSON answer."""
    if not os.path.isdir(APP):
        raise RuntimeError(f"no Tompion app at {APP}; build it with sh build.sh, or set TOMPION_APP to its path")
    with tempfile.TemporaryDirectory(prefix="tompion-") as tmp:
        out = os.path.join(tmp, "out")
        argv = ["--out", out, *args]
        if spec is not None:
            spec_path = os.path.join(tmp, "spec.json")
            with open(spec_path, "w", encoding="utf-8") as f:
                json.dump(spec, f)
            argv.append(spec_path)
        if subprocess.run(["open", "-n", APP, "--args", *argv]).returncode != 0:
            raise RuntimeError(f"open could not start {APP}")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(out + ".err"):
                with open(out + ".err", encoding="utf-8") as f:
                    raise RuntimeError(f.read().strip())
            if os.path.exists(out):
                with open(out, encoding="utf-8") as f:
                    return json.load(f)
            time.sleep(0.05)
    # Leaving the with block removed the folder, so a Tompion still running gives up before it commits.
    raise RuntimeError(f"Tompion gave no answer in {timeout} s")


def parts(dt):
    """A datetime as Tompion's [year, month, day, hour, minute, second]."""
    return [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]


def may_be_left(name, start, end, advice):
    """Say exactly which event may still be in the calendar."""
    print(f'Clean-up not confirmed. This event may still be in calendar "{name}": "{TITLE}", '
          f"{start:%A} {start.day} {start:%B %Y}, {start:%H:%M} to {end:%H:%M}. {advice}", file=sys.stderr)


def clean_up(name, created, start, end):
    """Delete what create saved. True only if every saved event is confirmed deleted."""
    confirmed = False
    try:
        ids = [e["id"] for e in created if e["status"] == "ok"]
        if None in ids:
            print("create saved the event but gave no id for it", file=sys.stderr)
        elif ids:
            answer = tompion("delete", spec={"calendar": name, "ids": ids})
            print("delete:", answer)
            confirmed = sorted(i for i, status in answer if status == "deleted") == sorted(ids)
        else:
            confirmed = True                   # nothing was saved, so nothing to delete
    except Exception as e:
        print(f"clean-up failed: {e}", file=sys.stderr)
    finally:
        if not confirmed:
            may_be_left(name, start, end, "Delete it in Calendar.")
    return confirmed


def main(name):
    calendars = tompion("calendars")
    print("calendars:", calendars)
    if name not in calendars:
        raise RuntimeError(f'no calendar called "{name}"; make it in Calendar first')

    start = (datetime.now() + timedelta(days=1)).replace(hour=10, minute=0, second=0, microsecond=0)
    end = start + timedelta(minutes=30)
    spec = {"calendar": name, "events": [{
        "title": TITLE, "note": "created by tompion_demo.py", "allday": False,
        "alarms": [-10],                       # ten minutes before
        "start": parts(start), "end": parts(end),
    }]}
    try:
        created = tompion("create", spec=spec)
    except RuntimeError as e:
        # A failed commit, or a Tompion that committed but could not answer, may still have saved it.
        if str(e).startswith(("commit failed", "Tompion gave no answer")):
            may_be_left(name, start, end,
                        "Check with read before running again, and delete it in Calendar if it is there.")
        raise

    # Create answered, so the delete always runs.
    try:
        print("create:", created)
        if created[0]["status"] != "ok":
            raise RuntimeError(f"create failed: {created[0]['status']}")
        events = tompion("read", name, date.today().isoformat(), start.date().isoformat())
        mine = [e for e in events if e["id"] == created[0]["id"]]
        if not mine:
            raise RuntimeError("the new event did not come back from read")
        print(f"read: {len(events)} event(s) in the window, the demo event among them, alarms {mine[0]['alarms']}")
    finally:
        cleaned = clean_up(name, created, start, end)
    if not cleaned:
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit("give one calendar name, in quotes if it has spaces")
    try:
        if len(sys.argv) == 1:
            print("calendars:", tompion("calendars"))   # reads only; name a calendar for the round trip
        else:
            main(sys.argv[1])
    except RuntimeError as e:
        sys.exit(f"tompion_demo.py: {e}")
