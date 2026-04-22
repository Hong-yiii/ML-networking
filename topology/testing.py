import topology


def ping(client, server, expected, count=1, wait=1):

    # TODO: What if ping fails? How long does it take? Add a timeout to the command!
    cmd = f"ping -W {wait} -c {count} {server} >/dev/null 2>&1; echo $?"
    ret = client.cmd(cmd).strip()
    # TODO: Here you should compare the return value "ret" with the expected value
    # (consider both failures
    success = (ret == "0")
    passed = (success == expected)
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] ping from {client} to {server} — got {'success' if success else 'failure'}, expected {'success' if expected else 'failure'}")
    return passed


def curl(client, server, method="GET", payload="", port=80, expected=True):
        """
        run curl for HTTP request. Request method and payload should be specified
        Server can either be a host or a string
        return True in case of success, False if not
        """

        if (isinstance(server, str) == 0):
            server_ip = str(server.IP())
        else:
            # If it's a string it should be the IP address of the node (e.g., the load balancer)
            server_ip = server

        # TODO: Specify HTTP method
        data_flag = f'-d "{payload}"' if payload else ""
        # TODO: Pass some payload (a.k.a. data). You may have to add some escaped quotes!
        # The magic string at the end reditect everything to the black hole and just print the return code
        cmd = f'curl --connect-timeout 3 --max-time 3 -s -X {method} {data_flag} {server_ip}:{port} > /dev/null 2>&1; echo $?'
        ret = client.cmd(cmd).strip()
        success = (ret == "0")
        passed = (success == expected)
        status = "PASS" if passed else "FAIL"
        print(f"[{status}] curl {method} from {client} to {server_ip}:{port} — returned {ret}, expected {'success' if expected else 'failure'}")

        # TODO: What value do you expect?
        return passed
