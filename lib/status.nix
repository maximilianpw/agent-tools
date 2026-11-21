{
  lib,
  pkgs,
}: {
  # Shell expression for the directory `dirs` are relative to.
  base,
  dirs,
}:
pkgs.writeShellApplication {
  name = "agent-tools";
  runtimeInputs = [pkgs.coreutils pkgs.git];
  text = ''
    base=${base}
    dirs=(${lib.escapeShellArgs dirs})
    ${builtins.readFile ../modules/status.sh}
  '';
}
