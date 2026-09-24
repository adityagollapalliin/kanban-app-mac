# Privacy

LocalBoard stores everything on this Mac and makes no network connections.
This document says exactly what is kept, where, and for how long.

## No network, by construction

The app is not merely configured not to phone home — it is built so that it
cannot.

- `App/LocalBoard.entitlements` contains **neither**
  `com.apple.security.network.client` **nor** `com.apple.security.network.server`.
  Under the App Sandbox, an outgoing connection without the client entitlement
  is refused by the operating system, not by the app's own good behaviour.
- `Scripts/verify-no-network.sh` fails the build if `URLSession`,
  `NSURLConnection`, `import Network`, `NWConnection`, BSD sockets, `Process(`
  or `NSTask` appear anywhere in the sources, and inspects the built app's
  entitlements with `plutil` rather than grepping for them. It runs as part of
  `make verify`.
- `Process(` is banned alongside the networking APIs on purpose: a program
  that can start another program can reach the network through it. This is
  why the optional repository link reads git's files directly rather than
  running `git`.

There are no accounts, no sign-in, no sync, no iCloud entitlement, no
analytics and no crash reporting.

## What is stored, and where

Everything lives inside the app's sandbox container:

```
~/Library/Containers/dev.localboard.LocalBoard/Data/Library/Application Support/LocalBoard/
```

`localboard where` prints the exact paths on your Mac.

| What | Where | Kept until |
|---|---|---|
| Boards, cards, comments, links, work log, history | `board.sqlite` | you delete them |
| Files you attach to cards | `Attachments/` | you remove the attachment |
| Diagnostics | `Diagnostics/` | **24 hours**, automatically |

Attachments are **copied** into that folder, so the originals can be moved or
deleted afterwards without breaking anything.

## Diagnostics are purged every 24 hours

Log and diagnostic files older than 24 hours are deleted:

- at every launch, before anything else happens;
- when the Mac wakes, so a machine asleep past the window purges on waking;
- on a low-frequency, tolerance-enabled timer while the app runs, which lets
  the app still take App Nap.

Logging uses `os.Logger` with privacy annotations. Card titles, descriptions,
comments and people's names are never written to the log — the diagnostics
record that an operation happened and whether it failed, not what it was
about. The Settings window shows where the folder is, how large it is, and
offers a "Delete now" button.

## The optional repository link

A project may be linked to a folder on this Mac, which is **off by default**
and only ever created by you choosing a folder. When it is set:

- the folder is opened through a security-scoped bookmark — macOS's record
  that you chose it — and access is released as soon as the read is finished;
- only `.git/refs/heads`, `.git/packed-refs` and `.git/logs/HEAD` are read;
- nothing is ever written into the folder, and no remote is contacted.

## Notifications

Due-date reminders are off until you turn them on, and are scheduled locally
by macOS. No device token is registered and no push service is contacted; the
app has no network entitlement with which to reach one.

## Getting your data out

Export is local and started by you: `localboard export` writes the project as
JSON on standard output. The SQLite file is yours and is a plain, documented
format you can open with any SQLite tool.

## Deleting your data

Remove the container directory. Nothing is stored anywhere else, so that is
all of it.
