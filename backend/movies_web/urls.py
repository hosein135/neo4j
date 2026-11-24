from django.urls import path

from graph import views

urlpatterns = [
    path("", views.home),
    path("api/health", views.health),
    path("api/query", views.query),
]
