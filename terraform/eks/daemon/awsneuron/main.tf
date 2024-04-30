// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

module "common" {
  source             = "../../../common"
  cwagent_image_repo = var.cwagent_image_repo
  cwagent_image_tag  = var.cwagent_image_tag
}

module "basic_components" {
  source = "../../../basic_components"

  region = var.region
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

resource "aws_eks_cluster" "this" {
  name     = "cwagent-eks-integ-neuron-3"
  role_arn = module.basic_components.role_arn
  version  = var.k8s_version
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
  vpc_config {
    subnet_ids         = module.basic_components.public_subnet_ids
    security_group_ids = [module.basic_components.security_group]
  }
}

# EKS Node Groups
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "cwagent-eks-integ-node"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = module.basic_components.public_subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  disk_size      = 20
  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_CloudWatchAgentServerPolicy
  ]
}

# EKS Node IAM Role
resource "aws_iam_role" "node_role" {
  name = "cwagent-eks-Worker-Role-${module.common.testing_id}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_CloudWatchAgentServerPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.node_role.name
}

# TODO: these security groups be created once and then reused
# EKS Cluster Security Group
resource "aws_security_group" "eks_cluster_sg" {
  name        = "cwagent-eks-cluster-sg-${module.common.testing_id}"
  description = "Cluster communication with worker nodes"
  vpc_id      = module.basic_components.vpc_id
}

resource "aws_security_group_rule" "cluster_inbound" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster_outbound" {
  description              = "Allow cluster API Server to communicate with the worker nodes"
  from_port                = 1024
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 65535
  type                     = "egress"
}


# EKS Node Security Group
resource "aws_security_group" "eks_nodes_sg" {
  name        = "cwagent-eks-node-sg-${module.common.testing_id}"
  description = "Security group for all nodes in the cluster"
  vpc_id      = module.basic_components.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "nodes_internal" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_cluster_inbound" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  to_port                  = 65535
  type                     = "ingress"
}


# create cert for communication between agent and neuron monitor
resource "tls_private_key" "private_key" {
  algorithm = "RSA"
}

resource "local_file" "ca_key" {
  content  = tls_private_key.private_key.private_key_pem
  filename = "${path.module}/certs/ca.key"
}

resource "tls_self_signed_cert" "ca_cert" {
  private_key_pem   = tls_private_key.private_key.private_key_pem
  is_ca_certificate = true
  subject {
    common_name  = "neuron-monitor-service.amazon-cloudwatch.svc"
    organization = "Amazon CloudWatch Agent"
  }
  validity_period_hours = 24
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "cert_signing",
    "crl_signing",
    "server_auth",
    "client_auth",
  ]
}

resource "local_file" "ca_cert_file" {
  content  = tls_self_signed_cert.ca_cert.cert_pem
  filename = "${path.module}/certs/ca.cert"
}

resource "tls_private_key" "server_private_key" {
  algorithm = "RSA"
}

resource "local_file" "server_key" {
  content  = tls_private_key.server_private_key.private_key_pem
  filename = "${path.module}/certs/server.key"
}

resource "tls_cert_request" "local_csr" {
  private_key_pem = tls_private_key.server_private_key.private_key_pem
  dns_names       = ["localhost", "127.0.0.1", "neuron-monitor-service.amazon-cloudwatch.svc"]
  subject {
    common_name  = "neuron-monitor-service.amazon-cloudwatch.svc"
    organization = "Amazon CloudWatch Agent"
  }
}

