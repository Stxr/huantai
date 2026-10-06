[Simplified Chinese](token-pet.zh_CN.md) · **English**

# Token Pet application

This derivative has its own three-page UI in `main/pet_main.c`. It reuses the board support drivers and does not compile the original demo menu. USB Serial/JTAG carries bounded version-1 JSONL snapshots from the local Mac ledger. A single NimBLE peripheral connection runs alongside USB. Encrypted characteristics and a USB-provisioned local key gate BLE snapshots. Both transports use the same model and bounded stream parser; the LVGL pool remains 64 KiB.

The six Pokémon families have 12 growth levels, with species changes at levels 5 and 9. Artwork is generated into four 120×120 ARGB8888 frames per species in Flash. The 16/20px Noto CJK subsets cover the UI strings; the OFL and generation inventory live in the parent project.

The pure model rejects stale sequence numbers and decreasing totals or levels. Token counters are decimal strings parsed to uint64. Duplicate snapshots only receive an ACK. Two versioned CRC-protected NVS slots retain the most recent state with a ten-second write interval.

`status` reads state and heap usage. `capture` streams the board's actual RGB565 flush buffers one RLE row at a time without allocating a full frame. Captured pixels establish software rendering, not physical panel or button acceptance.

Run `./tools/validate.sh` with ESP-IDF 5.5.3 activated. This includes model/protocol tests and the parent ledger/HTTP/USB tests, followed by firmware layout verification and a content-addressed ELF/MAP/image archive. Full merged images belong at 0x0 only after authorization; the parent project holds the user's existing overwrite authorization.

See [implementation](../../docs/IMPLEMENTATION.md), [asset provenance](../../docs/ASSETS.md) and [verification](../../evidence/verification.json). The parent README documents runtime commands and current acceptance scope.

The larger sprites use a common alpha bounding box across animation frames, then nearest-neighbor scaling to a maximum 112px inside each 120×120 frame. Web artwork displays at about 200px. The compatible application-only update at 0x10000 was verified to preserve pet NVS and the BLE owner key.

## Game controls and Huantai integration (0.3.0)

First choose one of six starting partners with UP/DOWN. Click OK to review, click again to adopt; confirmation permanently locks the family in the host ledger and same-epoch device state. Legacy intake/level and BLE keys survive the v1-to-v2 CRC-checked NVS migration. Intake pauses until the player chooses; do not select a production partner during testing.

Double OK cycles pet, three recent Huantai sessions, and daily meals. UP/DOWN selects rows; single OK opens the selected session on the Mac through Huantai's validated native opening API. Long OK enters/exits settings; UP/DOWN switches quota progress and pet/connection details. The existing BSP distinguishes single/double/long events, and callbacks only enqueue them.

A separate bounded companion message carries recent incomplete sessions, weekly remaining percentage, today reference, reference marker and reset countdown from the running Huantai loopback API. These updates never feed Tokens or write NVS. Request IDs make retried hardware actions idempotent. USB-only input diagnostics exercise the same game state machine; BLE rejects injected input. Body fonts cover printable GB2312 and ASCII; unsupported title characters become explicit question marks and titles stop on Unicode boundaries.

## Quiet pet and microphone response (0.4.0)

The home screen uses the pet name in the header and the name/level row. Today and lifetime intake share one line; abbreviated counters leave exact values in the Mac panel. The sprite is scaled to 1.5–1.57 times its 120px frame with room for an eight-pixel hop. Ordinary idle stays on frame zero without bobbing.

A dedicated worker reuses the ES8311 BSP at 16kHz, 16-bit mono with muted output. It reads only 320 samples (20ms), removes DC, computes RMS, then discards the PCM. After two seconds of baseline calibration, two consecutive blocks above an adaptive threshold trigger one 480ms hop. Hysteresis and a 700ms cooldown prevent repeated jumps on steady background sound. No audio is recorded, retained, sent to the Mac, or used as Token food. Failure leaves the pet still and shows microphone readiness in settings. Status diagnostics expose only aggregate volume, baseline, block/onset counts, frame and hop offset. The web preview uses a static PNG and no automatic bobbing; sound response runs on the board.

## Connection/battery header and sensitivity (0.4.1)

The header shows BLE/USB/offline on the left and CW2017 battery percentage plus an icon on the right; the pet name remains in the growth row. Gauge reads run in the application worker every five seconds, outside LVGL locks and button callbacks. Missing or failed readings show --% rather than zero. The gauge shares the I2C bus with ES8311, while audio sampling continues through I2S.

The RMS onset threshold is now max(120, noise floor × 2 + 40), down from max(200, floor × 3 + 80). This detects softer speech while retaining the two-block onset, warmup, hysteresis and cooldown. Host tests cover softer input, small baseline fluctuations, a single short click and steady noise.

## Three-tier device settings (0.4.2)

Long OK enters/exits settings. UP/DOWN move through quota, partner details, brightness and microphone onset threshold; click OK on either adjustment page to cycle low → medium → high → low. A highlighted row shows the active tier. Brightness uses 20%, 40% and 75% PWM, defaulting to medium (40%) instead of 75%. The status diagnostic also reads the configured LEDC duty, which is not measured panel luminance.

Microphone threshold tiers are low=max(120, floor×2+40), medium=max(160, floor×2.5+60), and high=max(200, floor×3+80). Low is more sensitive and remains the default. Changing tiers clears partial onset confirmation and waits for quiet input before rearming. Sampling, two-block confirmation, cooldown and audio privacy remain unchanged.

Both choices apply immediately and are committed from the application worker outside LVGL locks to a separate NVS preferences blob. Missing/invalid settings use defaults; failed writes show a retry state. Host snapshots, adoption, Token counters and BLE keys do not overwrite these settings.
