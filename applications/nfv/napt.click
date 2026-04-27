// NAPT — IK2221 Phase 1
// User zone:        napt-eth1  logical IP 10.0.0.1   (10.0.0.0/24)
// Inferencing zone: napt-eth2  logical IP 100.0.0.1  (100.0.0.0/24)
//
// Translates TCP and ICMP echo between the two zones and handles ARP on both sides.
// AverageCounter after each FromDevice and before each ToDevice (as required by brief).
// Per-class counters are written to napt.report via DriverManager on teardown.

define($USER_IF napt-eth1, $INF_IF napt-eth2)
define($USER_IP 10.0.0.1,  $INF_IP 100.0.0.1)
define($USER_MAC 02:aa:00:00:00:01, $INF_MAC 02:aa:00:00:00:02)

Script(print "Click NAPT on $USER_IF (10.0.0.0/24) <-> $INF_IF (100.0.0.0/24)")

// Ingress / Egress devices
from_user::FromDevice($USER_IF, SNIFFER false, METHOD LINUX, PROMISC true)
from_inf::FromDevice($INF_IF,  SNIFFER false, METHOD LINUX, PROMISC true)
to_user::ToDevice($USER_IF, METHOD LINUX)
to_inf::ToDevice($INF_IF,  METHOD LINUX)

// AverageCounters immediately after each FromDevice (required by brief)
ac_user_in::AverageCounter
ac_inf_in::AverageCounter

// AverageCounters immediately before each ToDevice (required by brief)
ac_user_out::AverageCounter
ac_inf_out::AverageCounter

// Per-class counters
cnt_user_arp::Counter    // ARP handled on user side
cnt_inf_arp::Counter     // ARP handled on inferencing side
cnt_user_tcp::Counter    // TCP translated user→inf
cnt_inf_tcp::Counter     // TCP translated inf→user
cnt_user_icmp::Counter   // ICMP echo translated user→inf
cnt_inf_icmp::Counter    // ICMP echo translated inf→user
cnt_drop::Counter        // packets dropped (non-ARP/TCP/ICMP)

// ARP responders: answer ARP-who-has for each side's logical IP
user_arp_resp::ARPResponder($USER_IP $USER_MAC)
inf_arp_resp::ARPResponder($INF_IP  $INF_MAC)

// ARP queriers: resolve next-hop MAC for outgoing translated IP packets
user_arp_q::ARPQuerier($USER_IP, $USER_MAC)
inf_arp_q::ARPQuerier($INF_IP,  $INF_MAC)

// Named rewrite patterns shared by both IPRewriter and ICMPPingRewriter.
// user_to_inf: outbound — replace src with $INF_IP and assign an ephemeral port.
// inf_to_user: used only for unsolicited inbound flows; reverse of established flows
//              is handled automatically by the mapping table.
napt_fwd::IPRewriterPatterns(user_to_inf $INF_IP 1024-65535 - -)
napt_rev::IPRewriterPatterns(inf_to_user $USER_IP 1024-65535 - -)

// IPRewriter: input 0 = user→inf (apply user_to_inf),
//             input 1 = inf→user (look up reverse mapping first).
tcp_rw::IPRewriter(
    pattern user_to_inf 0 1,
    pattern inf_to_user 1 0
)

// ICMPPingRewriter: same patterns (port field maps to ICMP identifier field).
icmp_rw::ICMPPingRewriter(
    pattern user_to_inf 0 1,
    pattern inf_to_user 1 0
)

// L2 classifiers: ARP vs IPv4 vs other
cl_user_l2::Classifier(12/0806, 12/0800, -)
cl_inf_l2::Classifier(12/0806,  12/0800, -)

// ARP sub-classifiers: request (opcode 0001) vs reply (opcode 0002)
user_arp_op::Classifier(20/0001, 20/0002, -)
inf_arp_op::Classifier(20/0001,  20/0002, -)

// IP classifiers: TCP vs ICMP echo-request vs ICMP echo-reply vs other
cl_user_ip::IPClassifier(tcp, icmp type echo, icmp type echo-reply, -)
cl_inf_ip::IPClassifier(tcp,  icmp type echo, icmp type echo-reply, -)

drop_other::Discard

// Queues and schedulers merge ARP and translated-IP streams toward each ToDevice.
// PrioSched gives ARP (input 0) higher priority than IP (input 1).
q_user_arp::Queue
q_inf_arp::Queue
q_user_ip::Queue
q_inf_ip::Queue

