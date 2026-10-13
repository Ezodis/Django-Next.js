from email import policy
from email.parser import BytesParser

from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.http import FileResponse, Http404
from django.shortcuts import get_object_or_404
from django.urls import path, reverse
from django.utils.html import format_html_join
from io import BytesIO
from urllib.parse import urlencode
from django.utils.html import format_html
from django import forms
from django.contrib import messages
from django.core.paginator import Paginator
from django.db.models import Q
from django.db.models.functions import Substr
from django.shortcuts import redirect
from django.template.response import TemplateResponse
from django.utils.translation import gettext_lazy as _

from .models import ReceivedEmail, OutgoingEmail
from .configuration import mailbox_domain


class ComposeForm(forms.ModelForm):
    class Meta:
        model = OutgoingEmail
        fields = ("from_alias", "recipient", "subject", "body")
        widgets = {"body": forms.Textarea(attrs={"rows": 12})}
        labels = {"from_alias": _("From"), "recipient": _("To"), "subject": _("Subject"), "body": _("Message")}


@admin.register(ReceivedEmail)
class ReceivedEmailAdmin(admin.ModelAdmin):
    list_display = ("subject", "sender", "recipient", "is_read", "is_archived", "received_at")
    list_filter = ("is_read", "is_archived", "recipient", "received_at")
    search_fields = ("subject", "sender", "recipient", "text_body")
    readonly_fields = ("sender", "recipient", "subject", "message_id", "text_body", "received_at", "downloads", "reply")
    fields = readonly_fields + ("is_read", "is_archived")
    actions = ("mark_read", "mark_unread", "archive", "unarchive")

    def get_model_perms(self, request):
        # One navigation entry serves both received and outgoing permissions.
        permitted = (self.has_view_permission(request)
                     or request.user.has_perm("mailroom.view_outgoingemail")
                     or request.user.has_perm("mailroom.change_outgoingemail")
                     or request.user.has_perm("mailroom.add_outgoingemail"))
        return {"view": permitted, "add": False, "change": False, "delete": False}

    def changelist_view(self, request, extra_context=None):
        incoming_allowed = self.has_view_permission(request)
        outgoing_allowed = (request.user.has_perm("mailroom.view_outgoingemail")
                            or request.user.has_perm("mailroom.change_outgoingemail"))
        compose_allowed = request.user.has_perm("mailroom.add_outgoingemail")
        if not (incoming_allowed or outgoing_allowed or compose_allowed):
            raise PermissionDenied
        folder = request.GET.get("folder", "inbox" if incoming_allowed else "sent" if outgoing_allowed else "outbox")
        folders = {"inbox": "Inbox", "unread": "Unread", "archive": "Archive", "sent": "Sent", "outbox": "Outbox"}
        if folder not in folders:
            raise Http404
        incoming = folder in {"inbox", "unread", "archive"}
        base_url = reverse("admin:mailroom_receivedemail_changelist")
        query = request.GET.get("q", "").strip()[:200]
        list_url = base_url + "?" + urlencode({"folder": folder, "q": query})
        received = ReceivedEmail.objects.all() if incoming_allowed else ReceivedEmail.objects.none()
        outgoing = OutgoingEmail.objects.all() if outgoing_allowed else OutgoingEmail.objects.none()
        form = ComposeForm()
        composing = "compose" in request.GET or "reply" in request.GET

        if request.method == "POST":
            action = request.POST.get("action")
            if action == "send":
                if not compose_allowed:
                    raise PermissionDenied
                composing = True
                form = ComposeForm(request.POST)
                if form.is_valid():
                    email = form.save()
                    self.log_addition(request, email, "Queued from mailbox")
                    self.message_user(request, "Email queued for delivery.", messages.SUCCESS)
                    return redirect(base_url + "?folder=outbox")
            else:
                ids = request.POST.getlist("selected")
                if len(ids) > 100 or any(not value.isdecimal() or len(value) > 18 for value in ids):
                    raise Http404
                if action == "retry":
                    if not request.user.has_perm("mailroom.change_outgoingemail"):
                        raise PermissionDenied
                    outgoing.filter(pk__in=ids, sent_at__isnull=True).update(next_attempt_at=None)
                elif action in {"read", "unread", "archive", "restore"}:
                    if not self.has_change_permission(request):
                        raise PermissionDenied
                    updates = {"read": {"is_read": True}, "unread": {"is_read": False},
                               "archive": {"is_archived": True}, "restore": {"is_archived": False}}
                    received.filter(pk__in=ids).update(**updates[action])
                else:
                    raise Http404
                self.message_user(request, "Mailbox updated.", messages.SUCCESS)
                return redirect(list_url)

        if composing and not compose_allowed:
            raise PermissionDenied
        reply_id = request.GET.get("reply")
        if reply_id and request.method != "POST":
            if not incoming_allowed:
                raise PermissionDenied
            original = self._message(received, reply_id)
            form = ComposeForm(initial={"from_alias": original.recipient.split("@", 1)[0],
                "recipient": original.sender,
                "subject": (original.subject if original.subject.lower().startswith("re:") else "Re: " + original.subject)[:255],
                "body": "\n\n--- Original message ---\n" + original.text_body})
        form.fields["from_alias"].help_text = "Sender alias on @" + mailbox_domain()

        if incoming:
            listing = received.filter(is_archived=(folder == "archive"))
            if folder == "unread":
                listing = listing.filter(is_read=False)
            if query:
                listing = listing.filter(Q(subject__icontains=query) | Q(sender__icontains=query)
                                         | Q(recipient__icontains=query) | Q(text_body__icontains=query))
            listing = listing.order_by("-received_at", "-pk").defer("raw_message", "text_body").annotate(preview=Substr("text_body", 1, 160))
        else:
            listing = outgoing.filter(sent_at__isnull=(folder == "outbox"))
            if query:
                listing = listing.filter(Q(subject__icontains=query) | Q(sender__icontains=query)
                                         | Q(recipient__icontains=query) | Q(body__icontains=query))
            listing = listing.order_by("-created_at", "-pk").defer("body").annotate(preview=Substr("body", 1, 160))
        page = Paginator(listing, 30).get_page(request.GET.get("page"))
        selected = None
        if request.GET.get("message"):
            selected = self._message(received if incoming else outgoing, request.GET["message"])
        attachments = []
        if selected and incoming:
            mime = BytesParser(policy=policy.default).parsebytes(bytes(selected.raw_message))
            attachments = [(reverse("admin:mailroom_receivedemail_download", args=[selected.pk, index]),
                            part.get_filename() or f"Attachment {index}")
                           for index, part in enumerate(mime.iter_attachments(), 1)]
        context = {**self.admin_site.each_context(request), **(extra_context or {}),
            "title": "Mailbox", "opts": self.model._meta, "folder": folder, "folder_title": folders[folder],
            "incoming": incoming, "query": query, "base_url": base_url, "list_url": list_url,
            "page": page, "selected": selected, "attachments": attachments,
            "compose_form": form, "composing": composing, "domain": mailbox_domain(),
            "can_receive": incoming_allowed, "can_view_outgoing": outgoing_allowed,
            "can_compose": compose_allowed, "can_change": self.has_change_permission(request),
            "can_retry": request.user.has_perm("mailroom.change_outgoingemail"),
            "unread_count": received.filter(is_archived=False, is_read=False).count(),
            "outbox_count": outgoing.filter(sent_at__isnull=True).count(),
            "archive_count": received.filter(is_archived=True).count()}
        return TemplateResponse(request, "admin/mailroom/mailbox.html", context)

    @staticmethod
    def _message(queryset, identifier):
        if not identifier.isdecimal() or len(identifier) > 18:
            raise Http404
        return get_object_or_404(queryset, pk=identifier)

    def has_add_permission(self, request):
        return False

    def get_queryset(self, request):
        return super().get_queryset(request).defer("raw_message", "text_body")

    def get_urls(self):
        return [path("<int:pk>/download/<int:part>/", self.admin_site.admin_view(self.download),
                     name="mailroom_receivedemail_download")] + super().get_urls()

    def download(self, request, pk, part):
        email = get_object_or_404(ReceivedEmail, pk=pk)
        if not self.has_view_permission(request, email):
            raise PermissionDenied
        raw = bytes(email.raw_message)
        if part == 0:
            content, filename = raw, f"email-{email.pk}.eml"
        else:
            attachments = list(BytesParser(policy=policy.default).parsebytes(raw).iter_attachments())
            if part > len(attachments):
                raise Http404
            attachment = attachments[part - 1]
            content = attachment.get_payload(decode=True)
            if content is None:
                content = attachment.as_bytes()
            filename = (attachment.get_filename() or f"attachment-{part}").replace("\\", "/").rsplit("/", 1)[-1]
            filename = filename.replace("\r", "").replace("\n", "")[:200] or f"attachment-{part}"
        response = FileResponse(BytesIO(content), as_attachment=True, filename=filename, content_type="application/octet-stream")
        response["X-Content-Type-Options"] = "nosniff"
        response["Cache-Control"] = "private, no-store"
        return response

    @admin.display(description="Downloads")
    def downloads(self, email):
        attachments = list(BytesParser(policy=policy.default).parsebytes(bytes(email.raw_message)).iter_attachments())
        links = [(reverse("admin:mailroom_receivedemail_download", args=[email.pk, 0]), "Original email (.eml)")]
        links += [(reverse("admin:mailroom_receivedemail_download", args=[email.pk, index]),
                   item.get_filename() or f"Attachment {index}") for index, item in enumerate(attachments, 1)]
        return format_html_join(" · ", '<a href="{}">{}</a>', links)

    @admin.display(description="Reply")
    def reply(self, email):
        if not email.sender:
            return "This delivery has no reply address."
        url = reverse("admin:mailroom_outgoingemail_add") + "?" + urlencode({"reply_to": email.pk})
        return format_html('<a href="{}">Reply from {}</a>', url, email.recipient)

    @admin.action(description="Mark as read", permissions=["change"])
    def mark_read(self, request, queryset):
        queryset.update(is_read=True)

    @admin.action(description="Mark as unread", permissions=["change"])
    def mark_unread(self, request, queryset):
        queryset.update(is_read=False)

    @admin.action(description="Archive", permissions=["change"])
    def archive(self, request, queryset):
        queryset.update(is_archived=True)

    @admin.action(description="Move back to inbox", permissions=["change"])
    def unarchive(self, request, queryset):
        queryset.update(is_archived=False)


