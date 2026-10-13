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
from django.conf import settings
from django.utils.html import format_html

from .models import ReceivedEmail, OutgoingEmail
from .configuration import mailbox_domain


@admin.register(ReceivedEmail)
class ReceivedEmailAdmin(admin.ModelAdmin):
    list_display = ("subject", "sender", "recipient", "is_read", "is_archived", "received_at")
    list_filter = ("is_read", "is_archived", "recipient", "received_at")
    search_fields = ("subject", "sender", "recipient", "text_body")
    readonly_fields = ("sender", "recipient", "subject", "message_id", "text_body", "received_at", "downloads", "reply")
    fields = readonly_fields + ("is_read", "is_archived")
    actions = ("mark_read", "mark_unread", "archive", "unarchive")

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
        return format_html_join(" Â· ", '<a href="{}">{}</a>', links)

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
