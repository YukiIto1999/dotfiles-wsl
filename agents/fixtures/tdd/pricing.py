from typing import Protocol


class FeePolicy(Protocol):
    def fee_for(self, account: dict[str, str]) -> int: ...


class Audit(Protocol):
    def record(self, account_id: str, result: dict[str, object]) -> None: ...


def charge(
    account: dict[str, str],
    fee_policy: FeePolicy,
    audit: Audit,
) -> dict[str, object]:
    if account["kind"] != "basic":
        raise ValueError("unsupported account kind")
    result: dict[str, object] = {"status": "charged", "amount": 100}
    audit.record(account["id"], result)
    return result
