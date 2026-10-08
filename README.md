# Tompion

Read, create and delete macOS Calendar events from the command line, through EventKit, the system's own calendar framework. One Swift file, no dependencies, and fast: it read a 444-event calendar in 0.3 seconds where driving Calendar with AppleScript took 3.5 minutes.

Named after Thomas Tompion, the father of English clockmaking, who built the year-going clocks, wound once a year, for the Royal Observatory at Greenwich when it opened in 1676.

Unlike similar EventKit command-line tools, it runs as its own app through `open`, so macOS asks once for calendar access and remembers the answer, and its `delete` leaves repeating events and events in other calendars alone.

It takes and prints JSON, so it is meant to be called from scripts. There are four commands: `calendars`, `read`, `create` and `delete`.

> **Tompion changes real calendars.** Whatever it creates or deletes syncs to your other devices like any edit made in Calendar, and a deleted event is gone. Try it on a throwaway calendar first (make an empty one called `tompion test` in Calendar) before pointing it at one you care about.

## Requirements

- macOS 14 or later. It uses `requestFullAccessToEvents`, which arrived in macOS 14, and it is built for macOS 14 whichever macOS builds it. Written and used on macOS 26 on Apple Silicon.
- The Swift compiler, from Xcode or the command-line tools (`xcode-select --install`).

## Build

1. Pick a bundle identifier of your own, for example `com.yourname.tompion`, using only letters, digits, hyphens and full stops (`build.sh` refuses anything else), and keep it the same from build to build. macOS ties the calendar permission to the app's identity, so a new identifier means being asked again.
2. From the top folder of this checkout, run:

```sh
TOMPION_BUNDLE_ID=com.yourname.tompion sh build.sh
```

This compiles `tompion.swift` with `swiftc -O`, for this Mac's processor and macOS 14 or later, into `build/Tompion.app`, a one-binary app bundle. Your identifier goes into the built app's copy of `Info.plist`; the `Info.plist` in this folder keeps the `com.example.tompion` placeholder. Without `TOMPION_BUNDLE_ID` it still builds, with the placeholder, and warns you. It strips extended attributes and signs the app ad hoc. The app is built in a temporary folder and only then put in place, so a failed build leaves any existing `Tompion.app` as it was. To build somewhere else, give a directory: `TOMPION_BUNDLE_ID=com.yourname.tompion sh build.sh /some/dir` makes `/some/dir/Tompion.app`.

Do not build inside an iCloud-synced folder (a synced Desktop or Documents folder, say): iCloud's file attributes break code signing. If your checkout is in one, pass an output directory outside it.

**A rebuild may bring the dialog back.** Ad-hoc signing gives every build a new signature, so to macOS a rebuilt Tompion is a new app, and it may ask for calendar access again. If instead Tompion fails with "no calendar access" after a rebuild, remove Tompion from System Settings > Privacy & Security > Calendars (or switch it off and on again there), or clear its entry so that the next run asks afresh:

```sh
tccutil reset Calendar com.yourname.tompion
```

## Run it as an app, through `open`

Start Tompion with `open`, as its own app, not directly from a shell. `open` does not hand back what the program prints, so Tompion writes its answer to a file and you wait for that file. `wait_for_answer` below waits up to two minutes for Tompion's answer in the folder `$d`, prints it, then removes `$d`. In Terminal, from the top folder of this checkout (if you built elsewhere, put that app's path in place of `build/Tompion.app`):

```sh
wait_for_answer() {
  if [ "${1:-0}" -ne 0 ]; then rm -r "$d"; return 1; fi
  i=0
  until [ -e "$d/answer.json" ] || [ -e "$d/answer.json.err" ] || [ "$i" -ge 1200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ -e "$d/answer.json" ]; then cat "$d/answer.json"; echo
  elif [ -e "$d/answer.json.err" ]; then cat "$d/answer.json.err"
  else echo "no answer from Tompion in two minutes"
  fi
  rm -r "$d"
}

d=$(mktemp -d)
open -n build/Tompion.app --args --out "$d/answer.json" calendars; wait_for_answer $?
```

