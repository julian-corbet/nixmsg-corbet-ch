{
  description = "nixmsg — messaging, both ends of it: the messenger apps (Discord, Telegram, Teams, Threema, Signal, WhatsApp, Element, Zoom, Mumble) declared per host, and the servers they talk to declared into a cluster";

  # NO INPUTS FOR CONSUMERS. This flake is options plus catalogues, taking `pkgs`/`config`/`lib` from
  # whichever evaluation composes it, so a real host — or a real cluster render — never puts a second
  # nixpkgs, or a sibling flake's whole input closure, into its own closure. Everything below is used
  # by `checks` ALONE; nothing this flake exports reaches into any of it.
  inputs = {
    # checks-only, same convention the rest of this family uses: the modules themselves take `pkgs`
    # from whatever evaluation composes them (never from this input directly), so a consumer who does
    # not `follow` this flake's `checks` output pays no second nixpkgs fetch for it.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The renderer the cluster module defines into. A real input rather than a name in a comment:
    # without it there is no module system to evaluate the cluster side against, and `nix flake
    # check` would pass on flake syntax alone.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE APP GRAMMAR AND CONSUMER FACTORY THIS REPOSITORY CONSUMES. The exported cluster module is
    # constructed by the matching factory, and the checks render it through the real grammar rather
    # than asserting that a module which merely mentions `nixk3s.apps` evaluates.
    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      # x86_64-linux only, and narrow ON PURPOSE. The cluster checks each build a real nixidy
      # environment, so a declared platform that cannot be built is a platform `nix flake check`
      # skips while exiting 0 — a check that passed having tested nothing. Narrow the claim rather
      # than weaken the check.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # ── The host plane: the CLIENTS ─────────────────────────────────────────────────────────
      # Platform-neutral policy: the options, catalogue resolution, and computed package lists.
      # Import this directly if you want the lists and intend to wire them yourself.
      nixosModules.nixmsg = ./modules/nixmsg.nix;
      systemManagerModules.nixmsg = ./modules/nixmsg.nix;

      # NixOS backend — installs via environment.systemPackages.
      nixosModules.default = ./modules/nixos.nix;
      nixosModules.install = ./modules/nixos.nix;

      # Arch / system-manager: the policy module IS the backend. Nothing platform-specific is left
      # to do on this plane — the lists are published for the host's own pacman reconciler to
      # consume (`nixarch.packages.pacman = config.nixmsg.archPackages;`), and the Flatpak channel
      # is nixflat's job now rather than a second oneshot here. See modules/nixos.nix's header.
      systemManagerModules.default = ./modules/nixmsg.nix;

      # Home-manager — autostart + workspace-pin intent, compositor-agnostic.
      homeManagerModules.default = ./modules/home.nix;
      homeManagerModules.home = ./modules/home.nix;

      # ── The cluster plane: the SERVERS those clients talk to ────────────────────────────────
      # Only one module in the class, so `.default` is honest rather than invented.
      nixidyModules.nixmsg = import ./modules/cluster.nix {
        mkConsumerModule = nixk3s.lib.mkConsumerModule;
      };
      nixidyModules.default = self.nixidyModules.nixmsg;

      # The catalogues, exposed so a consumer can inspect or validate either without re-reading the
      # file. Two of them because the subject has two planes, not because it has two halves of one
      # list: `catalogue` names apps installed on a desk, `servers` names software run in a cluster.
      lib.catalogue = import ./lib/catalogue.nix { };
      lib.servers = (import ./lib/servers.nix { }).servers;

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # EVAL-TIME checks for the host plane — see checks/default.nix's own header for what is
          # under test and why (`flatpakApps` carrying a remote per APP, and the autostart launch
          # commands resolving to a binary rather than a package name).
          hostPlane = import ./checks { inherit pkgs; };
        in
        hostPlane // {
          # The cluster module's own resolution and every guard it makes, in BOTH directions: an
          # empty surface renders nothing, a declared one resolves, and each refusal gets a
          # declaration that must be refused.
          cluster-eval = import ./checks/cluster-eval.nix {
            inherit pkgs nixidy;
            lib = nixpkgs.lib;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixmsg;
            values = ./examples/all/values.nix;
          };

          # The manifests that actually come out, read back off the rendered bytes rather than off
          # the options that produced them.
          cluster-render = import ./checks/cluster-render.nix {
            inherit pkgs nixidy;
            lib = nixpkgs.lib;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixmsg;
            values = ./examples/all/values.nix;
          };

          # The OTHER surface, and the one that decides whether this vocabulary can be adopted at
          # all: the same two servers declared against objects that already exist, where every name
          # the live pod holds and every number that cluster chose has to survive the translation.
          cluster-adopted = import ./checks/cluster-adopted.nix {
            inherit pkgs nixidy;
            lib = nixpkgs.lib;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixmsg;
            values = ./examples/adopted/values.nix;
          };
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
