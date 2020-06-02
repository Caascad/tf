{ sources ? import ./nix/sources.nix
, nixpkgs ? sources.nixpkgs
, pkgs ? import nixpkgs {}
}:

with pkgs;

stdenv.mkDerivation rec {
  pname = "tf";
  version = "1.5.0";

  unpackPhase = ":";
  installPhase = ''
    install -m755 -D ${./tf} $out/bin/tf
  '';

  meta = with stdenv.lib; {
    description = "Wrapper around terraform";
    homepage = "https://github.com/Caascad/tf";
    license = licenses.mit;
    maintainers = with maintainers; [ "Benjile" ];
  };

}
