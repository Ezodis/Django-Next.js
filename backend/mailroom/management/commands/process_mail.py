import time
from django.core.management.base import BaseCommand, CommandError
from django.db import close_old_connections
from mailroom.delivery import send_pending_mail


class Command(BaseCommand):
    help = "Deliver this project's queued admin mail using its configured Django email backend."

    def add_arguments(self, parser):
        parser.add_argument("--loop", action="store_true")
        parser.add_argument("--interval", type=int, default=15)

    def handle(self, *args, **options):
        if options["interval"] < 1:
            raise CommandError("Interval must be positive.")
        while True:
            close_old_connections()
            send_pending_mail()
            if not options["loop"]:
                return
            time.sleep(options["interval"])
