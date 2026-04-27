# Firmware build workflow

## Where things live

```
C:\project\micropython_debugger\firmware\    ← this folder (Windows)
├── BUILD.md              this file
├── patches\              our edits to MicroPython, as numbered .patch files
│   ├── 0001-*.patch
│   └── 0002-*.patch
├── apply.sh              reset MicroPython tree, apply all patches
└── build.sh              apply + build + copy UF2 here

~/micropython\            ← the MicroPython source tree (WSL, pristine git clone)
```

**Never edit files inside `~/micropython/` directly.** All edits live as
patches in `firmware/patches/`. This way we keep a clean record of every
change we make to upstream MicroPython.

## One-time setup

Done in Phase 1. Summary:

- WSL2 Ubuntu 24.04
- `build-essential git cmake gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib python3 pkg-config libusb-1.0-0-dev`
- MicroPython cloned at `~/micropython` with submodules

## Known gotchas (carry forward every build)

1. **picotool version**: pass `PICOTOOL_FORCE_FETCH_FROM_GIT=1` on the make
   command so the build fetches its own matching version.
2. **Windows PATH leakage**: WSL sees Windows' `picotool.exe` through `/mnt/c`
   and CMake picks it up. Strip PATH for the build:
   `PATH=/usr/local/bin:/usr/bin:/bin`

Both handled by `build.sh`.

## Daily flow

From a WSL terminal:

```bash
cd /mnt/c/project/micropython_debugger/firmware
./build.sh
```

Output: `firmware/firmware.uf2` on the Windows side, ready to flash.

To flash:
1. Unplug Pico 2 W.
2. Hold BOOTSEL, plug USB back in, release.
3. Drag `firmware.uf2` onto the `RP2350` drive.

## Adding a new patch

1. In WSL, edit the file(s) inside `~/micropython/`.
2. Generate the patch:
   ```bash
   cd ~/micropython
   git diff > /mnt/c/_Projects/micropython_debugger/firmware/patches/NNNN-short-description.patch
   ```
3. Reset the tree so nothing is left dirty:
   ```bash
   git checkout .
   ```
4. Test: run `build.sh` — it will apply all patches fresh, including the new one.

Numbering: `0001`, `0002`, ... applied in filename order.
