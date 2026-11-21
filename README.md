# iNoty

A tiny iOS app for LiveContainer. It runs a minimal HTTP server and turns each request into a fully customizable local notification. It stays alive in the background by looping silent audio.

By default the server listens on `127.0.0.1` only, so nothing on your Wi-Fi can reach it. Letting other devices on your network send requests is an optional switch in the app (off by default).

The UI uses Liquid Glass on iOS 26 and falls back to a blur material on older versions.

## Install

1. Open the IPA in LiveContainer. LiveContainer signs it itself.
2. **Enable "Fix Local Notification"** in iNoty's settings inside LiveContainer. Without it iOS rejects notifications from the guest app (`UNErrorDomain error 1`) and the permission prompt never appears.
3. Open iNoty once, allow notifications, then leave it running.

## The `inoty` script

`scripts/inoty` is a bash script (needs `curl`; works with the bash that ships with macOS). It stores the token once so you never type it again.

```sh
cp scripts/inoty ~/.local/bin/inoty      # or anywhere on your PATH
inoty setup                              # paste the token shown in the app
inoty setup --host 192.168.1.20          # for another device: the address shown in the app
```

The config is saved to `~/.config/inoty/config` with mode 600. `INOTY_HOST`, `INOTY_PORT` and `INOTY_TOKEN` environment variables override it.

```sh
inoty send "Build done" "All tests passed"
inoty "Build done" "All tests passed"                      # same thing
inoty send "Backup" "Finished" --sound none --thread backups
inoty send "Stand up" "Meeting soon" --delay 10m --id standup
inoty send "Deploy?" "main is green" \
  --action "yes|Deploy|https://example.com/deploy" --action "no|Skip"
inoty send "Photo" "Look" --image https://example.com/a.png
long_job; inoty "long_job finished" "exit code $?"
inoty clear standup                                        # remove one by id
inoty clear                                                # remove everything
inoty help
```

## HTTP API

Every request except `/health` needs the token, sent as `X-Token: TOKEN`, `Authorization: Bearer TOKEN` or `?token=TOKEN`.

```
GET|POST  /notify    send a notification
GET|POST|DELETE  /clear    remove notifications (optional "id")
GET       /health    no token needed
```

`/notify` reads query parameters and/or a JSON body (JSON wins). A POST body that is not JSON is used as the message.

```sh
curl -H "X-Token: TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Hello","body":"World","sound":"none","level":"timeSensitive"}' \
  http://127.0.0.1:8765/notify
```

Success returns `{"ok":true,"id":"..."}`. Problems return `{"ok":false,"error":"..."}` with a 4xx/5xx status.

### Fields

| Field | Meaning |
|---|---|
| `title`, `subtitle`, `body` | Text (`message` and `text` work as aliases for `body`). One of title or body is required. |
| `sound` | `default`, `none`, `ringtone`, or the name of a sound you added in the app (see Custom sounds) |
| `badge` | App badge number (0 clears it) |
| `level` | `passive`, `active` or `timeSensitive` |
| `relevance` | 0 to 1, orders it in the notification summary |
| `thread` | Groups notifications together |
| `summary`, `summaryCount` | Text and count used in grouped summaries |
| `target` | Target content identifier |
| `id` | Same id replaces the earlier notification, and is what `/clear` takes |
| `delay` | Seconds to wait before delivering |
| `repeat` | `true` repeats every `delay` seconds (minimum 60) |
| `at` | Deliver at a time: ISO 8601 (`2026-11-21T18:30:00+03:00`) or a unix timestamp. Use `delay` or `at`, not both |
| `url` | Opened when the notification is tapped |
| `image` | https URL of a PNG, JPEG or GIF to attach |
| `imageBase64` | Image data instead of a URL (max 10 MB) |
| `actions` | Buttons: `[{"id":"yes","title":"Deploy","url":"https://...","destructive":false,"foreground":false,"auth":false}]` (up to 10; a button with a `url` opens the app to open it) |
| `data` | Any JSON object, stored in the notification's userInfo |

Not possible: running code sent over HTTP. The API exposes every notification option iOS offers instead. Sounds cannot be uploaded through a request either, they are added in the app (below).

## Custom sounds

In the app, "Notification sounds", then "Add sound", pick one or more audio files (mp3, m4a, wav, aiff and caf all work, up to 30 seconds, which is an iOS limit). Each is converted to a `.caf` and named after the file, with spaces turned into `-`. Then use the name in a request:

```sh
inoty send "Done" "Build finished" --sound my-sound
```

An unknown name is refused, and the error lists the sounds that are installed. In the list, play previews inside the app, the bell sends a real notification with that sound, and the bin deletes it.

Uncertain inside LiveContainer: iOS looks for notification sounds in the app's own Library/Sounds folder, and with "Fix Local Notification" the notifications may be posted under LiveContainer's identity. If the preview plays but the bell's notification only makes the default sound, that is the cause.

## History

The main screen shows the last 5 requests. "Open full history" lists the last 100 (kept across launches); tap one to see its time, result and every field that was sent. Requests that were refused because a field was invalid show up in red with the reason. Image data is not stored, only its length. Requests with a wrong token are not recorded.

## Network access (optional)

Turn on "Allow other devices on my network" in the app. The server then listens on all interfaces but still only accepts connections from private addresses (10.x, 172.16-31.x, 192.168.x, link-local, and 100.64.x used by Tailscale). Public addresses are always refused, and the token is still required.

- Traffic is plain HTTP, so the token can be seen by anyone on that network. Only use it on networks you trust.
- The app shows the address to use. On the other device run `inoty setup --host THAT_ADDRESS`.
- iOS may ask for Local Network permission, which inside LiveContainer belongs to LiveContainer itself (iOS Settings, Privacy & Security, Local Network).
- If the token ever leaks, tap Regenerate in the app and run `inoty setup` again.

## Build

Push to `main` (or run the workflow manually). GitHub Actions builds an unsigned `iNoty.ipa` on a `macos-26` runner (Xcode 26, needed for the Liquid Glass APIs) and uploads it as the `iNoty-ipa` artifact. Pushing a `v*` tag also attaches it to a release.

## Notes

- The port is `AppModel.port` in `Sources/AppModel.swift` (default 8765).
- Background audio only keeps iNoty alive if LiveContainer itself is allowed to run in the background.
- Real push notifications (APNs) are not supported. This uses local notifications only.
