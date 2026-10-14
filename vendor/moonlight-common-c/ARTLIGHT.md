# moonlight-common-c in Artlight

Upstream: https://github.com/moonlight-stream/moonlight-common-c, master at commit
`5ec839727a8720640a354e3b4b78cf099ea8cc4d` (2026-10-14), GPLv3 (`LICENSE.txt`). Submodules copied in:

- `enet/`: https://github.com/cgutman/enet at `aca87840b57f045a1f7f9299e4b1b9b8e2a5e2f1` (MIT, `enet/LICENSE`);
  only the Unix sources and headers.
- `nanors/`: https://github.com/sleepybishop/nanors at `b1e3c22ca0cdc0bb83e3cd6ed1a2fc77869ed99a` (MIT,
  `nanors/LICENSE`); `rs.c` and the `oblas` files the library builds.

## Changes (each marked "Artlight" in the code)

1. `src/Platform.c` - the Darwin clock used `clock_gettime_nsec_np()`, which only exists from iOS 10 (and is not in
   the iOS 9.3 SDK the armv7 build uses): replaced by `mach_absolute_time()` with the timebase, the same clock.
2. `src/Limelight.h`, `src/Limelight-internal.h`, `src/ControlStream.c` - Apollo's server commands, as the Artemis
   fork (https://github.com/ClassicOldSong/moonlight-common-c) has them: `LiSendExecServerCmd(cmdId)` sends control
   message `0x3000` with the payload `{cmdId, 0, 0, 0}` on ENet channel 8 (`CTRL_CHANNEL_SERVERCTL`), reliably; only
   for Sunshine-family hosts with the encrypted control stream (`packetTypesGen7Enc`).

Build flags (Makefile): `USE_MBEDTLS` (the PSA crypto API of Mbed TLS 3.6), `HAS_SOCKLEN_T`, `__APPLE_USE_RFC_3542`
(ENet's IPv6 packet-info options).
