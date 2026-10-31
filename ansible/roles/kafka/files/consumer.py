"""Reads the order events and prints them. Uses a consumer group, so it remembers its position."""
import json
import os
import time

from kafka import KafkaConsumer
from kafka.errors import KafkaError

BOOTSTRAP = os.environ["BOOTSTRAP_SERVERS"].split(",")
TOPIC = os.environ.get("TOPIC", "order-events-live")
GROUP = os.environ.get("GROUP_ID", "order-processor")


def build_consumer():
    while True:
        try:
            return KafkaConsumer(
                TOPIC,
                bootstrap_servers=BOOTSTRAP,
                group_id=GROUP,
                auto_offset_reset="earliest",
                enable_auto_commit=True,
                value_deserializer=lambda v: json.loads(v.decode("utf-8")),
            )
        except KafkaError as exc:
            print(f"waiting for Kafka: {exc}", flush=True)
            time.sleep(5)


def main():
    consumer = build_consumer()
    print(f"CONSUMER_STARTED topic={TOPIC} group={GROUP}", flush=True)
    for msg in consumer:
        v = msg.value or {}
        print(f"CONSUMED partition={msg.partition} offset={msg.offset} "
              f"order={v.get('order_id')} status={v.get('status')}", flush=True)


if __name__ == "__main__":
    main()
