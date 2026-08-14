{
  description = "WSLg mutter RDP/VAIL backend dev environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = inputs: let
    forAllSystems = f:
      builtins.mapAttrs (system: pkgs: f system pkgs) inputs.nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShell {
        # Pull in the full build/runtime dependency closure of nixpkgs' own
        # mutter derivation, so our from-source build sees the same libraries.
        inputsFrom = [ pkgs.mutter ];

        hardeningDisable = ["fortify"];

        # Extra deps for the in-process RDP/VAIL backend (task 01) plus general
        # build tooling that is handy in a dev shell.
        packages = with pkgs; [
          # build tooling
          meson
          ninja
          pkg-config
          cmake
          gcc
          gdb
          git

          # Build deps for the Microsoft FreeRDP fork (FreeRDP 2.4.0), which we
          # build from vendor/FreeRDP into _install via build-freerdp.sh and then
          # always link mutter against (it ships the gfxredir server channel =
          # VAIL fast path). We deliberately do NOT pull nixpkgs' own freerdp:
          # everything links against our _install copy so it stays portable.
          openssl
          zlib
          libusb1
          cups
          icu

          # convenience for introspecting deps
          pkg-config
        ];

        shellHook = ''
          echo "mutter dev shell (nixpkgs mutter ${pkgs.mutter.version})"
          echo "freerdp:     ./build-freerdp.sh   (MS fork -> _install)"
          echo "configure:   ./build.sh"
        '';
      };
    });

    packages = forAllSystems (system: pkgs: {
      inherit (pkgs) mutter;
      default = pkgs.mutter;
    });
  };
}
