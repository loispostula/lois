{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    flake-utils.url = "github:numtide/flake-utils";
    gitignore.url = "github:hercules-ci/gitignore.nix";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      gitignore,
      devenv,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = (import nixpkgs) {
          inherit system;
          config.allowUnfree = true;
        };
        inherit (gitignore.lib) gitignoreSource;

        version = "0.1.0";
        src = gitignoreSource ./.;

        buildDependencies = with pkgs; [
          hunspellDicts.en_US
          hugo
        ];

        themeCongo = pkgs.fetchFromGitHub {
          owner = "jpanther";
          repo = "congo";
          rev = "v2.11.0";
          sha256 = "0q78dp3hf6cbgsgqpp7g471axwdpcf2270hi5i69bqnliwnb4iyz";
        };

        lois = pkgs.stdenv.mkDerivation {
          inherit version src;
          name = "lois.postu.la";
          buildInputs = buildDependencies;

          buildPhase = ''
            mkdir -p themes
            cp -r ${themeCongo} themes/congo
            ${pkgs.hugo}/bin/hugo
          '';

          installPhase = ''
            cp -r public $out
          '';
        };
      in
      {
        packages = {
          pages = lois;
          devenv-up = self.devShells.${system}.default.config.procfileScript;
          devenv-test = self.devShells.${system}.default.config.test;
        };

        devShells = {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              (
                {
                  pkgs,
                  config,
                  lib,
                  ...
                }:
                {
                  packages = buildDependencies;

                  pre-commit.hooks = {
                    actionlint.enable = true;
                    hunspell.enable = true;
                    markdownlint.enable = true;
                  };

                  enterShell = ''
                    [ ! -f .env ] || export $(grep -v '^#' .env | xargs)
                    rm -f $DEVENV_ROOT/themes/congo
                    mkdir -p $DEVENV_ROOT/themes
                    ln -s ${themeCongo} $DEVENV_ROOT/themes/congo
                    echo 👋 Welcome to lois Development Environment. 🚀
                    echo
                    echo If you see this message, it means your are inside the Nix shell ❄️.
                    echo
                    echo ------------------------------------------------------------------
                    echo
                    echo Commands available:
                    ${pkgs.gnused}/bin/sed -e 's| |••|g' -e 's|=| |' <<EOF | ${pkgs.util-linuxMinimal}/bin/column -t | ${pkgs.gnused}/bin/sed -e 's|^|💪 |' -e 's|••| |g'
                    ${lib.generators.toKeyValue { } (lib.mapAttrs (name: value: value.description) config.scripts)}
                    EOF
                    echo
                    echo Repository:
                    echo  - https://github.com/loispostula/lois
                    echo ------------------------------------------------------------------
                    echo
                  '';

                  env = {
                    LANG = "en_US.UTF-8";
                  };
                }
              )
            ];
          };
        };
      }
    );
}
