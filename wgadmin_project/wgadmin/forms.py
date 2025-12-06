import re

from django import forms


class ClientCreateForm(forms.Form):
    name = forms.CharField(max_length=64, help_text="Client name is used as identifier.")
    allowed_ips = forms.CharField(max_length=128, initial="0.0.0.0/0")

    def clean_name(self) -> str:
        name = self.cleaned_data["name"].strip()
        if len(name) < 3:
            raise forms.ValidationError("Name must be at least 3 characters long.")
        if not re.match(r"^[A-Za-z0-9._-]+$", name):
            raise forms.ValidationError("Name may contain only letters, numbers, dot, dash, and underscore.")
        return name

    def clean_allowed_ips(self) -> str:
        return self.cleaned_data["allowed_ips"].strip()


class ActivateClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)


class ToggleClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)


class DeleteClientForm(forms.Form):
    client_identifier = forms.CharField(widget=forms.HiddenInput)
