import unittest

from pricing import charge


class FixedFeePolicy:
    def fee_for(self, account: dict[str, str]) -> int:
        return 275


class RecordingAudit:
    def __init__(self) -> None:
        self.events: list[tuple[str, dict[str, object]]] = []

    def record(self, account_id: str, result: dict[str, object]) -> None:
        self.events.append((account_id, result))


class ChargeTest(unittest.TestCase):
    def test_basic_account_is_charged_and_audited(self) -> None:
        audit = RecordingAudit()

        result = charge(
            {"id": "basic-1", "kind": "basic"},
            FixedFeePolicy(),
            audit,
        )

        self.assertEqual({"status": "charged", "amount": 100}, result)
        self.assertEqual([("basic-1", result)], audit.events)


if __name__ == "__main__":
    unittest.main()
