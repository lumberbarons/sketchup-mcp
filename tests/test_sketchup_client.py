"""Unit tests for SketchupClient — the socket layer that talks to the
SketchUp Ruby server. Sockets are mocked or built from socketpair() so these
tests do not require a running SketchUp instance.
"""

from __future__ import annotations

import json
import socket
from unittest.mock import MagicMock

import pytest

from sketchup_mcp.server import SketchupClient


@pytest.fixture
def client() -> SketchupClient:
    return SketchupClient(host="localhost", port=9876, timeout=1.0)


class TestUnwrapResponse:
    def test_returns_result_payload(self, client: SketchupClient):
        envelope = {"jsonrpc": "2.0", "id": 1, "result": {"a": 1, "b": [2, 3]}}
        assert client._unwrap_response(envelope) == {"a": 1, "b": [2, 3]}

    def test_returns_empty_dict_when_result_key_missing(self, client: SketchupClient):
        # send_command treats a missing result as success-with-empty-payload.
        assert client._unwrap_response({"jsonrpc": "2.0", "id": 1}) == {}

    def test_raises_with_error_message(self, client: SketchupClient):
        envelope = {"jsonrpc": "2.0", "id": 1, "error": {"message": "boom"}}
        with pytest.raises(Exception, match="boom"):
            client._unwrap_response(envelope)

    def test_raises_unknown_when_message_missing(self, client: SketchupClient):
        with pytest.raises(Exception, match="Unknown error from Sketchup"):
            client._unwrap_response({"error": {"code": -1}})

    def test_passes_through_non_dict(self, client: SketchupClient):
        # Defensive branch: SketchUp shouldn't return a bare scalar, but if it
        # does we forward it untouched rather than raising.
        assert client._unwrap_response("scalar") == "scalar"
        assert client._unwrap_response([1, 2, 3]) == [1, 2, 3]


class TestReadResponse:
    def test_reads_one_newline_terminated_json(self, client: SketchupClient):
        a, b = socket.socketpair()
        try:
            b.sendall(b'{"jsonrpc": "2.0", "id": 1, "result": "ok"}\n')
            b.close()
            assert client._read_response(a) == {
                "jsonrpc": "2.0",
                "id": 1,
                "result": "ok",
            }
        finally:
            a.close()

    def test_stops_at_first_newline(self, client: SketchupClient):
        # Two messages back-to-back: we must consume exactly one.
        a, b = socket.socketpair()
        try:
            b.sendall(b'{"id": 1, "result": "first"}\n{"id": 2, "result": "second"}\n')
            b.close()
            assert client._read_response(a) == {"id": 1, "result": "first"}
        finally:
            a.close()

    def test_raises_on_immediate_eof(self, client: SketchupClient):
        a, b = socket.socketpair()
        try:
            b.close()
            with pytest.raises(Exception, match="Connection closed before receiving any data"):
                client._read_response(a)
        finally:
            a.close()

    def test_raises_on_malformed_json(self, client: SketchupClient):
        a, b = socket.socketpair()
        try:
            b.sendall(b"not json\n")
            b.close()
            with pytest.raises(json.JSONDecodeError):
                client._read_response(a)
        finally:
            a.close()


