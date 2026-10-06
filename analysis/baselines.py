#!/usr/bin/env python3
"""Deterministic baselines A-D for the DART comparative experiment (Cycle 2A).

Standard library only. Produces CSV evidence, no figures.

The same rule engine (`Vault` + `Policy`) drives both the step sequence and the
power surface, so the capability table is observed, not hand-written. Model D
mirrors the check order of `src/DARTVault.sol`. Models A, B and C are Python-only
archetypes; only D is also checked against the Foundry suite (see the map CSV).

Steps are scenario steps, not blockchain latency. Amounts are simulated units.
"""

from __future__ import annotations

import csv
import platform
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"

# ---------------------------------------------------------------------------
# Locked experiment parameters (TEST_PLAN "Experiment comparatiu minim")
# ---------------------------------------------------------------------------

STEPS = list(range(0, 10))          # t = 0 .. 9 inclusive
INITIAL_BALANCE = 100
AMOUNT = 10
MAX_AMOUNT_PER_ACTION = 10
T_EMERGENCY = 3                     # agent compromised and user unavailable from here
LONG_VALID_UNTIL = 100
SHORT_VALID_UNTIL = 5               # inclusive; first expired attempt is t = 6

VARIANTS = {"main": 4, "late6": 6, "late8": 8}   # revoke_before_step, C and D only

# Cause vocabulary (exact strings)
ACCEPTED_LEGITIMATE = "accepted_legitimate"
ACCEPTED_IN_SCOPE = "accepted_in_scope"
REJECTED_REVOKED = "rejected_revoked"
REJECTED_EXPIRED = "rejected_expired"
REJECTED_INSUFFICIENT_BALANCE = "rejected_insufficient_balance"
REJECTED_NOT_AGENT = "rejected_not_agent"
REJECTED_NOT_USER = "rejected_not_user"
REJECTED_NOT_AUTHORIZED = "rejected_not_authorized"
# Causes below can only arise on inputs outside the locked experiment; kept for
# engine fidelity with the contract, never expected in the CSVs.
REJECTED_NOT_YET_VALID = "rejected_not_yet_valid"
REJECTED_RECIPIENT = "rejected_recipient_not_allowed"
REJECTED_AMOUNT = "rejected_amount_exceeds_limit"
REJECTED_NOT_FOUND = "rejected_delegation_not_found"

# ---------------------------------------------------------------------------
# Rule engine
# ---------------------------------------------------------------------------


@dataclass
class Delegation:
    agent: str
    allowed_recipient: str
    max_amount_per_action: int
    valid_after: int
    valid_until: int
    revoked: bool = False


@dataclass
class Vault:
    balance: int
    user: str = "user"
    delegation: Optional[Delegation] = None


@dataclass(frozen=True)
class Policy:
    """Who may do what in a given model. Grant/revoke sets are actor names;
    execute is always the delegated agent, plus `execute_override` actors
    (the central administrator archetype) who may spend regardless."""

    model: str
    label: str
    grant: frozenset
    revoke: frozenset
    execute_override: frozenset
    actors: tuple
    emergency_actor: Optional[str]
    valid_until: int


POLICIES: Dict[str, Policy] = {
    "A": Policy(
        model="A", label="user-only revocation",
        grant=frozenset({"user"}), revoke=frozenset({"user"}),
        execute_override=frozenset(),
        actors=("user", "agent", "outsider"), emergency_actor=None,
        valid_until=LONG_VALID_UNTIL,
    ),
    "B": Policy(
        model="B", label="short-lived credential",
        grant=frozenset({"user"}), revoke=frozenset({"user"}),
        execute_override=frozenset(),
        actors=("user", "agent", "outsider"), emergency_actor=None,
        valid_until=SHORT_VALID_UNTIL,
    ),
    "C": Policy(
        model="C", label="central administrator",
        grant=frozenset({"user", "admin"}), revoke=frozenset({"user", "admin"}),
        execute_override=frozenset({"admin"}),
        actors=("user", "agent", "admin", "outsider"), emergency_actor="admin",
        valid_until=LONG_VALID_UNTIL,
    ),
    "D": Policy(
        model="D", label="DART guardian",
        grant=frozenset({"user"}), revoke=frozenset({"user", "guardian"}),
        execute_override=frozenset(),
        actors=("user", "agent", "guardian", "outsider"), emergency_actor="guardian",
        valid_until=LONG_VALID_UNTIL,
    ),
}


@dataclass
class Outcome:
    accepted: bool
    cause: str


