# Security Review - WireGuard Admin Django Project

This document contains the results of a security audit of the WireGuard Admin Django project.

**Review Date:** December 2024  
**Reviewer:** Security Audit  
**Scope:** Django settings, views, services, forms, URL configuration, and shell script interaction

---

## Executive Summary

The codebase has a solid foundation with good practices in many areas. However, several security issues were identified that should be addressed before production deployment:

| Severity | Count | Status |
|----------|-------|--------|
| High | 2 | Requires immediate attention |
| Medium | 4 | Should be fixed before production |
| Low | 3 | Recommended improvements |

---

## High Severity Issues

### 1. Debug Print Statement in Production Code

**Title:** Debug print statement leaks command execution details  
**Severity:** High  
**Location:** [`wgadmin/services/wireguard.py:231`](wgadmin/services/wireguard.py:231)

**Problem:**
```python
def _run_script(self, script_name: str, args: Iterable[str] | Dict[str, str]) -> Dict:
    # ...
    cmd = [str(script_path), *args]
    if self.use_sudo:
        cmd = [self.sudo_bin, *cmd]
    try:
        print(cmd)  # <-- DEBUG STATEMENT - LEAKS COMMANDS TO STDOUT
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=self.script_timeout)
```

**Impact:**
- Exposes executed commands to logs/stdout
- Could leak sensitive information like client identifiers
- Not suitable for production

**Fix:**
```python
# Remove or replace with proper logging
import logging
logger = logging.getLogger(__name__)

def _run_script(self, script_name: str, args: Iterable[str] | Dict[str, str]) -> Dict:
    # ...
    cmd = [str(script_path), *args]
    if self.use_sudo:
        cmd = [self.sudo_bin, *cmd]
    logger.debug("Executing script: %s", script_name)  # Don't log full command with args
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=self.script_timeout)
```

---

### 2. Insufficient Input Validation for Identifier in URL Path

**Title:** Path-based identifier accepts potentially dangerous characters  
**Severity:** High  
**Location:** [`wgadmin/urls.py:8-11`](wgadmin/urls.py:8-11)

**Problem:**
```python
urlpatterns = [
    path("clients/<path:identifier>/enable/", views.enable_client, name="client-enable"),
    path("clients/<path:identifier>/disable/", views.disable_client, name="client-disable"),
    path("clients/<path:identifier>/delete/", views.delete_client, name="client-delete"),
    path("clients/<path:identifier>/activate/", views.activate_client, name="client-activate"),
]
```

Using `<path:identifier>` allows slashes and other characters that could be problematic when passed to shell scripts.

**Impact:**
- The identifier is passed to shell scripts
- While `subprocess.run` with `shell=False` provides protection, the identifier should still be validated
- Could potentially bypass script logic or cause unexpected behavior

**Fix:**

Update [`wgadmin/urls.py`](wgadmin/urls.py):
```python
from django.urls import path, re_path

from . import views

# Use regex pattern to restrict identifier format
IDENTIFIER_PATTERN = r'[A-Za-z0-9._-]+'

urlpatterns = [
    path("", views.client_list, name="clients"),
    path("clients/create/", views.create_client, name="client-create"),
    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/enable/$", views.enable_client, name="client-enable"),
    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/disable/$", views.disable_client, name="client-disable"),
    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/delete/$", views.delete_client, name="client-delete"),
    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/activate/$", views.activate_client, name="client-activate"),
    path("config/<str:token>/", views.public_config, name="public-config"),
    path("config/<str:token>/download/", views.public_config_download, name="public-config-download"),
]
```

Add validation in views (defense in depth) - update [`wgadmin/views.py`](wgadmin/views.py):
```python
import re

def validate_identifier(identifier: str) -> bool:
    """Validate that identifier only contains safe characters."""
    return bool(re.match(r'^[A-Za-z0-9._-]+$', identifier))

@staff_required
def toggle_client(request: HttpRequest, identifier: str, enable: bool) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    if not validate_identifier(identifier):
        messages.error(request, "Invalid client identifier.")
        return redirect("clients")
    # ... rest of function
```

---

## Medium Severity Issues

### 3. CSRF Token Not Validated in Form Actions

**Title:** Forms missing explicit CSRF validation  
**Severity:** Medium  
**Location:** [`wgadmin/views.py`](wgadmin/views.py) - all POST handlers

**Problem:**
The views rely on Django's CSRF middleware but don't use Django forms with `is_valid()` for the hidden input forms (`ActivateClientForm`, `ToggleClientForm`, `DeleteClientForm`), potentially missing form validation.

**Current Code:**
```python
@staff_required
def delete_client(request: HttpRequest, identifier: str) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    # Form is not actually validated - identifier comes from URL
    service = WireGuardService()
```

**Fix:**
Already protected by CSRF middleware, but consider using form validation:
```python
@staff_required
def delete_client(request: HttpRequest, identifier: str) -> HttpResponse:
    if request.method != "POST":
        raise Http404()
    form = DeleteClientForm(request.POST)
    if not form.is_valid():
        messages.error(request, "Invalid request.")
        return redirect("clients")
    if not validate_identifier(identifier):
        messages.error(request, "Invalid client identifier.")
        return redirect("clients")
    # ... rest of function
```

