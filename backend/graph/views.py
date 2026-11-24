import json

from django.conf import settings
from django.http import JsonResponse
from django.shortcuts import redirect
from django.views.decorators.http import require_GET, require_POST

from graph.neo import QueryError, counts, run_query


def home(request):
    return redirect(settings.NEXT_ORIGIN + "/")


@require_GET
def health(request):
    try:
        data = counts()
    except Exception as exc:
        return JsonResponse({"ok": False, "error": str(exc)}, status=503)
    return JsonResponse({"ok": True, **data})


@require_POST
def query(request):
    try:
        body = json.loads(request.body.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        return JsonResponse({"error": "Request body must be JSON."}, status=400)
    if not isinstance(body, dict):
        return JsonResponse({"error": "Request body must be a JSON object."}, status=400)
    cypher = body.get("cypher", "")
    if not isinstance(cypher, str):
        return JsonResponse({"error": "cypher must be a string."}, status=400)
    try:
        payload = run_query(cypher)
    except QueryError as exc:
        return JsonResponse({"error": str(exc)}, status=exc.status)
    return JsonResponse(payload)
