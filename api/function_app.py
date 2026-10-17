import json
import logging
import os

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

import counter

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

_container = None


def get_container():
    """Connect to Cosmos DB once and reuse the connection across requests.

    DefaultAzureCredential signs in as the Function App's managed identity,
    so there is no key or connection string anywhere.
    """
    global _container
    if _container is None:
        client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=DefaultAzureCredential())
        database = client.get_database_client(os.environ["COSMOS_DATABASE"])
        _container = database.get_container_client(os.environ["COSMOS_CONTAINER"])
    return _container


def _json(body: dict, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(body),
        status_code=status,
        mimetype="application/json",
        headers={"Cache-Control": "no-store"},
    )


@app.route(route="visitor-count", methods=["GET", "POST"])
def visitor_count(req: func.HttpRequest) -> func.HttpResponse:
    """GET returns the current count; POST adds one visit and returns the new count."""
    try:
        container = get_container()
        if req.method == "POST":
            count = counter.increment(container)
        else:
            count = counter.get_count(container)
    except Exception:
        logging.exception("Visitor count request failed")
        return _json({"error": "Could not update the visitor count"}, status=500)
    return _json({"count": count})