def grant(policy: Policy, vault: Vault, actor: str, valid_until: int) -> Outcome:
    if actor not in policy.grant:
        return Outcome(False, REJECTED_NOT_USER)
    vault.delegation = Delegation(
        agent="agent", allowed_recipient="recipient",
        max_amount_per_action=MAX_AMOUNT_PER_ACTION,
        valid_after=0, valid_until=valid_until,
    )
    return Outcome(True, "granted")


def revoke(policy: Policy, vault: Vault, actor: str) -> Outcome:
    # Mirrors DARTVault.revokeDelegation order: exists, caller, already revoked.
    if vault.delegation is None:
        return Outcome(False, REJECTED_NOT_FOUND)
    if actor not in policy.revoke:
        return Outcome(False, REJECTED_NOT_AUTHORIZED)
    if vault.delegation.revoked:
        return Outcome(False, "rejected_already_revoked")
    vault.delegation.revoked = True
    return Outcome(True, "revoked")


def execute(policy: Policy, vault: Vault, actor: str, t: int,
            recipient: str = "recipient", amount: int = AMOUNT) -> Outcome:
    """Mirrors DARTVault.execute check order for the delegated agent. An
    execute_override actor (model C admin) bypasses the delegation entirely and
    only needs balance; that is the archetype's extra power."""
    d = vault.delegation
    if actor in policy.execute_override:
        if amount > vault.balance:
            return Outcome(False, REJECTED_INSUFFICIENT_BALANCE)
        vault.balance -= amount
        return Outcome(True, ACCEPTED_IN_SCOPE)
    if d is None:
        return Outcome(False, REJECTED_NOT_FOUND)
    if actor != d.agent:
        return Outcome(False, REJECTED_NOT_AGENT)
    if d.revoked:
        return Outcome(False, REJECTED_REVOKED)
    if t < d.valid_after:
        return Outcome(False, REJECTED_NOT_YET_VALID)
    if t > d.valid_until:
        return Outcome(False, REJECTED_EXPIRED)
    if recipient != d.allowed_recipient:
        return Outcome(False, REJECTED_RECIPIENT)
    if amount == 0 or amount > d.max_amount_per_action:
        return Outcome(False, REJECTED_AMOUNT)
    if amount > vault.balance:
        return Outcome(False, REJECTED_INSUFFICIENT_BALANCE)
    vault.balance -= amount
    return Outcome(True, ACCEPTED_LEGITIMATE if t < T_EMERGENCY else ACCEPTED_IN_SCOPE)


# ---------------------------------------------------------------------------
# Sequence experiment
# ---------------------------------------------------------------------------


@dataclass
class RunSummary:
    model: str
    variant: str
    revoke_before_step: Optional[int]
    t_revocation: Optional[int]
    t_expiry: Optional[int]
    damage_final: int
    balance_final: int
    accepted_total: int
    rows: List[dict] = field(default_factory=list)

    @property
    def delay_steps(self) -> Optional[int]:
        return None if self.t_revocation is None else self.t_revocation - T_EMERGENCY


def run_sequence(policy: Policy, variant: str, revoke_before_step: Optional[int]) -> RunSummary:
    vault = Vault(balance=INITIAL_BALANCE)
    g = grant(policy, vault, "user", policy.valid_until)
    assert g.accepted, "setup grant must succeed"

    damage = 0
    accepted_total = 0
    t_revocation: Optional[int] = None
    t_expiry: Optional[int] = None
    rows: List[dict] = []

    for t in STEPS:
        # Emergency response: the model's emergency actor revokes before this
        # step's attempt. The user never acts after T_EMERGENCY (unavailable).
        if (revoke_before_step is not None and t == revoke_before_step
                and policy.emergency_actor is not None):
            r = revoke(policy, vault, policy.emergency_actor)
            assert r.accepted, f"{policy.model}: emergency revoke must succeed"

        out = execute(policy, vault, "agent", t)
        if out.accepted:
            accepted_total += AMOUNT
            if t >= T_EMERGENCY:
                damage += AMOUNT
        if out.cause == REJECTED_REVOKED and t_revocation is None:
            t_revocation = t
        if out.cause == REJECTED_EXPIRED and t_expiry is None:
            t_expiry = t

        rows.append({
            "model": policy.model,
            "variant": variant,
            "step": t,
            "actor": "agent",
            "action": "execute",
            "compromised": str(t >= T_EMERGENCY).lower(),
            "accepted": str(out.accepted).lower(),
            "cause": out.cause,
            "balance_after": vault.balance,
            "damage_after": damage,
        })

    return RunSummary(policy.model, variant, revoke_before_step, t_revocation,
                      t_expiry, damage, vault.balance, accepted_total, rows)


