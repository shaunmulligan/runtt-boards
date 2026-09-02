# runtt-boards

**Getting a board to the point where [runtt](https://github.com/shaunmulligan/runtt) can
manage it** — and keeping it that way.

runtt deploys firmware to a microcontroller as an ordinary container image. That
works only once a board has MCUboot and a signed image in slot 0. Putting them
there is the one act that needs physical access, and this repository is how.

Everything after provisioning is remote. This is the step you do once per board.

## Start here

**[docs/PROVISIONING.md](docs/PROVISIONING.md)** — the provisioning flow, per
board, including the parts that are irreversible and how not to lose a bootloader.

**[docs/HARDWARE_TARGETS.md](docs/HARDWARE_TARGETS.md)** — which boards are
supported, what each one still needs, and the boards deliberately rejected with
the reasons. Read this before buying anything.

## What is here

| Path | What |
|---|---|
| `west.yml` | the Zephyr manifest: the exact pinned Zephyr, MCUboot and HALs |
| `patches.yml`, `patches/` | carried upstream patches, applied by `west patch` and pinned by sha256 |
| `app/` | the **reference application**. Every board build compiles this, which is how a board proves it can build the full contract — and its `native_sim` binary *becomes* the fixture published for [`runtt`](https://github.com/shaunmulligan/runtt)'s gates. Not an example to copy; that is [`runtt-examples`](https://github.com/shaunmulligan/runtt-examples) |
| `idle/` | the **provisioning payload**: the no-op application that ships in slot 0, so a fresh board enumerates and reports itself rather than looking dead. Only the `provision` build modes use it |
| `bringup/`, `diag/` | configurations for proving one thing at a time when a board misbehaves |
| `builder/` | a reusable Docker build environment, so an application directory needs a six-line Dockerfile |
| `scripts/build-*.sh` | per-board builds: bring-up, MCUboot, provisioning images |
| `scripts/flash-*.sh` | flashing over SWD or UF2. The Feather script refuses to run without a verified backup |
| `scripts/setup-prereqs.sh` | one-time host setup; `--check` just verifies |

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
* **`native_sim` firmware fixtures**, which [`runtt`](https://github.com/shaunmulligan/runtt)'s
  end-to-end gates consume. The runtime's tests need a firmware *binary*, not
  firmware source, so it pins a release from here rather than building Zephyr.

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
