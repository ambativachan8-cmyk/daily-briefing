variable "region" {
  description = "AWS region for the single VM (the account's Free-plan project is pinned to Sydney)."
  type        = string
  default     = "ap-southeast-2"
}

variable "instance_type" {
  description = "Free-plan eligible type with enough RAM for OpenClaw + Hermes + the app."
  type        = string
  default     = "m7i-flex.large" # 2 vCPU / 8 GiB
}

variable "root_volume_gb" {
  description = "Root gp3 volume size."
  type        = number
  default     = 30
}

variable "ssh_public_key_path" {
  description = "Path to the public key allowed to SSH in (private key never leaves your machine)."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (your IP/32). Agent dashboards are only reachable through SSH tunnels."
  type        = string
}

variable "name" {
  description = "Name prefix for resources."
  type        = string
  default     = "daily-briefing"
}
