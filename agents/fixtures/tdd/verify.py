import ast
import hashlib
import importlib
import inspect
import io
import unittest
from pathlib import Path

import pricing
import test_pricing


EXPECTED_BASIC_TEST = "70866a7aab7c4e702b370c34a422ad1dff7b42faf2d080e926ec6206278e1063"


class FixedFeePolicy:
    def fee_for(self, account: dict[str, str]) -> int:
        return 275


class TrackingFeePolicy:
    def __init__(self, value: int) -> None:
        self.value = value
        self.calls: list[str] = []

    def fee_for(self, account: dict[str, str]) -> int:
        self.calls.append(account["id"])
        return self.value


class RecordingAudit:
    def __init__(self) -> None:
        self.events: list[tuple[str, dict[str, object]]] = []

    def record(self, account_id: str, result: dict[str, object]) -> None:
        self.events.append((account_id, result))


def verify_case(kind: str, expected: dict[str, object]) -> None:
    audit = RecordingAudit()
    result = pricing.charge(
        {"id": f"{kind}-1", "kind": kind},
        FixedFeePolicy(),
        audit,
    )
    assert result == expected
    assert audit.events == [(f"{kind}-1", result)]


case_names = {"basic", "trial", "gold", "suspended"}
fixture_root = Path(__file__).parent
production_trees = [
    ast.parse(path.read_text())
    for path in fixture_root.glob("*.py")
    if path.name != "verify.py" and not path.name.startswith("test_")
]
protocol_names = {
    node.name
    for tree in production_trees
    for node in ast.walk(tree)
    if isinstance(node, ast.ClassDef)
    and any(ast.unparse(base).endswith("Protocol") for base in node.bases)
}
assert protocol_names == {"FeePolicy", "Audit"}, (
    f"production protocol set changed: {sorted(protocol_names)}"
)

charge_node = next(
    node
    for tree in production_trees
    for node in ast.walk(tree)
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "charge"
)
charge_cases = {
    node.value
    for node in ast.walk(charge_node)
    if isinstance(node, ast.Constant) and node.value in case_names
}
assert not charge_cases, f"public orchestration still owns pricing cases: {sorted(charge_cases)}"

decision_nodes = [
    node
    for tree in production_trees
    for node in ast.walk(tree)
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    and node.name != "charge"
    and {
        child.value
        for child in ast.walk(node)
        if isinstance(child, ast.Constant) and child.value in case_names
    }
]
owned_cases = {
    node.value
    for tree in production_trees
    for node in ast.walk(tree)
    if isinstance(node, ast.Constant) and node.value in case_names
}
assert owned_cases == case_names, f"pricing owner does not cover all cases: {sorted(owned_cases)}"
for node in decision_nodes:
    dependencies = {
        child.id.lower()
        for child in ast.walk(node)
        if isinstance(child, ast.Name)
    } | {
        child.attr.lower()
        for child in ast.walk(node)
        if isinstance(child, ast.Attribute)
    }
    assert "audit" not in dependencies and "record" not in dependencies, (
        f"pricing decision owns audit work: {node.name}"
    )

basic_test = inspect.getsource(test_pricing.ChargeTest.test_basic_account_is_charged_and_audited)
assert (
    hashlib.sha256(basic_test.encode()).hexdigest() == EXPECTED_BASIC_TEST
), "existing basic behavior test changed"
verify_case("basic", {"status": "charged", "amount": 100})
verify_case("trial", {"status": "charged", "amount": 0})
verify_case("gold", {"status": "charged", "amount": 275})
verify_case("suspended", {"status": "denied"})
for policy_value in (275, 410):
    policy = TrackingFeePolicy(policy_value)
    audit = RecordingAudit()
    result = pricing.charge(
        {"id": f"gold-{policy_value}", "kind": "gold"},
        policy,
        audit,
    )
    assert result == {"status": "charged", "amount": policy_value}
    assert policy.calls == [f"gold-{policy_value}"]
    assert audit.events == [(f"gold-{policy_value}", result)]

test_modules = [
    importlib.import_module(path.stem) for path in fixture_root.glob("test_*.py")
]
original_charge = pricing.charge
mutations = {
    "basic": ("amount", 101),
    "gold": ("amount", 276),
    "suspended": ("status", "charged"),
    "trial": ("amount", 1),
}
for mutated_case in sorted(case_names):
    def mutated_charge(
        account: dict[str, str],
        fee_policy: pricing.FeePolicy,
        audit: pricing.Audit,
        *,
        case: str = mutated_case,
    ) -> dict[str, object]:
        result = original_charge(account, fee_policy, audit)
        if account["kind"] == case:
            field, value = mutations[case]
            result[field] = value
        return result

    pricing.charge = mutated_charge
    replaced_bindings = []
    for module in test_modules:
        for name, value in list(vars(module).items()):
            if value is original_charge:
                setattr(module, name, mutated_charge)
                replaced_bindings.append((module, name, value))
    suite = unittest.defaultTestLoader.discover(fixture_root, pattern="test_*.py")
    mutation_result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    assert not mutation_result.wasSuccessful(), f"tests survived {mutated_case} behavior mutation"
    pricing.charge = original_charge
    for module, name, value in replaced_bindings:
        setattr(module, name, value)

suite = unittest.defaultTestLoader.discover(fixture_root, pattern="test_*.py")
result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
assert result.wasSuccessful(), "unmodified behavior tests failed"
