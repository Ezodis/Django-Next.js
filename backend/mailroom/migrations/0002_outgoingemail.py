from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("mailroom", "0001_initial")]
    operations = [migrations.CreateModel(name="OutgoingEmail", fields=[
        ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
        ("from_alias", models.CharField(default="bonn", help_text="Name before @oldbook.ai, e.g. bonn, support or orders.", max_length=64)),
        ("sender", models.EmailField(editable=False, max_length=320)),
        ("recipient", models.EmailField(max_length=320)),
        ("subject", models.CharField(max_length=255)),
        ("body", models.TextField()),
        ("sent_at", models.DateTimeField(blank=True, editable=False, null=True)),
        ("attempts", models.PositiveIntegerField(default=0, editable=False)),
        ("last_error", models.TextField(blank=True, editable=False)),
        ("next_attempt_at", models.DateTimeField(blank=True, editable=False, null=True)),
        ("created_at", models.DateTimeField(auto_now_add=True)),
    ], options={"ordering": ["-created_at"], "verbose_name": "outgoing email", "verbose_name_plural": "Compose and sent mail"})]
