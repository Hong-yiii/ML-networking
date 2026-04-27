// =============================================================================
// MOCK / STUB — transparent L2 bridge for LB-only and incremental testing.
// Replace with real NAPT (IPRewriter + ICMPPingRewriter + ARP) for submission.
// =============================================================================
// 2 variables to hold ports names
define($PORT1 napt-eth1, $PORT2 napt-eth2)
//require(library ./forwarder.click)
//Forwarder($PORT1, $PORT2, $VERBOSE)
// Script will run as soon as the router starts
Script(print "Click forwarder on $PORT1 $PORT2")

// Group common elements in a single block. $port is a parameter used just to print
elementclass L2Forwarder {$port|
	input
	->cnt::Counter
        ->Print
	->Queue
	->output
}

// From where to pick packets
fd1::FromDevice($PORT1, SNIFFER false, METHOD LINUX, PROMISC true)
fd2::FromDevice($PORT2, SNIFFER false, METHOD LINUX, PROMISC true)

// Where to send packets
td1::ToDevice($PORT1, METHOD LINUX)
td2::ToDevice($PORT2, METHOD LINUX)

// Instantiate 2 forwarders, 1 per directions
fd1->fwd1::L2Forwarder($PORT1)->td2
fd2->fwd2::L2Forwarder($PORT2)->td1


// Print something on exit
// DriverManager will listen on router's events
// The pause instruction will wait until the process terminates
// Then the prints will run an Click will exit
=======
define($USER_IF napt-eth1, $INF_IF napt-eth2)
define($USER_IP 10.0.0.1, $INF_IP 100.0.0.1)
define($USER_MAC 02:aa:00:00:00:01, $INF_MAC 02:aa:00:00:00:02)

Script(print "Click NAPT on $USER_IF (10.0.0.0/24) <-> $INF_IF (100.0.0.0/24)")

// Ingress/Egress devices
from_user::FromDevice($USER_IF, SNIFFER false, METHOD LINUX, PROMISC true)
from_inf::FromDevice($INF_IF, SNIFFER false, METHOD LINUX, PROMISC true)
to_user::ToDevice($USER_IF, METHOD LINUX)
to_inf::ToDevice($INF_IF, METHOD LINUX)

// ARP handling for both interfaces
user_arp_resp::ARPResponder($USER_IP $USER_MAC)
inf_arp_resp::ARPResponder($INF_IP $INF_MAC)
user_arp_q::ARPQuerier($USER_IP, $USER_MAC)
inf_arp_q::ARPQuerier($INF_IP, $INF_MAC)

// TCP translator (IPRewriter) and ICMP echo translator (ICMPPingRewriter)
// Use named rewrite patterns so the address/port template is explicit.
napt_user_to_inf::IPRewriterPatterns(user_to_inf 100.0.0.1 1024-65535 - -)
napt_inf_to_user::IPRewriterPatterns(inf_to_user 10.0.0.1 1024-65535 - -)

tcp_rw::IPRewriter(
	pattern user_to_inf 0 1,
	pattern inf_to_user 1 0
)

icmp_rw::ICMPPingRewriter(
	pattern user_to_inf 0 1,
	pattern inf_to_user 1 0
)

// Per-side L2/L3 classifiers
cl_user_l2::Classifier(12/0806, 12/0800, -)
cl_inf_l2::Classifier(12/0806, 12/0800, -)

cl_user_ip::IPClassifier(tcp, icmp type echo, icmp type echo-reply, -)
cl_inf_ip::IPClassifier(tcp, icmp type echo, icmp type echo-reply, -)

drop_other::Discard

// Queue bridges push pipelines (FromDevice/rewriters) into pull ToDevice elements.
q_user_arp::Queue
q_inf_arp::Queue
q_user_ip::Queue
q_inf_ip::Queue

user_sched::PrioSched
inf_sched::PrioSched

user_arp_l2::Classifier(20/0001, 20/0002, -)
inf_arp_l2::Classifier(20/0001, 20/0002, -)

// USER side ingress:
// - ARP requests are answered locally for 10.0.0.1
// - TCP and ICMP echo packets are sent through the NAPT translators
from_user
	-> cl_user_l2

cl_user_l2[0] -> user_arp_l2
user_arp_l2[0] -> user_arp_resp -> q_user_arp
user_arp_l2[1] -> [1]user_arp_q
user_arp_l2[2] -> drop_other
cl_user_l2[1]
	-> Strip(14)
	-> CheckIPHeader
	-> cl_user_ip

cl_user_ip[0] -> [0]tcp_rw
cl_user_ip[1] -> [0]icmp_rw
cl_user_ip[2] -> [0]icmp_rw
cl_user_ip[3] -> drop_other
cl_user_l2[2] -> drop_other

// INFERENCE side ingress:
// - ARP requests are answered locally for 100.0.0.1
// - TCP and ICMP echo packets are sent through the NAPT translators
from_inf
	-> cl_inf_l2

cl_inf_l2[0] -> inf_arp_l2
inf_arp_l2[0] -> inf_arp_resp -> q_inf_arp
inf_arp_l2[1] -> [1]inf_arp_q
inf_arp_l2[2] -> drop_other
cl_inf_l2[1]
	-> Strip(14)
	-> CheckIPHeader
	-> cl_inf_ip

cl_inf_ip[0] -> [1]tcp_rw
cl_inf_ip[1] -> [1]icmp_rw
cl_inf_ip[2] -> [1]icmp_rw
cl_inf_ip[3] -> drop_other
cl_inf_l2[2] -> drop_other

// Re-emit translated IP packets on the opposite interface (ARP resolved by ARPQuerier)
tcp_rw[0] -> inf_arp_q
tcp_rw[1] -> user_arp_q
icmp_rw[0] -> inf_arp_q
icmp_rw[1] -> user_arp_q

inf_arp_q -> q_inf_ip
user_arp_q -> q_user_ip

q_inf_arp -> [0]inf_sched
q_inf_ip -> [1]inf_sched
inf_sched -> to_inf

q_user_arp -> [0]user_sched
q_user_ip -> [1]user_sched
user_sched -> to_user
