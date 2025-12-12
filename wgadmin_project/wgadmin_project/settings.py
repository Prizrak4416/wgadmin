"""
Django settings for wgadmin_project.

Security-hardened configuration with automatic .env file loading.
"""
import environ
from pathlib import Path

# =============================================================================
# ENVIRONMENT SETUP
# =============================================================================

BASE_DIR = Path(__file__).resolve().parent.parent

# Initialize environ
env = environ.Env(
    # Default values
    DJANGO_DEBUG=(bool, True),
    DJANGO_SECRET_KEY=(str, "unsafe-secret-key-change-me"),
    DJANGO_ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    TZ=(str, "UTC"),
    # Security
    SECURE_SSL_REDIRECT=(bool, False),
    SESSION_COOKIE_SECURE=(bool, False),
    CSRF_COOKIE_SECURE=(bool, False),
    SECURE_HSTS_SECONDS=(int, 0),
    SECURE_HSTS_INCLUDE_SUBDOMAINS=(bool, False),
    SECURE_HSTS_PRELOAD=(bool, False),
    TRUST_PROXY_HEADERS=(bool, False),
    CSRF_TRUSTED_ORIGINS=(list, []),
    # WireGuard
    WG_CONFIG_PATH=(str, "/etc/wireguard/wg1.conf"),
    WG_INTERFACE=(str, "wg1"),
    WG_SCRIPTS_DIR=(str, ""),
    WG_CLIENT_CONFIG_DIR=(str, "/etc/wireguard/client"),
    WG_PUBLIC_CONF_DIR=(str, "/var/www/wireguard/conf"),
    WG_QR_DIR=(str, "/var/www/wireguard/qr"),
    WG_USE_SUDO=(bool, True),
    WG_SUDO_BIN=(str, "sudo"),
    WG_SCRIPT_TIMEOUT=(int, 15),
)

# Read .env file from project root (parent of wgadmin_project)
# Looks for .env in: /path/to/wireguard_server_admin/.env
ENV_FILE = BASE_DIR.parent / ".env"
if ENV_FILE.exists():
    environ.Env.read_env(ENV_FILE)

# Also check for .env in wgadmin_project directory
ENV_FILE_ALT = BASE_DIR / ".env"
if ENV_FILE_ALT.exists():
    environ.Env.read_env(ENV_FILE_ALT)

# =============================================================================
# CORE SETTINGS
# =============================================================================

SECRET_KEY = env("DJANGO_SECRET_KEY")
DEBUG = env("DJANGO_DEBUG")
ALLOWED_HOSTS = env("DJANGO_ALLOWED_HOSTS")

# =============================================================================
# APPLICATION DEFINITION
# =============================================================================

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

# =============================================================================
# DATABASE
# =============================================================================

DATABASES = {
    "default": env.db_url(
        "DATABASE_URL",
        default=f"sqlite:///{BASE_DIR / 'db.sqlite3'}"
    )
}

# =============================================================================
# PASSWORD VALIDATION
# =============================================================================

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

# =============================================================================
# INTERNATIONALIZATION
# =============================================================================

LANGUAGE_CODE = "en-us"
TIME_ZONE = env("TZ")
USE_I18N = True
USE_TZ = True

# =============================================================================
# STATIC FILES
# =============================================================================

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "wgadmin" / "static"]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# =============================================================================
# AUTHENTICATION
# =============================================================================

LOGIN_URL = "/login/"
LOGIN_REDIRECT_URL = "/"
LOGOUT_REDIRECT_URL = "/login/"

# =============================================================================
# SECURITY SETTINGS
# =============================================================================

# HTTPS/SSL settings
_HTTPS_ENABLED = env("SECURE_SSL_REDIRECT")

if _HTTPS_ENABLED or not DEBUG:
    SECURE_SSL_REDIRECT = env("SECURE_SSL_REDIRECT") if _HTTPS_ENABLED else True
    SESSION_COOKIE_SECURE = env("SESSION_COOKIE_SECURE") if _HTTPS_ENABLED else True
    CSRF_COOKIE_SECURE = env("CSRF_COOKIE_SECURE") if _HTTPS_ENABLED else True
    SECURE_HSTS_SECONDS = env("SECURE_HSTS_SECONDS") if env("SECURE_HSTS_SECONDS") else 31536000
    SECURE_HSTS_INCLUDE_SUBDOMAINS = env("SECURE_HSTS_INCLUDE_SUBDOMAINS") if _HTTPS_ENABLED else True
    SECURE_HSTS_PRELOAD = env("SECURE_HSTS_PRELOAD")
else:
    SECURE_SSL_REDIRECT = False
    SESSION_COOKIE_SECURE = False
    CSRF_COOKIE_SECURE = False
    SECURE_HSTS_SECONDS = 0
    SECURE_HSTS_INCLUDE_SUBDOMAINS = False
    SECURE_HSTS_PRELOAD = False

# Additional browser security headers
X_FRAME_OPTIONS = "DENY"
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "strict-origin-when-cross-origin"
SECURE_CROSS_ORIGIN_OPENER_POLICY = "same-origin"

# Trust X-Forwarded headers from proxy
if env("TRUST_PROXY_HEADERS"):
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    USE_X_FORWARDED_HOST = True
    USE_X_FORWARDED_PORT = True

# CSRF settings
CSRF_TRUSTED_ORIGINS = env("CSRF_TRUSTED_ORIGINS")

# Session settings
SESSION_COOKIE_AGE = 86400  # 24 hours
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"

# CSRF cookie settings
CSRF_COOKIE_HTTPONLY = True
CSRF_COOKIE_SAMESITE = "Lax"

# =============================================================================
# LOGGING
# =============================================================================

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "verbose": {
            "format": "{levelname} {asctime} {module} {process:d} {thread:d} {message}",
            "style": "{",
        },
        "simple": {
            "format": "{levelname} {message}",
            "style": "{",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "simple",
        },
    },
    "root": {
        "handlers": ["console"],
        "level": "INFO" if not DEBUG else "DEBUG",
    },
    "loggers": {
        "django": {
            "handlers": ["console"],
            "level": "INFO",
            "propagate": False,
        },
        "django.security": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False,
        },
        "wgadmin": {
            "handlers": ["console"],
            "level": "DEBUG" if DEBUG else "INFO",
            "propagate": False,
        },
    },
}

# =============================================================================
# WIREGUARD SETTINGS
# =============================================================================

WG_CONFIG_PATH = env("WG_CONFIG_PATH")
WG_INTERFACE = env("WG_INTERFACE")
WG_SCRIPTS_DIR = Path(env("WG_SCRIPTS_DIR") or (BASE_DIR / "scripts"))
WG_CLIENT_CONFIG_DIR = Path(env("WG_CLIENT_CONFIG_DIR"))
WG_PUBLIC_CONF_DIR = Path(env("WG_PUBLIC_CONF_DIR"))
WG_QR_DIR = Path(env("WG_QR_DIR"))
WG_USE_SUDO = env("WG_USE_SUDO")
WG_SUDO_BIN = env("WG_SUDO_BIN")
WG_SCRIPT_TIMEOUT = env("WG_SCRIPT_TIMEOUT")

# =============================================================================
# TAILWIND CSS (convenience settings - not used in CDN mode)
# =============================================================================

TAILWIND_INPUT_CSS = BASE_DIR / "wgadmin" / "static" / "wgadmin" / "css" / "input.css"
TAILWIND_OUTPUT_CSS = BASE_DIR / "wgadmin" / "static" / "wgadmin" / "css" / "tailwind.css"
