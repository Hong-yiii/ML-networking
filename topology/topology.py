
from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import Switch
from mininet.cli import CLI
from mininet.node import RemoteController, OVSController, Controller
from mininet.node import OVSSwitch
import subprocess
import signal
import os
import time

class MyTopo(Topo):
    def __init__(self):

        # Initialize topology
        Topo.__init__(self)

        # Here you initialize hosts, web servers and switches
        # (There are sample host, switch and link initialization,  you can rewrite it in a way you prefer)
        ### UPDATE THIS PART AS YOU SEE FIT ###
        # This is a simple implementation of a simple networl
        # # Initialize hosts
        # h1 = self.addHost('h1', ip='100.0.0.10/24')
        # h2 = self.addHost('h2', ip='100.0.0.11/24')

        # # Initial switches
        # sw1 = self.addSwitch('sw1', dpid="1")

        # # Defining links
        # self.addLink(h1, sw1)
        # self.addLink(h2, sw1)

        # This is the implementation of the topology for the project
        # Please update the IP addresses to the correct ones
        # You can update the topology as you see fit

        # Initialize hosts for user zone
        h1 = self.addHost('h1', ip='10.0.0.50/24', defaultRoute='via 10.0.0.1')
        h2 = self.addHost('h2', ip='10.0.0.51/24', defaultRoute='via 10.0.0.1')
        # Initialize switch for user zone
        sw1 = self.addSwitch('sw1', dpid="1")
        # Connect hosts to switch
        self.addLink(h1, sw1)
        self.addLink(h2, sw1)

        # Initialize napt between user zone and inferencing zone
        napt = self.addSwitch('napt', dpid="4") # dpid is 4 because we have 3 normal switches in the topology
        # Connect user zone switch to napt
        self.addLink(sw1, napt)

        # Initalize access switch for inferencing zone
        sw2 = self.addSwitch('sw2', dpid="2")
        # Connect napt to access switch
        self.addLink(napt, sw2)

        # Initialize ids switch for inferencing zone
        ids = self.addSwitch('ids', dpid="5") # dpid is 5 because we have 3 normal switches and 1 napt switch in the topology
        # Connect access switch to ids switch
        self.addLink(sw2, ids)

        # Create inspection server for inferencing zone
        # TODO: Change IP to correct IP
        # insp = self.addHost('insp', ip='10.0.0.30/24')
        insp = self.addHost('insp', ip='100.0.0.30/24', defaultRoute='via 100.0.0.1')
        
        # Connect inspection server to ids switch
        self.addLink(insp, ids)

        # Create load balancer for inferencing zone
        lb1 = self.addSwitch('lb1', dpid="6")
        # Connect ids switch to load balancer
        self.addLink(ids, lb1)

        # Create switch to connect load balancer to inferencing servers
        sw3 = self.addSwitch('sw3', dpid="3")
        # Connect load balancer to switch
        self.addLink(lb1, sw3)

        # Create inferencing servers 
        # TODO: Change IPs to correct IPs
        # llm1 = self.addHost('llm1', ip='10.0.0.40/24')
        # llm2 = self.addHost('llm2', ip='10.0.0.41/24')
        # llm3 = self.addHost('llm3', ip='10.0.0.42/24')

        llm1 = self.addHost('llm1', ip='100.0.0.40/24', defaultRoute='via 100.0.0.45')
        llm2 = self.addHost('llm2', ip='100.0.0.41/24', defaultRoute='via 100.0.0.45')
        llm3 = self.addHost('llm3', ip='100.0.0.42/24', defaultRoute='via 100.0.0.45')

        # Connect inferencing servers to switch
        self.addLink(llm1, sw3)
        self.addLink(llm2, sw3)
        self.addLink(llm3, sw3)

