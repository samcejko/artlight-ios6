# Artlight - developer notes

Artlight streams games from the user's own PC to jailbroken iOS 6 (iPad 2 / A5 first) using the GameStream
protocol of Moonlight: it works with **Sunshine** hosts and with **Apollo** (ClassicOldSong's Sunshine fork), including
the Apollo extras the Android client **Artemis** uses. The name is ours (not "Moonlight", not "Artemis").

Research of 2026-10-14 (sources read: moonlight-common-c master 5ec8397 of 2026-10-14, moonlight-ios master,
Artemis = ClassicOldSong/moonlight-android branch `moonlight-noir` + its moonlight-common-c fork c999436,
Apollo master `src/nvhttp.cpp`, `src/crypto.h`, `src/stream.cpp`).

## moonlight-common-c (vendor/moonlight-common-c, GPLv3)

The whole streaming protocol in portable C: RTSP handshake (plain or `rtspenc://` AES-GCM), ENet control stream,
RTP video with Reed-Solomon FEC (nanors), RTP audio with FEC, input stream (AES-GCM encrypted), loss stats, IDR
requests. The client only supplies:

- `SERVER_INFORMATION`: address, `appversion` and `GfeVersion` from /serverinfo, `sessionUrl0` from /launch or
  /resume, `ServerCodecModeSupport`.
- `STREAM_CONFIGURATION`: width/height/fps/bitrate (kbps), packetSize (1392 LAN), `STREAM_CFG_AUTO`, audio config
  (`AUDIO_CONFIGURATION_STEREO`), `supportedVideoFormats` (= `VIDEO_FORMAT_H264` only here), `encryptionFlags`,
  `remoteInputAesKey` + `remoteInputAesIv` (the same 16-byte key as `rikey` and the big-endian `rikeyid` in the
  first 4 bytes of the IV).
- Decoder callbacks: `setup(videoFormat, w, h, fps)`, `start`, `stop`, `cleanup`, `submitDecodeUnit(du)` returning
  `DR_OK` or `DR_NEED_IDR`. For H.264 every buffer of an IDR frame's list is typed (SPS, PPS, then picture data) and
  each one starts with its Annex B start code, so the list concatenated is one Annex B access unit.
  Without `CAPABILITY_DIRECT_SUBMIT` the library calls submit from its own decoder thread.
- Audio callbacks: `init(audioConfig, opusConfig)` (Opus **multistream**: sampleRate, channelCount, streams,
  coupledStreams, samplesPerFrame, mapping), `decodeAndPlaySample(data, len)` - `data == NULL` means a lost packet
  (run Opus packet-loss concealment). With `CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION` the frame size is
  samplesPerFrame (not always 240).
- Connection listener: stage starting/complete/failed, connectionStarted, connectionTerminated(error),
  logMessage, rumble, connectionStatusUpdate (poor/okay), setHdrMode, ...
- Input: `LiSendMouseMoveEvent`, `LiSendMousePositionEvent`, `LiSendMouseButtonEvent`, `LiSendKeyboardEvent`
  (Windows VK codes), `LiSendUtf8TextEvent`, `LiSendScrollEvent`/`HighRes`, `LiSendMultiControllerEvent`
  (XInput bit layout: A 0x1000, B 0x2000, X 0x4000, Y 0x8000, dpad 1/2/4/8, start 0x10, back 0x20, LB 0x100,
  RB 0x200), `LiSendControllerArrivalEvent`, `LiSendTouchEvent` (Sunshine; check `LiGetHostFeatureFlags() &
  LI_FF_PEN_TOUCH_EVENTS`).
- `LiGetLaunchUrlQueryParameters()` must be appended to /launch and /resume (it is `&corever=1`, which turns on the
  encrypted RTSP on Sunshine/Apollo).

Crypto: `USE_MBEDTLS` -> `USE_PSA_CRYPTO`: AES-GCM and AES-CBC through the **PSA API** of mbedTLS 3.x (so
`MBEDTLS_PSA_CRYPTO_C` must stay on in our config) and `psa_generate_random`.

### Our changes (marked "Artlight" in the code)

1. `src/Platform.c`: the Darwin timer used `clock_gettime_nsec_np()` (iOS 10+, not in the 9.3 SDK) -> now
   `mach_absolute_time()` with the timebase.
2. Apollo server commands (as in the Artemis fork): `LiSendExecServerCmd(cmdId)` = control message type `0x3000`
   with payload `{cmdId, 0, 0, 0}` on ENet channel 8 (`CTRL_CHANNEL_SERVERCTL`), reliable; only in the
   `packetTypesGen7Enc` table (Sunshine family).

Build notes: ENet (cgutman fork, submodule commit aca8784) and nanors (b1e3c22) are copied in; ENet needs
`-D__APPLE_USE_RFC_3542` for the IPv6 pktinfo options and `HAS_SOCKLEN_T`; nanors uses NEON on armv7 (A5 has it).
`SO_NET_SERVICE_TYPE` does not exist in the 9.3 SDK, so that `setsockopt` is compiled out for iOS 6 (it only
logs when it fails anyway).

## The HTTP API (nvhttp)

Two ports on the host: **HTTP 47989** (serverinfo, pairing) and **HTTPS 47984** (`HttpsPort` in serverinfo; the
TLS connection carries **our client certificate**, and we pin the host certificate we got while pairing). Every
request has the query parameters `uniqueid=0123456789ABCDEF` (fixed - Sunshine tells clients apart by the
certificate), `uuid=<random>` and, for pairing, `devicename=<name>`. Answers are XML `<root status_code="200"
status_message="...">...</root>`; any status_code other than 200 is an error (Apollo: 403 "Permission denied",
503 "OTP auth not available.", 400 "An app is already running on this host", 410 "App terminated.").

- `GET /serverinfo` (HTTP before pairing, HTTPS after): `hostname`, `appversion` (4 parts, e.g. 7.1.431.-1 -
  a negative 4th part = Sunshine family), `GfeVersion`, `uniqueid` (host id), `HttpsPort`, `ExternalPort`,
  `mac` (00:00:... over HTTP), `LocalIP`, `ServerCodecModeSupport`, `PairStatus` (1 only over HTTPS with a
  paired cert), `currentgame` + `currentgameuuid` + `state` (`SUNSHINE_SERVER_BUSY`/`_FREE`).
  **Apollo extras over HTTPS:** `Permission` (bitmask, below), repeated `<ServerCommand>` names (only with the
  server_cmd permission), `VirtualDisplayCapable` and `VirtualDisplayDriverReady` (Windows hosts).
- Pairing (`GET /pair?uniqueid&devicename&updateState=1&...`), hash = SHA-256 for appversion major >= 7 (SHA-1 for
  older GFE):
  1. `phrase=getservercert&salt=<16 random bytes hex>&clientcert=<hex of our PEM certificate>` - blocks until the
     user types the 4-digit PIN (which **we** show) on the host (Sunshine/Apollo web UI, PIN page). Answer:
     `paired=1`, `plaincert` = hex of the host's PEM certificate (empty = someone else is pairing -> unpair, retry).
     AES key = first 16 bytes of hash(salt || PIN ascii).
     **Apollo OTP pairing:** add `&otpauth=<HEX of SHA-256(pin + saltHex + passphrase)>` (uppercase hex; saltHex is
     the same uppercase hex string sent as `salt`); the PIN and passphrase come from Apollo's web UI ("One Time
     PIN"), the request then answers at once (no typing on the host). The OTP expires after a short time.
  2. `clientchallenge=<hex AES-128-ECB(16 random bytes)>` -> `challengeresponse` (decrypt: first hashLen bytes =
     server response hash, next 16 = server challenge).
  3. `serverchallengeresp=<hex AES-ECB(hash(serverChallenge || clientCertSignature || clientSecret16))>` ->
     `pairingsecret` = 16-byte server secret || RSA-SHA256 signature of it; verify the signature with the host
     certificate; check hash(ourChallenge || hostCertSignature || serverSecret) == server response hash, else the
     PIN was wrong. ("certificate signature" = the raw signature value inside the X.509 certificate.)
  4. `clientpairingsecret=<hex clientSecret || RSA-SHA256 signature of it with our key>` -> `paired=1`.
  5. Over **HTTPS**: `phrase=pairchallenge` -> `paired=1`.
  On any failure: `GET /unpair`. Our identity: RSA-2048 key + self-signed X.509 (CN "NVIDIA GameStream Client",
  SHA-256), made once on the device.
- `GET /applist` (HTTPS): `<App><AppTitle/><ID/><UUID/><IDX/><IsHdrSupported/></App>`... Apollo without the list
  permission returns one fake app "Permission Denied" with ID 114514.
- `GET /appasset?appid=<id>&AssetType=2&AssetIdx=0` (HTTPS): the box art, PNG.
- `GET /launch` and `/resume` (HTTPS, no read timeout - the host starts the game):
  `appid`, (`appuuid` Apollo), `mode=WxHxFPS`, `additionalStates=1`, `sops=0|1`, `rikey=<hex 16>`, `rikeyid=<int>`,
  `localAudioPlayMode=0|1`, `surroundAudioInfo=<SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION>`,
  `remoteControllersBitmap`, `gcmap`, `gcpersist`, + `LiGetLaunchUrlQueryParameters()`.
  **Apollo extras:** `virtualDisplay=0|1` (create a virtual monitor at the client's resolution),
  `scaleFactor=<percent, 100>`. Answer: `gamesession` (launch) / `resume` != 0 and `sessionUrl0` (the RTSP URL).
- `GET /cancel` (HTTPS): quits the running app (`cancel` != 0).
- **Apollo clipboard:** `GET /actions/clipboard?type=text` returns the host's clipboard text (needs clipboard_read
  permission and a running stream of this client); `POST /actions/clipboard?type=text` with a text/plain body sets
  it (clipboard_set; an empty answer body = success).

### Apollo permission bits (`Permission` in serverinfo)

| bit | meaning |
| --- | --- |
| 0x00000100 | input: controller |
| 0x00000200 | input: touch |
| 0x00000400 | input: pen |
| 0x00000800 | input: mouse |
| 0x00001000 | input: keyboard |
| 0x00010000 | clipboard set (client -> host) |
| 0x00020000 | clipboard read (host -> client) |
| 0x00040000 | file upload |
| 0x00080000 | file download |
| 0x00100000 | server commands |
| 0x01000000 | list apps |
| 0x02000000 | view streams |
| 0x04000000 | launch apps |

New clients get view + list by default; the user grants more in Apollo's web UI (Clients page).

### Other Artemis features (not all worth it on iOS 6)

- OTP pairing (done), server commands menu during a stream (done via `LiSendExecServerCmd`), clipboard sync
  (done: send / fetch from the stream menu), virtual display toggle + "VirtualDisplayDriverReady" warning,
  resolution scale factor, permission display, `appuuid` launches, "terminate" pseudo app (Apollo answers 410).
- `LiSendEmptyPayload()` every 20 ms (a "background ping" keeping some Wi-Fi chips awake) - not used.
- `art://host:port?pin=&passphrase=` QR links from Apollo's web UI - not used (no camera QR reader on iOS 6).

## Discovery

mDNS service `_nvstream._tcp` in `local.` (NSNetServiceBrowser works on iOS 6); resolve -> IPv4 address; then
/serverinfo identifies the host by `uniqueid`. Manual add by IP or name. Wake-on-LAN uses `mac` (HTTPS
serverinfo only) - magic packet to UDP 9 broadcast.

## Device constraints (from GFN6)

- The A5 hardware decoder needs ~16.7 ms per 1024x768 H.264 frame: **30 fps is smooth, 60 fps is borderline** ->
  defaults 1024x768 / 30 fps; H.264 only (no HEVC/AV1 on A5).
- VideoToolbox is a private framework on iOS 6 (dlopen'd), and the sandbox of a container (IPA) app denies
  `iokit-open AppleVXD390UserClient` -> **Artlight must be installed as the DEB into /Applications**.
- No GameController framework on iOS 6 -> on-screen gamepad, touch mouse, software keyboard.
