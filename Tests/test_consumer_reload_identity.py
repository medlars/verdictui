"""Consumer selection follows the guardian topology and refuses changed identities."""

import ctypes
import errno
import importlib.util
import os
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

PATH = Path(__file__).resolve().parents[1] / "examples/ConsumerApp/verify-integration.py"
SPEC = importlib.util.spec_from_file_location("consumer_reload_proof", PATH)
assert SPEC and SPEC.loader
PROOF = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROOF
SPEC.loader.exec_module(PROOF)


@pytest.fixture
def identities(tmp_path):
    executable = tmp_path / "ConsumerScenarios"
    owner = PROOF.ProcessIdentity(100, 50, 50, (1000, 1), "/private/launcher")
    guardian = PROOF.ProcessIdentity(101, 100, 101, (1000, 2), owner.executable)
    consumer = PROOF.ProcessIdentity(102, 100, 101, (1000, 3), str(executable.resolve()))
    return owner, guardian, consumer, executable


def test_guardian_topology_selects_actual_consumer_in_either_order(identities):
    owner, guardian, consumer, executable = identities
    for children in ([guardian, consumer], [consumer, guardian]):
        assert PROOF.select_consumer(owner, children, executable) == consumer


@pytest.mark.parametrize(
    "fault",
    [
        "extra",
        "missing",
        "duplicate",
        "wrong-parent",
        "wrong-executable",
        "wrong-group",
        "guardian-executable",
        "guardian-group",
        "second-guardian",
    ],
)
def test_unexpected_children_fail_closed(identities, fault):
    owner, guardian, consumer, executable = identities
    children = [guardian, consumer]
    if fault == "extra":
        children.append(replace(consumer, pid=103, group=999, executable="/private/unrelated"))
    elif fault == "missing":
        children.pop()
    elif fault == "duplicate":
        children = [guardian, guardian]
    elif fault == "wrong-parent":
        children[1] = replace(consumer, parent=999)
    elif fault == "wrong-executable":
        children[1] = replace(consumer, executable="/private/unrelated")
    elif fault == "wrong-group":
        children[1] = replace(consumer, group=999)
    elif fault == "guardian-executable":
        children[0] = replace(guardian, executable="/private/unrelated")
    elif fault == "guardian-group":
        children[0] = replace(guardian, group=999)
    elif fault == "second-guardian":
        children[1] = replace(consumer, executable=owner.executable, group=consumer.pid)
    with pytest.raises(AssertionError):
        PROOF.select_consumer(owner, children, executable)


@pytest.mark.parametrize("changed", ["owner-birth", "consumer-birth", "consumer-parent", "exit"])
def test_recycled_or_reparented_process_is_not_selected(monkeypatch, identities, changed):
    owner, guardian, consumer, executable = identities
    broker = SimpleNamespace(pid=owner.pid, poll=lambda: 0 if changed == "exit" else None)
    current = {owner.pid: owner, consumer.pid: consumer}
    if changed == "owner-birth":
        current[owner.pid] = replace(owner, birth=(1001, 1))
    elif changed == "consumer-birth":
        current[consumer.pid] = replace(consumer, birth=(1001, 3))
    elif changed == "consumer-parent":
        current[consumer.pid] = replace(consumer, parent=999)
    monkeypatch.setattr(PROOF, "process_identity", current.get)
    monkeypatch.setattr(PROOF, "direct_children", lambda parent: [guardian, consumer])
    with pytest.raises(AssertionError):
        PROOF.consumer_identity(broker, owner, executable)


def test_stable_owned_consumer_is_selected(monkeypatch, identities):
    owner, guardian, consumer, executable = identities
    broker = SimpleNamespace(pid=owner.pid, poll=lambda: None)
    monkeypatch.setattr(PROOF, "process_identity", {owner.pid: owner, consumer.pid: consumer}.get)
    monkeypatch.setattr(PROOF, "direct_children", lambda parent: [guardian, consumer])
    assert PROOF.consumer_identity(broker, owner, executable) == consumer


