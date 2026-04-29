// IDS — IK2221 Phase 1
// eth1 (ids-eth1): toward sw2 / NAPT (client direction)
// eth2 (ids-eth2): toward insp  (suspicious-traffic sink)
// eth3 (ids-eth3): toward lb1   (allowed traffic)
//
// Policy (from client side, dst port 80):
//   - TCP control packets (SYN/FIN/RST/ACK-only, i.e. no payload) -> pass through
//   - POST                 -> pass through
//   - PUT (clean body)     -> pass through
//   - PUT (injection keyword in body) -> redirect to insp
//   - All other methods    -> redirect to insp
//   ARP, ICMP, TCP responses (src port 80), other TCP -> transparent pass through
//
// NOTE: The payload inspection uses RegexClassifier which requires PCRE-enabled Click
// (standard on the IK2221 VM). If unavailable, rebuild Click with --enable-pcre.

define($PORT1 ids-eth1)
define($PORT2 ids-eth2)
define($PORT3 ids-eth3)

Script(print "IDS starting on $PORT1 (clients) / $PORT2 (insp) / $PORT3 (lb1)")

fd1::FromDevice($PORT1, SNIFFER false, METHOD LINUX, PROMISC true)
fd2::FromDevice($PORT2, SNIFFER false, METHOD LINUX, PROMISC true)
fd3::FromDevice($PORT3, SNIFFER false, METHOD LINUX, PROMISC true)

td1::ToDevice($PORT1, METHOD LINUX)
td2::ToDevice($PORT2, METHOD LINUX)
td3::ToDevice($PORT3, METHOD LINUX)

q1_lb::Queue
q1_insp::Queue
sched1::PrioSched

q2_m0::Queue
q2_m1::Queue
q2_m2::Queue
q2_m3::Queue
q2_m4::Queue
q2_oth::Queue
sched2::PrioSched

q3_arp::Queue
q3_icmp::Queue
q3_resp::Queue
q3_sig::Queue
q3_post::Queue
q3_put_clean::Queue
sched3::PrioSched

cnt_arp::Counter
cnt_icmp::Counter
cnt_resp::Counter
cnt_tcpsig::Counter
cnt_post::Counter
cnt_put::Counter
cnt_malicious::Counter
cnt_blocked::Counter
cnt_drop::Counter

q1_lb -> [0]sched1
q1_insp -> [1]sched1
sched1 -> td1

q2_m0 -> [0]sched2
q2_m1 -> [1]sched2
q2_m2 -> [2]sched2
q2_m3 -> [3]sched2
q2_m4 -> [4]sched2
q2_oth -> [5]sched2
sched2 -> td2

q3_arp -> [0]sched3
q3_icmp -> [1]sched3
q3_resp -> [2]sched3
q3_sig -> [3]sched3
q3_post -> [4]sched3
q3_put_clean -> [5]sched3
sched3 -> td3

// === Ingress from client side (eth1) ===
fd1 -> ac_in1::AverageCounter -> cl1::Classifier(
    12/0806,        // [0] ARP
    12/0800 23/01,  // [1] ICMP
    12/0800 23/06,  // [2] TCP
    -               // [3] other — drop
);

// Return traffic from lb1 (eth3) and any traffic from insp (eth2) -> back to clients.
fd3 -> ac_in3::AverageCounter -> q1_lb
fd2 -> ac_in2::AverageCounter -> q1_insp

// ARP and ICMP: pass transparently toward lb1 (eth3)
cl1[0] -> cnt_arp::Counter  -> q3_arp
cl1[1] -> cnt_icmp::Counter -> q3_icmp
cl1[3] -> cnt_drop::Counter -> Discard

// TCP: split into to-port-80 (outbound requests), from-port-80 (responses), other
cl1[2] -> ipc::IPClassifier(
    dst port 80,  // [0] client -> VIP:80 (requests and TCP control)
    src port 80,  // [1] lb1 -> client (responses arriving on eth1, unusual)
    -             // [2] other TCP signaling (e.g. non-80 flows)
);

ipc[1] -> cnt_resp::Counter   -> q3_resp   // responses -> pass through
ipc[2] -> cnt_tcpsig::Counter -> q3_sig    // other TCP -> pass through

// === HTTP method classification ===
// RegexClassifier scans the packet payload, so this works even when curl adds
// TCP options and the TCP header length is not the minimum 20 bytes.
ipc[0] -> method_cl::RegexClassifier(
    "POST ",
    "PUT ",
    "GET ",
    "HEAD ",
    "DELETE ",
    "OPTIONS ",
    "TRACE ",
    "CONNECT "
);

method_cl[0] -> cnt_post::Counter    -> q3_post   // POST allowed
method_cl[1] -> cnt_put::Counter -> regex_payload::RegexClassifier(
    "cat /etc/passwd",
    "cat /var/log/",
    "INSERT",
    "UPDATE",
    "DELETE"
);
method_cl[2] -> cnt_blocked::Counter -> Discard   // GET -> blocked
method_cl[3] -> Discard                                  // HEAD -> blocked
method_cl[4] -> Discard                                  // DELETE -> blocked
method_cl[5] -> Discard                                  // OPTIONS -> blocked
method_cl[6] -> Discard                                  // TRACE -> blocked
method_cl[7] -> Discard                                  // CONNECT -> blocked
method_cl[8] -> Discard                                  // no match -> blocked

// Clean PUT is allowed; malicious PUT goes to the inspector sink.
regex_payload[0] -> cnt_malicious::Counter -> q2_m0   // keyword matched -> insp
regex_payload[1] -> Discard
regex_payload[2] -> Discard
regex_payload[3] -> Discard
regex_payload[4] -> Discard
regex_payload[5] -> cnt_put_clean::Counter -> q3_put_clean   // clean PUT -> allow

DriverManager(
    print "IDS starting",
    pause,
    print "=== IDS Report ===",
    print "ARP packets:            ", read cnt_arp.count,
    print "ICMP packets:           ", read cnt_icmp.count,
    print "TCP signaling / ctrl:   ", read cnt_tcpsig.count,
    print "HTTP responses:         ", read cnt_resp.count,
    print "HTTP POST allowed:      ", read cnt_post.count,
    print "HTTP PUT clean:         ", read cnt_put_clean.count,
    print "HTTP PUT malicious:     ", read cnt_malicious.count,
    print "HTTP blocked methods:   ", read cnt_blocked.count,
    print "Non-IP dropped:         ", read cnt_drop.count,
)
