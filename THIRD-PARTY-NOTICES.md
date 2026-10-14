# Third-party notices

Artlight is an independent client for the GameStream protocol as spoken by the Sunshine and Apollo hosts. It is not
affiliated with, endorsed by or associated with the Moonlight project, Artemis, LizardByte (Sunshine), ClassicOldSong
(Apollo, Artemis) or NVIDIA Corporation. GameStream and NVIDIA are trademarks of NVIDIA Corporation.

The protocol knowledge comes from the open-source Moonlight family: moonlight-common-c (shipped, see below),
[moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) and
[moonlight-android](https://github.com/moonlight-stream/moonlight-android) (pairing and the HTTP API),
[Artemis](https://github.com/ClassicOldSong/moonlight-android) and [Apollo](https://github.com/ClassicOldSong/Apollo)
(one-time-PIN pairing, server commands, clipboard, virtual display) - all GPLv3. The private VideoToolbox entry points
of iOS 4-7 were known from the XBMC/Kodi project's VideoToolbox decoder (GPL-2.0); only the function names and
signatures are used, resolved at run time.

## Software

- **moonlight-common-c** - GPLv3 (Moonlight Game Streaming Project). The whole streaming protocol: RTSP, the ENet
  control stream, RTP video and audio with FEC, input. Included in `vendor/moonlight-common-c` with a few marked
  changes (see `vendor/moonlight-common-c/ARTLIGHT.md`). https://github.com/moonlight-stream/moonlight-common-c
- **ENet** (Moonlight's fork) - MIT (Lee Salzman). The reliable UDP transport of the control stream.
  https://github.com/cgutman/enet
- **nanors** - MIT (sleepybishop). Reed-Solomon forward error correction. https://github.com/sleepybishop/nanors
- **Mbed TLS 3.6** - Apache License 2.0. TLS 1.2 with the client certificate, RSA, X.509, the PSA crypto API
  moonlight-common-c uses (AES-GCM, AES-CBC). https://github.com/Mbed-TLS/mbedtls
- **Opus 1.4** - BSD 3-clause (Xiph.Org Foundation and others). Audio decoding (multistream). https://opus-codec.org
- **Theos** - the build system; not shipped in the app.

The license texts of the shipped libraries are included in the app bundle (Settings - Open-source licenses).