`mktemp -d` makes a new folder that only you can read, for this one run. Every example below follows the same steps: a new folder, `open`, then `wait_for_answer $?`, which you define once in each Terminal window. The `$?` hands it `open`'s result, so if `open` fails (the app is not at that path, say) it removes the folder and returns at once, after `open`'s own message, instead of waiting two minutes for nothing.

The first time, macOS shows its usual dialog asking whether Tompion may access your calendars. Allow it. If you refused by mistake, switch it on in System Settings > Privacy & Security > Calendars. Tompion waits at most 100 seconds for an answer to the dialog; after that it fails with "timed out waiting for calendar access", and you answer the dialog, or allow it in System Settings, and run it again. That is why callers here wait two minutes.

Every check that needs no calendar is made before Tompion asks for access: the command, its arguments, `--out`, `read`'s dates, and the whole of a `create` or `delete` spec. A typo never brings up the dialog.

**Why through `open`.** Run directly (`build/Tompion.app/Contents/MacOS/tompion calendars`), the program is just a child of your shell, and on the Mac this was written on macOS refuses it calendar access without showing a prompt. Started with `open`, it runs as its own app, with its own identity (the bundle identifier and the usage strings in `Info.plist`), so macOS asks once and remembers the answer for Tompion, instead of refusing silently on behalf of whatever started it.

**Why `--out`.** `open` does not hand the program's output back to you, and `open -W` does not always wait for a helper that finishes this quickly. So with `--out <path>`, Tompion writes its answer to `<path>.part` and renames it onto `<path>` in one step when it is complete, so a caller never sees half a file. If something goes wrong, the message reaches `<path>.err` the same way, so wait for either file. Without `--out`, the answer goes to stdout and errors to stderr, which is the mode for running the binary directly, and as above macOS may refuse that.

The rules for `--out <path>`:

- It comes first, straight after `--args`.
- `<path>` must be absolute and name a file, not a folder, in a folder that already exists and that you can write in. Otherwise Tompion writes a message to stderr, which `open` does not show you, and stops with exit code 2 without writing anything. Your caller then sees neither file, which is one reason to stop waiting after a time limit.
- At startup Tompion removes any `<path>`, `<path>.err` or `<path>.part` left by an earlier run. It removes plain files and symlinks only (the link, not what it points to). If any of the three is a folder, or anything else, that counts as a bad path, and nothing is removed.
- The answer is written readable by you only.

Spec files for `create` and `delete` must be given as absolute paths too. An app started by `open` runs with `/` as its working directory, so `create spec.json` would look for `/spec.json`.

`-n` opens a new instance each time, even if one is already running.

### Exit codes

| Code | Meaning | What a caller using `open` sees |
|---|---|---|
| 0 | Done. | `<path>` |
| 1 | Failed. The reason is in `<path>.err` (on stderr without `--out`). | `<path>.err` |
| 2 | A bad `--out` path, or Tompion could not write its answer or error to `<path>` or `<path>.err` (or, without `--out`, its answer to stdout). The reason goes to stderr only. | neither file |
| 3 | The caller had given up before `create` or `delete` committed (below). Nothing was committed and nothing written. | neither file |

`open` does not pass the exit code on, so through `open` the files are what you go by.

### If you stop waiting on a `create` or `delete`

Remove the run's folder, as `wait_for_answer` and the Python helper below do. Just before it commits, Tompion checks that the folder `--out` writes into is still there; if it has gone, Tompion stops with exit code 3 and changes nothing. But a Tompion that had already committed has made its changes and only failed to write the answer. So after a timeout, run `read` to see what was saved or deleted before you run the same `create` or `delete` again, or you may create the events twice.

## Commands

Every command prints JSON. Its arguments go after `--args --out <path>`. The examples use `wait_for_answer` from above.

### `calendars`

```sh
d=$(mktemp -d)
open -n build/Tompion.app --args --out "$d/answer.json" calendars; wait_for_answer $?
```

