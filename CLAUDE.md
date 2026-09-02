# runtt-boards

Board support, provisioning images and the Zephyr manifest for
[runtt](https://github.com/shaunmulligan/runtt) — an OCI runtime that deploys
firmware to a microcontroller instead of running a container.

This repo produces the **one thing a user flashes by hand**. Everything after
provisioning is remote, so a mistake here is the mistake that needs someone to
walk to the device.

## This is a west manifest repo: it needs a workspace

Nothing here builds on its own. `zephyr/`, `modules/runtt/` and
`bootloader/mcuboot/` sit **beside** this repository, not inside it:

```bash
mkdir ws && cd ws
git clone https://github.com/shaunmulligan/runtt-boards boards
west init -l boards && west update --narrow -o=--depth=1
pip install -r zephyr/scripts/requirements-base.txt
```

```
ws/boards/          this repository (self.path in west.yml)
ws/zephyr/          pinned v4.4.2
ws/modules/runtt/   the device half of the contract
ws/bootloader/mcuboot/
```

**Resolve paths through `west topdir`, never from the repo root.** Several bugs
came from scripts assuming `$REPO/zephyr` — correct in the monorepo this was
extracted from, wrong now, and the resulting CMake error (`Unknown CMake command
"zephyr_get"`) says nothing about the cause.

## Building

```bash
./scripts/build-native-sim.sh              # no SDK needed: host toolchain
./scripts/build-pico.sh    mcuboot         # full contract on RP2040
./scripts/build-feather.sh mcuboot         # full contract on nRF52840
./scripts/build-pico.sh    provision       # the flashable image
./scripts/boards.py --collect out          # gather every board's artefacts
```

Only ARM and the host compiler are needed: `west sdk install -t arm-zephyr-eabi`,
about 2 GB. Do **not** reach for `zephyrprojectrtos/ci` — it carries ~35
toolchains, comes to 33 GB, and exhausted the CI runner's disk.

## boards.yml is the source of truth

`boards.yml` drives the CI build list, the release assets and the README table.
Adding a board is one entry plus `./scripts/boards.py --write-readme`;
`--check-readme` fails the build if they disagree. Do not hand-edit the generated
README block, and do not add a board's assets to the workflow by hand.

[`docs/PORTING.md`](docs/PORTING.md) is the walkthrough for a new device.

## What this codebase cares about

**Claims must be verified, not inferred.** A flag existing does not prove its
effect. Grep the linked ELF, not the source — three USB descriptor strings
survived a project-wide rename because every check read source files.

**Run the full sequence from a clean tree, in CI's order.** A stale build
directory made a wrong default look correct for days; the bug surfaced only in CI,
where the steps run in a different order and nothing is left over. `rm -rf build*`
before believing a green run.

**A default that is right half the time is worse than none.** Two bugs here were
plausible defaults naming one of the two directories a caller might mean
(`--mcuboot`, `--build-dir`). Both are required arguments now. Prefer failing
loudly over guessing.

**Comments record why, not what.** The valuable content in this repo is the
recorded reasons — why `idle/` exists at all, why the swap mode is pinned, why
signing for the primary slot uses `--pad --confirm` rather than `--pad-header`.
Each is a bug that cost real time. Keep that habit.

**Never weaken a safety check to make something pass.** `runtt-board flash` refuses to flash the Feather without a verified backup because that erase destroys a
bootloader with no ROM loader behind it. If it is in the way, fix the backup.

## The two applications are not duplicates

`app-test/` is the reference application every board build compiles, and its
`native_sim` binary is the fixture runtt's gates consume — it must keep logging.
`idle/` ships inside every provisioning image and must be silent and tiny. See
the note in `app-test/prj.conf`; one application cannot be both.

## Signing

Everything is signed with MCUboot's **published development key**, so no trust
root is enrolled and an image signature proves nothing. Fine on a bench, unfit for
a fleet. Say so wherever a user might otherwise assume otherwise — and note that
on the Feather the public half is baked into MCUboot, so rotating it means another
SWD flash.

## Commits

Explain the change and the reasoning. If a bug was subtle, record what made it
subtle — that is what stops the next person reintroducing it. If something was
measured, give the number.