def run_all_sequences() -> List[RunSummary]:
    runs: List[RunSummary] = []
    for model in ("A", "B", "C", "D"):
        policy = POLICIES[model]
        if policy.emergency_actor is None:
            runs.append(run_sequence(policy, "main", None))
        else:
            for variant, step in VARIANTS.items():
                runs.append(run_sequence(policy, variant, step))
    return runs


# ---------------------------------------------------------------------------
# Power surface (same engine, fresh miniature state per attempt)
# ---------------------------------------------------------------------------


def fresh_state(policy: Policy) -> Vault:
    vault = Vault(balance=INITIAL_BALANCE)
    assert grant(policy, vault, "user", policy.valid_until).accepted
    return vault


def run_power_surface() -> List[dict]:
    rows: List[dict] = []
    for model in ("A", "B", "C", "D"):
        policy = POLICIES[model]
        for actor in policy.actors:
            for operation in ("grant", "revoke", "execute"):
                vault = fresh_state(policy)
                if operation == "grant":
                    out = grant(policy, vault, actor, policy.valid_until)
                elif operation == "revoke":
                    out = revoke(policy, vault, actor)
                else:
                    out = execute(policy, vault, actor, t=0)
                rows.append({
                    "model": model,
                    "model_label": policy.label,
                    "actor": actor,
                    "operation": operation,
                    "observed": "success" if out.accepted else "failure",
                    "cause": "" if out.accepted else out.cause,
                })
    return rows


# ---------------------------------------------------------------------------
# DART main sequence <-> existing Foundry tests
# ---------------------------------------------------------------------------

FOUNDRY_OUTPUT = RESULTS / "test-output.txt"


def foundry_statuses() -> Dict[str, str]:
    """Observed statuses parsed from the saved forge output. Never assumed."""
    statuses: Dict[str, str] = {}
    if not FOUNDRY_OUTPUT.exists():
        return statuses
    pattern = re.compile(r"^\[(PASS|FAIL)[^\]]*\]\s+(test_\w+)\(\)")
    for line in FOUNDRY_OUTPUT.read_text(encoding="utf-8").splitlines():
        m = pattern.match(line.strip())
        if m:
            statuses[m.group(2)] = m.group(1)
    return statuses


def build_sequence_map(d_main: RunSummary, power: List[dict]) -> List[dict]:
    statuses = foundry_statuses()

    def status(test: str) -> str:
        if test == "NOT_COVERED":
            return "NOT_RUN"
        return statuses.get(test, "NOT_RUN")

    # step -> list of (foundry test, note)
    mapping = {
        0: ["test_T02_ValidActionReducesBalanceAndEmits"],
        1: ["test_T19_RepeatedValidExecutesSucceedWhileBalanceLasts"],
        2: ["test_T19_RepeatedValidExecutesSucceedWhileBalanceLasts"],
        3: ["test_T11_UserUnavailable_GuardianRevokes_AgentBlocked"],
        # T06 is deliberately absent here: it verifies a successful revoke and
        # never attempts execute, so its PASS does not witness this rejection row.
        # T06 stays on the power-surface guardian:revoke mapping below.
        4: ["test_T11_UserUnavailable_GuardianRevokes_AgentBlocked",
            "test_T07_AgentExecuteAfterRevokeFailsInWindow"],
    }
    for t in range(5, 10):
        mapping[t] = ["test_T07_RevokedStaysRevokedAcrossTimeWarps"]

    rows: List[dict] = []
    for row in d_main.rows:
        t = row["step"]
        for test in mapping.get(t, ["NOT_COVERED"]):
            rows.append({
                "step": t,
                "variant": "main",
                "python_accepted": row["accepted"],
                "python_cause": row["cause"],
                "foundry_test": test,
                "foundry_status": status(test),
            })

    # Guardian containment facts observed in the power surface for D.
    containment = {
        ("guardian", "grant"): ["test_T08_GuardianCannotGrant",
                                "test_T10_GuardianSameCalldataAsUserIsRejected"],
        ("guardian", "execute"): ["test_T09_GuardianCannotExecute"],
        ("guardian", "revoke"): ["test_T06_GuardianRevokesActiveDelegation"],
        ("outsider", "revoke"): ["test_T13_OutsiderCannotRevoke"],
        ("agent", "revoke"): ["test_T13_AgentCannotRevoke"],
    }
    for p in power:
        if p["model"] != "D":
            continue
        for test in containment.get((p["actor"], p["operation"]), []):
            rows.append({
                "step": f"power_surface:{p['actor']}:{p['operation']}",
                "variant": "main",
                "python_accepted": str(p["observed"] == "success").lower(),
                "python_cause": p["cause"] or "accepted",
                "foundry_test": test,
                "foundry_status": status(test),
            })
    # No-reactivation property is not a step of the sequence but belongs to D.
    rows.append({
        "step": "property:no_reactivation",
        "variant": "main",
        "python_accepted": "n/a",
        "python_cause": "no restore operation exists in the engine",
        "foundry_test": "test_T12_NewGrantWithIdenticalTermsDoesNotReviveRevokedId",
        "foundry_status": status("test_T12_NewGrantWithIdenticalTermsDoesNotReviveRevokedId"),
    })
    return rows


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def write_csv(path: Path, rows: List[dict]) -> None:
    assert rows, f"no rows for {path}"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def git_head() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       text=True).strip()
    except Exception as exc:  # noqa: BLE001
        return f"unavailable ({exc})"


