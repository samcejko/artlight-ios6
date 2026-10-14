# Changelog

## 0.1.0 (2026-10-15)

First version. Tested on an iPad 2 with iOS 6.1.3 against Apollo on Windows: pairing, the app list, video, sound and
touch input.

- GameStream client on moonlight-common-c (master of 2026-10-14) with Mbed TLS: Sunshine and Apollo hosts.
- Discovery (mDNS `_nvstream._tcp`) and manual add; PIN pairing (SHA-256) and Apollo's one-time-PIN pairing.
- App grid with box art from the host; launch, resume, quit; Apollo permission handling.
- Hardware H.264 decoding (private VideoToolbox on iOS 6), Opus multistream audio through RemoteIO.
- On-screen gamepad, trackpad / direct pointer / touchscreen modes, keyboard with UTF-8 text.
- Apollo: server commands, clipboard both ways, virtual display.
- Settings: resolution (1024x768 default), 30/60 fps, bitrate, statistics overlay; English and Czech.

Good to know:

- On iOS 6 install the **DEB**, not the IPA: only an app in `/Applications` may open the hardware H.264 decoder, the
  IPA shows a black stream.
- The arm64 build (iOS 14-17: the rootless DEB and the TrollStore IPA) has not been tested on a device yet.
- Not tried on the device yet: the on-screen gamepad (the PC needs a virtual gamepad driver, ViGEmBus on Windows) and
  the Apollo extras (server commands, clipboard, virtual display, one-time-PIN pairing).