def startup_services(net):
    # Start http services and executing commands you require on each host...
    ### COMPLETE THIS PART ###
    def start_backend_server(host, name):
        host.cmd('mkdir -p /tmp/www')
        # Keep the static file for GET-based checks and run a tiny handler that
        # also answers POST with the same identifying body for the round-robin test.
        host.cmd(f'echo "<html><body>index from {name}</body></html>" > /tmp/www/index.html')
        host.cmd(f"cat > /tmp/www/server.py <<'PY'\nfrom http.server import BaseHTTPRequestHandler, HTTPServer\n\nBODY = b\"<html><body>index from {name}</body></html>\"\n\nclass Handler(BaseHTTPRequestHandler):\n    def _send_body(self):\n        self.send_response(200)\n        self.send_header('Content-Type', 'text/html')\n        self.send_header('Content-Length', str(len(BODY)))\n        self.end_headers()\n        self.wfile.write(BODY)\n\n    def do_GET(self):\n        self._send_body()\n\n    def do_POST(self):\n        self._send_body()\n\n    def do_PUT(self):\n        self._send_body()\n\n    def log_message(self, format, *args):\n        pass\n\nHTTPServer(('0.0.0.0', 80), Handler).serve_forever()\nPY")
        host.cmd(f'nohup python3 /tmp/www/server.py >/tmp/{name}.http.log 2>&1 < /dev/null &')

    # Start HTTP servers on LLM nodes
    for name in ['llm1', 'llm2', 'llm3']:
        host = net.get(name)
        start_backend_server(host, name)

    # Start tcpdump on inspector to capture suspicious packets
    insp = net.get('insp')
    insp.cmd('rm -f /tmp/insp_capture.pcap && tcpdump -i insp-eth0 -w /tmp/insp_capture.pcap &')

    # Set MAC addresses on Click bridges to match Click config
    lb = net.get('lb1')
    if lb:
        lb.cmd('ip link set dev lb1-eth1 address 02:00:00:00:01:45 2>/dev/null || true')
        lb.cmd('ip link set dev lb1-eth2 address 02:00:00:00:02:45 2>/dev/null || true')

    # Match napt.click ARP identities on each side.
    napt = net.get('napt')
    if napt:
        napt.cmd('ip link set dev napt-eth1 address 02:aa:00:00:00:01 2>/dev/null || true')
        napt.cmd('ip link set dev napt-eth2 address 02:aa:00:00:00:02 2>/dev/null || true')

<<<<<<< HEAD
=======
        if skip_controller_nfv:
            napt_out = os.environ.get('IK2221_NAPT_REPORT', '/tmp/napt.report')
            napt_err = os.environ.get('IK2221_NAPT_STDERR', '/tmp/napt.stderr')
            napt.cmd(f'nohup sudo click /opt/pox/ext/napt.click >"{napt_out}" 2>>"{napt_err}" < /dev/null &')

    ids = net.get('ids')
    if ids and skip_controller_nfv:
        ids_out = os.environ.get('IK2221_IDS_REPORT', '/tmp/ids.report')
        ids_err = os.environ.get('IK2221_IDS_STDERR', '/tmp/ids.stderr')
        ids.cmd(f'nohup sudo click /opt/pox/ext/ids.click >"{ids_out}" 2>>"{ids_err}" < /dev/null &')

    lb = net.get('lb1')
    if lb and skip_controller_nfv:
        lb_out = os.environ.get('IK2221_LB_REPORT', '/tmp/lb1.report')
        lb_err = os.environ.get('IK2221_LB_STDERR', '/tmp/lb1.stderr')
        lb.cmd(f'nohup sudo click /opt/pox/ext/lb1.click >"{lb_out}" 2>>"{lb_err}" < /dev/null &')

>>>>>>> 298dbe252d02db65dc4f6a002a23e943bc3b5c29


# topos = {'mytopo': (lambda: MyTopo())}

if __name__ == "__main__":

    # Create topology
    topo = MyTopo()

    ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)

    # Create the network
    net = Mininet(topo=topo,
                  switch=OVSSwitch,
                  controller=ctrl,
                  autoSetMacs=True,
                  autoStaticArp=True,
                  build=True,
                  cleanup=True)

    # Start the network
    net.start()

    startup_services(net)

    # Start the CLI
    CLI(net)

    # You may need some commands before stopping the network! If you don't, leave it empty
    ### COMPLETE THIS PART ###
    net.stop()