def na(value: Optional[int]) -> str:
    return "N/A" if value is None else str(value)


def write_config(runs: List[RunSummary]) -> str:
    lines = [
        "# DART TR: baseline experiment configuration and derived summary (Cycle 2A)",
        f"# Captured: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"# Python: {platform.python_version()} ({sys.executable})",
        f"# Script: analysis/baselines.py (stdlib only)",
        f"# Commit (git rev-parse HEAD at capture time): {git_head()}",
        "",
        "[parameters]",
        f"steps = {STEPS[0]}..{STEPS[-1]} inclusive ({len(STEPS)} attempts)",
        f"initial_balance = {INITIAL_BALANCE}",
        f"amount_per_step = {AMOUNT}",
        f"max_amount_per_action = {MAX_AMOUNT_PER_ACTION}",
        f"t_emergency = {T_EMERGENCY} (agent compromised and user unavailable from this step)",
        f"long_valid_until = {LONG_VALID_UNTIL} (A, C, D)",
        f"short_valid_until = {SHORT_VALID_UNTIL} inclusive (B); no auto-renewal",
        "variants (C, D): " + ", ".join(f"{k}: revoke_before_step={v}" for k, v in VARIANTS.items()),
        "damage = cumulative accepted amount for steps >= t_emergency",
        "t_revocation = first step rejected as rejected_revoked; delay = t_revocation - t_emergency",
        "monitor = absent (constant across models)",
        "units = simulated units and scenario steps; not currency, not chain latency",
        "",
        "[models]",
    ]
    for p in POLICIES.values():
        lines.append(f"{p.model} = {p.label}; grant={sorted(p.grant)}; revoke={sorted(p.revoke)}; "
                     f"execute_override={sorted(p.execute_override)}; emergency_actor={p.emergency_actor}; "
                     f"valid_until={p.valid_until}")
    lines += [
        "",
        "[derived_summary]  # recomputed from the same run that wrote baseline-results.csv",
        "model,variant,revoke_before_step,t_emergency,t_revocation,delay_steps,t_expiry,accepted_total,balance_final,damage_final",
    ]
    for r in runs:
        lines.append(",".join([
            r.model, r.variant, na(r.revoke_before_step), str(T_EMERGENCY),
            na(r.t_revocation), na(r.delay_steps), na(r.t_expiry),
            str(r.accepted_total), str(r.balance_final), str(r.damage_final),
        ]))
    lines.append("")
    text = "\n".join(lines)
    (RESULTS / "baseline-config.txt").write_text(text, encoding="utf-8")
    return text


def main() -> int:
    RESULTS.mkdir(exist_ok=True)

    runs = run_all_sequences()
    write_csv(RESULTS / "baseline-results.csv", [row for r in runs for row in r.rows])

    power = run_power_surface()
    write_csv(RESULTS / "power-surface.csv", power)

    d_main = next(r for r in runs if r.model == "D" and r.variant == "main")
    write_csv(RESULTS / "dart-sequence-map.csv", build_sequence_map(d_main, power))

    config_text = write_config(runs)

    print(config_text.split("[derived_summary]")[1].strip())
    print()
    print("power surface (D):")
    for p in power:
        if p["model"] == "D":
            print(f"  {p['actor']:<9} {p['operation']:<8} {p['observed']:<8} {p['cause']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
