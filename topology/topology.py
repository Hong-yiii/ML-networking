
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
    # Start HTTP servers on LLM nodes
    for name in ['llm1', 'llm2', 'llm3']:
        host = net.get(name)
        host.cmd('mkdir -p /tmp/www')
        # Create a few test pages
        for i in range(1, 4):
            host.cmd(f'echo "<html><body>Page {i} from {name}</body></html>" > /tmp/www/page{i}.html')
        host.cmd(f'echo "<html><body>index from {name}</body></html>" > /tmp/www/index.html')
        host.cmd('cd /tmp/www && python3 -m http.server 80 &')

    # Start tcpdump on inspector to capture suspicious packets
    insp = net.get('insp')
    insp.cmd('rm -f /tmp/insp_capture.pcap && tcpdump -i insp-eth0 -w /tmp/insp_capture.pcap &')

    # Match lb1.click AddressInfo / ARPResponder MACs (Click does not learn these from Linux).
    # We intentionally do NOT install actions=NORMAL on napt/ids/lb1: Click is the sole data
    # plane on those bridges. An OVS NORMAL flow would L2-bridge every frame in parallel with
    # Click's PF_PACKET pipeline, producing duplicate (untranslated) packets and masking
    # NAPT/IDS/LB function. Set IK2221_NFV_OVS_NORMAL=1 to re-enable the fallback.
    lb = net.get('lb1')
    if lb:
        lb.cmd('ip link set dev lb1-eth1 address 02:00:00:00:01:45 2>/dev/null || true')
        lb.cmd('ip link set dev lb1-eth2 address 02:00:00:00:02:45 2>/dev/null || true')

    if os.environ.get('IK2221_NFV_OVS_NORMAL') == '1':
        for sw_name in ('napt', 'ids', 'lb1'):
            sw = net.get(sw_name)
            if not sw:
                continue
            for proto in ('OpenFlow10', 'OpenFlow13', 'OpenFlow14'):
                sw.cmd(
                    f"ovs-ofctl -O {proto} add-flow {sw.name} 'priority=0,actions=NORMAL' 2>/dev/null || true"
                )



# topos = {'mytopo': (lambda: MyTopo())}

if __name__ == "__main__":

    # Create topology
    topo = MyTopo()

    ctrl = RemoteController("c0", ip="127.0.0.1", port=6633)

    # Create the network
    # autoStaticArp=True pre-populates `arp -s peer-ip peer-mac` between every
    # host pair. With our topology that places `100.0.0.45 -> lb1-eth1's MAC`
    # on h1, even though h1 is in 10.0.0.0/24 and the VIP is supposed to be
    # reached via NAPT's gateway 10.0.0.1. The poisoned ARP makes h1 send TCP
    # to VIP with dst_mac=lb1-eth1, OVS NORMAL floods that frame all the way
    # to llm*, and the llm kernel drops it (dst-MAC mismatch). Real ARP via
    # NAPT/LB ARPResponders works correctly.
    net = Mininet(topo=topo,
                  switch=OVSSwitch,
                  controller=ctrl,
                  autoSetMacs=True,
                  autoStaticArp=False,
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
