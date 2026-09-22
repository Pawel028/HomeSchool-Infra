# Metric alerts for the API Container App (enabled for prod). Both alerts email one action group.
# Metric names are those of the Microsoft.App/containerApps namespace: Requests (dimension statusCodeCategory)
# and RestartCount.

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${var.name_prefix}-ops"
  resource_group_name = var.resource_group_name
  short_name          = "hsops"
  tags                = var.tags

  email_receiver {
    name                    = "ops-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "alert-${var.name_prefix}-api-5xx"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "The API returned more than ${var.http_5xx_threshold} responses with a 5xx status in 5 minutes."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.http_5xx_threshold

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-${var.name_prefix}-api-restarts"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "API containers restarted more than ${var.restart_threshold} times in 15 minutes (crash loop, OOM or failing liveness probe)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.restart_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}
