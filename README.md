# iNoty

A tiny iOS app for LiveContainer. It runs a minimal HTTP server on `127.0.0.1` (loopback only, so nothing on your Wi-Fi can reach it) and turns each request into a local notification. It stays alive in the background by looping silent audio.

## Sending a notification

Every request needs the secret token shown in the app (first launch generates it).

```
GET  http://127.0.0.1:8765/notify?token=TOKEN&title=Hello&body=World
POST http://127.0.0.1:8765/notify        (header: X-Token: TOKEN)
     {"title": "Hello", "body": "World", "subtitle": "optional"}
```

The token can also be sent as `Authorization: Bearer TOKEN`. `GET /health` needs no token.

From iOS Shortcuts, use "Get Contents of URL" with the URL above.

## Build

Push to `main` (or run the workflow manually). GitHub Actions builds an unsigned `iNoty.ipa` and uploads it as the `iNoty-ipa` artifact. Pushing a `v*` tag also attaches it to a release.

## Install

Open the IPA in LiveContainer. LiveContainer signs it itself. Open iNoty once, allow notifications, then leave it running.

## Notes

- The port is `AppModel.port` in `Sources/AppModel.swift` (default 8765).
- Background audio only keeps iNoty alive if LiveContainer itself is allowed to run in the background.
- Real push notifications (APNs) are not supported. This uses local notifications only.
