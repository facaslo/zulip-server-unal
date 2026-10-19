# ============================================================
# Módulo genérico: un componente del sistema desplegado como
# contenedor en GKE. Equivale a uno de los docker-compose.yml
# de deploy/ (imagen, comando, variables, volumen, healthcheck
# y puerto publicado).
# ============================================================
locals {
  labels = merge(var.labels, { app = var.name })
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "${var.name}-env"
    namespace = var.namespace
    labels    = local.labels
  }

  data = var.secret_env
}

resource "kubernetes_persistent_volume_claim_v1" "this" {
  count = var.volume == null ? 0 : 1

  metadata {
    name      = "${var.name}-data"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = var.volume.size
      }
    }
  }

  # GKE crea el disco recién cuando el Pod lo monta
  # (WaitForFirstConsumer); no hay que esperar al bind aquí.
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = var.name }
    }

    # Un disco ReadWriteOnce solo se puede montar en un Pod a la vez.
    strategy {
      type = var.volume == null ? "RollingUpdate" : "Recreate"
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Fuerza un rollout cuando cambian las credenciales.
          "checksum/secret" = sha256(jsonencode(var.secret_env))
        }
      }

      spec {
        automount_service_account_token = false

        dynamic "init_container" {
          for_each = var.init_args == null ? [] : [var.init_args]

          content {
            name  = "${var.name}-init"
            image = var.image
            args  = init_container.value

            dynamic "env" {
              for_each = var.env
              content {
                name  = env.key
                value = env.value
              }
            }

            env_from {
              secret_ref {
                name = kubernetes_secret_v1.this.metadata[0].name
              }
            }

            dynamic "volume_mount" {
              for_each = var.volume == null ? [] : [var.volume]
              content {
                name       = "data"
                mount_path = volume_mount.value.mount_path
              }
            }
          }
        }

        container {
          name    = var.name
          image   = var.image
          command = var.command
          args    = var.args

          port {
            container_port = var.port
          }

          dynamic "env" {
            for_each = var.env
            content {
              name  = env.key
              value = env.value
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.this.metadata[0].name
            }
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          dynamic "volume_mount" {
            for_each = var.volume == null ? [] : [var.volume]
            content {
              name       = "data"
              mount_path = volume_mount.value.mount_path
            }
          }

          # El healthcheck del compose se usa como startup probe
          # (tolera arranques lentos) y como readiness probe.
          startup_probe {
            failure_threshold = var.probe.startup_failure_threshold
            period_seconds    = 10
            timeout_seconds   = 5

            dynamic "exec" {
              for_each = var.probe.exec == null ? [] : [var.probe.exec]
              content {
                command = exec.value
              }
            }

            dynamic "tcp_socket" {
              for_each = var.probe.tcp ? [var.port] : []
              content {
                port = tcp_socket.value
              }
            }

            dynamic "http_get" {
              for_each = var.probe.http_path == null ? [] : [var.probe.http_path]
              content {
                path   = http_get.value
                port   = var.port
                scheme = var.probe.http_scheme
              }
            }
          }

          readiness_probe {
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 5

            dynamic "exec" {
              for_each = var.probe.exec == null ? [] : [var.probe.exec]
              content {
                command = exec.value
              }
            }

            dynamic "tcp_socket" {
              for_each = var.probe.tcp ? [var.port] : []
              content {
                port = tcp_socket.value
              }
            }

            dynamic "http_get" {
              for_each = var.probe.http_path == null ? [] : [var.probe.http_path]
              content {
                path   = http_get.value
                port   = var.port
                scheme = var.probe.http_scheme
              }
            }
          }
        }

        dynamic "volume" {
          for_each = var.volume == null ? [] : [var.volume]
          content {
            name = "data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.this[0].metadata[0].name
            }
          }
        }
      }
    }
  }

  wait_for_rollout = var.wait_for_rollout
}

# El Service da un nombre DNS estable (p. ej. "postgres") que
# reemplaza a host.docker.internal de los .env de deploy/.
resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    type             = var.service_type
    load_balancer_ip = var.load_balancer_ip
    selector         = { app = var.name }

    port {
      port        = var.port
      target_port = var.port
    }
  }
}

# Solo los Pods listados en allowed_clients pueden abrir
# conexiones a este componente (flechas del diagrama).
resource "kubernetes_network_policy_v1" "this" {
  count = var.allowed_clients == null ? 0 : 1

  metadata {
    name      = "${var.name}-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { app = var.name }
    }

    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = var.port
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.allowed_clients
        content {
          pod_selector {
            match_labels = { app = from.value }
          }
        }
      }
    }
  }
}
