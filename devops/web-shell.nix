# Dev shell and CLI tools. Python comes from Nix (python313Packages.neo4j), never the OS.
{
  pkgs,
  lib,
}:
let
  # python313.pkgs.neo4j is python313Packages.neo4j, the official Bolt driver.
  webPython = pkgs.python313.withPackages (
    ps: with ps; [
      neo4j
      django
    ]
  );

  webPythonBin = "${webPython}/bin/python";
  neo4jDist = "${pkgs.neo4j}/share/neo4j";

  resolveRoot = ''
    resolve_neo4j_movies_root() {
      if [ -n "''${NEO4J_MOVIES_ROOT:-}" ] && [ -f "''${NEO4J_MOVIES_ROOT}/backend/manage.py" ]; then
        printf '%s\n' "''${NEO4J_MOVIES_ROOT}"
        return 0
      fi
      local dir="''${PWD}"
      while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -f "$dir/backend/manage.py" ]; then
          printf '%s\n' "$dir"
          return 0
        fi
        dir="$(dirname "$dir")"
      done
      echo "neo4j-movies: could not find backend/manage.py" >&2
      echo "Set NEO4J_MOVIES_ROOT to the repo root or run from the project tree." >&2
      return 1
    }
  '';

  exportAppEnv = ''
    ${resolveRoot}
    if ! NEO4J_MOVIES_ROOT="$(resolve_neo4j_movies_root)"; then
      exit 1
    fi
    export NEO4J_MOVIES_ROOT
    if [ -z "''${NEO4J_MOVIES_DATA_DIR:-}" ]; then
      case "''${NEO4J_MOVIES_ROOT}" in
        /mnt/*)
          export NEO4J_MOVIES_DATA_DIR="''${HOME}/.local/share/neo4j-movies"
          ;;
        *)
          export NEO4J_MOVIES_DATA_DIR="''${NEO4J_MOVIES_ROOT}/.neo4j-data"
          ;;
      esac
    fi
    mkdir -p "''${NEO4J_MOVIES_DATA_DIR}"
    export DJANGO_SETTINGS_MODULE=movies_web.settings
    export PYTHONNOUSERSITE=1
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONUNBUFFERED=1
    export PYTHONPATH="''${NEO4J_MOVIES_ROOT}/backend''${PYTHONPATH:+:''${PYTHONPATH}}"
    export NEO4J_MOVIES_PYTHON="${webPythonBin}"
    export NEO4J_DIST="${neo4jDist}"
    export NEO4J_URI="''${NEO4J_URI:-bolt://127.0.0.1:7687}"
    export NEO4J_USER="''${NEO4J_USER:-neo4j}"
    export NEO4J_PASSWORD="''${NEO4J_PASSWORD:-neo4jadmin}"
    export NEXT_ORIGIN="''${NEXT_ORIGIN:-http://127.0.0.1:3000}"
    export DJANGO_ORIGIN="''${DJANGO_ORIGIN:-http://127.0.0.1:8000}"
    export NEXT_TELEMETRY_DISABLED=1
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    export NODE_EXTRA_CA_CERTS="''${SSL_CERT_FILE}"
    export PATH="${webPython}/bin:${pkgs.neo4j}/bin:${pkgs.nodejs_22}/bin:$PATH"
  '';

  manage = pkgs.writeShellScriptBin "neo4j-movies-manage" ''
    set -euo pipefail
    ${exportAppEnv}
    exec "${webPythonBin}" "''${NEO4J_MOVIES_ROOT}/backend/manage.py" "$@"
  '';

  web = pkgs.writeShellScriptBin "neo4j-movies-web" ''
    set -euo pipefail
    export NEO4J_MOVIES_WEB_HOST="''${NEO4J_MOVIES_WEB_HOST:-127.0.0.1}"
    export NEO4J_MOVIES_WEB_PORT="''${NEO4J_MOVIES_WEB_PORT:-8000}"
    ${exportAppEnv}
    exec neo4j-movies-manage runserver --noreload \
      "''${NEO4J_MOVIES_WEB_HOST}:''${NEO4J_MOVIES_WEB_PORT}"
  '';

  shell = pkgs.mkShell {
    packages = [
      webPython
      manage
      web
      pkgs.neo4j
      pkgs.nodejs_22
      pkgs.cacert
      pkgs.curl
      pkgs.git
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
      pkgs.which
      pkgs.procps
    ];

    shellHook = ''
      ${exportAppEnv}
      echo "Neo4j movies shell"
      echo "  Python: ${webPythonBin}"
      echo "  Neo4j Community: ${pkgs.neo4j}"
      echo "  Repo root: $NEO4J_MOVIES_ROOT"
      echo "  Data dir: $NEO4J_MOVIES_DATA_DIR"
      echo "  neo4j-movies-manage — Django management (load_movies)"
      echo "  neo4j-movies-web — Django API on :8000"
      echo "  ./run.sh — Neo4j, movie graph, API, and the Next.js page"
    '';
  };
in
{
  inherit
    webPython
    manage
    web
    shell
    ;
}
