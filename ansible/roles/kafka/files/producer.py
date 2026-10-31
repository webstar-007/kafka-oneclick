"""Sends food-delivery order events to Kafka, one per second.
Keeps running through broker failures (retries) so it can be used in the failover demo."""
import json
import os
import time
from datetime import datetime, timezone

from kafka import KafkaProducer
from kafka.errors import KafkaError

BOOTSTRAP = os.environ["BOOTSTRAP_SERVERS"].split(",")
TOPIC = os.environ.get("TOPIC", "order-events-live")
INTERVAL = float(os.environ.get("INTERVAL", "1"))
STATUSES = ["created", "accepted", "preparing", "ready_for_pickup", "out_for_delivery", "delivered"]


def build_producer():
    while True:
        try:
            return KafkaProducer(
                bootstrap_servers=BOOTSTRAP,
                acks="all",              # wait for all in-sync replicas
                retries=10,
                retry_backoff_ms=500,
                key_serializer=lambda k: k.encode("utf-8"),
                value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            )
        except KafkaError as exc:
            print(f"waiting for Kafka: {exc}", flush=True)
            time.sleep(5)


def main():
    producer = build_producer()
    print(f"PRODUCER_STARTED topic={TOPIC} brokers={BOOTSTRAP}", flush=True)
    seq, order = 0, 1
    while True:
        order_id = f"order-{order:05d}"
        for step, status in enumerate(STATUSES, start=1):
            seq += 1
            event = {
                "order_id": order_id,
                "status": status,
                "status_step": step,
                "event_time": datetime.now(timezone.utc).isoformat(),
            }
            try:
                meta = producer.send(TOPIC, key=order_id, value=event).get(timeout=30)
                print(f"PRODUCED seq={seq} order={order_id} status={status} "
                      f"partition={meta.partition} offset={meta.offset}", flush=True)
            except KafkaError as exc:
                print(f"SEND_FAILED seq={seq}: {exc}", flush=True)
            time.sleep(INTERVAL)
        order += 1


if __name__ == "__main__":
    main()