---

### 4. Missing Rate Limiting on Authentication

**Title:** No rate limiting on login attempts  
**Severity:** Medium  
**Location:** Application-level (uses Django's built-in auth)

**Problem:**
The application uses Django's built-in authentication but doesn't implement rate limiting on login attempts, making it vulnerable to brute-force attacks.

**Fix:**
Install and configure `django-axes` or `django-ratelimit`:

Add to `requirements.txt`:
```
django-axes>=6.0
```

Update `settings.py`:
```python
INSTALLED_APPS = [
    # ... existing apps
    "axes",
]

MIDDLEWARE = [
    # ... existing middleware
    "axes.middleware.AxesMiddleware",  # Add after AuthenticationMiddleware
]

AUTHENTICATION_BACKENDS = [
    "axes.backends.AxesStandaloneBackend",
    "django.contrib.auth.backends.ModelBackend",
]

# Axes configuration
AXES_FAILURE_LIMIT = 5
AXES_COOLOFF_TIME = timedelta(minutes=15)
AXES_LOCKOUT_TEMPLATE = "wgadmin/lockout.html"
```

---

### 5. Potential Information Disclosure in Error Messages

**Title:** Detailed error messages exposed to users  
**Severity:** Medium  
**Location:** [`wgadmin/views.py`](wgadmin/views.py) - multiple locations

**Problem:**
```python
except WireGuardError as exc:
    messages.error(request, f"Unable to read WireGuard config: {exc}")
```

Exception details are shown to users, which could reveal system information.

**Fix:**
Log detailed errors but show generic messages to users:
```python
import logging
logger = logging.getLogger(__name__)

except WireGuardError as exc:
    logger.error("WireGuard config read failed: %s", exc)
    messages.error(request, "Unable to read WireGuard configuration. Please contact the administrator.")
```

---

### 6. Missing Content Security Policy

**Title:** No Content Security Policy header  
**Severity:** Medium  
**Location:** [`wgadmin_project/settings.py`](wgadmin_project/settings.py)

**Problem:**
The application doesn't set a Content Security Policy header, leaving it more vulnerable to XSS attacks.

**Fix:**
Add CSP middleware. Install `django-csp`:

Add to `requirements.txt`:
```
django-csp>=3.7
```

Update `settings.py`:
```python
MIDDLEWARE = [
    # ... existing middleware
    "csp.middleware.CSPMiddleware",
]

# Content Security Policy
CSP_DEFAULT_SRC = ("'self'",)
CSP_SCRIPT_SRC = ("'self'", "https://cdn.tailwindcss.com")
CSP_STYLE_SRC = ("'self'", "'unsafe-inline'", "https://cdn.tailwindcss.com")
CSP_IMG_SRC = ("'self'", "data:")
CSP_FONT_SRC = ("'self'",)
CSP_CONNECT_SRC = ("'self'",)
CSP_FRAME_ANCESTORS = ("'none'",)
CSP_FORM_ACTION = ("'self'",)
```

---

## Low Severity Issues

### 7. Hardcoded Default Values in Forms

**Title:** Default allowed_ips value exposes full network access  
**Severity:** Low  
**Location:** [`wgadmin/forms.py:8`](wgadmin/forms.py:8)

**Problem:**
```python
class ClientCreateForm(forms.Form):
    allowed_ips = forms.CharField(max_length=128, initial="0.0.0.0/0")
```

The default `0.0.0.0/0` allows full internet access through the VPN, which may not always be desired.

**Fix:**
Consider making this field required without a default, or use a more restrictive default:
```python
class ClientCreateForm(forms.Form):
    name = forms.CharField(max_length=64, help_text="Client name is used as identifier.")
    allowed_ips = forms.CharField(
        max_length=128, 
        initial="",
        help_text="IP ranges the client can access. Use 0.0.0.0/0 for full tunnel."
    )
```

---

### 8. Token Expiry Cleanup Could Be More Aggressive

**Title:** Expired tokens remain in database  
**Severity:** Low  
**Location:** [`wgadmin/views.py:206-210`](wgadmin/views.py:206-210)

**Problem:**
```python
def _cleanup_tokens() -> None:
    now = timezone.now()
    expired = ConfigDownloadToken.objects.filter(is_active=True, expires_at__lte=now)
    if expired.exists():
        expired.update(is_active=False)
```

This only deactivates tokens but doesn't delete them. Old tokens accumulate in the database.

**Fix:**
Add periodic deletion of old tokens:
```python
def _cleanup_tokens() -> None:
    now = timezone.now()
    # Deactivate expired tokens
    ConfigDownloadToken.objects.filter(is_active=True, expires_at__lte=now).update(is_active=False)
    # Delete tokens older than 30 days
    cutoff = now - timedelta(days=30)
    ConfigDownloadToken.objects.filter(created_at__lt=cutoff).delete()
```

Update the management command too.

---

### 9. Logging Configuration Could Expose Sensitive Data

**Title:** Log level too verbose in development mode  
**Severity:** Low  
**Location:** [`wgadmin_project/settings.py`](wgadmin_project/settings.py) - LOGGING config

**Problem:**
The DEBUG log level in development could log sensitive request data.

**Fix:**
Ensure sensitive data is filtered in logs:
```python
LOGGING = {
    # ... existing config
    "filters": {
        "require_debug_false": {
            "()": "django.utils.log.RequireDebugFalse",
        },
        "require_debug_true": {
            "()": "django.utils.log.RequireDebugTrue",
        },
    },
    # ... rest of config
}
```

---

## Security Best Practices Already Implemented ✓

The following security measures are already properly implemented:

1. **subprocess.run with shell=False**: Scripts are executed safely without shell interpolation
2. **CSRF protection**: Django's CSRF middleware is enabled
3. **Staff-only access**: Management views require `is_staff` permission
4. **Secure session cookies**: Configuration available via environment variables
5. **Password validation**: Django's built-in password validators are enabled
6. **Clickjacking protection**: X-Frame-Options is set
7. **Content-Type sniffing protection**: SECURE_CONTENT_TYPE_NOSNIFF is enabled
8. **Secret key from environment**: SECRET_KEY can be set via environment variable
9. **DEBUG from environment**: DEBUG flag controlled externally
10. **Secure token generation**: Uses `secrets.token_urlsafe()` for download tokens

---

## Recommended Actions

### Immediate (Before Production)

1. [ ] Remove debug print statement from [`wireguard.py`](wgadmin/services/wireguard.py)
2. [ ] Add identifier validation in URLs and views
3. [ ] Set `DJANGO_DEBUG=false` in production
4. [ ] Generate and set a strong `DJANGO_SECRET_KEY`
5. [ ] Configure HTTPS and related security headers

### Short-term

6. [ ] Implement rate limiting with django-axes
7. [ ] Add Content Security Policy
8. [ ] Replace user-facing error messages with generic ones
9. [ ] Add logging for security events

### Long-term

10. [ ] Implement audit log retention policy
11. [ ] Add security headers monitoring
12. [ ] Consider implementing 2FA for admin access
13. [ ] Set up automated security scanning in CI/CD

---

## Code Patches

### Patch 1: Fix wireguard.py debug statement

```diff
--- a/wgadmin/services/wireguard.py
+++ b/wgadmin/services/wireguard.py
@@ -1,6 +1,7 @@
 from __future__ import annotations
 
 import json
+import logging
 import re
 import subprocess
 from dataclasses import dataclass
@@ -12,6 +13,8 @@ from django.conf import settings
 from django.utils import timezone
 
 
+logger = logging.getLogger(__name__)
+
 class WireGuardError(Exception):
     """Raised when the WireGuard service encounters a problem."""
 
@@ -228,7 +231,7 @@ class WireGuardService:
         cmd = [str(script_path), *args]
         if self.use_sudo:
             cmd = [self.sudo_bin, *cmd]
+        logger.debug("Executing script: %s", script_name)
-        print(cmd)
         try:
             proc = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=self.script_timeout)
         except subprocess.TimeoutExpired as exc:
```

### Patch 2: Fix urls.py identifier validation

```diff
--- a/wgadmin/urls.py
+++ b/wgadmin/urls.py
@@ -1,14 +1,18 @@
-from django.urls import path
+from django.urls import path, re_path
 
 from . import views
 
+# Restrict identifiers to safe characters only
+IDENTIFIER_PATTERN = r'[A-Za-z0-9._-]+'
+
 urlpatterns = [
     path("", views.client_list, name="clients"),
     path("clients/create/", views.create_client, name="client-create"),
-    path("clients/<path:identifier>/enable/", views.enable_client, name="client-enable"),
-    path("clients/<path:identifier>/disable/", views.disable_client, name="client-disable"),
-    path("clients/<path:identifier>/delete/", views.delete_client, name="client-delete"),
-    path("clients/<path:identifier>/activate/", views.activate_client, name="client-activate"),
+    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/enable/$", views.enable_client, name="client-enable"),
+    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/disable/$", views.disable_client, name="client-disable"),
+    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/delete/$", views.delete_client, name="client-delete"),
+    re_path(rf"^clients/(?P<identifier>{IDENTIFIER_PATTERN})/activate/$", views.activate_client, name="client-activate"),
     path("config/<str:token>/", views.public_config, name="public-config"),
     path("config/<str:token>/download/", views.public_config_download, name="public-config-download"),
 ]
```

---

## Conclusion

The WireGuard Admin application has a reasonable security baseline. Addressing the high-severity issues (debug print statement and identifier validation) should be the top priority before production deployment. The medium-severity issues should be addressed in the near term to improve the overall security posture.

The application benefits from Django's built-in security features, and the use of `subprocess.run` with `shell=False` for script execution is the correct approach. The main areas for improvement are input validation, error handling, and adding additional layers of defense through CSP and rate limiting.