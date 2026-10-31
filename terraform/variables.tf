variable "zone_id" {
  description = "Cloudflare zone id of example.com"
  type        = string
}

variable "zone_name" {
  description = "Zone apex, used to build record names"
  type        = string
  default     = "example.com"
}

variable "origin_hostname" {
  description = "Origin the proxied record points at, e.g. the AWS load balancer DNS name"
  type        = string
}

variable "legacy_record_id" {
  description = "Id of the manually-created www record being adopted (Cloudflare API: GET /zones/{zone_id}/dns_records?name=www.<zone>)"
  type        = string
}

variable "legacy_record_content" {
  description = "Current content of the manually-created www record; must match what is live or the first plan shows a change"
  type        = string
}
