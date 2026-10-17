import json
from unittest.mock import MagicMock, patch

import azure.functions as func

import function_app

# Get the plain Python function behind the @app.route decorator.
handler = function_app.visitor_count.build().get_user_function()


def make_request(method: str) -> func.HttpRequest:
    return func.HttpRequest(method=method, url="/api/visitor-count", body=b"")


@patch("function_app.get_container")
def test_post_increments_and_returns_count(mock_get_container):
    container = MagicMock()
    container.patch_item.return_value = {"id": "visitors", "count": 5}
    mock_get_container.return_value = container

    resp = handler(make_request("POST"))

    assert resp.status_code == 200
    assert json.loads(resp.get_body()) == {"count": 5}
    assert resp.headers["Cache-Control"] == "no-store"


@patch("function_app.get_container")
def test_get_reads_without_incrementing(mock_get_container):
    container = MagicMock()
    container.read_item.return_value = {"id": "visitors", "count": 9}
    mock_get_container.return_value = container

    resp = handler(make_request("GET"))

    assert json.loads(resp.get_body()) == {"count": 9}
    container.patch_item.assert_not_called()


@patch("function_app.get_container")
def test_database_error_returns_500_without_details(mock_get_container):
    mock_get_container.side_effect = RuntimeError("connection refused")

    resp = handler(make_request("POST"))

    assert resp.status_code == 500
    assert "connection refused" not in resp.get_body().decode()
