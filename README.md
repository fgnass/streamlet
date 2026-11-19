# Streamlet

Your music streaming service as a small Mac app with a player in the menu bar.

Streamlet opens the web player of a streaming service (SoundCloud, Spotify,
YouTube Music, Deezer, Apple Music, Tidal, Bandcamp or any other URL) in its own
window. The menu bar shows the current track, and you can play, pause, skip and
seek from there without the window. Close the window and the music keeps playing.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/fgnass/streamlet/main/install.sh | sh
```

Or download `Streamlet.zip` from the [latest release](https://github.com/fgnass/streamlet/releases/latest).
Requires macOS 13 or later on Apple silicon. On an Intel Mac, [build it yourself](#build).

The app is not notarized. A download with `curl` gets no quarantine flag, so
macOS opens it without a warning. If you download the zip with a browser,
macOS blocks the first start: open System Settings → Privacy & Security and
click Open Anyway.

## How it works

Streamlet shows the service's own web page in WebKit, the engine of Safari.
A script in the page reads the track and the playback state from the
[Media Session API](https://developer.mozilla.org/docs/Web/API/Media_Session_API)
and from the page's audio and video elements. The menu bar controls send their
commands back to the page through the same API.

What this means for you:

- A service that does not play in Safari does not play in Streamlet.
- Next, previous and seek work only when the service supports them in the
  Media Session API. Play and pause also work without it.
- Shuffle and repeat appear only for services where Streamlet knows the
  buttons in the web player. At the moment this is SoundCloud.

## Privacy

You sign in to the service in Streamlet's window. Cookies and website data stay
in Streamlet's WebKit data store on your Mac. Streamlet sends no data to anyone
other than the services you open. To show the service suggestions, it loads
their icons once from the services' websites.

To sign out of all services: menu bar item → right-click → Clear Website Data….

## Build

```sh
./build.sh           # build/Streamlet.app
./build.sh install   # also copy to ~/Applications
./build.sh release   # also write build/Streamlet.zip for a GitHub release
./run.sh             # debug build, without an app bundle
```

Requires the Xcode Command Line Tools (Swift 5.9 or later). `build.sh` builds for the
Mac it runs on, so this also works on an Intel Mac. Only `release` always builds for
Apple silicon. To build for another architecture, set `STREAMLET_ARCH` (`arm64` or `x86_64`).

Signing: set `STREAMLET_SIGN_IDENTITY` to sign with a given identity, for
example a Developer ID. Otherwise `build.sh` uses a certificate named
"Streamlet Local Signing" if one is in the keychain, else ad hoc.

"Open at Startup" uses a login item and works only in the app bundle, not with
`run.sh`.

## Contributing

Issues and pull requests are welcome. To add shuffle, repeat or like for a
service, add an entry to `serviceControls` in
`Streamlet/Sources/MediaSessionBridge.swift`: a selector for the button in the
service's web player and a function that reads its state. Test it with the
real service before you open a pull request.

## License

MIT, see [LICENSE](LICENSE). Third-party packages keep their own licenses, see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
