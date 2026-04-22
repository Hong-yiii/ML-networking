
from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import Switch
from mininet.cli import CLI
from mininet.node import RemoteController
from mininet.node import OVSSwitch
from topology import *
import testing


topos = {'mytopo': (lambda: MyTopo())}


def run_tests(net):
    # You can automate some tests here

    # TODO: How to get the hosts from the net??
    h1 = net.get('h1')
    h2 = net.get('h2')

    # Launch some tests
    testing.ping(h1, '10.0.0.51', True) 
    testing.curl(h1, '100.0.0.45', expected=False)

    # Basic connectivity within user zone
    testing.ping(h1, '10.0.0.51', True)
    
    # Ping the virtual service IP through NAPT
    testing.ping(h1, '100.0.0.45', True)
    
    # HTTP to the virtual service (should work for GET once IDS allows, 
    # or test POST which IDS allows)
    testing.curl(h1, '100.0.0.45', method='POST', expected=True)
    
    # IDS should block GET
    testing.curl(h1, '100.0.0.45', method='GET', expected=False)


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
    run_tests(net)

    # Start the CLI
    CLI(net)

    # You may need some commands before stopping the network! If you don't, leave it empty
    ### COMPLETE THIS PART ###

    net.stop()
