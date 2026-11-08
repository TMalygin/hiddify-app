# Recovering an AppImage update

The updater stages the candidate in a new `<current-path>.update-<random>`
directory next to the installed AppImage. It checks `chmod`, saves the current
image as `previous.AppImage`, and then atomically replaces the installed path.
If the operating system rejects the launch, it restores the previous image and
reports the error without closing the running application.

A detached process starting successfully does not confirm that the application
finished initializing. The recovery copy is therefore retained even after a
successful launch; its path is written to the application log. This also leaves
a recovery option when the replacement starts but crashes or exits immediately.

To recover in that case, close Hiddify and move the saved image over the installed
path. Substitute the actual paths, keeping the quotes:

```sh
mv -- "/path/Hiddify.AppImage.update-<random>/previous.AppImage" "/path/Hiddify.AppImage"
```

Then launch the restored AppImage normally. If automatic restoration itself
fails, the error includes the recovery path and both failures; the saved image
is retained. Remove old recovery directories only after verifying the newer
version works. The updater does not overwrite existing `.new` or `.backup` files.
