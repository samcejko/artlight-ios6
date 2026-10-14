# Artlight

Game streaming from your own PC to jailbroken **iOS 6** (iPad 2 and newer, iPhone 4S and newer) - and a second build
for 64-bit devices with iOS 14-17. Artlight speaks the GameStream protocol of Moonlight, so it plays games from PCs
running **[Sunshine](https://github.com/LizardByte/Sunshine)** or **[Apollo](https://github.com/ClassicOldSong/Apollo)**,
including the Apollo extras that the Android client Artemis knows.

- finds the PCs on the network by itself (mDNS), or add one by its address
- pairing with a PIN typed on the PC, or with Apollo's **one-time PIN** and passphrase
- the PC's apps as a grid of box art; start, resume, quit
- hardware H.264 decoding (VideoToolbox), Opus sound, 1024x768 at 30 fps by default (what an iPad 2 decodes smoothly)
- on-screen Xbox gamepad, touch as a trackpad, as a direct pointer or as real Windows touch, keyboard with Esc, Tab,
  Ctrl, Alt, Win and arrows, any character as text (č, ř, ...)
- **Apollo:** server commands from the stream menu, clipboard both ways, virtual display at the device's resolution,
  the client permissions shown per PC
- statistics overlay, Wake-on-LAN, English and Czech

## Install

iOS 6: install the **DEB** (Cydia, or `dpkg -i` then `su mobile -c uicache`). It must be the DEB: it goes into
`/Applications`, where the app may open the hardware video decoder; an IPA in an app container is sandboxed away from
it and shows a black screen. iOS 14-17: the `iphoneos-arm64` DEB for rootless jailbreaks, the `-arm64.ipa` for
TrollStore (not tested on a device yet). Releases: [GitHub](https://github.com/samcejko/artlight-ios6/releases), or
the Cydia repository `http://repo.samcejko.eu/`.

On the PC: install Sunshine or Apollo, then in Artlight tap the PC and pair. For a normal pairing Artlight shows a
4-digit PIN that you type on the PC's web page (`https://<pc>:47990`, PIN). With Apollo you can instead create a
one-time PIN with a passphrase on its web page and type both into Artlight.

## Building

No Mac needed: every push builds on GitHub Actions (Theos, the iOS 9.3 and 16.5 SDKs, Mbed TLS 3.6, libopus 1.4).
See [CONTRIBUTING.md](CONTRIBUTING.md) and the developer notes in [NOTES.md](NOTES.md).

## License

GPLv3 (see [LICENSE](LICENSE)) - Artlight is built on [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c).
Not affiliated with Moonlight, Artemis, Sunshine, Apollo or NVIDIA. Third-party code and its licenses:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Like it? [ko-fi.com/samcejko](https://ko-fi.com/samcejko)
