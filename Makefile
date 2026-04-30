poxdir ?= /opt/pox/

# Default POX install path on course VM; override: ``make poxdir=/path app``.
# Rules mirror PDF deliverable: topo / app / clean / test; extras: test-lb, vm-sync, vm-test-lb.

topo:
	@echo "Starting topology (Mininet)..."
	sudo python ./topology/topology.py

app:
	@echo "Starting baseController (POX + Click)..."
	cp applications/controller/* $(poxdir)ext/
	cp applications/nfv/*.click $(poxdir)ext/
	sudo python $(poxdir)pox.py baseController

# Automated end-to-end test.
# Starts POX in the background with report paths set to the project root,
# runs topology_test.py (non-interactive), writes stdout+stderr to phase_1_report,
# then tears down cleanly.
test:
	@echo "=== IK2221 Phase 1 — automated test suite ==="
	$(MAKE) clean 2>/dev/null || true
	sleep 2
	cp applications/controller/* $(poxdir)ext/
	cp applications/nfv/*.click   $(poxdir)ext/
	sudo -E \
	    IK2221_NAPT_REPORT="$(CURDIR)/napt.report" \
	    IK2221_IDS_REPORT="$(CURDIR)/ids.report"   \
	    IK2221_LB_REPORT="$(CURDIR)/lb1.report"    \
	    python $(poxdir)pox.py baseController > /tmp/pox_test.stdout 2>&1 &
	# Allow POX + first OpenFlow connections + Click launches (especially IDS/LB waits) before Mininet starts.
	sleep 8
	sudo -E \
	    MN_AUTOMATED=1 \
	    PYTHONPATH=$(CURDIR) \
	    IK2221_NAPT_REPORT="$(CURDIR)/napt.report" \
	    IK2221_IDS_REPORT="$(CURDIR)/ids.report"   \
	    IK2221_LB_REPORT="$(CURDIR)/lb1.report"    \
	    python3 topology/topology_test.py 2>&1 | tee phase_1_report
	$(MAKE) clean 2>/dev/null || true
	@echo "=== Results written to phase_1_report, napt.report, ids.report, lb1.report ==="

# Sync repo to IK2221 QEMU VM (see scripts/vm-sync.sh; set VM_SSH_PASS if needed).
vm-sync:
	bash scripts/vm-sync.sh

# Run LB-only tests on the VM (SSH + sudo; VM_SSH_PASS / VM_SUDO_PASS as for vm-sync).
vm-test-lb:
	bash scripts/vm-run.sh

# Load-balancer integration test (LB-only topology, no napt/ids).
test-lb:
	POXDIR="$(poxdir)" bash scripts/run_lb_integration_test.sh

clean:
	@echo "Cleaning up..."
	rm -f $(poxdir)ext/baseController.py $(poxdir)ext/click_wrapper.py $(poxdir)ext/*.click
	kill `ps -ef | grep pox[.py] | awk '{print $$2}'` 2>/dev/null || true
	sudo mn -c 2>/dev/null || true
	sudo killall click 2>/dev/null || true
