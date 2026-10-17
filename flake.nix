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
        pkgs = nixpkgs.legacyPackages.${system};
        lib = mine.lib.${system};

        # bundlerEnv evaluates the gemspec, because the Gemfile says `gemspec` and the
        # lockfile carries kube_schema as a path gem, so the gemspec and the version file
        # it require_relatives both have to reach the build directory. Nothing else is
        # copied, so no second copy of the library lands on the load path.
        gemspecFiles = pkgs.runCommand "kube_schema-gemspec" { } ''
          mkdir -p $out/lib/kube/schema
          cp ${./kube_schema.gemspec}        $out/kube_schema.gemspec
          cp ${./lib/kube/schema/version.rb} $out/lib/kube/schema/version.rb
        '';

        gems = pkgs.bundlerEnv {
          name = "kube_schema-gems";
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
          extraConfigPaths = [ "${gemspecFiles}/." ];
        };
      in
      {
        devShells.default = lib.mkRubyShell {
          buildInputs = [
            gems
            gems.wrappedRuby
            pkgs.trufflehog
          ];

          shellHook = /* bash */ ''
            unset RUBYOPT
            export BUNDLE_GEMFILE="$PWD/Gemfile"

            # The gemspec's `git ls-files` finds nothing in the sandbox, so the path gem
            # ships no files. Put the working tree's lib/ on the load path instead, which
            # is what you want in a devshell anyway.
            export RUBYLIB="$PWD/lib''${RUBYLIB:+:$RUBYLIB}"
          '';
        };
      }
    );
}
