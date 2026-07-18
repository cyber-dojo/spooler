variable "service_name" {
  type    = string
  default = "spooler"
}

variable "env" {
  type = string
}

variable "ecr_replication_targets" {
  type    = list(map(string))
  default = []
}

variable "ecr_replication_origin" {
  type    = string
  default = ""
}
