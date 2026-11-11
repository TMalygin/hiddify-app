# Private Weston runtime for the x86-64 AppImage

The Linux build packages Weston 16.0.2-1, the Wayland backend, the kiosk shell and the libraries and data they need. The UI runs in the application's own display session. The AppImage carries its own glibc loader, software renderer and keyboard maps. Building the archive needs Python 3.10 or newer and no package installation.

```sh
python3 scripts/linux/prepare_weston_runtime.py \
  --cache build/weston-package-cache \
  --output build/hiddify-weston-runtime.tar.gz
```

Add `--offline` to rebuild using only previously downloaded packages. The builder checks every input's exact size and SHA-256 and selects individual files from the package data. Aliases are materialized as regular files. The builder verifies the size and SHA-256 of the complete uncompressed USTAR stream before replacing the output. The core independently checks that same stream before starting Weston.

## Provenance and notices

`weston-runtime.lock.json` records the exact Debian snapshot, package paths and SHA-256 values, selected files and canonical archive digest. The signed `InRelease` lists the SHA-256 values for `main/binary-amd64/Packages.xz`, `main/Contents-amd64.gz` and `main/source/Sources.xz`. The snapshot used for this lock had valid signatures from the Debian 12 and 13 archive signing keys. Their full primary fingerprints are in the lock. See [Debian archive signing keys](https://ftp-master.debian.org/keys.html) and the [pinned snapshot](https://snapshot.debian.org/archive/debian/20261108T120000Z/dists/sid/InRelease).

Every binary package's Debian copyright notice is present in the archive under `usr/share/doc/hiddify-weston/<binary-package>/copyright`. It also includes the license texts in `usr/share/common-licenses/`. For example, the `libatomic1` notice comes from that package's `gcc-16-base` documentation target, including the GCC Runtime Library Exception.

To obtain the corresponding source, look up the binary package's `source` in `packages`, then the matching `source_packages` entry. Append its `source_control` path to `base_url` and verify the recorded SHA-256. That Debian `.dsc` lists the source archives and their checksums in the same directory. The lock covers all 47 source packages used for this runtime.

When updating the snapshot, verify its archive signatures, index checksums, source descriptions and notices. Regenerate the selected file list and canonical digest, review the matching core pin, then run the real AppImage display and offline build tests on the resulting payload.
