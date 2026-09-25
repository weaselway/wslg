{
  description = "WSLg (WSLGd + rdpapplist) dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: f nixpkgs.legacyPackages.${system}
        );
    in
    {
      devShells = forAllSystems (pkgs: {
        # The Dockerfile builds WSLGd with clang.
        default = (pkgs.mkShell.override { stdenv = pkgs.clangStdenv; }) {
          packages = with pkgs; [
            meson
            ninja
            pkg-config
            gdb
            git

            # WSLGd links -lcap
            libcap

            # rdpapplist wants freerdp3/winpr3
            freerdp
          ];

          # Keeps the default (debug, -O0) meson builds free of _FORTIFY_SOURCE warnings.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            echo "build with: ./weaselway-build.sh   (see WEASELWAY.md)"
          '';
        };
      });
    };
}
