# Debian installer

Zeravi includes a local `.deb` builder for its Linux release bundle. The current
installer targets the Ubuntu 26.04 amd64 build host. It is not a cross-distribution
binary: builds made on newer Ubuntu releases may need newer system libraries.

## Build

From the project root:

```sh
python3 tool/build_deb.py
```

This runs the Flutter release build and writes the package and SHA256 checksum
to `build/packages/`. Version `0.2.0+1` becomes Debian version `0.2.0-1`.

To package a release bundle that has already been built and checked:

```sh
python3 tool/build_deb.py --skip-build
```

Packaging uses Python 3, `dpkg-deb`, `dpkg-query`, `readelf` and `ldd`. The builder
uses the local Git maintainer identity by default; use `--maintainer "Name <email>"`
to supply one explicitly. `--output` chooses a different artifact directory.

The builder discovers direct ELF runtime dependencies and records conservative
minimum versions based on the packages installed on the build host. Rebuild on
an older target distribution rather than weakening those requirements by hand.

## Install or update

For the amd64 preview package:

```sh
sudo apt install ./build/packages/zeravi_0.2.0-1_amd64.deb
```

Search the applications menu for **Zeravi**, or run `zeravi` from a terminal.
The executable, Flutter engine, native plugins and SQLite library are installed
under `/opt/zeravi`. A launcher is installed at `/usr/bin/zeravi`, with a desktop
entry and scalable application icon in the standard system locations.

## Verify and remove

```sh
dpkg-query -W zeravi
dpkg --verify zeravi
sudo apt remove zeravi
```

Removing the application does not erase saved connections, preferences or SSH
configuration in your home directory. These are user data, not package contents.

## Package checks

The package is built with root ownership and normalized permissions. Checksums
cover every payload file, and the desktop entry can be checked with
`desktop-file-validate`. The runtime native-asset manifest is copied consistently
so SQLite loads from the installed bundle rather than a project build path.
After extraction, check `ldd` for both the executable and bundled shared libraries.
