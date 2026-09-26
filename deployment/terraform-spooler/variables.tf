variable "service_name" {
  type    = string
  default = "spooler"
}

variable "env" {
  type = string
}

variable "app_port" {
  type    = number
  default = 4539
}

variable "cpu_limit" {
  type    = number
  default = 50
}

variable "mem_limit" {
  type    = number
  default = 256
}

variable "mem_reservation" {
  type    = number
  default = 128
}

variable "container_restart_policy_enabled" {
  description = "Whether to enable restart policy for the container."
  type        = bool
  default     = true
}

variable "TAGGED_IMAGE" {
  type = string
}

# App variables
variable "app_env_vars" {
  type = map(any)
  default = {
    CYBER_DOJO_PROMETHEUS     = "true"
    CYBER_DOJO_SPOOLER_PORT   = "4539"
    CYBER_DOJO_SAVER_HOSTNAME = "saver.cyber-dojo.eu-central-1"
    CYBER_DOJO_SAVER_PORT     = "4537"
  }
}

variable "ecr_replication_targets" {
  type    = list(map(string))
  default = []
}

variable "ecr_replication_origin" {
  type    = string
  default = ""
}
