# Security Group for EKS Cluster Control Plane
resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-sg-"
  description = "Security group for EKS cluster control plane"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

# Allow HTTPS from anywhere to cluster (for kubectl access)
resource "aws_security_group_rule" "cluster_ingress_workstation_https" {
  type              = "ingress"
  description       = "Allow workstation to communicate with the cluster API Server"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

# Allow all outbound traffic from cluster
resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  description       = "Allow all outbound traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

# Security Group for EKS Worker Nodes
resource "aws_security_group" "nodes" {
  name_prefix = "${var.cluster_name}-nodes-sg-"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name                                        = "${var.cluster_name}-nodes-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Allow nodes to communicate with each other
resource "aws_security_group_rule" "nodes_internal" {
  type                     = "ingress"
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id
}

# Allow worker nodes to receive traffic from cluster control plane
resource "aws_security_group_rule" "nodes_cluster_ingress" {
  type                     = "ingress"
  description              = "Allow worker Kubelets and pods to receive communication from cluster control plane"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.cluster.id
}

# Allow cluster control plane to communicate with worker nodes
resource "aws_security_group_rule" "cluster_ingress_nodes_https" {
  type                     = "ingress"
  description              = "Allow pods to communicate with cluster API Server"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.nodes.id
}

# Allow all outbound traffic from nodes
resource "aws_security_group_rule" "nodes_egress_all" {
  type              = "egress"
  description       = "Allow all outbound traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nodes.id
}