resource "tls_locally_signed_cert" "server_cert" {
  cert_request_pem      = tls_cert_request.local_csr.cert_request_pem
  ca_private_key_pem    = tls_private_key.private_key.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca_cert.cert_pem
  validity_period_hours = 12
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

resource "local_file" "server_cert_file" {
  content  = tls_locally_signed_cert.server_cert.cert_pem
  filename = "${path.module}/certs/server.cert"
}

resource "kubernetes_secret" "agent_cert" {
  metadata {
    name      = "amazon-cloudwatch-observability-agent-cert"
    namespace = "amazon-cloudwatch"
  }
  data = {
    "ca.crt"  = tls_self_signed_cert.ca_cert.cert_pem              #filebase64(local_file.ca_cert_file.filename)
    "tls.crt" = tls_locally_signed_cert.server_cert.cert_pem       #filebase64(local_file.server_cert_file.filename)
    "tls.key" = tls_private_key.server_private_key.private_key_pem #filebase64(local_file.server_key.filename)
  }
}


resource "kubernetes_namespace" "namespace" {
  metadata {
    name = "amazon-cloudwatch"
  }
}

# dummy daemonset that simulates neuron-monitor assuming there is only 1 node
resource "kubernetes_daemonset" "exporter" {
  depends_on = [
    kubernetes_namespace.namespace,
    kubernetes_service_account.cwagentservice,
    aws_eks_node_group.this,
    kubernetes_config_map.httpdconfig,
  ]
  metadata {
    name      = "neuron-monitor"
    namespace = "amazon-cloudwatch"
    labels = {
      k8s-app = "neuron-monitor"
    }
  }
  spec {
    selector {
      match_labels = {
        "k8s-app" = "neuron-monitor"
      }
    }
    template {
      metadata {
        labels = {
          "name" : "neuron-monitor"
          "k8s-app" : "neuron-monitor"
        }
      }
      spec {
        node_selector = {
          "kubernetes.io/os" : "linux"
        }
        container {
          name  = "neuron-monitor"
          image = "httpd:2.4-alpine"
          resources {
            limits = {
              "cpu" : "50m",
              "memory" : "50Mi"
            }
            requests = {
              "cpu" : "50m",
              "memory" : "50Mi"
            }
          }
          port {
            name           = "metrics"
            container_port = 8000
            host_port      = 8000
            protocol       = "TCP"
          }
          command = [
            "/bin/sh",
            "-c",
          ]
          args = [
           "/bin/echo '# HELP execution_errors_total Execution errors total\n# TYPE execution_errors_total counter\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"generic\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"numerical\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"transient\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"model\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"runtime\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_errors_total{availability_zone=\"us-west-2c\",error_type=\"hardware\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\n# HELP execution_status_total Execution status total\n# TYPE execution_status_total counter\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"completed\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"completed_with_err\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"completed_with_num_err\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"timed_out\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"incorrect_input\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nexecution_status_total{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",runtime_tag=\"367\",status_type=\"failed_to_queue\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\n# HELP neuron_runtime_memory_used_bytes Runtime memory used bytes\n# TYPE neuron_runtime_memory_used_bytes gauge\nneuron_runtime_memory_used_bytes{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"host\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 7.7488128e+07\nneuron_runtime_memory_used_bytes{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"neuron_device\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 3.4291933568e+010\n# HELP neuroncore_memory_usage_constants NeuronCore memory utilization for constants\n# TYPE neuroncore_memory_usage_constants gauge\nneuroncore_memory_usage_constants{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 3.462272e+08\nneuroncore_memory_usage_constants{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 3.462272e+08\n# HELP neuroncore_memory_usage_model_code NeuronCore memory utilization for model_code\n# TYPE neuroncore_memory_usage_model_code gauge\nneuroncore_memory_usage_model_code{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 1.82208784e+08\nneuroncore_memory_usage_model_code{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 1.82208784e+08\n# HELP neuroncore_memory_usage_model_shared_scratchpad NeuronCore memory utilization for model_shared_scratchpad\n# TYPE neuroncore_memory_usage_model_shared_scratchpad gauge\nneuroncore_memory_usage_model_shared_scratchpad{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 5.36870912e+08\nneuroncore_memory_usage_model_shared_scratchpad{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 5.36870912e+08\n# HELP neuroncore_memory_usage_runtime_memory NeuronCore memory utilization for runtime_memory\n# TYPE neuroncore_memory_usage_runtime_memory gauge\nneuroncore_memory_usage_runtime_memory{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nneuroncore_memory_usage_runtime_memory{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\n# HELP neuroncore_memory_usage_tensors NeuronCore memory utilization for tensors\n# TYPE neuroncore_memory_usage_tensors gauge\nneuroncore_memory_usage_tensors{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 6.315872e+06\nneuroncore_memory_usage_tensors{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",memory_location=\"None\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 6.315872e+06\n# HELP neuroncore_utilization_ratio NeuronCore utilization ratio\n# TYPE neuroncore_utilization_ratio gauge\nneuroncore_utilization_ratio{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",neuroncore=\"0\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\nneuroncore_utilization_ratio{PodName=\"pod1\",ContainerName=\"container1\",availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",neuroncore=\"1\",region=\"us-west-2\",runtime_tag=\"367\",subnet_id=\"subnet-06a7754948e8a000f\"} 10.0\n# HELP instance_info EC2 instance information\n# TYPE instance_info counter\ninstance_info{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",region=\"us-west-2\",subnet_id=\"subnet-06a7754948e8a000f\"} 1.0\n# HELP neuron_hardware Neuron Hardware Information\n# TYPE neuron_hardware counter\nneuron_hardware{availability_zone=\"us-west-2c\",instance_id=\"i-09db9b55e0095612f\",instance_name=\"\",instance_type=\"trn1.2xlarge\",neuron_device_count=\"1\",neuroncore_per_device_count=\"2\",region=\"us-west-2\",subnet_id=\"subnet-06a7754948e8a000f\"} 1.0' >> /usr/local/apache2/htdocs/metrics && httpd-foreground -k restart"
          ]
          volume_mount {
            mount_path = "/etc/amazon-cloudwatch-observability-neuron-cert"
            name       = "neurontls"
            read_only  = true
          }
          volume_mount {
            mount_path = "/usr/local/apache2/conf/httpd.conf"
            sub_path   = "httpd.conf"
            name       = "httpdconfig"
            read_only  = true
          }
          volume_mount {
            mount_path = "/usr/local/apache2/conf/extra/httpd-ssl.conf"
            sub_path   = "httpd-ssl.conf"
            name       = "httpdconfig"
            read_only  = true
          }
          env {
            name = "HOST_IP"
            value_from {
              field_ref {
                field_path = "status.hostIP"
              }
            }
          }
          env {
            name = "HOST_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "K8S_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
        }
        volume {
          name = "neurontls"
          secret {
            secret_name = "amazon-cloudwatch-observability-agent-cert"
            items {
              key  = "tls.crt"
              path = "server.crt"
            }
            items {
              key  = "tls.key"
              path = "server.key"
            }
          }
        }
        volume {
          name = "httpdconfig"
          config_map {
            name = "httpdconfig"
          }
        }
        service_account_name             = "cloudwatch-agent"
        termination_grace_period_seconds = 60
      }
    }
  }
}

resource "kubernetes_service" "exporter" {
  depends_on = [
    kubernetes_namespace.namespace,
    kubernetes_service_account.cwagentservice,
    aws_eks_node_group.this,
    kubernetes_daemonset.exporter
  ]
  metadata {
    name      = "neuron-monitor-service"
    namespace = "amazon-cloudwatch"
    labels = {
      "k8s-app" : "neuron-monitor-service"
    }
    annotations = {
      "prometheus.io/scrape" : "true"
    }
  }
  spec {
    type = "ClusterIP"
    selector = {
      k8s-app = "neuron-monitor"
    }
    port {
      name        = "metrics"
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_daemonset" "service" {
  depends_on = [
    kubernetes_namespace.namespace,
    kubernetes_service_account.cwagentservice,
    aws_eks_node_group.this,
    kubernetes_service.exporter
  ]
  metadata {
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }
  spec {
    selector {
      match_labels = {
        "name" : "cloudwatch-agent"
      }
    }
    template {
      metadata {
        labels = {
          "name" : "cloudwatch-agent"
        }
      }
      spec {
        node_selector = {
          "kubernetes.io/os" : "linux"
        }
        container {
          name              = "cwagent"
          image             = "${var.cwagent_image_repo}:${var.cwagent_image_tag}"
          image_pull_policy = "Always"
          resources {
            limits = {
              "cpu" : "200m",
              "memory" : "200Mi"
            }
            requests = {
              "cpu" : "200m",
              "memory" : "200Mi"
            }
          }
          port {
            container_port = 25888
            host_port      = 25888
            protocol       = "UDP"
          }
          env {
            name = "HOST_IP"
            value_from {
              field_ref {
                field_path = "status.hostIP"
              }
            }
          }
          env {
            name = "HOST_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "K8S_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          volume_mount {
            mount_path = "/etc/cwagentconfig"
            name       = "cwagentconfig"
          }
          volume_mount {
            mount_path = "/rootfs"
            name       = "rootfs"
            read_only  = true
          }
          volume_mount {
            mount_path = "/var/run/docker.sock"
            name       = "dockersock"
            read_only  = true
          }
          volume_mount {
            mount_path = "/var/lib/docker"
            name       = "varlibdocker"
            read_only  = true
          }
          volume_mount {
            mount_path = "/run/containerd/containerd.sock"
            name       = "containerdsock"
            read_only  = true
          }
          volume_mount {
            mount_path = "/sys"
            name       = "sys"
            read_only  = true
          }
          volume_mount {
            mount_path = "/dev/disk"
            name       = "devdisk"
            read_only  = true
          }
          volume_mount {
            mount_path = "/etc/amazon-cloudwatch-observability-agent-cert"
            name       = "agenttls"
            read_only  = true
          }
          volume_mount {
            mount_path = "/var/lib/kubelet/pod-resources"
            name       = "kubelet-podresources"
            read_only  = true
          }
        }
        volume {
          name = "cwagentconfig"
          config_map {
            name = "cwagentconfig"
          }
        }
        volume {
          name = "rootfs"
          host_path {
            path = "/"
          }
        }
        volume {
          name = "dockersock"
          host_path {
            path = "/var/run/docker.sock"
          }
        }
        volume {
          name = "varlibdocker"
          host_path {
            path = "/var/lib/docker"
          }
        }
        volume {
          name = "containerdsock"
          host_path {
            path = "/run/containerd/containerd.sock"
          }
        }
        volume {
          name = "sys"
          host_path {
            path = "/sys"
          }
        }
        volume {
          name = "devdisk"
          host_path {
            path = "/dev/disk"
          }
        }
        volume {
          name = "kubelet-podresources"
          host_path {
            path = "/var/lib/kubelet/pod-resources"
          }
        }
        volume {
          name = "agenttls"
          secret {
            secret_name = "amazon-cloudwatch-observability-agent-cert"
            items {
              key  = "ca.crt"
              path = "tls-ca.crt"
            }
          }
        }
        service_account_name             = "cloudwatch-agent"
        termination_grace_period_seconds = 60
      }
    }
  }
}

##########################################
# Template Files
##########################################
locals {
  httpd_config     = "../../../../${var.test_dir}/resources/httpd.conf"
  httpd_ssl_config = "../../../../${var.test_dir}/resources/httpd-ssl.conf"
  cwagent_config   = fileexists("../../../../${var.test_dir}/resources/config.json") ? "../../../../${var.test_dir}/resources/config.json" : "../default_resources/default_amazon_cloudwatch_agent.json"
}

data "template_file" "cwagent_config" {
  template = file(local.cwagent_config)
  vars = {
  }
}

resource "kubernetes_config_map" "cwagentconfig" {
  depends_on = [
    kubernetes_namespace.namespace,
    kubernetes_service_account.cwagentservice
  ]
  metadata {
    name      = "cwagentconfig"
    namespace = "amazon-cloudwatch"
  }
  data = {
    "cwagentconfig.json" : data.template_file.cwagent_config.rendered
  }
}

data "template_file" "httpd_config" {
  template = file(local.httpd_config)
  vars     = {}
}
data "template_file" "httpd_ssl_config" {
  template = file(local.httpd_ssl_config)
  vars     = {}
}

resource "kubernetes_config_map" "httpdconfig" {
  depends_on = [
    kubernetes_namespace.namespace,
    kubernetes_service_account.cwagentservice
  ]
  metadata {
    name      = "httpdconfig"
    namespace = "amazon-cloudwatch"
  }
  data = {
    "httpd.conf" : data.template_file.httpd_config.rendered
    "httpd-ssl.conf" : data.template_file.httpd_ssl_config.rendered
  }
}

resource "kubernetes_service_account" "cwagentservice" {
  depends_on = [kubernetes_namespace.namespace]
  metadata {
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }
}

resource "kubernetes_cluster_role" "clusterrole" {
  depends_on = [kubernetes_namespace.namespace]
  metadata {
    name = "cloudwatch-agent-role"
  }
  rule {
    verbs      = ["get", "list", "watch"]
    resources  = ["pods", "pods/logs", "nodes", "nodes/proxy", "namespaces", "endpoints"]
    api_groups = [""]
  }
  rule {
    verbs      = ["list", "watch"]
    resources  = ["replicasets"]
    api_groups = ["apps"]
  }
  rule {
    verbs      = ["list", "watch"]
    resources  = ["jobs"]
    api_groups = ["batch"]
  }
  rule {
    verbs      = ["get"]
    resources  = ["nodes/proxy"]
    api_groups = [""]
  }
  rule {
    verbs      = ["create"]
    resources  = ["nodes/stats", "configmaps", "events"]
    api_groups = [""]
  }
  rule {
    verbs          = ["get", "update"]
    resource_names = ["cwagent-clusterleader"]
    resources      = ["configmaps"]
    api_groups     = [""]
  }
  rule {
    verbs      = ["list", "watch"]
    resources  = ["services"]
    api_groups = [""]
  }
  rule {
    non_resource_urls = ["/metrics"]
    verbs             = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "rolebinding" {
  depends_on = [kubernetes_namespace.namespace]
  metadata {
    name = "cloudwatch-agent-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cloudwatch-agent-role"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cloudwatch-agent"
    namespace = "amazon-cloudwatch"
  }
}

resource "null_resource" "validator" {
  depends_on = [
    aws_eks_node_group.this,
    kubernetes_daemonset.service,
    kubernetes_cluster_role_binding.rolebinding,
    kubernetes_service_account.cwagentservice,
  ]
  provisioner "local-exec" {
    command = <<-EOT
      echo "Validating EKS metrics/logs for EMF"
      cd ../../../..
      go test ${var.test_dir} -eksClusterName=${aws_eks_cluster.this.name} -computeType=EKS -v -eksDeploymentStrategy=DAEMON -eksGpuType=nvidia
    EOT
  }
}