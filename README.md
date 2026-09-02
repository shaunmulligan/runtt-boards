# runtt-boards

**Getting a board to the point where [runtt](https://github.com/shaunmulligan/runtt) can
manage it** — and keeping it that way.

runtt deploys firmware to a microcontroller as an ordinary container image. That
works only once a board has MCUboot and a signed image in slot 0. Putting them
there is the one act that needs physical access, and this repository is how.

Everything after provisioning is remote. This is the step you do once per board.

## Provision a board

**One script, no toolchain.** It downloads the right image for your board, writes
the name you give it into flash, and flashes the result:

```bash
curl -fLO https://raw.githubusercontent.com/shaunmulligan/runtt-boards/main/scripts/runtt-board
chmod +x runtt-board

./runtt-board list
./runtt-board provision rpi_pico --name pico-01
```

That is the whole thing. No repository to clone, no Zephyr, no 2 GB SDK — it
fetches the published image, verifies it against `SHA256SUMS`, and refuses to
flash a download that does not match.

The **name** matters more than it looks. It becomes the board's USB serial and
its identity in flash, so `runtt` can address it as `usb:pico-01` wherever it is
plugged in, rather than by which port it happens to occupy. Add
`--can-node-id 0x45` for a board on a CAN bus.

```bash
./runtt-board provision adafruit_feather_nrf52840 --name arm-01 --can-node-id 0x45
./runtt-board provision rpi_pico --name pico-02 --release v0.1.0   # pin a release
./runtt-board provision rpi_pico --name pico-03 --build            # build locally
```

`--build` is for developing or porting, and is the only mode that needs a west
workspace. Everything else works from the single file.

## Or download the image yourself

Flash one of these **once per board**. After that every update is remote: the
board becomes a container image you deploy with
[runtt](https://github.com/shaunmulligan/runtt).

Doing it this way leaves the board **unnamed** — it will publish a
hardware-derived serial and, on CAN, use the built-in default node id. That is
fine for one board and a collision waiting to happen for two, so prefer
`runtt-board provision` above unless you have a reason not to.

<!-- BEGIN GENERATED: supported devices (scripts/boards.py) -->

| Board | Download | Probe needed? | How |
|---|---|---|---|
| **Raspberry Pi Pico** (RP2040) | [`provision-rpi_pico.uf2`](https://github.com/shaunmulligan/runtt-boards/releases/latest/download/provision-rpi_pico.uf2) | **No** | Hold BOOTSEL, plug in, copy the file onto the drive that appears. Unbrickable — the RP2040 mask ROM always gives you BOOTSEL back |
| **Adafruit Feather nRF52840** (nRF52840) | [`provision-adafruit_feather_nrf52840-mcuboot.hex`](https://github.com/shaunmulligan/runtt-boards/releases/latest/download/provision-adafruit_feather_nrf52840-mcuboot.hex) + [`provision-adafruit_feather_nrf52840-slot0.hex`](https://github.com/shaunmulligan/runtt-boards/releases/latest/download/provision-adafruit_feather_nrf52840-slot0.hex) | Yes, SWD | SWD, both files in order without resetting in between. **Back the board up first — this erases the Adafruit UF2 bootloader and its UICR settings, and there is no ROM loader to fall back on**  |

Check what you downloaded against [`SHA256SUMS`](https://github.com/shaunmulligan/runtt-boards/releases/latest/download/SHA256SUMS). Those
links always resolve to the newest release; [older releases](https://github.com/shaunmulligan/runtt-boards/releases) stay
available.

**Being brought up**, not yet published:

* **Raspberry Pi Pico 2 W** (RP2350) — Unbrickable — the RP2350 boot ROM always gives BOOTSEL back. MCUboot uses 53% of the 64K boot slot, against RP2040's tighter 63.5K (RP2350 needs no 256-byte second-stage bootloader). For bring-up over SWD, pyocd needs -O connect_mode=under-reset: RP2350's flash routines live in ROM and require the core in secure state, and the first connect otherwise fails with "Unable to set target to secure mode".
* **Waveshare ESP32-S3 (DevKitC-compatible)** (ESP32-S3) — Hardware on order. Needs the module dtsi swapped for the N16R8 variant and a partition table chosen — see docs/HARDWARE_TARGETS.md
* **Adafruit RP2040 CAN Bus Feather** (RP2040 + MCP25625) — Hardware on order. Zephyr has the board and `zephyr,canbus` is already chosen, but it ships no MCUboot slots, so a partition variant needs writing

<!-- END GENERATED -->

⚠️ **These images are signed with MCUboot's published development key**, so no
trust root is enrolled and an image signature proves nothing. That is fine on a
bench and unfit for a fleet — generate your own key first, and note that on the
Feather the public half is baked into MCUboot, so rotating it means another SWD
flash.

### Adding a board

Boards are declared in [`boards.yml`](boards.yml), which drives the table above,
the CI build list and the release assets. [`docs/PORTING.md`](docs/PORTING.md) is
the walkthrough; [`docs/HARDWARE_TARGETS.md`](docs/HARDWARE_TARGETS.md) covers
what each candidate still needs, and the boards deliberately rejected with the
reasons.

## What is here

| Path | What |
|---|---|
| `west.yml` | the Zephyr manifest: the exact pinned Zephyr, MCUboot and HALs |
| `patches.yml`, `patches/` | carried upstream patches, applied by `west patch` and pinned by sha256 |
| `app-test/` | the **board test application**. Every board build compiles this, which is how a board proves it can build the full contract — and its `native_sim` binary *becomes* the fixture published for [`runtt`](https://github.com/shaunmulligan/runtt)'s gates. Not an example to copy; that is [`runtt-examples`](https://github.com/shaunmulligan/runtt-examples) |
| `idle/` | the **provisioning payload**: the no-op application that ships in slot 0, so a fresh board enumerates and reports itself rather than looking dead. Only the `provision` build modes use it |
| `bringup/`, `diag/` | configurations for proving one thing at a time when a board misbehaves |
| `builder/` | a reusable Docker build environment, so an application directory needs a six-line Dockerfile |
| `scripts/build-*.sh` | per-board builds: bring-up, MCUboot, provisioning images |
| `scripts/runtt-board` | one entry point: `list`, `build`, `provision`, `flash`, `backup`. Dispatches per board from `boards.yml` |
| `scripts/setup-prereqs.sh` | one-time host setup; `--check` just verifies |

## Why there are two applications

They look like duplication and are not: their requirements conflict.

| | `app-test/` | `idle/` |
|---|---|---|
| Role | test fixture, and per-board build proof | shipped in every provisioning image |
| Logging | `alive, tick N` every 2 s | one line, then sleeps forever |
| Size | ordinary | minimal — `LOG_MODE_MINIMAL`, 1 KB stack |
| `CONFIG_RUNTT_IDLE` | off | **on** |

`app-test/` has to keep talking, because [`runtt`](https://github.com/shaunmulligan/runtt)'s
end-to-end gates assert that application output reaches the log channel — and the
CAN gate greps a *recurring* line, since a raw CAN log channel has no backlog and
a one-shot startup message would race the listener.

`idle/` has to be quiet and small, because it is written into every provisioning
image, where every byte is wasted flash and a slower write. It logs once and
sleeps.

One application cannot be both, and a flag switching between them would put the
provisioning payload's size at the mercy of the test fixture's needs.

## Why `idle/` matters more than it looks

MCUboot with an empty primary slot halts with *Unable to find bootable image* —
and, having no USB of its own, does so **completely silently**. No enumeration, no
device node. A board in that state is indistinguishable from one that is unplugged
or dead.

`idle` is a no-op application that reports `idle: true` over `describe`, so a
factory-fresh board shows up as a service saying *"provisioned, awaiting first
firmware"*. Those two states look identical otherwise and want opposite reactions.

## What this repository publishes

* **Provisioning images** per supported board — MCUboot plus a signed idle
  application, as one contiguous region ready to flash.
* **`native_sim` firmware fixtures** — as build *artefacts*, not release assets.
  They are host executables that only a CI job or someone debugging a run has any
  use for, and a release page is where a user goes to flash a board.

## The runtt repositories

| Repo | What it holds | Start here if |
|---|---|---|
| [`runtt`](https://github.com/shaunmulligan/runtt) | the OCI runtime — the **host** side | you want to know what runtt is, or to work on the runtime |
| [`runtt-zephyr-module`](https://github.com/shaunmulligan/runtt-zephyr-module) | the Zephyr module — the **device** side | you have firmware and want it manageable |
| [`runtt-boards`](https://github.com/shaunmulligan/runtt-boards) | provisioning, board bring-up, the west manifest | you have a board that has never run runtt |
| [`runtt-examples`](https://github.com/shaunmulligan/runtt-examples) | two worked applications, and the walkthrough | you want to watch it work end to end |

**New here?** Read [`runtt`](https://github.com/shaunmulligan/runtt)’s README for what this
is and why, then follow the walkthrough in
[`runtt-examples`](https://github.com/shaunmulligan/runtt-examples).

## Licence

Dual licensed under [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your
option.