user_sched::PrioSched
inf_sched::PrioSched

// ===================== USER side ingress =====================
from_user -> ac_user_in -> cl_user_l2

cl_user_l2[0] -> cnt_user_arp -> user_arp_op
user_arp_op[0] -> user_arp_resp -> q_user_arp   // answer ARP-who-has 10.0.0.1
user_arp_op[1] -> [1]user_arp_q                  // ARP reply → feed into querier cache
user_arp_op[2] -> drop_other

cl_user_l2[1]
    -> Strip(14)
    -> CheckIPHeader
    -> cl_user_ip

cl_user_ip[0] -> cnt_user_tcp  -> [0]tcp_rw    // TCP outbound: source-NAPT
cl_user_ip[1] -> cnt_user_icmp -> [0]icmp_rw   // ICMP echo request: rewrite outbound
cl_user_ip[2] ->                  [0]icmp_rw   // ICMP echo reply (return): rewrite
cl_user_ip[3] -> cnt_drop -> drop_other
cl_user_l2[2] -> cnt_drop -> drop_other

// ===================== INFERENCING side ingress =====================
from_inf -> ac_inf_in -> cl_inf_l2

cl_inf_l2[0] -> cnt_inf_arp -> inf_arp_op
inf_arp_op[0] -> inf_arp_resp -> q_inf_arp      // answer ARP-who-has 100.0.0.1
inf_arp_op[1] -> [1]inf_arp_q                   // ARP reply → feed into querier cache
inf_arp_op[2] -> drop_other

cl_inf_l2[1]
    -> Strip(14)
    -> CheckIPHeader
    -> cl_inf_ip

cl_inf_ip[0] -> cnt_inf_tcp  -> [1]tcp_rw    // TCP inbound: reverse mapping
cl_inf_ip[1] -> cnt_inf_icmp -> [1]icmp_rw   // ICMP echo from inf side
cl_inf_ip[2] ->                 [1]icmp_rw   // ICMP echo reply from inf side
cl_inf_ip[3] -> cnt_drop -> drop_other
cl_inf_l2[2] -> cnt_drop -> drop_other

// ===================== Translated packets → ARPQuerier → ToDevice =====================
// Forward (user→inf): IPRewriter/ICMPPingRewriter output 0
tcp_rw[0]  -> inf_arp_q
icmp_rw[0] -> inf_arp_q

// Reverse (inf→user): IPRewriter/ICMPPingRewriter output 1
tcp_rw[1]  -> user_arp_q
icmp_rw[1] -> user_arp_q

inf_arp_q  -> q_inf_ip
user_arp_q -> q_user_ip

// PrioSched: ARP at priority 0 (higher) to avoid ARP starvation under load
q_inf_arp  -> [0]inf_sched
q_inf_ip   -> [1]inf_sched
inf_sched  -> ac_inf_out  -> to_inf

q_user_arp -> [0]user_sched
q_user_ip  -> [1]user_sched
user_sched -> ac_user_out -> to_user

DriverManager(
    print "NAPT starting (10.0.0.0/24 <-> 100.0.0.0/24)",
    pause,
    print "=== NAPT Report ===",
    print "User-side in  avg pps:    ", $(ac_user_in.rate),
    print "User-side in  total pkts: ", $(ac_user_in.count),
    print "Inf-side  in  avg pps:    ", $(ac_inf_in.rate),
    print "Inf-side  in  total pkts: ", $(ac_inf_in.count),
    print "User-side out avg pps:    ", $(ac_user_out.rate),
    print "User-side out total pkts: ", $(ac_user_out.count),
    print "Inf-side  out avg pps:    ", $(ac_inf_out.rate),
    print "Inf-side  out total pkts: ", $(ac_inf_out.count),
    print "ARP (user side):          ", $(cnt_user_arp.count),
    print "ARP (inf side):           ", $(cnt_inf_arp.count),
    print "TCP translated (user→inf):", $(cnt_user_tcp.count),
    print "TCP translated (inf→user):", $(cnt_inf_tcp.count),
    print "ICMP translated (user→inf):", $(cnt_user_icmp.count),
    print "ICMP translated (inf→user):", $(cnt_inf_icmp.count),
    print "Dropped (non-ARP/TCP/ICMP):", $(cnt_drop.count),
)
