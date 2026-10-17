from unittest.mock import MagicMock

from azure.cosmos.exceptions import CosmosResourceExistsError, CosmosResourceNotFoundError

import counter


def test_increment_existing_counter():
    container = MagicMock()
    container.patch_item.return_value = {"id": "visitors", "count": 42}

    assert counter.increment(container) == 42
    container.patch_item.assert_called_once()
    container.create_item.assert_not_called()


def test_increment_creates_counter_on_first_visit():
    container = MagicMock()
    container.patch_item.side_effect = CosmosResourceNotFoundError()
    container.create_item.return_value = {"id": "visitors", "count": 1}

    assert counter.increment(container) == 1
    container.create_item.assert_called_once_with({"id": "visitors", "count": 1})


def test_increment_handles_two_first_visitors_at_once():
    container = MagicMock()
    # First patch: not found. Create: someone else just made it. Second patch: works.
    container.patch_item.side_effect = [CosmosResourceNotFoundError(), {"id": "visitors", "count": 2}]
    container.create_item.side_effect = CosmosResourceExistsError()

    assert counter.increment(container) == 2
    assert container.patch_item.call_count == 2


def test_get_count_returns_current_value():
    container = MagicMock()
    container.read_item.return_value = {"id": "visitors", "count": 7}

    assert counter.get_count(container) == 7


def test_get_count_is_zero_before_first_visit():
    container = MagicMock()
    container.read_item.side_effect = CosmosResourceNotFoundError()

    assert counter.get_count(container) == 0
