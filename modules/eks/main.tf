# Security Group for EKS Cluster
resource "aws_security_group" "eks_sg" {
  name        = "${var.cluster_name}-sg"
  description = "Security group for EKS cluster and node groups"
  vpc_id      = var.vpc_id

  # Allow all traffic within the same security group
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow all traffic within the same security group"
  }
  
  # Allow inbound traffic on port 443 from VPN security group
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.vpn_sg_id]
    description     = "Allow HTTPS traffic from VPN"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "${var.cluster_name}-sg"
    Environment = "DevTest"
  }
}

# IAM Role for EKS Cluster - Only created if not using existing roles
resource "aws_iam_role" "eks_cluster_role" {
  count = var.use_existing_roles ? 0 : 1
  
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  count = var.use_existing_roles ? 0 : 1
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role[0].name
}

locals {
  cluster_role_arn = var.use_existing_roles ? var.existing_cluster_role_name : aws_iam_role.eks_cluster_role[0].arn
  node_role_arn    = var.use_existing_roles ? var.existing_node_role_name : aws_iam_role.eks_node_group_role[0].arn
}

# EKS Cluster using existing roles
resource "aws_eks_cluster" "eks_cluster_with_existing_role" {
  count    = var.use_existing_roles ? 1 : 0
  
  name     = var.cluster_name
  role_arn = var.existing_cluster_role_name
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.eks_sg.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # Set standard support type instead of extended
  upgrade_policy {
    support_type = "STANDARD"
  }

  tags = {
    Name        = var.cluster_name
    Environment = "DevTest"
  }
}

# EKS Cluster creating new roles
resource "aws_eks_cluster" "eks_cluster_with_new_role" {
  count    = var.use_existing_roles ? 0 : 1
  
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role[0].arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.eks_sg.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # Set standard support type instead of extended
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy[0]
  ]

  tags = {
    Name        = var.cluster_name
    Environment = "DevTest"
  }
}

# Local to get the proper cluster output regardless of which resource was used
locals {
  cluster_name = var.use_existing_roles ? aws_eks_cluster.eks_cluster_with_existing_role[0].name : aws_eks_cluster.eks_cluster_with_new_role[0].name
  cluster_endpoint = var.use_existing_roles ? aws_eks_cluster.eks_cluster_with_existing_role[0].endpoint : aws_eks_cluster.eks_cluster_with_new_role[0].endpoint
  cluster_certificate_authority_data = var.use_existing_roles ? aws_eks_cluster.eks_cluster_with_existing_role[0].certificate_authority[0].data : aws_eks_cluster.eks_cluster_with_new_role[0].certificate_authority[0].data
}

# IAM Role for EKS Node Group - Only created if not using existing roles
resource "aws_iam_role" "eks_node_group_role" {
  count = var.use_existing_roles ? 0 : 1
  
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  count = var.use_existing_roles ? 0 : 1
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group_role[0].name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count = var.use_existing_roles ? 0 : 1
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group_role[0].name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  count = var.use_existing_roles ? 0 : 1
  
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group_role[0].name
}

# Node Group with existing IAM role
resource "aws_eks_node_group" "eks_node_group_existing_role" {
  count           = var.use_existing_roles ? 1 : 0
  
  cluster_name    = local.cluster_name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = var.existing_node_role_name
  subnet_ids      = var.subnet_ids

  instance_types = ["t3a.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name        = "${var.cluster_name}-node-group"
    Environment = "DevTest"
  }
}

# Node Group with new IAM role
resource "aws_eks_node_group" "eks_node_group_new_role" {
  count           = var.use_existing_roles ? 0 : 1
  
  cluster_name    = local.cluster_name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role[0].arn
  subnet_ids      = var.subnet_ids

  instance_types = ["t3a.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy[0],
    aws_iam_role_policy_attachment.eks_cni_policy[0],
    aws_iam_role_policy_attachment.eks_container_registry_policy[0]
  ]

  tags = {
    Name        = "${var.cluster_name}-node-group"
    Environment = "DevTest"
  }
} 