# dockmove

`dockmove` is a small CLI for moving a macOS window to another Space on macOS 15
by executing the move from Dock's process context instead of from an ordinary
client process.

## Why this exists

The older client-side move calls such as `CGSMoveWindowsToManagedSpace` and
`SLSMoveWindowsToManagedSpace` are still present, but on current macOS they no
longer reliably move windows when called from a normal process. They still
appear to work from Dock's WindowServer context, which is the same general
approach used by yabai's scripting addition.

This repo builds:

- `dockmove`
- `dockmove-payload.dylib`

The CLI enumerates windows and spaces, injects a small payload into Dock, and
then asks that payload to perform `SLSMoveWindowsToManagedSpace` over a local
Unix socket.

## Current scope

- Apple Silicon only
- macOS 15 / Sequoia target
- minimal release engineering
- no Accessibility dependency for the current command surface

## Quick install

From a published repo:

```sh
curl -fsSL https://raw.githubusercontent.com/KonradStanski/dockmove/main/install.sh | sh
```

From source:

```sh
./build.sh
```

## Required manual setup

This part cannot be automated by an install script. Dock injection needs the
same class of SIP relaxation that yabai's scripting addition uses.

### 1. Relax SIP in Recovery

Boot into Recovery, open `Utilities > Terminal`, then run:

```sh
csrutil enable --without fs --without debug --without nvram
```

Reboot normally, then run:

```sh
sudo nvram boot-args=-arm64e_preview_abi
```

Reboot again.

### 2. Set the relevant macOS Space settings

In `System Settings > Desktop & Dock > Mission Control`:

- `Displays have separate Spaces` = `On`
- `Automatically rearrange Spaces based on most recent use` = `Off`

## Usage

Inject the payload into Dock:

```sh
sudo dockmove inject
```

Inspect windows and spaces:

```sh
dockmove list-spaces
dockmove list-windows
dockmove window-space --window-id 12345
```

Move a window:

```sh
dockmove move-window --window-id 12345 --space-id 17
dockmove move-window --window-id 12345 --space-index 3
```

If Dock restarts, inject again.

## Development

Build locally:

```sh
./build.sh
```

Create a release archive:

```sh
./scripts/package.sh v0.1.0
```

## Notes

- Run the tool from a local GUI session, not over SSH.
- `move-window` can auto-inject if the payload is missing, but that still
  requires the same privileges as `dockmove inject`.
- The CI workflow builds on `macos-15`.