The names of every event calendar: `["Home", "Work", "tompion test"]`. (Reminders lists are not included.)

### `read <calendar> [<from> <to>]`

```sh
d=$(mktemp -d)
open -n build/Tompion.app --args --out "$d/answer.json" read "tompion test" 2026-10-01 2026-10-31; wait_for_answer $?
```

Every event in one calendar, as a list:

```json
[{"id": "5D1C...:ABC...", "uid": "9F2E...", "title": "Dentist",
  "start": "2026-10-12T08:00:00Z", "end": "2026-10-12T09:00:00Z",
  "allday": false, "location": "", "note": "", "url": "",
  "recurring": false, "alarms": [-15]}]
```

- `id` is EventKit's `eventIdentifier`, the value `delete` takes. `uid` is the item's external identifier.
- `start` and `end` are ISO 8601 in UTC (see Limits for all-day events).
- `alarms` are minutes relative to the start (`-15` is fifteen minutes before). Alarms set for a fixed time or a place are left out.
- `<from>` and `<to>` are real dates written `YYYY-MM-DD`, in local time, `<to>` inclusive and not before `<from>`. Without them, Tompion reads from one year ago to two years ahead. EventKit searches at most four years at once, so Tompion refuses a window (from the start of `<from>` to the end of `<to>`) longer than 1461 x 24 hours; split it. A 1461-day window that gains an hour when the clocks go back counts as too long.
- There must be exactly one calendar with that name.

### `create <spec.json>`

```sh
d=$(mktemp -d)
cat > "$d/spec.json" <<'EOF'
{"calendar": "tompion test",
 "events": [
   {"title": "Dentist", "note": "Bring the form", "allday": false,
    "alarms": [-15],
    "start": [2026, 10, 12, 9, 0, 0],
    "end":   [2026, 10, 12, 10, 0, 0]}
 ]}
EOF
open -n build/Tompion.app --args --out "$d/answer.json" create "$d/spec.json"; wait_for_answer $?
```

- `start` and `end` are `[year, month, day, hour, minute, second]` in local time.
- `title` is required, though it may be empty. `note`, `allday` (default `false`) and `alarms` are optional. `alarms` are minutes relative to the start; negative is before. Any other field is refused, so a misspelt one fails instead of being ignored.
- The calendar must already exist. Tompion does not create calendars.
- Tompion checks the whole spec before it asks for calendar access or creates anything. `calendar` must be a non-empty string and `events` a non-empty list, with no other field besides them. Each event may have only the six fields above. In each event, `start` and `end` must be six whole numbers, the month 1-12, and a time that really happens locally (not 30 February, not hour 25, not a time skipped when the clocks go forward), with `end` not before `start`; `title` and `note` must be strings, `allday` `true` or `false` (not `"true"` or `1`), and `alarms` a list of whole numbers, each at most 5,256,000 minutes (ten years) from the start. On the first problem it fails, naming the event (counting from 1) and what is wrong, for example `event 2 ("Dentist"): "start" month must be 1-12, not 13` or `event 1 ("Dentist"): unknown field "all_day"`, and nothing is created. A problem outside the events starts `spec:`, for example `spec: unknown field "calender"`.

The events are saved together with a single commit at the end. The answer has one entry per event, in order:

```json
[{"title": "Dentist", "id": "5D1C...:ABC...", "status": "ok"}]
```

`id` is the new event's id, the same value `read` gives and `delete` takes. An event that could not be saved has `"id": null` and `"status": "error: <reason>"`; the others are still created. In the rare case that EventKit gives a saved event no id, it has `"status": "ok"` with `"id": null`. If the commit itself fails, Tompion fails with `commit failed: <reason>. Check with read what was saved.` Some events may have been saved, so look before running it again.

### `delete <spec.json>`

Before you run this, replace `PASTE-THE-ID-FROM-CREATE` with the `"id"` the `create` example printed (list more ids to delete several). Left as it is, the answer is that id with `not found, left alone`, and the Dentist event stays.

