#!/usr/bin/env python3
# Frame-aware caller-differentiated identity relay for unifi-drive's
# connection to unifi-core, port 11081.
#
# Replaces an earlier naive byte-substitution approach that corrupted the
# WebSocket stream (RSV1/RSV2 set, bad opcode errors, escalating to
# connection timeout) because it never recomputed the length fields it
# changed. This version parses the wire protocol instead of guessing at it:
#
#   - Standard RFC 6455 WebSocket framing. unifi-core (server) sends unmasked
#     binary frames (opcode 2) to unifi-drive; unifi-drive sends masked frames
#     back (untouched -- only upstream -> client carries the model fields).
#   - Each WS message payload is a sequence of length-prefixed sub-messages:
#     1 byte type + 1 byte version + 6-byte big-endian length + that many
#     bytes of body (JSON). Multiple sub-messages pack into one WS frame back
#     to back.
#   - The hardware/model JSON (containing "sysid"/"name"/"shortname") lives
#     inside a type=2 sub-message, one field deep in a ~17KB system-info blob.
#
# Fix: reassemble each complete WS message (handling continuation frames
# defensively, though none were observed), split it into sub-messages via the
# 8-byte header, rewrite only bodies containing the target fields, and
# reconstruct BOTH length fields correctly -- the sub-message's own 6-byte
# length and the outer WS frame payload length (7/16/64-bit encoding). A Go
# websocket client validates both, so the receiver must see consistent lengths
# at both layers.
#
# Everything else (the HTTP Upgrade handshake, the client->server direction,
# WS control frames -- ping/pong/close -- and any non-binary-opcode frame) is
# forwarded completely unmodified.

import asyncio
import sys

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 11090
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 11081

SUBSTITUTIONS = [
    (b'"sysid":59760', b'"sysid":60018'),
    (b'"shortname":"UCKP"', b'"shortname":"UNAS2B"'),
    (b'"name":"UniFi Cloudkey Plus"', b'"name":"UNAS 2"'),
]


def rewrite_body(body: bytes) -> bytes:
    for old, new in SUBSTITUTIONS:
        body = body.replace(old, new)
    return body


def rewrite_submessages(payload: bytes) -> bytes:
    """Parse the 8-byte-header sub-message stream, rewrite bodies that
    need it, and reassemble with corrected per-sub-message lengths.
    Falls back to returning the input unchanged if the payload doesn't
    parse cleanly as this sub-message format (e.g. it's some other
    message type this project hasn't seen) -- never emit something we
    can't account for byte-for-byte."""
    out = bytearray()
    i = 0
    n = len(payload)
    while i < n:
        if i + 8 > n:
            return payload  # doesn't parse cleanly, leave untouched
        mtype = payload[i]
        ver = payload[i + 1]
        sublen = int.from_bytes(payload[i + 2:i + 8], "big")
        body_start = i + 8
        body_end = body_start + sublen
        if body_end > n:
            return payload  # declared length overruns buffer, don't touch
        body = payload[body_start:body_end]
        new_body = rewrite_body(body)
        out.append(mtype)
        out.append(ver)
        out += len(new_body).to_bytes(6, "big")
        out += new_body
        i = body_end
    return bytes(out)


def encode_ws_frame(opcode: int, payload: bytes) -> bytes:
    """Server->client frames are always unmasked per RFC 6455."""
    length = len(payload)
    header = bytearray()
    header.append(0x80 | (opcode & 0x0F))  # FIN=1, given opcode
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += length.to_bytes(2, "big")
    else:
        header.append(127)
        header += length.to_bytes(8, "big")
    return bytes(header) + payload


class WSFrameParser:
    """Incremental RFC 6455 frame parser over a growing byte buffer fed
    from successive socket reads. Reassembles fragmented messages
    (continuation frames) defensively, though none were observed live."""

    def __init__(self):
        self.buf = bytearray()
        self._msg_opcode = None
        self._msg_payload = bytearray()

    def feed(self, data: bytes):
        self.buf += data

    def next_complete_message(self):
        """Returns (opcode, full_payload) for the next complete WS
        message once enough bytes are buffered, else None. Control
        frames (ping/pong/close) are returned as their own single-frame
        "message" immediately, since they can't be fragmented."""
        while True:
            frame = self._try_parse_one_frame()
            if frame is None:
                return None
            fin, opcode, payload = frame
            if opcode in (0x8, 0x9, 0xA):  # close/ping/pong: never fragmented
                return (opcode, payload)
            if opcode != 0x0:  # start of a new (possibly fragmented) message
                self._msg_opcode = opcode
                self._msg_payload = bytearray(payload)
            else:  # continuation frame
                self._msg_payload += payload
            if fin:
                opcode_out = self._msg_opcode
                payload_out = bytes(self._msg_payload)
                self._msg_opcode = None
                self._msg_payload = bytearray()
                return (opcode_out, payload_out)
            # else: fragment consumed, loop to try parsing the next frame

    def _try_parse_one_frame(self):
        buf = self.buf
        if len(buf) < 2:
            return None
        b0, b1 = buf[0], buf[1]
        fin = (b0 >> 7) & 1
        opcode = b0 & 0x0F
        masked = (b1 >> 7) & 1
        ln = b1 & 0x7F
        pos = 2
        if ln == 126:
            if len(buf) < pos + 2:
                return None
            ln = int.from_bytes(buf[pos:pos + 2], "big")
            pos += 2
        elif ln == 127:
            if len(buf) < pos + 8:
                return None
            ln = int.from_bytes(buf[pos:pos + 8], "big")
            pos += 8
        mask_key = None
        if masked:
            if len(buf) < pos + 4:
                return None
            mask_key = buf[pos:pos + 4]
            pos += 4
        if len(buf) < pos + ln:
            return None
        payload = bytes(buf[pos:pos + ln])
        if masked:
            payload = bytes(payload[j] ^ mask_key[j % 4] for j in range(len(payload)))
        del self.buf[:pos + ln]
        return (fin, opcode, payload)


async def pump_passthrough(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def pump_rewrite_s2c(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Upstream (unifi-core) -> client (unifi-drive): forward the HTTP
    Upgrade response untouched until the header terminator, then rewrite
    binary-opcode WS messages frame-by-frame."""
    parser = WSFrameParser()
    handshake_done = False
    handshake_buf = b""
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            if not handshake_done:
                handshake_buf += chunk
                idx = handshake_buf.find(b"\r\n\r\n")
                if idx == -1:
                    writer.write(chunk)
                    await writer.drain()
                    continue
                writer.write(handshake_buf[:idx + 4])
                await writer.drain()
                handshake_done = True
                parser.feed(handshake_buf[idx + 4:])
                handshake_buf = b""
            else:
                parser.feed(chunk)

            while True:
                msg = parser.next_complete_message()
                if msg is None:
                    break
                opcode, payload = msg
                if opcode == 0x2:  # binary: the only type carrying our fields
                    new_payload = rewrite_submessages(payload)
                    writer.write(encode_ws_frame(opcode, new_payload))
                else:
                    writer.write(encode_ws_frame(opcode, payload))
                await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def handle_client(client_reader, client_writer):
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT)
    except Exception as e:
        print(f"upstream connect failed: {e}", file=sys.stderr, flush=True)
        client_writer.close()
        return
    await asyncio.gather(
        pump_passthrough(client_reader, upstream_writer),
        pump_rewrite_s2c(upstream_reader, client_writer),
    )


async def main():
    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    print(f"drive-hardware-relay-v3 (frame-aware) listening on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
