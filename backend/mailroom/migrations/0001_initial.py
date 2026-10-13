from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = []
    operations = [migrations.CreateModel(name="ReceivedEmail", fields=[
        ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
        ("sender", models.CharField(blank=True, max_length=320)),
        ("recipient", models.EmailField(db_index=True, max_length=320)),
        ("subject", models.CharField(blank=True, max_length=1000)),
        ("message_id", models.CharField(blank=True, max_length=1000)),
        ("text_body", models.TextField(blank=True)),
        ("raw_message", models.BinaryField(editable=False)),
        ("digest", models.CharField(editable=False, max_length=64, unique=True)),
        ("is_read", models.BooleanField(default=False)),
        ("is_archived", models.BooleanField(default=False)),
        ("received_at", models.DateTimeField(auto_now_add=True)),
    ], options={"ordering": ["-received_at"], "verbose_name": "received email", "verbose_name_plural": "Inbox"})]
