# Building WSLg pieces for weaselway (Nix)

A compile check for the Linux-side components of this fork, using the dev
shell in [flake.nix](flake.nix) (nixpkgs `nixos-26.05`, clang toolchain as in
the [Dockerfile](Dockerfile)). Nothing is installed. The full system distro
image is still built by [build-and-export.sh](build-and-export.sh) (Docker).

```sh
./weaselway-build.sh
```

This enters `nix develop` on its own. For each project it configures the
build dir on the first run and then compiles:

| Project | Build dir | Output |
|---|---|---|
| [WSLGd](WSLGd) | `build/WSLGd` | `build/WSLGd/WSLGd` |
| [rdpapplist](rdpapplist) | `build/rdpapplist` | `build/rdpapplist/server/librdpapplist-server.so` |

- The default build type is meson's `debug`. Use
  `BUILDTYPE=release ./weaselway-build.sh` after `rm -rf build/WSLGd build/rdpapplist`
  (the build type only applies when configuring).

## Notes

- WSLGd needs nothing beyond the C++ standard library. rdpapplist needs
  freerdp3/winpr3, which the shell takes from nixpkgs (3.x).
- The shell disables `_FORTIFY_SOURCE` hardening. With it on, every file of
  the default `-O0` debug build warns that fortify needs optimization.
- Not covered: [WSLDVCPlugin](WSLDVCPlugin), which is a Windows MSVC project.
