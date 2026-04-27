import os
from pox.core import core
import pox.openflow.libopenflow_01 as of
from pox.lib.addresses import IPAddr
from pox.lib.util import dpid_to_str
import pox.lib.packet as pkt
from forwarding.l2_learning import LearningSwitch
import subprocess
import shlex
import datetime
import click_wrapper
import time
import os

log = core.getLogger()


class controller (object):
    devices = dict()
    firstSeenAt = dict()

    def __init__(self):
        core.openflow.addListeners(self)

    def _handle_ConnectionUp(self, event):
        id = event.dpid
        if id <= 3:
            log.info(f"Starting Learning Switch for switch {id}")
            self.devices[id] = LearningSwitch(event.connection, False)
        elif id == 4:
            log.info("Starting NAPT")
            self.devices[id] = click_wrapper.start_click("/opt/pox/ext/napt.click", "", "/tmp/napt.stdout", "/tmp/napt.stderr")
        elif id == 5:
            log.info("Starting IDS - waiting for interface...")
            for i in range(20):
                if os.path.exists('/sys/class/net/ids-eth1'):
                    break
                time.sleep(1)
            log.info("IDS interface ready, starting Click")
            self.devices[id] = click_wrapper.start_click("/opt/pox/ext/ids.click", "", "/tmp/ids.stdout", "/tmp/ids.stderr")
        elif id == 6:
            log.info("Starting Load Balancer")
            lb_out = os.environ.get("IK2221_LB_REPORT", "/tmp/lb1.report")
            lb_err = os.environ.get("IK2221_LB_STDERR", "/tmp/lb1.stderr")
            self.devices[id] = click_wrapper.start_click(
                "/opt/pox/ext/lb1.click", "", lb_out, lb_err
            )
        else:
            log.error("Unknown device connected to the controller")

    def updatefirstSeenAt(self, mac, where):
        if mac not in self.firstSeenAt:
            log.info(f"New MAC {mac} seen at {where}")
            self.firstSeenAt[mac] = (where, datetime.datetime.now().isoformat())
        else:
            log.info(f"MAC {mac} is already in the firstSeenAt dictionary")


def launch(configuration=""):
    core.registerNew(controller)
