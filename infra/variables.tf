variable "resource_group_name" {
  description = "Resource group created by bootstrap.sh"
  type        = string
  default     = "rg-resume-prod"
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    project    = "cloud-resume"
    component  = "backend"
    managed_by = "terraform"
  }
}
