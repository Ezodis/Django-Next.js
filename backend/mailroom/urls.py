from django.urls import path
from .views import receive_email

urlpatterns = [path("inbound/", receive_email, name="mailroom-inbound")]
