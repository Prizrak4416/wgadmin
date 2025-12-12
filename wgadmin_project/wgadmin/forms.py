import re

from django import forms


class ClientCreateForm(forms.Form):
    name = forms.CharField(max_length=64, help_text="Client name is used as identifier.")
    allowed_ips = forms.CharField(max_length=128)

    def __init__(self, *args, used_ips=None, used_names=None, **kwargs):
        self.used_ips = {ip.strip() for ip in (used_ips or []) if ip.strip()}
        self.used_names = {name.strip() for name in (used_names or []) if name}
        super().__init__(*args, **kwargs)

    def clean_name(self) -> str:
        name = self.cleaned_data["name"].strip()
        if len(name) < 3:
            raise forms.ValidationError("Name must be at least 3 characters long.")
        if not re.match(r"^[A-Za-z0-9._-]+$", name):
            raise forms.ValidationError("Name may contain only letters, numbers, dot, dash, and underscore.")
        if self.used_names and name in self.used_names:
            raise forms.ValidationError("Name already exists.")
        return name

    def clean_allowed_ips(self) -> str:
        allowed_ips = self.cleaned_data["allowed_ips"].strip()
        requested_ips = {ip.strip() for ip in allowed_ips.split(",") if ip.strip()}
        if self.used_ips:
            duplicate_ips = sorted(self.used_ips.intersection(requested_ips))
            if duplicate_ips:
                raise forms.ValidationError(f"IP already in use: {', '.join(duplicate_ips)}")
        return allowed_ips


class ActivateClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)


class ToggleClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)


class DeleteClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)
