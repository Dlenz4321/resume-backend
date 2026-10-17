output "cosmos_account_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.api.name
}

output "function_base_url" {
  value = "https://${azurerm_function_app_flex_consumption.api.default_hostname}"
}
