from django.db import migrations, models
import mailroom.configuration


class Migration(migrations.Migration):
    dependencies = [("mailroom", "0002_outgoingemail")]
    operations = [migrations.AlterField(
        model_name="outgoingemail", name="from_alias",
        field=models.CharField(default=mailroom.configuration.default_alias,
                               help_text="Sender alias on this project’s configured mail domain.", max_length=64),
    )]
