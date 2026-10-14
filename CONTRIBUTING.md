# Contributing

## Building without a Mac

Every push builds on GitHub Actions (`.github/workflows/build.yml`): Theos, the iOS 9.3 and 16.5 SDKs from
theos/sdks, a Linux clang toolchain, Mbed TLS 3.6 and libopus 1.4 are fetched there; moonlight-common-c with ENet and
nanors is in `vendor/`. The result is an IPA and a DEB per architecture in the `Artlight-packages` (armv7, iOS 6) and
`Artlight-packages-arm64` (iOS 14+) artifacts. Compile errors show up in the "Syntax check" step and in the
`build-log-*` artifacts.

`tools/gh-push.ps1 -Message "..."` pushes the working tree through the GitHub API (no git needed),
`tools/gh-build.ps1 -Download -HeadSha <sha>` waits for the build and downloads the packages,
`. .\tools\ipad.ps1; Install-IPadPackage -DebPath ...` installs over SSH (the DEB: see below), `Enable-ArtlightDebug`
turns the `artlight:` debug commands on, `Invoke-Artlight 'artlight:selftest'` runs the self tests on the device,
`Get-ArtlightLog` reads the app's log lines, `Get-IPadScreen -OutFile x.png -Real` grabs the screen.
`tools/local.json` (ignored by the push script) holds the repository, token and the device addresses.

On iOS 6 the app must be installed as the **DEB** (into `/Applications`): the sandbox of an IPA in an app container
denies the hardware H.264 decoder (`iokit-open AppleVXD390UserClient`).

## Ground rules

- iOS 6.0 is the deployment target for the armv7 build. Anything newer than iOS 6 is a compile error
  (`-Wunguarded-availability` and the pragma in `ALCommon.h`); `src/Util/ALModern.m` bridges iOS 7+ for the arm64 build.
  No storyboards, no auto layout, UI in code, the skeuomorphic iOS 6 look.
- ARC in Objective-C. The protocol is moonlight-common-c; changes to it stay small and are marked "Artlight" and
  listed in `vendor/moonlight-common-c/ARTLIGHT.md`.
- The GameStream HTTP calls go through `ALNvRequest` (mbedTLS, our client certificate, the host's certificate pinned).
  Never `NSURLConnection`/`NSURLSession`.
- Text shown to the user goes through `L()` with the English text as the key; `Resources/cs.lproj` has the Czech.
  `tools/check-strings.ps1` lists what is missing.
- No secrets in the repository. The client certificate is made on the device.
- `artlight:selftest` checks SHA-256, AES-128-ECB (FIPS-197), RSA sign/verify with the identity, SPS parsing and
  VideoToolbox.

## In the pull request

Say what you tested on a real device (model, iOS version, host: Sunshine or Apollo and its version) and attach a
screenshot when the UI changed.
