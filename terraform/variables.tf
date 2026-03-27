variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the Mac dedicated host (must support the chosen instance type)"
  type        = string
  default     = "us-east-1a"
}

variable "secondary_az" {
  description = "Second AZ for ALB (requires min 2)"
  type        = string
  default     = "us-east-1b"
}

variable "instance_type" {
  description = "EC2 Mac instance type (mac2.metal, mac2-m2.metal, mac2-m2pro.metal)"
  type        = string
  default     = "mac2.metal"
}

variable "hostname" {
  description = "Fully qualified hostname for the service (e.g. qrscanner.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the domain"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "private_key_path" {
  description = "Path to the private key file for SSH provisioning"
  type        = string
}

variable "wtqrk_user" {
  description = "Basic auth username (leave empty to disable auth)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "wtqrk_pass" {
  description = "Basic auth password (leave empty to disable auth)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_port" {
  description = "Port the QR scanner listens on"
  type        = number
  default     = 8080
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed SSH access to the instance (no default — must be explicitly set)"
  type        = list(string)
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
