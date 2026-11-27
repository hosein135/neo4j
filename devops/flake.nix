# Development environment for the Neo4j movie explorer (Django API + Next.js).
# Neo4j Community Edition is pkgs.neo4j. The Bolt driver is python313Packages.neo4j.
{
  description = "Neo4j Community movie graph explorer";

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
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          web = import ./web-shell.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };
        in
        {
          default = web.shell;
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          web = import ./web-shell.nix {
            inherit pkgs;
            lib = pkgs.lib;
          };
        in
        {
          inherit (web) manage web;
          default = web.web;
          python = web.webPython;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.web}/bin/neo4j-movies-web";
        };
      });
    };
}
