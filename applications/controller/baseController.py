import os
import datetime
import time
from pox.core import core
import pox.openflow.libopenflow_01 as of
from pox.lib.util import dpid_to_str
from forwarding.l2_learning import LearningSwitch
import click_wrapper

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
            napt_out = os.environ.get("IK2221_NAPT_REPORT", "/tmp/napt.report")
            napt_err = os.environ.get("IK2221_NAPT_STDERR", "/tmp/napt.stderr")
            self.devices[id] = click_wrapper.start_click(
                "/opt/pox/ext/napt.click", "", napt_out, napt_err
            )
        elif id == 5:
            log.info("Starting IDS — waiting for ids-eth1 to appear...")
            for i in range(20):
                if os.path.exists('/sys/class/net/ids-eth1'):
                    break
                time.sleep(1)
            log.info("IDS interface ready, starting Click")
            ids_out = os.environ.get("IK2221_IDS_REPORT", "/tmp/ids.report")
            ids_err = os.environ.get("IK2221_IDS_STDERR", "/tmp/ids.stderr")
            self.devices[id] = click_wrapper.start_click(
                "/opt/pox/ext/ids.click", "", ids_out, ids_err
            )
        elif id == 6:
            log.info("Starting Load Balancer - waiting for lb1-eth1 to appear...")
            for i in range(20):
                if os.path.exists('/sys/class/net/lb1-eth1'):
                    break
                time.sleep(1)
            log.info("LB interface ready, starting Click")
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
