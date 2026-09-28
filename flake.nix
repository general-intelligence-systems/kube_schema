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
        # No mine.overlays.default: it overrides pkg-config, which stdenv
        # splices, so the overlay rebuilds stdenv and all of nixpkgs from
        # source. mine.inputs.nixpkgs.follows makes it redundant anyway.
        pkgs = nixpkgs.legacyPackages.${system};
        ruby = pkgs.ruby_3_4;
      in
      {
        # pkg-config, bundix, libyaml, openssl, overmind, tmux and `bundix -l`
        # come from mkRubyShell.
        devShells.default = mine.lib.${system}.mkRubyShell {
          buildInputs = [
            pkgs.trufflehog
            ruby
          ];

          shellHook = ''
            export GEM_HOME="$HOME/.gem-${ruby.version}"
            export GEM_PATH="$GEM_HOME"
            export PATH="$GEM_HOME/bin:$PATH"
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_PATH="$GEM_HOME"
            export BUNDLE_BIN="$GEM_HOME/bin"
          '';
        };
      }
    );
}