```sh
d=$(mktemp -d)
cat > "$d/spec.json" <<'EOF'
{"calendar": "tompion test", "ids": ["PASTE-THE-ID-FROM-CREATE"]}
EOF
open -n build/Tompion.app --args --out "$d/answer.json" delete "$d/spec.json"; wait_for_answer $?
```

The ids come from `read` or `create`. `calendar` must be a non-empty string and `ids` a non-empty list of non-empty strings, with no other field, checked before Tompion asks for calendar access. The deletions are committed once at the end. The answer has one `[id, status]` pair per id, for example `[["5D1C...:ABC...", "deleted"], ["7A40...:DEF...", "repeating event, left alone"]]`. The status is one of:

- `deleted`
- `not found, left alone`: no event has that id.
- `in another calendar, left alone`: the event is not in the calendar the spec names.
- `repeating event, left alone`: Tompion does not delete repeating events.
- `error: <reason>`: EventKit would not delete it.

If the commit fails, Tompion fails with `commit failed: <reason>. Check with read what was deleted.`

## Calling it from Python

Python's `subprocess` is a child of your shell too, so it goes through `open` as well. This function makes a private temporary folder for each call, waits up to two minutes for the answer, and removes the folder when it returns or gives up. It looks for the app at the path in the `TOMPION_APP` environment variable, or else at `build/Tompion.app` beside the script, so save the script in the top folder of the checkout or set `TOMPION_APP`. In a REPL, a notebook or `python3 -c` there is no script file to look beside, so there `TOMPION_APP` must be set. An error from Tompion comes back as a `RuntimeError` carrying its message.

```python
import json
import os
import subprocess
import tempfile
import time

# __file__ is looked at only when TOMPION_APP is unset, so the helper also works in a REPL with it set.
APP = os.path.abspath(os.environ.get("TOMPION_APP")
                      or os.path.join(os.path.dirname(os.path.realpath(__file__)), "build", "Tompion.app"))


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


print(tompion("calendars"))
print(tompion("read", "tompion test", "2026-10-01", "2026-10-31"))
```

`examples/tompion_demo.py` is the same function with a full create, read and delete round trip. Run it with no argument first: it only lists your calendars, which is a safe way to get the permission dialog out of the way. Then give it the name of a throwaway calendar: it lists your calendars, creates one event in the one you name ("tompion demo", tomorrow 10:00 to 10:30, alert ten minutes before), reads it back and deletes it. If the create or the delete cannot be confirmed, it says which event may be left behind. It finds `build/Tompion.app` from its own location, so it runs from any folder; set `TOMPION_APP` if you built the app elsewhere. This writes to the calendar you name:

```sh
python3 examples/tompion_demo.py "tompion test"
```

## Speed

These are the figures from the author's own use of it, on one Mac with iCloud calendars, while replacing Calendar's AppleScript scripting in a calendar-sync script. They are timings of real work, not a controlled benchmark.

| Task | Through Calendar's scripting | Through Tompion |
|---|---|---|
| Read a 444-event calendar | 3.5 minutes | 0.3 seconds |
| Delete events | about 25 seconds an event | a whole batch at once |
| One run of a sync script that manages eleven calendars | half an hour or more | about 5 seconds |

## Limits

- `create` makes single events only: there is no recurrence option.
- `calendars` prints names only. Two calendars with the same name (a "Home" in two accounts, say) show up as the same name twice, and `read`, `create` and `delete` refuse a name that more than one calendar has. Rename one in Calendar to use it.
- All occurrences of a repeating event share one `id`. `read` returns every occurrence in the window, each with that id and with `recurring` set to `true`. `delete` will not touch them.
- `read` gives times in UTC, so an all-day event's `start` is local midnight converted to UTC: an all-day event on 12 October 2026 in London comes back as `2026-10-11T23:00:00Z`, as the clocks are then an hour ahead of UTC. Convert to local time before taking the date.
- `read` lists only alarms set relative to the start. Alarms at a fixed time or for a place are left out.
- Event calendars only. Reminders are not supported.

## Licence

MIT. See [LICENSE](LICENSE).
