# ============================================================
# Toxiproxy, escenario 2 del GameDay: proxy TCP en espacio de
# usuario (sin privilegios especiales) entre Zulip y RabbitMQ,
# para inyectar retraso de red controlado vía su API HTTP de
# administracion (gameday/toxiproxy_toggle.py). Modulo dedicado
# y minimo, no una extension de k8s-service: ese modulo lo usan
# postgres/redis/memcached/rabbitmq/zulip y solo soporta un
# puerto por servicio; Toxiproxy necesita dos (proxy + admin) en
# el mismo Pod. Mismo criterio que modules/monitoring: lo que no
# encaja en el modelo de un-servicio-un-puerto va aparte, para no
# arriesgar el despliegue real de la app por una herramienta de
# demo de curso.
# ============================================================
locals {
  labels = merge(var.labels, { app = var.name })

  # Proxy "rabbitmq" definido desde el arranque (config inicial de
  # Toxiproxy), para que el puerto 5672 ya este disponible sin
  # necesidad de un paso manual de creacion antes de que Zulip
  # intente conectarse.
  proxy_config = jsonencode([
    {
      name     = "rabbitmq"
      listen   = "0.0.0.0:${var.proxy_port}"
      upstream = "${var.upstream_host}:${var.upstream_port}"
      enabled  = true
    }
  ])
}

resource "kubernetes_config_map_v1" "config" {
  metadata {
    name      = "${var.name}-config"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "toxiproxy.json" = local.proxy_config
  }
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

    template {
      metadata {
        labels = local.labels
        annotations = {
          "checksum/config" = sha256(local.proxy_config)
        }
      }

      spec {
        automount_service_account_token = false

        container {
          name  = var.name
          image = var.image
          args  = ["-host=0.0.0.0", "-config=/etc/toxiproxy/toxiproxy.json"]

          port {
            name           = "proxy"
            container_port = var.proxy_port
          }
          port {
            name           = "admin"
            container_port = var.admin_port
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          # El puerto admin siempre responde al arrancar, sin
          # depender de que exista ningun toxic activo.
          readiness_probe {
            tcp_socket {
              port = var.admin_port
            }
            period_seconds = 10
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/toxiproxy"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.config.metadata[0].name
          }
        }
      }
    }
  }
}

# El Service da el nombre DNS que Zulip usa en vez de hablarle
# directo a RabbitMQ (ver terraform/main.tf, SETTING_RABBITMQ_HOST).
resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = { app = var.name }

    port {
      name        = "proxy"
      port        = var.proxy_port
      target_port = var.proxy_port
    }
    port {
      name        = "admin"
      port        = var.admin_port
      target_port = var.admin_port
    }
  }
}

# Puerto proxy: solo Zulip puede conectarse (reemplaza el ingreso
# que antes tenia RabbitMQ directamente).
resource "kubernetes_network_policy_v1" "proxy_ingress" {
  metadata {
    name      = "${var.name}-proxy-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { app = var.name }
    }

    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = var.proxy_port
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.allowed_proxy_clients
        content {
          pod_selector {
            match_labels = { app = from.value }
          }
        }
      }
    }
  }
}

# Puerto admin: sin ingreso declarado a proposito. Se administra
# via `kubectl port-forward` durante la demo (gameday/toxiproxy_toggle.py),
# que pasa por el apiserver y no necesita abrir el puerto a ningun
# Pod ni a internet.
