"""Check the admission decision against the invariants it must keep, over many generated states.

The decision is a pure function of the request, the scopes that exist and the observation.  Each test states one
invariant in its own terms (what a running acceptance or capped scope can still claim, which class may be cancelled, what
the capped scopes have reserved of the CPU budget) and compares the decision with it; no expected value is computed with
the decision's own formula.
"""

import dataclasses
from pathlib import Path
import random
import sys
import unittest

sys.path.insert(0, str(Path(sys.argv.pop(1)).resolve()))
import admission  # noqa: E402

GIB = 1024 ** 3
CASES = 5000
SEED = 20261116
CAPPED = "capped"
# The classes whose running scopes may still grow into what they reserved, so that the room they claim is not free.
RESERVING = ("acceptance", CAPPED)


def generate(rng):
    """One state: the class, demand and CPU of the request, the scopes that run, the observation, and whether an acceptance waits."""
    scopes = []
    for index in range(rng.randrange(0, 5)):
        klass = rng.choice(admission.CLASSES)
        scopes.append(admission.Scope(klass=klass, unit=f"scope-{index}.scope", limit=rng.randrange(1, 10 * GIB),
                                      working_set=rng.randrange(0, 12 * GIB),
                                      cpu=rng.randrange(1, 600) if klass == CAPPED else 0))
    limits = tuple((f"/limit-{index}", rng.randrange(0, 20 * GIB)) for index in range(rng.randrange(0, 4)))
    # The decision takes the scopes with their usage already attached, so the observation carries none.
    observation = admission.Observation(host_headroom=rng.randrange(0, 40 * GIB), limits=limits, usage={})
    return {"klass": rng.choice(admission.CLASSES), "demand": rng.randrange(1, 12 * GIB), "scopes": scopes,
            "observation": observation, "acceptance_waiting": rng.random() < 0.3,
            "cpu_request": rng.randrange(1, 600), "cpu_budget": rng.randrange(1, 1200)}


def room(state):
    """What the request needs beyond what is in use now, if every running acceptance and capped scope grows to its reservation.

    A scope that already uses more than it reserved claims nothing further; one that uses less can still claim the rest.
    """
    claim = 0
    for scope in state["scopes"]:
        if scope.klass in RESERVING:
            claim += max(scope.limit, scope.working_set) - scope.working_set
    return state["demand"] + claim


def fits(state):
    """Whether the request, with what the running acceptances and capped runs may still claim, fits every free amount.

    The host-wide free amount and each cgroup limit's take the whole request.
    """
    observation = state["observation"]
    needed = room(state)
    return needed <= observation.host_headroom and all(needed <= headroom for _, headroom in observation.limits)


def cpu_fits(state):
    """Whether the CPU the request asks for, with what the capped scopes that run have reserved, stays within the budget."""
    reserved = sum(scope.cpu for scope in state["scopes"] if scope.klass == CAPPED)
    return state["cpu_request"] + reserved <= state["cpu_budget"]


def states():
    rng = random.Random(SEED)
    return (generate(rng) for _ in range(CASES))


def decide(state, **changes):
    return admission.decide(**{**state, **changes})


