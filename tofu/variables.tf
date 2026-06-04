variable "image_id" {
  description = "Private image id produced by scripts/upload-image.sh, e.g. \"private/1234567\"."
  type        = string

  validation {
    condition     = can(regex("^private/[0-9]+$", var.image_id))
    error_message = "image_id must look like \"private/<number>\" (run scripts/upload-image.sh first)."
  }
}

variable "ignition_path" {
  description = "Path to the rendered Ignition JSON (make ignition -> build/ignition.json)."
  type        = string
  default     = "../build/ignition.json"
}

variable "region" {
  description = "Linode region. Must match the region the image was uploaded to."
  type        = string
  default     = "us-ord"
}

variable "instance_type" {
  description = "Linode instance type. g6-standard-1 (2 GB) is the minimum comfortable size for k3s; g6-nanode-1 (1 GB) is sufficient for bare Flatcar."
  type        = string
  default     = "g6-standard-1"
}

variable "label" {
  description = "Label for the instance, disk, and config."
  type        = string
  default     = "flatcar-akamai"
}

variable "tags" {
  description = "Tags applied to the instance."
  type        = list(string)
  default     = ["flatcar", "managed-by-opentofu"]
}

variable "private_ip" {
  description = "Enable Linode private networking (192.168.0.0/17). See docs for the Ignition unit needed to configure it."
  type        = bool
  default     = false
}