def test_exit_wait_does_not_wait_for_recycled_process(monkeypatch, identities):
    _, _, consumer, _ = identities
    monkeypatch.setattr(PROOF, "process_identity", lambda pid: replace(consumer, birth=(2000, 1)))
    PROOF.wait_for_consumer_exit(consumer, timeout=0)
    monkeypatch.setattr(PROOF, "process_identity", lambda pid: consumer)
    with pytest.raises(AssertionError, match="did not exit"):
        PROOF.wait_for_consumer_exit(consumer, timeout=0)


def test_crash_capability_is_private_and_one_use(tmp_path):
    request = tmp_path / ".verdictui" / "private-crash"
    text = PROOF.crash_capable_source("    static func main() async {\n    }", request)
    assert str(request) in text
    assert text.index("removeItem(at: request)") < text.index("_exit(86)")
    assert "kill(" not in text
    with pytest.raises(AssertionError, match="absent or ambiguous"):
        PROOF.crash_capable_source("no entry", request)


@pytest.mark.parametrize("fault", ["denied", "short", "wrong-pid", "no-path", "absent", "zombie"])
def test_native_identity_fails_closed_on_unavailable_metadata(monkeypatch, fault):
    def info(pid, flavor, arg, target, size):
        target._obj.pid = 102 if fault == "wrong-pid" else pid
        target._obj.status = 5 if fault == "zombie" else 2
        if fault in ("denied", "absent"):
            ctypes.set_errno(errno.EPERM if fault == "denied" else errno.ESRCH)
            return 0
        return size - 1 if fault == "short" else size

    def path(pid, target, size):
        target.value = b"/private/consumer"
        return 0 if fault == "no-path" else len(target.value)

    monkeypatch.setattr(
        PROOF, "_libproc", lambda: SimpleNamespace(proc_pidinfo=info, proc_pidpath=path)
    )
    if fault in ("absent", "zombie"):
        assert PROOF.process_identity(100) is None
    else:
        with pytest.raises(AssertionError):
            PROOF.process_identity(100)


@pytest.mark.parametrize("fault", ["denied", "oversized", "read-error", "overflow", "disappeared"])
def test_native_inventory_fails_closed(monkeypatch, identities, fault):
    owner, guardian, consumer, _ = identities

    def inventory(kind, parent, target, capacity):
        assert kind == 6 and parent == owner.pid
        if target is None:
            return {"denied": -1, "oversized": 2 * 1024 * 1024 + 1}.get(fault, 8)
        target[0], target[1] = guardian.pid, consumer.pid
        return {"read-error": -1, "overflow": capacity}.get(fault, 8)

    monkeypatch.setattr(PROOF, "_libproc", lambda: SimpleNamespace(proc_listpids=inventory))
    monkeypatch.setattr(
        PROOF,
        "process_identity",
        lambda pid: (
            None
            if fault == "disappeared"
            else {guardian.pid: guardian, consumer.pid: consumer}.get(pid)
        ),
    )
    with pytest.raises(AssertionError):
        PROOF.direct_children(owner.pid)


def test_native_api_rejects_other_platforms(monkeypatch):
    monkeypatch.setattr(PROOF.sys, "platform", "linux")
    with pytest.raises(AssertionError, match="require macOS"):
        PROOF._libproc()


@pytest.mark.skipif(sys.platform != "darwin", reason="public Darwin process identity API")
def test_actual_process_identity_uses_current_birth_and_executable():
    identity = PROOF.process_identity(os.getpid())
    assert identity.pid == os.getpid()
    assert identity.parent == os.getppid()
    assert identity.group == os.getpgrp()
    assert identity.birth[0] > 0
    assert Path(identity.executable).is_file()
    assert PROOF.process_identity(2147483647) is None
    owned = subprocess.Popen(["/bin/sleep", "5"])
    try:
        child = PROOF.process_identity(owned.pid)
        assert child.parent == os.getpid()
        assert child.executable == os.path.realpath("/bin/sleep")
        assert child in PROOF.direct_children(os.getpid())
    finally:
        owned.terminate()
        owned.wait(timeout=3)
