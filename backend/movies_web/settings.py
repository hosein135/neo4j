import os
import sys
from pathlib import Path

# Movie data lives in Neo4j. Django is only the JSON API, so there is no Postgres.
if not str(Path(sys.executable).resolve()).startswith("/nix/store/"):
    raise RuntimeError(
        "Django must run under Nix Python. Use: ./run.sh or nix develop devops && neo4j-movies-web"
    )

BASE_DIR = Path(__file__).resolve().parent.parent


def _project_root() -> Path:
    return Path(os.environ.get("NEO4J_MOVIES_ROOT", BASE_DIR.parent))


PROJECT_ROOT = _project_root()

SECRET_KEY = os.environ.get(
    "DJANGO_SECRET_KEY",
    "neo4j-movies-dev-only-change-in-production",
)
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"
_allowed = os.environ.get("DJANGO_ALLOWED_HOSTS", "*")
ALLOWED_HOSTS = (
    ["*"] if _allowed.strip() == "*" else [h.strip() for h in _allowed.split(",") if h.strip()]
)

NEXT_ORIGIN = os.environ.get("NEXT_ORIGIN", "http://127.0.0.1:3000").rstrip("/")

INSTALLED_APPS = [
    "graph",
]

MIDDLEWARE = [
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "movies_web.urls"
WSGI_APPLICATION = "movies_web.wsgi.application"

# Django wants a database setting even though this app never stores rows.
# :memory: is not a service and is not Postgres.
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    }
}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True
APPEND_SLASH = False
