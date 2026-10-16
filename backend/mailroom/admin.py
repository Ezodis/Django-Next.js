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
from django.db.models import OuterRef, Subquery, DateTimeField
from django.db.models.functions import Coalesce, Greatest
from django.db import transaction
from django.http import JsonResponse
from pathlib import PurePosixPath
from django.shortcuts import redirect
from django.template.response import TemplateResponse
from django.utils.translation import gettext_lazy as _

from .models import ReceivedEmail, OutgoingEmail, MailThread, OutgoingAttachment, address_list
from .configuration import mailbox_domain
from .content import message_content, linked_text, message_ids


class ComposeForm(forms.ModelForm):
    def __init__(self, *args, draft=False, **kwargs):
        super().__init__(*args, **kwargs)
        if draft:
            for name in ("recipient", "subject", "body"):
                self.fields[name].required = False

    class Meta:
        model = OutgoingEmail
        fields = ("from_alias", "recipient", "cc", "bcc", "subject", "body")
        widgets = {"body": forms.Textarea(attrs={"rows": 12})}
        labels = {"from_alias": _("From"), "recipient": _("To"), "cc": _("Cc"), "bcc": _("Bcc"), "subject": _("Subject"), "body": _("Message")}


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
        can_receive = self.has_view_permission(request)
        can_outgoing = request.user.has_perm("mailroom.view_outgoingemail") or request.user.has_perm("mailroom.change_outgoingemail")
        can_compose = request.user.has_perm("mailroom.add_outgoingemail")
        can_change = self.has_change_permission(request)
        can_retry = request.user.has_perm("mailroom.change_outgoingemail")
        if not (can_receive or can_outgoing or can_compose):
            raise PermissionDenied
        folder = request.GET.get("folder", "inbox" if can_receive else "sent" if can_outgoing else "drafts")
        folders = {"inbox": _("Inbox"), "unread": _("Unread"), "starred": _("Starred"), "archive": _("Archive"),
                   "sent": _("Sent"), "outbox": _("Outbox"), "drafts": _("Drafts"), "trash": _("Trash"), "all": _("All mail")}
        if folder not in folders:
            raise Http404
        incoming = folder not in {"sent", "outbox", "drafts"}
        base_url = reverse("admin:mailroom_receivedemail_changelist")
        query = request.GET.get("q", "").strip()[:200]
        list_url = base_url + "?" + urlencode({"folder": folder, "q": query})
        received = ReceivedEmail.objects.all() if can_receive else ReceivedEmail.objects.none()
        outgoing = OutgoingEmail.objects.filter(is_draft=False) if can_outgoing else OutgoingEmail.objects.none()
        drafts = OutgoingEmail.objects.filter(is_draft=True, created_by=request.user) if can_compose else OutgoingEmail.objects.none()
        visible = MailThread.objects.filter(Q(pk__in=received.values("thread_id")) | Q(pk__in=outgoing.values("thread_id")))
        editable = visible if can_change and can_retry else visible.exclude(outgoing__is_draft=False) if can_change else visible.none()
        form = ComposeForm()
        draft = None
        source_email = None
        mode = request.POST.get("mode", "") if request.method == "POST" else next((key for key in ("reply", "reply_all", "forward") if key in request.GET), "")
        source_type = request.POST.get("source_type", "incoming") if request.method == "POST" else request.GET.get("source_type", "incoming")
        source_id = request.POST.get("source_id") if request.method == "POST" else request.GET.get(mode) if mode else None
        if source_id:
            if not can_compose or mode not in {"reply", "reply_all", "forward"} or source_type not in {"incoming", "outgoing"}:
                raise PermissionDenied
            source_email = self._message(received if source_type == "incoming" else outgoing, source_id)
        draft_id = request.POST.get("draft") if request.method == "POST" else request.GET.get("draft")
        if draft_id:
            draft = self._message(drafts, draft_id)
            form = ComposeForm(instance=draft)
        composing = "compose" in request.GET or bool(mode or draft)
        if composing and not can_compose:
            raise PermissionDenied
        compose_error = ""

        if request.method == "POST":
            action = request.POST.get("action")
            if action in {"send", "save_draft", "discard_draft"}:
                if not can_compose:
                    raise PermissionDenied
                composing = True
                if action == "discard_draft":
                    if draft:
                        draft.delete()
                    return redirect(list_url)
                saving_draft = action == "save_draft"
                form = ComposeForm(request.POST, instance=draft, draft=saving_draft)
                uploads = request.FILES.getlist("attachments")
                existing_size = sum(len(item.content) for item in draft.attachments.all()) if draft else 0
                if len(uploads) + (draft.attachments.count() if draft else 0) > 10 or sum(item.size for item in uploads) + existing_size > 10 * 1024 * 1024:
                    compose_error = _("Attach up to 10 files, totaling at most 10 MiB.")
                if form.is_valid() and not compose_error:
                    with transaction.atomic():
                        # Lock an existing draft so double-clicks cannot queue it twice.
                        if draft:
                            locked = OutgoingEmail.objects.select_for_update().get(pk=draft.pk)
                            if not locked.is_draft or locked.created_by_id != request.user.pk:
                                raise Http404
                        email = form.save(commit=False)
                        email.is_draft = saving_draft
                        email.created_by = request.user
                        if source_email and mode != "forward":
                            email.thread = source_email.thread
                            email.in_reply_to = " ".join(message_ids(source_email.message_id))
                            refs = message_content(source_email)["references"] if source_type == "incoming" else source_email.references + " " + source_email.message_id
                            email.references = " ".join(message_ids(refs))
                        email.save()
                        for upload in uploads:
                            OutgoingAttachment.objects.create(email=email,
                                filename=PurePosixPath(upload.name.replace("\\", "/")).name[:200] or "attachment",
                                content_type=upload.content_type or "application/octet-stream", content=upload.read())
                        self.log_addition(request, email, "Draft saved" if saving_draft else "Queued from mailbox")
                    self.message_user(request, _("Draft saved.") if saving_draft else _("Email queued for delivery."), messages.SUCCESS)
                    return redirect(base_url + ("?folder=drafts" if saving_draft else "?folder=outbox"))
            else:
                ids = request.POST.getlist("selected")
                thread_ids = request.POST.getlist("threads")
                for values in (ids, thread_ids):
                    if len(values) > 100 or any(not value.isdecimal() or len(value) > 18 for value in values):
                        raise Http404
                targets = visible.filter(pk__in=thread_ids)
                if action == "retry":
                    if not can_retry:
                        raise PermissionDenied
                    outgoing.filter(Q(pk__in=ids) | Q(thread__in=targets), sent_at__isnull=True).update(next_attempt_at=None)
                elif action in {"read", "unread", "archive", "restore", "star", "unstar", "trash"}:
                    if not can_change:
                        raise PermissionDenied
                    if ids:
                        targets = visible.filter(pk__in=received.filter(pk__in=ids).values("thread_id"))
                    if action in {"read", "unread", "archive", "restore"}:
                        updates = {"read": {"is_read": True}, "unread": {"is_read": False},
                                   "archive": {"is_archived": True}, "restore": {"is_archived": False}}
                        received.filter(thread__in=targets).update(**updates[action])
                    if action in {"star", "unstar", "trash", "restore"}:
                        targets = editable.filter(pk__in=targets.values("pk"))
                        if action in {"star", "unstar"}:
                            targets.update(is_starred=action == "star")
                        else:
                            targets.update(is_trashed=action == "trash")
                else:
                    raise Http404
                if request.headers.get("X-Requested-With") == "XMLHttpRequest":
                    return JsonResponse({"ok": True, "unread_count": received.filter(
                        is_archived=False, is_read=False, thread__is_trashed=False).values("thread").distinct().count()})
                self.message_user(request, _("Mailbox updated."), messages.SUCCESS)
                return redirect(list_url)

        if source_email and request.method != "POST":
            content = message_content(source_email) if source_type == "incoming" else None
            recipient = content["reply_to"] if content else source_email.recipient
            initial = {"from_alias": (source_email.recipient if content else source_email.sender).split("@", 1)[0],
                       "recipient": recipient, "subject": source_email.subject[:255], "body": ""}
            if mode == "forward":
                initial.update(recipient="", subject=("Fwd: " + source_email.subject)[:255],
                    body="\n\n---------- Forwarded message ----------\nFrom: " + source_email.sender + "\nTo: " + source_email.recipient + "\nSubject: " + source_email.subject + "\n\n" + (source_email.text_body if content else source_email.body))
            else:
                if not initial["subject"].lower().startswith("re:"):
                    initial["subject"] = ("Re: " + initial["subject"])[:255]
                if mode == "reply_all":
                    others = address_list(content["to"] + "," + content["cc"] if content else source_email.cc)
                    own = source_email.recipient.lower() if content else source_email.sender.lower()
                    initial["cc"] = ", ".join(dict.fromkeys(address for address in others if address.lower() not in {own, recipient.lower()}))
            form = ComposeForm(initial=initial)
        form.fields["from_alias"].help_text = _("Sender alias on @") + mailbox_domain()
        matches_in = received.filter(thread__is_trashed=folder == "trash")
        matches_out = outgoing.filter(thread__is_trashed=folder == "trash")
        if folder in {"inbox", "unread", "archive"}:
            matches_in = matches_in.filter(is_archived=folder == "archive")
            matches_out = matches_out.none()
            if folder == "unread":
                matches_in = matches_in.filter(is_read=False)
        elif folder in {"sent", "outbox"}:
            matches_in = matches_in.none()
            matches_out = matches_out.filter(sent_at__isnull=folder == "outbox")
        if query:
            matches_in = matches_in.filter(Q(subject__icontains=query) | Q(sender__icontains=query) | Q(recipient__icontains=query) | Q(text_body__icontains=query))
            matches_out = matches_out.filter(Q(subject__icontains=query) | Q(sender__icontains=query) | Q(recipient__icontains=query) | Q(cc__icontains=query) | Q(body__icontains=query))
        listing = visible.filter(Q(pk__in=matches_in.values("thread_id")) | Q(pk__in=matches_out.values("thread_id")))
        if folder == "starred":
            listing = listing.filter(is_starred=True)
        last_in = Subquery(received.filter(thread_id=OuterRef("pk")).order_by("-received_at").values("received_at")[:1], output_field=DateTimeField())
        last_out = Subquery(outgoing.filter(thread_id=OuterRef("pk")).order_by("-created_at").values("created_at")[:1], output_field=DateTimeField())
        listing = listing.annotate(last_in=last_in, last_out=last_out).annotate(latest=Greatest(Coalesce("last_in", "last_out"), Coalesce("last_out", "last_in"))).order_by("-latest", "-pk")
        if folder == "drafts":
            listing = drafts
            if query:
                listing = listing.filter(Q(subject__icontains=query) | Q(recipient__icontains=query) | Q(body__icontains=query))
        page = Paginator(listing, 30).get_page(request.GET.get("page"))
        rows = []
        page_items = list(page.object_list)
        if folder == "drafts":
            for email in page_items:
                rows.append({"pk": email.pk, "subject": email.subject, "correspondent": email.recipient, "preview": email.body[:160],
                    "date": email.created_at, "count": 1, "url": list_url + "&draft=" + str(email.pk), "status": _("Draft")})
        else:
            thread_ids = [item.pk for item in page_items]
            grouped = {pk: [] for pk in thread_ids}
            for email in received.filter(thread_id__in=thread_ids).defer("raw_message", "text_body").annotate(preview=Substr("text_body", 1, 160)):
                email.date = email.received_at
                email.incoming = True
                grouped[email.thread_id].append(email)
            for email in outgoing.filter(thread_id__in=thread_ids).defer("body").annotate(preview=Substr("body", 1, 160)):
                email.date = email.created_at
                email.incoming = False
                grouped[email.thread_id].append(email)
            editable_ids = set(editable.filter(pk__in=thread_ids).values_list("pk", flat=True))
            for thread in page_items:
                items = sorted(grouped[thread.pk], key=lambda item: item.date)
                if not items:
                    continue
                email = items[-1]
                rows.append({"pk": thread.pk, "subject": email.subject, "correspondent": email.sender if email.incoming else email.recipient,
                    "preview": email.preview, "date": email.date, "count": len(items), "unread": any(item.incoming and not item.is_read for item in items),
                    "starred": thread.is_starred, "editable": thread.pk in editable_ids,
                    "status": "" if email.incoming else _("Sent") if email.sent_at else _("Retrying") if email.last_error else _("Queued"),
                    "url": list_url + "&page=" + str(page.number) + "&thread=" + str(thread.pk)})
        selected_thread = None
        if request.GET.get("thread"):
            selected_thread = self._message(visible, request.GET["thread"])
        elif request.GET.get("message"):
            selected_thread = self._message(received if incoming else outgoing, request.GET["message"]).thread
        conversation = []
        if selected_thread:
            for email in received.filter(thread=selected_thread):
                content = message_content(email)
                attachments = [(reverse("admin:mailroom_receivedemail_download", args=[email.pk, index]), part.get_filename() or _("Attachment"))
                    for index, part in enumerate(content["mime"].iter_attachments(), 1)]
                conversation.append({"email": email, "incoming": True, "date": email.received_at, "content": content, "attachments": attachments})
            for email in outgoing.filter(thread=selected_thread).prefetch_related("attachments"):
                attachments = [(reverse("admin:mailroom_outgoing_attachment", args=[item.pk]), item.filename) for item in email.attachments.all()]
                conversation.append({"email": email, "incoming": False, "date": email.created_at, "content": {"text": linked_text(email.body)}, "attachments": attachments})
            conversation.sort(key=lambda item: (item["date"], item["email"].pk))
        selected = conversation[-1]["email"] if conversation else None
        context = {**self.admin_site.each_context(request), **(extra_context or {}),
            "title": _("Mailbox"), "opts": self.model._meta, "folder": folder, "folder_title": folders[folder],
            "incoming": incoming, "query": query, "base_url": base_url, "list_url": list_url, "page": page, "rows": rows,
            "selected": selected, "selected_thread": selected_thread, "conversation": conversation,
            "thread_editable": selected_thread and editable.filter(pk=selected_thread.pk).exists(),
            "thread_unread": any(item["incoming"] and not item["email"].is_read for item in conversation),
            "compose_form": form, "composing": composing, "compose_error": compose_error, "domain": mailbox_domain(),
            "draft": draft, "mode": mode, "source_email": source_email, "source_type": source_type,
            "can_receive": can_receive, "can_view_outgoing": can_outgoing, "can_compose": can_compose,
            "can_change": can_change, "can_retry": can_retry,
            "unread_count": received.filter(is_archived=False, is_read=False, thread__is_trashed=False).values("thread").distinct().count(),
            "outbox_count": outgoing.filter(sent_at__isnull=True, thread__is_trashed=False).count(), "draft_count": drafts.count()}
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
        return [path("attachments/<int:pk>/", self.admin_site.admin_view(self.outgoing_attachment), name="mailroom_outgoing_attachment"),
                path("<int:pk>/download/<int:part>/", self.admin_site.admin_view(self.download),
                     name="mailroom_receivedemail_download")] + super().get_urls()

    def outgoing_attachment(self, request, pk):
        attachment = get_object_or_404(OutgoingAttachment.objects.select_related("email"), pk=pk)
        email = attachment.email
        if email.is_draft:
            permitted = email.created_by_id == request.user.pk and request.user.has_perm("mailroom.add_outgoingemail")
        else:
            permitted = request.user.has_perm("mailroom.view_outgoingemail") or request.user.has_perm("mailroom.change_outgoingemail")
        if not permitted:
            raise PermissionDenied
        response = FileResponse(BytesIO(bytes(attachment.content)), as_attachment=True,
                                filename=attachment.filename, content_type="application/octet-stream")
        response["X-Content-Type-Options"] = "nosniff"
        response["Cache-Control"] = "private, no-store"
        return response

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

    def get_queryset(self, request):
        return super().get_queryset(request).filter(Q(is_draft=False) | Q(created_by=request.user))

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
        if not change and request.GET.get("reply_to") and request.user.has_perm("mailroom.view_receivedemail"):
            original = ReceivedEmailAdmin._message(ReceivedEmail.objects.all(), request.GET["reply_to"])
            obj.thread = original.thread
            obj.in_reply_to = " ".join(message_ids(original.message_id))
            obj.references = message_content(original)["references"]
        if not change:
            obj.created_by = request.user
        super().save_model(request, obj, form, change)
        if not change:
            self.message_user(request, "Email queued. The mail worker will send it through this project’s email provider and update delivery status.")

    @admin.display(description="Status")
    def delivery_status(self, obj):
        return "Sent" if obj.sent_at else "Retrying" if obj.last_error else "Queued"

    @admin.action(description="Retry unsent emails", permissions=["change"])
    def retry_delivery(self, request, queryset):
        queryset.filter(sent_at__isnull=True).update(next_attempt_at=None)
