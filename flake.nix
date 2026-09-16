{
  description = "Multi-account switcher for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Resolve dependencies from uv.lock, so Nix builds exactly what `uv sync` would.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python314;
        in
        (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
          ]
        )
      );
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system};
          venv = pythonSet.mkVirtualEnv "claude-swap-env" workspace.deps.default;
        in
        {
          # Expose only the console scripts, not the whole virtualenv's bin/.
          claude-swap =
            pkgs.runCommand "claude-swap-${pythonSet.claude-swap.version}"
              {
                meta = {
                  description = "Multi-account switcher for Claude Code";
                  homepage = "https://github.com/realiti4/claude-swap";
                  license = lib.licenses.mit;
                  mainProgram = "cswap";
                };
              }
              ''
                mkdir -p $out/bin
                ln -s ${venv}/bin/cswap ${venv}/bin/claude-swap $out/bin/
              '';
          default = self.packages.${system}.claude-swap;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.claude-swap;
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system};
          testEnv = pythonSet.mkVirtualEnv "claude-swap-test-env" {
            claude-swap = [ "dev" ];
          };
        in
        {
          inherit (self.packages.${system}) claude-swap;

          pytest =
            pkgs.runCommand "claude-swap-pytest"
              {
                nativeBuildInputs = [
                  testEnv
                  pkgs.ps # process_detection shells out to ps
                ];
              }
              ''
                cp -r ${./.} src && chmod -R u+w src && cd src
                export HOME=$TMPDIR
                pytest
                touch $out
              '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pythonSets.${system}.python
              pkgs.uv
            ];
            env = {
              UV_PYTHON_DOWNLOADS = "never";
              UV_PYTHON = pythonSets.${system}.python.interpreter;
            };
            shellHook = ''
              unset PYTHONPATH
            '';
          };
        }
      );
    };
}
