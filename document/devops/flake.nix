{
  description = "Neo4j movie explorer Typst document (typst + parastoo-fonts, nixos-25.05)";

  # Package versions are pinned in ./.tack (tack). This flake has no inputs of
  # its own, so `nix flake update` cannot move nixpkgs.
  outputs =
    { self, ... }@args:
    let
      inputs = (import ./.tack) {
        overrides = args.tackOverrides or { };
      };
      inherit (inputs) nixpkgs;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgs = system: import nixpkgs { inherit system; };
      fontDir = pkgs: "${pkgs.parastoo-fonts}/share/fonts/parastoo-fonts";

      compileScript =
        pkgs:
        pkgs.writeShellApplication {
          name = "compile-neo4j-movies-doc";
          runtimeInputs = [
            pkgs.typst
            pkgs.coreutils
          ];
          text = ''
            set -euo pipefail
            root="''${NEO4J_DOC_ROOT:-$(pwd)}"
            if [ ! -f "$root/src/main.typ" ] && [ -f "$root/../src/main.typ" ]; then
              root="$(cd "$root/.." && pwd)"
            fi
            src="$root/src/main.typ"
            out_dir="$root/output"
            out_pdf="$out_dir/neo4j-movies.pdf"
            font_dir="${fontDir pkgs}"
            if [ ! -f "$src" ]; then
              echo "missing Typst source: $src" >&2
              exit 1
            fi
            mkdir -p "$out_dir"
            export TYPST_FONT_PATHS="$font_dir"
            echo "==> typst $(typst --version)"
            echo "==> fonts  $TYPST_FONT_PATHS"
            typst compile \
              --root "$root" \
              --font-path "$font_dir" \
              --ignore-system-fonts \
              "$src" \
              "$out_pdf"
            echo "==> wrote $out_pdf"
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = compileScript pkgs;
          compile = compileScript pkgs;
        }
      );

      apps = forAllSystems (
        system:
        let
          compile = self.packages.${system}.compile;
        in
        {
          default = {
            type = "app";
            program = "${compile}/bin/compile-neo4j-movies-doc";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.typst
              pkgs.parastoo-fonts
            ];
            TYPST_FONT_PATHS = fontDir pkgs;
            shellHook = ''
              export NEO4J_DOC_ROOT="''${NEO4J_DOC_ROOT:-$PWD}"
              export TYPST_FONT_PATHS="${fontDir pkgs}"
              echo "typst $(typst --version 2>/dev/null || true)"
              echo "Parastoo fonts: $TYPST_FONT_PATHS"
            '';
          };
        }
      );
    };
}
