# iNoty

A tiny iOS app for LiveContainer. It runs a minimal HTTP server and turns each request into a fully customizable local notification. It stays alive in the background by looping silent audio.

By default the server listens on `127.0.0.1` only, so nothing on your Wi-Fi can reach it. Letting other devices on your network send requests is an optional switch in the app (off by default), and so is receiving requests from the internet through a relay.

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
| `sound` | `default`, `none` or `ringtone` |
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

Not possible: running code sent over HTTP, and custom sound files. The API exposes every notification option iOS offers instead.

## History

The main screen shows the last 5 requests. "Open full history" lists the saved ones (kept across launches; 100 by default, change it from 10 to 500 with the gear button in the top right, which deletes the oldest ones if you lower it); tap one to see its time, result and every field that was sent. Requests that were refused because a field was invalid show up in red with the reason. Image data is not stored, only its length. Requests with a wrong token are not recorded.

## Network access (optional)

Turn on "Allow other devices on my network" in the app. The server then listens on all interfaces but still only accepts connections from private addresses (10.x, 172.16-31.x, 192.168.x, link-local, and 100.64.x used by Tailscale). Public addresses are always refused, and the token is still required.

- Traffic is plain HTTP, so the token can be seen by anyone on that network. Only use it on networks you trust.
- The app shows the address to use. On the other device run `inoty setup --host THAT_ADDRESS`.
- iOS may ask for Local Network permission, which inside LiveContainer belongs to LiveContainer itself (iOS Settings, Privacy & Security, Local Network).
- If the token ever leaks, tap Regenerate in the app and run `inoty setup` again.

## Internet relay (optional)

To send from anywhere (another network, a server, an agent running in the cloud), turn on "Receive requests over the internet" in the app. The app then makes an **outgoing** HTTPS connection to a relay (a free [ntfy](https://ntfy.sh) topic by default) and turns every message posted to that topic into a notification. Nothing is opened on your phone, so it works on cellular and behind any router.

The "Internet relay" card shows the secret address, for example `https://ntfy.sh/inoty-0123...`. Send to it with the script:

```sh
inoty setup --relay https://ntfy.sh/inoty-0123...     # once, on the sending machine
inoty send "Agent finished" "Refactor is done"       # now goes over the internet
```

or with plain curl. A text body becomes the notification body, and the `Title` header becomes the title. A JSON body can use every field from the table above, and `{"clear":true,"id":"x"}` removes a notification:

```sh
curl -d "Agent finished" https://ntfy.sh/inoty-0123...
curl -H "Title: Agent" -d "Refactor is done" https://ntfy.sh/inoty-0123...
curl -d '{"title":"Agent","body":"Done","level":"timeSensitive"}' https://ntfy.sh/inoty-0123...
```

- If the phone is offline, messages are fetched when it reconnects, as long as the relay still has them (12 hours on ntfy.sh by default).
- Keep messages under about 4096 bytes, so no `imageBase64` (an `image` URL is fine). ntfy.sh limits anonymous senders to a burst of 60 requests and then one every 5 seconds.
- **The address is a password.** Anyone who has it can send you notifications, including ones with links and images, and the relay server can read every message. Don't send anything sensitive. "New topic" in the app replaces the address, and the old one stops working.
- To use your own ntfy server, set its https address under the gear button, "Relay server".
- Untested inside LiveContainer: whether iOS keeps the connection alive while the app is in the background. The app reconnects automatically when it can and when you open it.

## Build

Push to `main` (or run the workflow manually). GitHub Actions builds an unsigned `iNoty.ipa` on a `macos-26` runner (Xcode 26, needed for the Liquid Glass APIs) and uploads it as the `iNoty-ipa` artifact. Pushing a `v*` tag also attaches it to a release.

## Notes

- The port is `AppModel.port` in `Sources/AppModel.swift` (default 8765).
- Background audio only keeps iNoty alive if LiveContainer itself is allowed to run in the background.
- Real push notifications (APNs) are not supported. This uses local notifications only.
