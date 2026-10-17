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

variable "frontend_url" {
  description = "Resume site URL allowed to call the API (CORS)"
  type        = string
  default     = "https://stresumelvoc8r.z1.web.core.windows.net/"
}