class TestConnectWithRetries:
    def test_succeeds_first_attempt(self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch):
        attempts: list[int] = []
        sentinel = MagicMock(name="socket")

        def fake_open() -> socket.socket:
            attempts.append(1)
            return sentinel

        monkeypatch.setattr(client, "_open_socket", fake_open)
        assert client._connect_with_retries() is sentinel
        assert len(attempts) == 1

    def test_retries_then_succeeds(self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch):
        attempts: list[int] = []
        sentinel = MagicMock(name="socket")

        def fake_open() -> socket.socket:
            attempts.append(1)
            if len(attempts) < 3:
                raise OSError("connection refused")
            return sentinel

        monkeypatch.setattr(client, "_open_socket", fake_open)
        assert client._connect_with_retries(max_retries=2) is sentinel
        assert len(attempts) == 3

    def test_raises_after_exhausting_retries(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        attempts: list[int] = []

        def fake_open() -> socket.socket:
            attempts.append(1)
            raise OSError("nope")

        monkeypatch.setattr(client, "_open_socket", fake_open)
        with pytest.raises(ConnectionError, match="after 3 attempts"):
            client._connect_with_retries(max_retries=2)
        assert len(attempts) == 3


class TestSendCommandRetryPolicy:
    """The retry policy is the central safety contract: connect failures are
    retried (idempotent), but any failure after the connect succeeds must NOT
    be retried, since a partial send may already have reached SketchUp."""

    def test_does_not_retry_after_successful_connect(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        open_calls: list[int] = []
        fake_sock = MagicMock(spec=socket.socket)
        fake_sock.sendall.side_effect = OSError("send failed mid-flight")

        def fake_open() -> socket.socket:
            open_calls.append(1)
            return fake_sock

        monkeypatch.setattr(client, "_open_socket", fake_open)
        with pytest.raises(OSError, match="send failed mid-flight"):
            client.send_command("anything")

        assert len(open_calls) == 1, "send-failure must not trigger reconnect"
        fake_sock.sendall.assert_called_once()

    def test_retries_only_on_connect_failures(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        attempts: list[int] = []
        a, b = socket.socketpair()
        try:
            b.sendall(b'{"jsonrpc": "2.0", "id": 1, "result": {"ok": true}}\n')

            def fake_open() -> socket.socket:
                attempts.append(1)
                if len(attempts) == 1:
                    raise OSError("first attempt fails at connect")
                return a

            monkeypatch.setattr(client, "_open_socket", fake_open)
            result = client.send_command("noop", {"x": 1}, request_id=42)
            assert result == {"ok": True}
            assert len(attempts) == 2
        finally:
            a.close()
            b.close()


class TestSendCommandHappyPath:
    def test_serialises_request_and_unwraps_result(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        # Use a real socketpair so request bytes can be inspected and the
        # response can be served by writing canned bytes back to the client.
        a, b = socket.socketpair()
        try:
            b.sendall(b'{"jsonrpc": "2.0", "id": 7, "result": {"id": "comp-1"}}\n')

            monkeypatch.setattr(client, "_open_socket", lambda: a)
            result = client.send_command(
                "tools/call",
                {"name": "create_component", "arguments": {"type": "cube"}},
                request_id=7,
            )
            assert result == {"id": "comp-1"}

            # Verify the bytes the client wrote are a single newline-terminated
            # JSON-RPC request with the expected envelope.
            received = b.recv(4096)
            assert received.endswith(b"\n")
            decoded = json.loads(received.rstrip(b"\n"))
            assert decoded == {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": "create_component", "arguments": {"type": "cube"}},
                "id": 7,
            }
        finally:
            a.close()
            b.close()

    def test_propagates_sketchup_error_envelope(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        a, b = socket.socketpair()
        try:
            b.sendall(b'{"jsonrpc": "2.0", "id": 1, "error": {"message": "ruby boom"}}\n')
            monkeypatch.setattr(client, "_open_socket", lambda: a)
            with pytest.raises(Exception, match="ruby boom"):
                client.send_command("tools/call", {})
        finally:
            a.close()
            b.close()


class TestProbe:
    def test_returns_true_when_socket_opens(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        fake_sock = MagicMock(spec=socket.socket)
        monkeypatch.setattr(client, "_open_socket", lambda: fake_sock)
        assert client.probe() is True
        fake_sock.close.assert_called_once()

    def test_returns_false_when_socket_fails(
        self, client: SketchupClient, monkeypatch: pytest.MonkeyPatch
    ):
        def fake_open() -> socket.socket:
            raise OSError("refused")

        monkeypatch.setattr(client, "_open_socket", fake_open)
        assert client.probe() is False
