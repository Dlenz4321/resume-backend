data "azurerm_resource_group" "prod" {
  name = var.resource_group_name
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# --- Cosmos DB (NoSQL, serverless, keys disabled) ---
resource "azurerm_cosmosdb_account" "main" {
  name                          = "cosmos-resume-${random_string.suffix.result}"
  resource_group_name           = data.azurerm_resource_group.prod.name
  location                      = data.azurerm_resource_group.prod.location
  offer_type                    = "Standard"
  kind                          = "GlobalDocumentDB"
  local_authentication_disabled = true
  minimal_tls_version           = "Tls12"
  tags                          = var.tags

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = data.azurerm_resource_group.prod.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "resume" {
  name                = "resume"
  resource_group_name = data.azurerm_resource_group.prod.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "counter" {
  name                = "counter"
  resource_group_name = data.azurerm_resource_group.prod.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.resume.name
  partition_key_paths = ["/id"]
}
