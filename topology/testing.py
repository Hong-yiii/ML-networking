"""
Thin assertion helpers run *inside* Mininet host contexts via ``host.cmd``.

Exit-code convention: ping/curl treat shell exit 0 as success; IDS tests flip ``expected`` so
“blocked” traffic is *success* when curl fails (non-zero).
"""

import topology  # noqa: F401 — skeleton kept optional shared imports for packaging symmetry.


def ping(client, server, expected, count=1, wait=2):
    # -W: seconds until “failure” per probe; count=1 keeps tests fast.
    cmd = f"ping -W {wait} -c {count} {server} >/dev/null 2>&1; echo $?"
    ret = client.cmd(cmd).strip()
    success = (ret == "0")
    passed = (success == expected)
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] ping {client} -> {server} — "
          f"got {'success' if success else 'failure'}, "
          f"expected {'success' if expected else 'failure'}")
    return passed


def curl(client, server, method="GET", payload="", port=80, expected=True):
    """Send an HTTP request and check whether it succeeds or fails.

    Returns True if the outcome matches *expected*, False otherwise.

    Curl hits ``http://<VIP>:80/`` from the client namespace; return path must traverse LB/NAPT in reverse.
    """
    server_ip = server if isinstance(server, str) else str(server.IP())
    data_flag = f'-d "{payload}"' if payload else ""
    cmd = (f'curl --connect-timeout 3 --max-time 5 -s '
           f'-X {method} {data_flag} http://{server_ip}:{port}/ '
           f'> /dev/null 2>&1; echo $?')
    ret = client.cmd(cmd).strip()
    success = (ret == "0")
    passed = (success == expected)
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] curl {method} {client} -> {server_ip}:{port} — "
          f"exit {ret}, expected {'success' if expected else 'failure'}")
    return passed


def curl_body(client, server, method="GET", payload="", port=80):
    """Send an HTTP request and return the response body as a string.

    Returns the body string (may be empty on failure).

    Used to read embedded backend tag (“index from llmN”) for round-robin verification.
    """
    server_ip = server if isinstance(server, str) else str(server.IP())
    data_flag = f'-d "{payload}"' if payload else ""
    cmd = (f'curl --connect-timeout 3 --max-time 5 -s '
           f'-X {method} {data_flag} http://{server_ip}:{port}/')
    return client.cmd(cmd)