class AdmissionDecision(unittest.TestCase):
    def assert_state(self, state, message):
        return f"{message}: {state}"

    def test_i1_an_admitted_request_fits_with_everything_the_running_acceptances_and_capped_runs_may_still_claim(self):
        """I1: after the request is admitted, the acceptance and capped scopes together cannot outgrow any free amount."""
        for state in states():
            if decide(state).kind == admission.ADMIT:
                self.assertTrue(fits(state), self.assert_state(state, "overcommitted"))

    def test_i1_a_request_that_fits_and_breaks_no_class_rule_is_admitted(self):
        """The converse of I1: nothing but a class rule, a lack of room or of CPU budget refuses a request."""
        for state in states():
            blocked = state["klass"] == "deep" and (
                state["acceptance_waiting"] or any(scope.klass == "deep" for scope in state["scopes"]))
            fits_all = fits(state) and (state["klass"] != CAPPED or cpu_fits(state))
            if fits_all and not blocked:
                self.assertEqual(decide(state).kind, admission.ADMIT, self.assert_state(state, "refused without a reason"))

    def test_i2_an_acceptance_is_not_held_by_other_acceptances_that_wait(self):
        """I2: whether other acceptances wait does not enter the decision for an acceptance."""
        for state in states():
            state["klass"] = "acceptance"
            self.assertEqual(decide(state, acceptance_waiting=True), decide(state, acceptance_waiting=False))

    def test_i3_no_deep_request_is_admitted_or_allowed_to_cancel_while_an_acceptance_waits(self):
        """I3: a waiting acceptance keeps every deep request out, and a deep request never cancels anything."""
        for state in states():
            state["klass"] = "deep"
            state["acceptance_waiting"] = True
            self.assertEqual(decide(state).kind, admission.WAIT, self.assert_state(state, "a deep request got in"))

    def test_i4_only_an_acceptance_that_lacks_room_cancels_and_only_deep_scopes_are_cancelled(self):
        """I4: the cancellation is the answer to an acceptance without room while a deep scope exists, and only that."""
        for state in states():
            decision = decide(state)
            deep = [scope for scope in state["scopes"] if scope.klass == "deep"]
            lacks_room = not fits(state)
            expected = state["klass"] == "acceptance" and lacks_room and bool(deep)
            self.assertEqual(decision.kind == admission.CANCEL_DEEP, expected, self.assert_state(state, "wrong cancellation"))
            targets = admission.cancellable(state["scopes"])
            self.assertEqual(sorted(scope.unit for scope in targets), sorted(scope.unit for scope in deep))
            self.assertTrue(all(scope.klass == "deep" for scope in targets))

    def test_i5_a_deep_request_waits_for_the_deep_scope_that_runs(self):
        """I5: at most one deep scope exists, so a deep request waits while one does."""
        for state in states():
            state["klass"] = "deep"
            state["acceptance_waiting"] = False
            if any(scope.klass == "deep" for scope in state["scopes"]):
                self.assertEqual(decide(state).kind, admission.WAIT, self.assert_state(state, "a second deep scope"))

    def test_a_deep_scope_never_takes_room_from_an_acceptance(self):
        """Deep scopes are cancelled for room, so what they may still grow into is not held against an acceptance."""
        for state in states():
            state["klass"] = "acceptance"
            without_deep = {**state, "scopes": [scope for scope in state["scopes"] if scope.klass != "deep"]}
            self.assertEqual(decide(state).kind == admission.ADMIT, decide(without_deep).kind == admission.ADMIT)

    def test_more_demand_or_one_more_running_acceptance_never_turns_a_refusal_into_an_admission(self):
        """Monotonicity of I1: a larger request and a busier host can only make the decision stricter."""
        rng = random.Random(SEED + 1)
        for state in states():
            if decide(state).kind == admission.ADMIT:
                continue
            larger = {**state, "demand": state["demand"] + rng.randrange(1, GIB)}
            busier = {**state, "scopes": [*state["scopes"], admission.Scope(
                klass="acceptance", unit="extra.scope", limit=rng.randrange(1, 4 * GIB), working_set=0)]}
            self.assertNotEqual(decide(larger).kind, admission.ADMIT)
            self.assertNotEqual(decide(busier).kind, admission.ADMIT)

    def test_every_refusal_says_why(self):
        """A caller that waits reports the reason, so a refusal without one is a defect."""
        for state in states():
            decision = decide(state)
            self.assertEqual(decision.reason is None, decision.kind == admission.ADMIT)

    def test_a_decision_does_not_change_its_inputs(self):
        """The decision is pure: the scopes and the observation are as they were."""
        for state in states():
            before = (list(state["scopes"]), dataclasses.astuple(state["observation"]))
            decide(state)
            self.assertEqual((state["scopes"], dataclasses.astuple(state["observation"])), before)

    def test_i8_an_admitted_capped_request_keeps_the_reserved_cpu_within_the_budget(self):
        """I8: the CPU of the capped scopes that run, with the request, never exceeds the budget once the request is admitted."""
        for state in states():
            state["klass"] = CAPPED
            if decide(state).kind == admission.ADMIT:
                self.assertTrue(cpu_fits(state), self.assert_state(state, "the CPU budget is overcommitted"))

    def test_i8_a_capped_request_that_fits_the_cpu_and_the_memory_is_admitted_whatever_else_waits_or_runs(self):
        """I8: neither a waiting acceptance nor a deep scope holds a capped request, and the CPU of no other class counts."""
        for state in states():
            state["klass"] = CAPPED
            expected = admission.ADMIT if fits(state) and cpu_fits(state) else admission.WAIT
            self.assertEqual(decide(state).kind, expected, self.assert_state(state, "wrong decision for a capped request"))
            self.assertEqual(decide(state, acceptance_waiting=True), decide(state, acceptance_waiting=False))

    def test_i8_a_capped_request_never_cancels_anything(self):
        """I8: lacking room, a capped request waits even when a deep scope exists that an acceptance would cancel."""
        for state in states():
            state["klass"] = CAPPED
            self.assertNotEqual(decide(state).kind, admission.CANCEL_DEEP, self.assert_state(state, "a capped request cancelled"))

    def test_i8_the_cpu_asked_for_is_judged_for_the_capped_class_only(self):
        """The other classes reserve no CPU, so what they ask for in CPU and the budget do not enter their decision."""
        for state in states():
            if state["klass"] == CAPPED:
                continue
            self.assertEqual(decide(state), decide(state, cpu_request=0, cpu_budget=0))

    def test_i8_a_busier_cpu_never_turns_a_capped_refusal_into_an_admission(self):
        """Monotonicity of I8: a larger CPU request and one more capped scope can only make the decision stricter."""
        rng = random.Random(SEED + 2)
        for state in states():
            state["klass"] = CAPPED
            if decide(state).kind == admission.ADMIT:
                continue
            larger = {**state, "cpu_request": state["cpu_request"] + rng.randrange(1, 100)}
            busier = {**state, "scopes": [*state["scopes"], admission.Scope(
                klass=CAPPED, unit="extra.scope", limit=1, working_set=0, cpu=rng.randrange(1, 100))]}
            self.assertNotEqual(decide(larger).kind, admission.ADMIT)
            self.assertNotEqual(decide(busier).kind, admission.ADMIT)


if __name__ == "__main__":
    unittest.main()
