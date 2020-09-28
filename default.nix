{ sources ? import ./nix/sources.nix
, nixpkgs ? sources.nixpkgs
, pkgs ? import nixpkgs {}
}:

with pkgs;

stdenv.mkDerivation rec {
  pname = "tf";
  version = "1.6.4";

  unpackPhase = ":";
  buildInputs = [ makeWrapper ];
  installPhase = ''
    install -m755 -D ${./tf} $out/bin/tf
    wrapProgram $out/bin/tf --prefix PATH : "${lib.makeBinPath [ findutils gnused coreutils jq curl vault ]}"
  '';

  meta = with stdenv.lib; {
    description = "Wrapper around terraform";
    homepage = "https://github.com/Caascad/tf";
    license = licenses.mit;
    maintainers = with maintainers; [ "Benjile" ];
  };

}
