"""Summarize only complete pairs, preserving missing phases and reuse disagreements."""

import json
import math
import statistics

PHASES = ("dnsMs", "connectMs", "tlsMs", "requestMs", "waitMs", "responseMs")
TLS_CODES = {"TLSv1.2": 0x0303, "TLSv1.3": 0x0304}


def object_schema(required, optional=None):
    return {
        "type": "object",
        "required": list(required),
        "properties": {**required, **(optional or {})},
        "additionalProperties": False,
    }


def sample_schema():
    number = {"type": "number", "minimum": 0}
    integer = {"type": "integer", "minimum": 0}
    transaction = object_schema(
        {
            "reused": {"type": "boolean"},
            "proxy": {"type": "boolean"},
            "fetch": {"enum": ["network", "cache", "push", "unknown"]},
        },
        {
            **dict.fromkeys(PHASES, number),
            "status": integer,
            "networkProtocol": {"type": "string"},
            "tlsProtocolCode": integer,
        },
    )
    task = object_schema(
        {
            "identifier": integer,
            "taskMs": number,
            "redirectCount": integer,
            "transactions": {"type": "array", "items": transaction},
        }
    )
    return object_schema(
        {
            "pair": {"type": "integer", "minimum": 1},
            "position": {"enum": [1, 2]},
            "outcome": {"enum": ["ok", "unexpectedResponse", "cancelled", "requestFailed"]},
            "backendMs": number,
        },
        {"gapMs": number, "task": task},
    )


def read_samples(path):
    rows, invalid = [], 0
    for line in path.read_bytes().splitlines():
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            invalid += 1
            continue
        if isinstance(value, dict):
            rows.append(value)
        else:
            invalid += 1
    return rows, invalid


def valid(value, schema):
    if "enum" in schema:
        return any(type(value) is type(choice) and value == choice for choice in schema["enum"])
    kind = schema["type"]
    if kind == "object":
        properties = schema["properties"]
        return (
            isinstance(value, dict)
            and set(schema["required"]) <= value.keys() <= properties.keys()
            and all(valid(item, properties[name]) for name, item in value.items())
        )
    if kind == "array":
        return isinstance(value, list) and all(valid(item, schema["items"]) for item in value)
    if kind == "string":
        return isinstance(value, str)
    if kind == "boolean":
        return type(value) is bool
    types = (int,) if kind == "integer" else (int, float)
    try:
        return type(value) in types and value >= schema["minimum"] and math.isfinite(value)
    except OverflowError:
        return False


def indexed(rows, pairs, schema):
    result, seen, invalid = {}, set(), 0
    for row in rows:
        if not valid(row, schema) or row["pair"] > pairs:
            invalid += 1
            continue
        key = (row["pair"], row["position"])
        if key in seen:
            invalid += 1
            result.pop(key, None)
        else:
            result[key] = row
            seen.add(key)
    return result, invalid


def distribution(values):
    observed = sorted(value for value in values if value is not None)
    if not observed:
        return {"n": 0, "missing": len(values), "p50": None, "p95": None}
    return {
        "n": len(observed),
        "missing": len(values) - len(observed),
        "p50": statistics.median(observed),
        "p95": observed[math.ceil(0.95 * len(observed)) - 1],
    }


def one_network_transaction(row):
    if row is None or row.get("outcome") != "ok":
        return None
    task = row.get("task")
    if not isinstance(task, dict) or task.get("redirectCount") != 0:
        return None
    transactions = task.get("transactions")
    if not isinstance(transactions, list) or len(transactions) != 1:
        return None
    transaction = transactions[0]
    if not isinstance(transaction, dict) or transaction.get("fetch") != "network" or transaction.get("status") != 200:
        return None
    if transaction.get("proxy") is not False or not isinstance(transaction.get("reused"), bool):
        return None
    return transaction


def tls_matches(transaction, server_row, scheme):
    version = server_row.get("tlsVersion")
    code = transaction.get("tlsProtocolCode")
    if scheme == "http":
        return version is None and code is None and "tlsSessionResumed" not in server_row
    return version in TLS_CODES and (code is None or TLS_CODES[version] == code)


def summarize(rows, invalid_lines, server, pairs, scheme="http"):
    samples, invalid_samples = indexed(rows, pairs, sample_schema())
    server_schema = object_schema(
        {
            "pair": {"type": "integer", "minimum": 1},
            "position": {"enum": [1, 2]},
            "connection": {"type": "integer", "minimum": 1},
        },
        {"tlsVersion": {"enum": list(TLS_CODES)}, "tlsSessionResumed": {"type": "boolean"}},
    )
    requests, invalid_requests = indexed(server["requests"], pairs, server_schema)
    seen_connections, socket_reuse = set(), {}
    for key, request in sorted(requests.items()):
        connection = request["connection"]
        socket_reuse[key] = connection in seen_connections
        seen_connections.add(connection)
    positions = {1: [], 2: []}
    same_socket, first_agreement, second_agreement = 0, 0, 0
    for pair in range(1, pairs + 1):
        first, second = (samples.get((pair, position)) for position in (1, 2))
        first_tx, second_tx = one_network_transaction(first), one_network_transaction(second)
        first_server, second_server = (requests.get((pair, position)) for position in (1, 2))
        if any(value is None for value in (first_tx, second_tx, first_server, second_server)):
            continue
        if first["task"]["identifier"] == second["task"]["identifier"]:
            invalid_samples += 1
            continue
        if not tls_matches(first_tx, first_server, scheme) or not tls_matches(second_tx, second_server, scheme):
            invalid_samples += 1
            continue
        positions[1].append((first, first_tx))
        positions[2].append((second, second_tx))
        same_socket += first_server["connection"] == second_server["connection"]
        first_agreement += socket_reuse[(pair, 1)] == first_tx["reused"]
        second_agreement += socket_reuse[(pair, 2)] == second_tx["reused"]
    complete = len(positions[1])
    tls_resumption = {
        request["connection"]: request["tlsSessionResumed"]
        for request in requests.values()
        if "tlsSessionResumed" in request
    }
    result = {
        "plannedPairs": pairs,
        "completePairs": complete,
        "sampleRows": len(rows),
        "serverRequests": len(server["requests"]),
        "invalidRows": invalid_lines + invalid_samples + invalid_requests,
        "serverRejected": server["rejected"],
        "serverHandlerErrors": server["handlerErrors"],
        "sameSocketPairs": same_socket,
        "acceptedSockets": server.get("connections"),
        "serverTLSVersions": sorted(
            {request["tlsVersion"] for request in requests.values() if "tlsVersion" in request}
        ),
        "resumedTLSSockets": sum(tls_resumption.values()) if tls_resumption else None,
        "firstReuseAgreementPairs": first_agreement,
        "secondReuseAgreementPairs": second_agreement,
        "reuseDisagreements": 2 * complete - first_agreement - second_agreement,
    }
    for position, label in ((1, "first"), (2, "second")):
        observed = positions[position]
        result[label] = {
            "reportedReused": sum(transaction["reused"] for _, transaction in observed),
            "protocols": sorted(
                {tx["networkProtocol"] for _, tx in observed if isinstance(tx.get("networkProtocol"), str)}
            ),
            "backendMs": distribution([row.get("backendMs") for row, _ in observed]),
            "taskMs": distribution([row["task"].get("taskMs") for row, _ in observed]),
            **{phase: distribution([transaction.get(phase) for _, transaction in observed]) for phase in PHASES},
        }
    result["second"]["gapMs"] = distribution([row.get("gapMs") for row, _ in positions[2]])
    return result
