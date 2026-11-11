# Opening a private window on Linux

The x86_64 AppImage includes Weston for applications launched through the
core's authenticated `RunApplication` API. Weston displays their windows
inside the current Wayland desktop. Each session has its own display socket;
the selected application does not receive the host's display socket.
Weston does not choose a proxy or grant network access. A compatible app
can stay open without network access while the profile is disconnected.

Use an ordinary user session on a Wayland desktop with unprivileged user
namespaces and a compatible system bubblewrap. Weston itself does not have
to be installed. Both normal AppImage execution and
`APPIMAGE_EXTRACT_AND_RUN=1` use the same bundled runtime. If it is missing
or damaged, the window request fails. Console sessions do not need it.

The general launcher accepts an executable and its arguments. A graphical
file picker, X11-only applications, sharing the desktop clipboard and audio
are outside this packaging change. Programs that need a separate renderer
sandbox may require additional support.

To inspect the files shipped in a particular build, run
`./Hiddify.AppImage --appimage-extract 'lib/hiddify-weston-*'` in an empty
directory. The JSON manifest identifies the source packages. The companion
archive includes their copyright notices under `usr/share/doc/hiddify-weston/`.
The core checks the uncompressed archive against its own build-time digest
before displaying a window. It does not download components at launch.
