from collections.abc import Iterator
from contextlib import contextmanager
from unittest.mock import MagicMock, patch

import pika.exceptions
from django.db import connection
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.sdk.trace.sampling import ALWAYS_ON
from opentelemetry.trace import StatusCode
from psycopg2.sql import SQL

from zerver.lib import tracing
from zerver.lib.queue import SimpleQueueClient
from zerver.lib.test_classes import ZulipTestCase
from zerver.lib.tracing import (
    NoOrphanClientSpansSampler,
    add_sql_tracing,
    continue_trace,
    get_trace_context,
    trace_sql,
)


class TracingTest(ZulipTestCase):
    @contextmanager
    def capture_spans(self) -> Iterator[InMemorySpanExporter]:
        # The global tracer provider can only be set once per process,
        # so the tests swap in a tracer from a provider of their own.
        exporter = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        with patch("zerver.lib.tracing.tracer", provider.get_tracer("test")):
            yield exporter

    def test_sql_spans(self) -> None:
        with (
            self.capture_spans() as exporter,
            connection.execute_wrapper(trace_sql),
            connection.cursor() as cursor,
        ):
            cursor.execute("SELECT 1")
            cursor.execute(SQL("SELECT 2"))

        [plain, composed] = exporter.get_finished_spans()
        self.assertEqual(plain.name, "SELECT")
        assert plain.attributes is not None
        self.assertEqual(plain.attributes["db.query.text"], "SELECT 1")
        self.assertEqual(plain.attributes["db.operation.name"], "SELECT")
        self.assertEqual(composed.name, "SQL")
        assert composed.attributes is not None
        self.assertNotIn("db.query.text", composed.attributes)

    def test_add_sql_tracing_once(self) -> None:
        with patch.object(connection, "execute_wrappers", []):
            add_sql_tracing(connection)
            add_sql_tracing(connection)
            self.assertEqual(connection.execute_wrappers, [trace_sql])

    def test_orphan_client_spans_are_dropped(self) -> None:
        sampler = NoOrphanClientSpansSampler(ALWAYS_ON)
        self.assertIn("NoOrphanClientSpansSampler", sampler.get_description())
        exporter = InMemorySpanExporter()
        provider = TracerProvider(sampler=sampler)
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        tracer = provider.get_tracer("test")

        with tracer.start_as_current_span("SELECT", kind=trace.SpanKind.CLIENT):
            pass
        self.assertEqual(exporter.get_finished_spans(), ())

        with (
            tracer.start_as_current_span("POST /messages", kind=trace.SpanKind.SERVER),
            tracer.start_as_current_span("SELECT", kind=trace.SpanKind.CLIENT),
        ):
            pass
        self.assertEqual(
            [span.name for span in exporter.get_finished_spans()], ["SELECT", "POST /messages"]
        )

    def test_orphan_publish_spans_are_dropped(self) -> None:
        exporter = InMemorySpanExporter()
        provider = TracerProvider(sampler=NoOrphanClientSpansSampler(ALWAYS_ON))
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        tracer = provider.get_tracer("test")

        with tracer.start_as_current_span("publish events", kind=trace.SpanKind.PRODUCER):
            pass
        self.assertEqual(exporter.get_finished_spans(), ())

        with (
            tracer.start_as_current_span("POST /messages", kind=trace.SpanKind.SERVER),
            tracer.start_as_current_span("publish events", kind=trace.SpanKind.PRODUCER),
        ):
            pass
        self.assertEqual(
            [span.name for span in exporter.get_finished_spans()],
            ["publish events", "POST /messages"],
        )

    def test_publish_span(self) -> None:
        client = MagicMock()
        with self.capture_spans() as exporter:
            SimpleQueueClient.json_publish(client, "notify_tornado", {"event": "message"})

        client.publish.assert_called_once()
        client._reconnect.assert_not_called()
        [span] = exporter.get_finished_spans()
        self.assertEqual(span.name, "publish notify_tornado")
        self.assertEqual(span.kind, trace.SpanKind.PRODUCER)
        self.assertEqual(span.status.status_code, StatusCode.UNSET)
        assert span.attributes is not None
        self.assertEqual(span.attributes["messaging.system"], "rabbitmq")
        self.assertEqual(span.attributes["messaging.destination.name"], "notify_tornado")
        self.assertNotIn("error.type", span.attributes)

    def test_publish_span_covers_successful_retry(self) -> None:
        client = MagicMock()
        client.publish.side_effect = [pika.exceptions.AMQPConnectionError(), None]
        with self.capture_spans() as exporter:
            SimpleQueueClient.json_publish(client, "notify_tornado", {"event": "message"})

        client._reconnect.assert_called_once()
        [span] = exporter.get_finished_spans()
        self.assertEqual(span.status.status_code, StatusCode.UNSET)
        assert span.attributes is not None
        self.assertNotIn("error.type", span.attributes)

    def test_publish_span_records_failure(self) -> None:
        client = MagicMock()
        client.publish.side_effect = pika.exceptions.AMQPConnectionError()
        with (
            self.capture_spans() as exporter,
            self.assertRaises(pika.exceptions.AMQPConnectionError),
        ):
            SimpleQueueClient.json_publish(client, "notify_tornado", {"event": "message"})

        [span] = exporter.get_finished_spans()
        self.assertEqual(span.status.status_code, StatusCode.ERROR)
        assert span.attributes is not None
        self.assertEqual(span.attributes["error.type"], "AMQPConnectionError")

    def test_untraced_notification(self) -> None:
        self.assertEqual(get_trace_context(), {})

        with (
            self.capture_spans() as exporter,
            continue_trace("process_notification", {}, {"zulip.event.type": "message"}),
        ):
            pass

        self.assertEqual(exporter.get_finished_spans(), ())

    def test_notification_continues_request_trace(self) -> None:
        with self.capture_spans() as exporter:
            with tracing.tracer.start_as_current_span("POST /messages"):
                trace_context = get_trace_context()
            self.assertIn("traceparent", trace_context)

            with continue_trace(
                "process_notification", trace_context, {"zulip.event.type": "message"}
            ):
                pass

        [request, notification] = exporter.get_finished_spans()
        self.assertEqual(notification.name, "process_notification")
        self.assertEqual(notification.kind, trace.SpanKind.CONSUMER)
        assert notification.attributes is not None
        self.assertEqual(notification.attributes["zulip.event.type"], "message")
        assert notification.parent is not None
        assert request.context is not None and notification.context is not None
        self.assertEqual(notification.parent.span_id, request.context.span_id)
        self.assertEqual(notification.context.trace_id, request.context.trace_id)
