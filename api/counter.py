"""Visitor counter logic, kept separate from Azure Functions so it is easy to test."""
from azure.cosmos.exceptions import CosmosResourceExistsError, CosmosResourceNotFoundError

COUNTER_ID = "visitors"


def increment(container) -> int:
    """Atomically add 1 to the counter and return the new value.

    Uses a Cosmos DB patch "incr" operation, so two visitors arriving at the
    same moment can't overwrite each other's update.
    """
    try:
        item = container.patch_item(
            item=COUNTER_ID,
            partition_key=COUNTER_ID,
            patch_operations=[{"op": "incr", "path": "/count", "value": 1}],
        )
    except CosmosResourceNotFoundError:
        # First visitor ever: the counter document doesn't exist yet.
        try:
            item = container.create_item({"id": COUNTER_ID, "count": 1})
        except CosmosResourceExistsError:
            # Another request created it a split second earlier; increment that one.
            return increment(container)
    return int(item["count"])


def get_count(container) -> int:
    """Return the current count without changing it (0 if nobody has visited yet)."""
    try:
        item = container.read_item(item=COUNTER_ID, partition_key=COUNTER_ID)
    except CosmosResourceNotFoundError:
        return 0
    return int(item["count"])
