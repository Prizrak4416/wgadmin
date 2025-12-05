import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "unsafe-secret-key-change-me")
DEBUG = os.environ.get("DJANGO_DEBUG", "true").lower() == "true"

ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "wgadmin",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "wgadmin_project.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "wgadmin" / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "wgadmin_project.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = os.environ.get("TZ", "UTC")
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "wgadmin" / "static"]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

LOGIN_URL = "/login/"
LOGIN_REDIRECT_URL = "/"

# WireGuard paths and scripts
WG_CONFIG_PATH = os.environ.get("WG_CONFIG_PATH", "/etc/wireguard/wg1.conf")
WG_INTERFACE = os.environ.get("WG_INTERFACE", "wg1")
WG_SCRIPTS_DIR = Path(os.environ.get("WG_SCRIPTS_DIR", BASE_DIR / "scripts"))
WG_CLIENT_CONFIG_DIR = Path(os.environ.get("WG_CLIENT_CONFIG_DIR", "/etc/wireguard/client"))
WG_PUBLIC_CONF_DIR = Path(os.environ.get("WG_PUBLIC_CONF_DIR", "/var/www/wireguard/conf"))
WG_QR_DIR = Path(os.environ.get("WG_QR_DIR", "/var/www/wireguard/qr"))

# Tailwind build input/output for convenience
TAILWIND_INPUT_CSS = BASE_DIR / "wgadmin" / "static" / "wgadmin" / "css" / "input.css"
TAILWIND_OUTPUT_CSS = BASE_DIR / "wgadmin" / "static" / "wgadmin" / "css" / "tailwind.css"
