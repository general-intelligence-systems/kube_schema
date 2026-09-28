{
  description = "Ruby gem flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca"; # == this machine's system nixpkgs
    utils.url = "github:numtide/flake-utils";
    mine.url = "github:n-at-han-k/flake.nix";
    mine.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, utils, mine }:
    utils.lib.eachDefaultSystem (system:
      let
        # No mine.overlays.default: it used to override pkg-config, which stdenv
        # splices, so the overlay rebuilt stdenv and all of nixpkgs from source.
        # mine.inputs.nixpkgs.follows makes it redundant anyway.
        pkgs = nixpkgs.legacyPackages.${system};
        lib = mine.lib.${system};

        gems = lib.buildGemset {
          name = "kube_schema";
          src = ./.;
        };
      in
      {
        # pkg-config, bundix, libyaml, openssl, overmind, tmux and `bundix -l`
        # come from mkRubyShell.
        devShells.default = lib.mkRubyShell {
          buildInputs = [
            gems
            gems.wrappedRuby
            pkgs.trufflehog
          ];
        };
      }
    );
}
