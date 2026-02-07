variable "aws_region" {
  description = "The AWS region where the workstation will be deployed (e.g., us-east-1)."
  type        = string
  default     = "us-east-1" # We default to N. Virginia as it's usually cheapest for Spot/GPU.
}

variable "key_name" {
  description = "The name of the SSH Key Pair in AWS to allow login. (User must create this in AWS Console first!)."
  type        = string
}

variable "instance_type" {
  description = "The EC2 hardware type. Default is 'g4dn.xlarge' (NVIDIA T4 GPU)."
  type        = string
  default     = "g4dn.xlarge"
}

variable "project_name" {
  description = "Tag to identify resources in the AWS Console."
  type        = string
  default     = "Aerospace-CFD"
}

variable "student_id" {
  description = "Optional: A label to track which student owns this instance."
  type        = string
  default     = "Unknown-Student"
}