@admin.register(OutgoingEmail)
class OutgoingEmailAdmin(admin.ModelAdmin):
    change_form_template = "admin/mailroom/outgoingemail/change_form.html"
    list_display = ("subject", "sender", "recipient", "delivery_status", "sent_at", "created_at")
    list_filter = ("sent_at", "sender", "created_at")
    search_fields = ("subject", "sender", "recipient", "body")
    actions = ("retry_delivery",)
    readonly_fields = ("sender", "sent_at", "attempts", "last_error", "created_at")
    fields = ("from_alias", "recipient", "subject", "body") + readonly_fields

    def get_model_perms(self, request):
        # Keep legacy admin URLs available without a second navigation entry.
        return {}

    def get_readonly_fields(self, request, obj=None):
        return self.fields if obj else self.readonly_fields

    def get_form(self, request, obj=None, **kwargs):
        form = super().get_form(request, obj, **kwargs)
        if "from_alias" in form.base_fields:
            form.base_fields["from_alias"].help_text = "Name before @" + mailbox_domain()
        return form

    def get_changeform_initial_data(self, request):
        initial = super().get_changeform_initial_data(request)
        if request.GET.get("reply_to") and request.user.has_perm("mailroom.view_receivedemail"):
            email = get_object_or_404(ReceivedEmail, pk=request.GET["reply_to"])
            initial.update(from_alias=email.recipient.split("@", 1)[0], recipient=email.sender,
                           subject=(email.subject if email.subject.lower().startswith("re:") else "Re: " + email.subject)[:255],
                           body="\n\n--- Original message ---\n" + email.text_body)
        return initial

    def save_model(self, request, obj, form, change):
        super().save_model(request, obj, form, change)
        if not change:
            self.message_user(request, "Email queued. The mail worker will send it through this project’s email provider and update delivery status.")

    @admin.display(description="Status")
    def delivery_status(self, obj):
        return "Sent" if obj.sent_at else "Retrying" if obj.last_error else "Queued"

    @admin.action(description="Retry unsent emails", permissions=["change"])
    def retry_delivery(self, request, queryset):
        queryset.filter(sent_at__isnull=True).update(next_attempt_at=None)
