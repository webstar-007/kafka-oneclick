# These are the only settings you may want to change. Defaults work as they are.

variable "region" {
  type    = string
  default = "us-east-1"
}

# Used in names and tags: kafka-demo-vpc, kafka-demo-key, ...
variable "project" {
  type    = string
  default = "kafka-demo"
}

variable "broker_count" {
  type    = number
  default = 3
}

# t3.small is allowed on new AWS free-plan accounts (t3.medium is rejected).
variable "broker_instance_type" {
  type    = string
  default = "t3.small"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.small"
}

# Who may SSH to the bastion. "0.0.0.0/0" = anyone, but the login still needs the private key file.
# It is a demo, so we keep it simple. To restrict it, use your own IP, e.g. "203.0.113.7/32".
variable "allowed_ssh_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
