# ============================================================
# Detección de caídas desde fuera del clúster. Las métricas de los
# SLI las reporta Zulip y las alertas las evalúa Grafana, así que
# ninguna de las dos avisa si se cae Zulip o el clúster completo.
# La sonda, la alerta y el correo corren en Cloud Monitoring.
# ============================================================
resource "google_monitoring_uptime_check_config" "zulip" {
  project      = var.project_id
  display_name = "${var.name} sitio público"
  period       = "300s"
  timeout      = "10s"

  # "/" pasa por el balanceador, nginx, Django y PostgreSQL, y genera
  # solo 2 spans por sonda; /login/ genera 27. Responde con una
  # redirección a /login/, que las sondas no siguen.
  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = false

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_3XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.uptime_check_host
    }
  }
}

resource "google_monitoring_notification_channel" "outage_email" {
  project      = var.project_id
  display_name = "${var.name} caídas"
  type         = "email"
  labels = {
    email_address = var.outage_alert_email
  }
}

resource "google_monitoring_alert_policy" "zulip_down" {
  project               = var.project_id
  display_name          = "${var.name} no responde"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.outage_email.name]

  # Exige que falle más de una región, para no alertar por un problema
  # de red de una sola sonda.
  conditions {
    display_name = "La sonda falla desde más de una región"

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.zulip.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "60s"

      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "El sitio público de Zulip no responde desde más de una región. Revisa el Pod de Zulip, el balanceador y el estado del clúster."
  }
}
