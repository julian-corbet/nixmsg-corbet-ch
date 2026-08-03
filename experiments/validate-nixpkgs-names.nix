# Checks every `nixpkgs` attribute in lib/catalogue.nix actually exists. A wrong attribute name is
# invisible until a NixOS host tries to build, and then it is an eval error in someone else's
# config — so it gets checked here instead. Same shape as nixdev's own check of the same name.
#
#   nix-instantiate --eval --strict experiments/validate-nixpkgs-names.nix -A missing   # => [ ]
{ nixpkgs ? <nixpkgs> }:
let
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  catalogue = import ../lib/catalogue.nix { };
  entries = lib.attrValues catalogue;
  named = lib.filter (e: e.nixpkgs != null) entries;
in
{
  checked = builtins.length named;
  missing = map (e: e.nixpkgs) (lib.filter (e: !(lib.hasAttrByPath (lib.splitString "." e.nixpkgs) pkgs)) named);
}
