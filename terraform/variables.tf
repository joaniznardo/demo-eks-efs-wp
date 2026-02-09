variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nom del cluster EKS"
  type        = string
  default     = "wordpress-eks"
}

variable "eks_version" {
  description = "Versio de Kubernetes per EKS"
  type        = string
  default     = "1.31"
}
