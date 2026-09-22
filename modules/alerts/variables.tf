variable "name_prefix" {
  description = "Prefix for resource names, for example hs-prod."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "container_app_id" {
  description = "Container App the metric alerts watch."
  type        = string
}

variable "alert_email" {
  description = "Address that receives alert emails."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "http_5xx_threshold" {
  description = "Alert when more than this many 5xx responses occur within the 5 minute window."
  type        = number
  default     = 5
}

variable "restart_threshold" {
  description = "Alert when more than this many container restarts occur within the 15 minute window."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
