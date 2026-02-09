output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "efs_id" {
  description = "EFS File System ID - necessari per al StorageClass de Kubernetes"
  value       = aws_efs_file_system.main.id
}

output "configure_kubectl" {
  description = "Comanda per configurar kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "update_storageclass" {
  description = "Comanda per actualitzar el StorageClass amb el EFS ID"
  value       = "sed -i 's/__EFS_ID__/${aws_efs_file_system.main.id}/' ../k8s/02-storageclass.yaml"
}
