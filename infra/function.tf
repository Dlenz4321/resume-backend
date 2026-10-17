# --- Monitoring ---
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-resume-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.prod.name
  location            = data.azurerm_resource_group.prod.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-resume-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.prod.name
  location            = data.azurerm_resource_group.prod.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = var.tags
}

# --- Function storage (code package + host bookkeeping) ---
resource "azurerm_storage_account" "func" {
  name                            = "stfunc${random_string.suffix.result}"
  resource_group_name             = data.azurerm_resource_group.prod.name
  location                        = data.azurerm_resource_group.prod.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "deploy" {
  name                  = "deploymentpackage"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# --- Flex Consumption plan + Function App ---
resource "azurerm_service_plan" "func" {
  name                = "asp-resume-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.prod.name
  location            = data.azurerm_resource_group.prod.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "api" {
  name                = "func-resume-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.prod.name
  location            = data.azurerm_resource_group.prod.location
  service_plan_id     = azurerm_service_plan.func.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.func.primary_access_key

  runtime_name           = "python"
  runtime_version        = "3.11"
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    COSMOS_ENDPOINT  = azurerm_cosmosdb_account.main.endpoint
    COSMOS_DATABASE  = azurerm_cosmosdb_sql_database.resume.name
    COSMOS_CONTAINER = azurerm_cosmosdb_sql_container.counter.name
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.main.connection_string

    cors {
      allowed_origins = [trimsuffix(var.frontend_url, "/"), "https://portal.azure.com"]
    }
  }

  tags = var.tags
}

# --- Let the function's identity read/write Cosmos data (no keys) ---
resource "azurerm_cosmosdb_sql_role_assignment" "func_data" {
  resource_group_name = data.azurerm_resource_group.prod.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_function_app_flex_consumption.api.identity[0].principal_id
  scope               = azurerm_cosmosdb_account.main.id
}
