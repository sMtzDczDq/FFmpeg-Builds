# What `fast.sh` does

A quick, friendlier walk-through. Everything below comes from the script
itself — it's just the steps re-told in plain language.

## The goal in one sentence

Build the latest released FFmpeg with the "nonfree" extras (AudioMux/FDK-AAC
etc.) for
Linux-64 and Windows-64, both static and shared — but do it in minutes
instead of hours by reusing pre-built Docker images that already have all
the hard work done.

## Why it's fast (the core idea)

The normal way to build FFmpeg from scratch is to first compile the
toolchain (30–60 min), then compile ~120 third-party libraries (about 2 h),
and only then compile FFmpeg itself.

This script takes a shortcut: it starts from a published Docker image where
the toolchain and all ~120 libraries are **already installed**. The only real
difference between a "gpl" build and a "nonfree" build is one extra library
(fdk-aac) plus two extra `./configure` flags. So the script only:

1. grabs an existing image,
2. adds the one missing library (fdk-aac) on top of it,
3. compiles FFmpeg inside that image,
4. packages the result.

No toolchain rebuild, no 120-library rebuild.

## What it builds

Four combinations, driven by a list inside the script:

| Target      | Variant          |
|-------------|------------------|
| linux64     | nonfree-shared   |
| linux64     | nonfree (static) |
| win64       | nonfree-shared   |
| win64       | nonfree (static) |

By default it builds the **newest released FFmpeg**: it reads the release
listing on ffmpeg.org, picks the highest version, and reduces it to its
release branch (e.g. `9.0.2` → `9.0`), which it uses both for the base image
name and for cloning the `release/9.0` git branch. Pin an older branch with
`FAST_FFVER=9.0 ./fast.sh` if you ever need to.

## Outputs

- **Binaries**: `.cache/ffbuild-output/<target>-nonfree/prefix/bin/`
  (`ffmpeg`, plus `ffplay`/`ffprobe`, or `.exe` on Windows).
- **Download packages**: `artifacts/` in the repo root, named
  `ffmpeg-<version>-<target>-<variant>.tar.xz` (Linux) or `.zip` (Windows).
  The directory *inside* the archive is shortened to the plain version
  (e.g. `ffmpeg-n9.0.2/`), and the Linux packages also contain an `install.sh`
  that installs the build into `/usr/local`.
- **Images**: tagged `ghcr.io/btbn/ffmpeg-builds/<target>-<variant>:<version>`.

## Installing the Linux packages

The Linux archives contain an `install.sh` that drops the build into
`/usr/local`:

```sh
tar xf artifacts/ffmpeg-n9.0.2-3-gabc1234-linux64-nonfree-shared.tar.xz
cd ffmpeg-n9.0.2
sudo ./install.sh
```

It puts the executables in `/usr/local/bin`, the libraries in
`/usr/local/lib`, the headers in `/usr/local/include`, the pkg-config files
in `/usr/local/lib/pkgconfig` and the documentation, man pages and presets
in `/usr/local/share`. Set `PREFIX` to install somewhere else:

```sh
PREFIX=/opt/ffmpeg sudo -E ./install.sh
```

The pkg-config files are rewritten while the package is built, so their
`prefix` points at the package's own directory rather than at the
`/ffbuild/prefix` path used inside the build container. They therefore work
no matter where the package is unpacked — `/usr/local`, `/opt/ffmpeg`, or a
build directory you are pointing `PKG_CONFIG_PATH` at. The private
dependency list, which names libraries that are not part of the package,
is stripped out.

The same script handles the static and the shared package. For the shared
one it also refreshes the linker cache (`ldconfig`) when the prefix is a
system one such as `/usr/local`, so the new libraries are picked up
immediately.

## Steps, top to bottom

1. **Pick the FFmpeg version** — reads the newest release on ffmpeg.org
   (or uses `FAST_FFVER` if set) and reduces it to its release branch.
2. **Check disk space** — wants ~20 GB free (just warns if not enough).
3. **Prepare Docker's build tool** ("buildx builder"). Reuses it if already
   there; otherwise creates one. By default it caps the parallel workloads at
   4 unless you override with an env var. Warning for macOS users: pass
   `FAST_NO_HOST_NET=1` if your Docker setup rejects the default host
   networking mode.
4. **Download the two base images** — `linux64-gpl-shared-<version>` and
   `win64-gpl-shared-<version>` from `ghcr.io/btbn/ffmpeg-builds`. These
   contain all ~120 libraries. If BtbN hasn't published that version yet,
   it stops early and tells you to pin an older one with `FAST_FFVER`.
   Hint: if the download fails, it suggests `docker login ghcr.io` first.
   (Name quirk: the FFmpeg version is part of the image *name*, not the tag —
   every image shares the `:latest` tag.)
5. **Clone fdk-aac once** into `.cache/` — the only missing library.
   It's pinned to the same commit the repo's own build script uses.
6. **For each of the 4 combinations**, repeat three things:
   - **Build a thin "overlay" image** on top of the downloaded base image.
     Its only job: compile fdk-aac into the library directory, and bake the
     FFmpeg `./configure` flags into the image as environment variables
     (`FF_CONFIGURE`, plus cflags/libs). The overlay Dockerfile is saved to
     `.cache/Dockerfile.nonfree.<target>-<variant>` so you can inspect it.
   - **Run the build** inside the overlay image. A generated script clones
     FFmpeg's `release/<version>` branch and runs the classic
     `./configure … && make && make install`, installing into a `prefix`
     folder that's shared with the host through a mounted folder
     (`.cache/ffbuild-output/<target>-<variant>`).
   - **Package it** — copy that `prefix` into a staging folder, then create
     a `tar.xz` (Linux) or `zip` (Windows) under `artifacts/`, using a
     name like `ffmpeg-n9.0.2-3-gabc1234-linux64-nonfree.tar.xz`. The
     directory inside the archive is named after the version alone
     (`ffmpeg-n9.0.2/`). On Linux the package also gets an `install.sh`.
6. **Clean up** — unless told otherwise (see env vars), it keeps `.cache/`
   and the builder around so the next run is even faster.
7. At the end it prints a summary of the built images, binaries and archives.

## Usage

```sh
./fast.sh                        # build the newest release, all four combinations
./fast.sh linux64                # only the two linux64 builds
./fast.sh win64 nonfree-shared   # just one target + variant
FAST_FFVER=9.0 ./fast.sh         # pin an older (already-published) branch
```

## Settings (env vars)

| Variable                   | Effect                                                             |
|----------------------------|--------------------------------------------------------------------|
| `FAST_FFVER=x.y`           | Pin the FFmpeg release branch (default: auto-detect newest from ffmpeg.org). |
| `FAST_NO_HOST_NET=1`      | Skip the `network=host` Docker option — needed on macOS Docker Desktop / Lima / Colima style setups. |
| `FAST_PARALLELISM=N`      | Override the amount of parallel work (default: capped at 4).       |
| `FAST_KEEP_CACHES=0`      | Delete `.cache/` and the builder when done (default is to keep them). |