import asyncio
import hashlib
import io
import json
from pathlib import Path
import zipfile

from memory import Client, LEGACY_BANK, MemoryFailure, SENSITIVE, canonical, digest


def load_export(source: str, expected_sha256: str) -> list[dict]:
    try:
        raw = Path(source).read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected_sha256:
            raise MemoryFailure("migration_source_changed", "export checksum differs from the approved snapshot")
        exported = json.loads(raw)
    except (OSError, ValueError):
        raise MemoryFailure("invalid_input", "legacy export cannot be read") from None
    if not isinstance(exported, dict) or not isinstance(exported.get("memories"), list):
        raise MemoryFailure("invalid_input", "source is not an AgentMemory export")
    if exported.get("sessions") != []:
        raise MemoryFailure("migration_source_changed", "source has session records outside the approved memory-only snapshot")
    records = exported["memories"]
    identifiers = set()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("id"), str) or not record["id"]:
            raise MemoryFailure("invalid_input", "legacy record has no stable ID")
        if record["id"] in identifiers:
            raise MemoryFailure("invalid_input", "legacy export contains duplicate IDs")
        identifiers.add(record["id"])
        if not isinstance(record.get("content"), str) or not record["content"].strip():
            raise MemoryFailure("invalid_input", "legacy record has no searchable content")
        if SENSITIVE.search(canonical(record)):
            raise MemoryFailure("privacy", "legacy export contains credential or personal-data indicators; not transmitted")
    return sorted(records, key=lambda record: record["id"])


def archive(records: list[dict]) -> bytes:
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.writestr("manifest.json", canonical({
            "schema_version": 1,
            "source_bank_id": LEGACY_BANK,
            "archive_type": "documents",
            "document_count": len(records),
            "fact_count": len(records),
            "observation_count": 0,
        }))
        for index, record in enumerate(records):
            original = canonical(record)
            metadata = {
                "legacy_id": record["id"],
                "legacy_version": str(record.get("version", "")),
                "source": "agentmemory-export",
                "source_sha256": digest(original),
                "admission": "historical-unverified",
            }
            document = {
                "id": record["id"],
                "original_text": original,
                "created_at": record.get("createdAt"),
                "retain_params": {"metadata": metadata},
                "tags": ["historical-unverified"],
                "chunks": [{"chunk_index": 0, "chunk_text": original}],
                "facts": [{
                    "text": record.get("title", "") + "\n" + record["content"],
                    "fact_type": "world",
                    "context": "Unverified legacy history without project identity; not current instructions or evidence",
                    "metadata": metadata,
                    "tags": ["historical-unverified"],
                    "observation_scopes": "shared",
                    "chunk_index": 0,
                    "mentioned_at": record.get("updatedAt"),
                    "created_at": record.get("createdAt"),
                }],
            }
            output.writestr(f"documents/{index:06d}.json", canonical(document))
    return stream.getvalue()


async def verify_import(client: Client, records: list[dict], source_sha256: str) -> dict:
    expected = {record["id"]: digest(canonical(record)) for record in records}
    identifiers = []
    while True:
        page = await client.request("GET", client.route(LEGACY_BANK, "/documents"), params={"limit": 100, "offset": len(identifiers)})
        if page.get("total") != len(expected) or not isinstance(page.get("items"), list):
            raise MemoryFailure("migration_not_verified", "destination document count differs from the source snapshot")
        identifiers.extend(item.get("id") for item in page["items"])
        if len(identifiers) >= len(expected):
            break
        if not page["items"]:
            raise MemoryFailure("migration_not_verified", "destination pagination ended before the expected count")
    if len(identifiers) != len(expected) or set(identifiers) != set(expected):
        raise MemoryFailure("migration_not_verified", "destination IDs differ from the source snapshot")
    for identifier, checksum in expected.items():
        document = await client.document(LEGACY_BANK, identifier)
        original = document.get("original_text")
        if not isinstance(original, str) or digest(original) != checksum or document.get("memory_unit_count") != 1:
            raise MemoryFailure("migration_not_verified", "a destination record differs from its source content or searchable fact count")
    configuration = await client.request("GET", client.route(LEGACY_BANK, "/config"))
    effective = configuration.get("config", {})
    if effective.get("enable_observations") is not False or effective.get("enable_auto_consolidation") is not False:
        raise MemoryFailure("migration_not_verified", "legacy history is not isolated from automatic consolidation")
    return {
        "state": "verified",
        "bank_id": LEGACY_BANK,
        "source_sha256": source_sha256,
        "record_count": len(expected),
        "ids_sha256": digest(canonical(sorted(expected))),
        "records_sha256": digest(canonical(expected)),
        "automatic_recall": False,
    }


async def migrate(client: Client, source: str, source_sha256: str, verify_only: bool) -> dict:
    records = load_export(source, source_sha256)
    async with asyncio.timeout(600):
        if not verify_only:
            await client.configure(LEGACY_BANK, legacy=True)
            effective = await client.request("GET", client.route(LEGACY_BANK, "/config"))
            if any(effective.get("config", {}).get(key) is not False for key in ("enable_observations", "enable_auto_consolidation")):
                raise MemoryFailure("migration_not_verified", "legacy isolation was not acknowledged; import was not started")
            response = await client.request(
                "POST", client.route(LEGACY_BANK, "/transfer/import"),
                params={"mode": "merge", "document_conflict": "skip"},
                files={"file": ("agentmemory-history.zip", archive(records), "application/zip")},
            )
            operation_id = response.get("operation_id")
            if not isinstance(operation_id, str) or response.get("status") != "pending":
                raise MemoryFailure("protocol_error", "legacy import did not acknowledge a pending operation")
            while (await client.operation(LEGACY_BANK, operation_id))["status"] != "completed":
                await asyncio.sleep(1)
        return await verify_import(client, records, source_sha256)
