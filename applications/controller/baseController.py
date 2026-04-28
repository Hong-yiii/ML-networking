import os
import datetime
import time
from pox.core import core
import pox.openflow.libopenflow_01 as of
from forwarding.l2_learning import LearningSwitch
import click_wrapper

log = core.getLogger()


class controller (object):
    devices = dict()
    firstSeenAt = dict()

    def __init__(self):
        core.openflow.addListeners(self)

    def _install_nfv_bridge_l2_fallback(self, conn):
        """Historical fallback that put `actions=NORMAL` on NFV switches.

        Removed by default: when this flow runs alongside Click on the same
        bridge, OVS L2-bridges every frame in parallel with Click's PF_PACKET
        pipeline. Receivers see two copies (one untranslated from OVS NORMAL,
        one rewritten from Click), which makes TCP look like a blackhole and
        causes ICMP to "succeed" via OVS alone — masking that NAPT/IDS/LB are
        not actually doing their job.

        Click's `FromDevice(METHOD LINUX, PROMISC true)` sees ingress frames
        via PF_PACKET regardless of whether OVS has any flows (PF_PACKET RX
        runs before the OVS rx_handler in __netif_receive_skb_core), so an
        empty flow table does NOT prevent Click from receiving traffic.

        Set IK2221_NFV_OVS_NORMAL=1 to re-enable the fallback during
        debugging; otherwise leave the bridge empty so Click owns the
        data plane on dpids 4/5/6.
        """
        if os.environ.get("IK2221_NFV_OVS_NORMAL") != "1":
            return
        msg = of.ofp_flow_mod()
        msg.priority = 1
        try:
            normal_port = of.OFPP_NORMAL
        except AttributeError:
            normal_port = 0xFFFA  # OpenFlow 1.0 OFPP_NORMAL (65530)
        msg.actions.append(of.ofp_action_output(port=normal_port))
        conn.send(msg)

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
            self._install_nfv_bridge_l2_fallback(event.connection)
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
            self._install_nfv_bridge_l2_fallback(event.connection)
        elif id == 6:
            log.info("Starting Load Balancer")
            lb_out = os.environ.get("IK2221_LB_REPORT", "/tmp/lb1.report")
            lb_err = os.environ.get("IK2221_LB_STDERR", "/tmp/lb1.stderr")
            self.devices[id] = click_wrapper.start_click(
                "/opt/pox/ext/lb1.click", "", lb_out, lb_err
            )
            self._install_nfv_bridge_l2_fallback(event.connection)
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
