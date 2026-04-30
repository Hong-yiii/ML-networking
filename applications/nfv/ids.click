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
// NOTE: PUT body inspection uses Search to reach the HTTP body and Classifier
// on hex prefixes, so we only inspect the first bytes of the payload.

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

// Inspector egress queue (simpler than a MixedQueue fan-in tree)
q_insp::Queue

q3_arp::Queue
q3_icmp::Queue
q3_resp::Queue
q3_sig::Queue
q3_post::Queue
q3_put_clean::Queue
sched3::PrioSched

// Schedulers to merge multiple inspector-bound flows so a single Counter can be used
// schedulers removed for inspector aggregation; use per-branch counters feeding `q_insp`

// Counters (single declaration to avoid redeclaration errors)
cnt_arp::Counter
cnt_icmp::Counter
cnt_drop::Counter
cnt_resp::Counter
cnt_tcpsig::Counter
cnt_tcpsig_no_payload::Counter
cnt_post::Counter
cnt_put::Counter
// Per-branch counters for inspector (push-only usage)
cnt_inspect_get::Counter
cnt_inspect_head::Counter
cnt_inspect_delete::Counter
cnt_inspect_options::Counter
cnt_inspect_trace::Counter
cnt_inspect_connect::Counter
cnt_inspect_default::Counter
cnt_inspect_put_search::Counter
cnt_inspect_put_body0::Counter
cnt_inspect_put_body1::Counter
cnt_inspect_put_body2::Counter
cnt_inspect_put_body3::Counter
cnt_inspect_put_body4::Counter
cnt_put_clean::Counter

q1_lb -> [0]sched1
q1_insp -> [1]sched1
sched1 -> td1

q_insp -> td2

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
cl1[0] -> cnt_arp -> q3_arp
cl1[1] -> cnt_icmp -> q3_icmp
cl1[3] -> cnt_drop -> Discard

// TCP: split into to-port-80 (outbound requests), from-port-80 (responses), other
cl1[2] -> ipc::IPClassifier(
    dst port 80,  // [0] client -> VIP:80 (requests and TCP control)
    src port 80,  // [1] lb1 -> client (responses arriving on eth1, unusual)
    -             // [2] other TCP signaling (e.g. non-80 flows)
);

ipc[1] -> cnt_resp   -> q3_resp   // responses -> pass through
ipc[2] -> cnt_tcpsig -> q3_sig    // other TCP -> pass through

// === HTTP method classification ===
// Inspect only actual HTTP requests by matching the method bytes.
// Anything on dst port 80 that does not start with a supported HTTP method
// is treated as TCP signaling/control and forwarded transparently.
ipc[0] -> strip_eth::Strip(14) -> checkip::CheckIPHeader -> strip_tcp::StripTCPHeader -> checklen::CheckLength(0);

// If packet has payload (length>0) go to HTTP method classifier, else treat as TCP signalling
checklen[1] -> method_cl::Classifier(
    0/504f535420,      // "POST "
    0/50555420,        // "PUT "
    0/47455420,        // "GET "
    0/4845414420,      // "HEAD "
    0/44454c45544520,  // "DELETE "
    0/4f5054494f4e5320,// "OPTIONS "
    0/545241434520,    // "TRACE "
    0/434f4e4e45435420, // "CONNECT "
    -
);

checklen[0] -> cnt_tcpsig_no_payload -> q3_sig

method_cl[0] -> cnt_post    -> q3_post   // POST allowed
method_cl[1] -> cnt_put -> put_search :: Search("\r\n\r\n");

put_search[0] -> put_body::Classifier(
        0/636174202f6574632f706173737764,  // cat /etc/passwd
        0/636174202f7661722f6c6f672f,      // cat /var/log/
        0/494e53455254,                    // INSERT
        0/555044415445,                    // UPDATE
        0/44454c455445,                    // DELETE
        -
    );
// Method-based redirects: merge into a scheduler, count once, then send to inspector tree
method_cl[2] -> cnt_inspect_get -> q_insp   // GET -> inspector
method_cl[3] -> cnt_inspect_head -> q_insp  // HEAD -> inspector
method_cl[4] -> cnt_inspect_delete -> q_insp// DELETE -> inspector
method_cl[5] -> cnt_inspect_options -> q_insp// OPTIONS -> inspector
method_cl[6] -> cnt_inspect_trace -> q_insp // TRACE -> inspector
method_cl[7] -> cnt_inspect_connect -> q_insp// CONNECT -> inspector
method_cl[8] -> cnt_inspect_default -> q_insp   // default/unknown HTTP methods -> inspector

// Clean PUT is allowed; malformed or malicious PUT goes to the inspector sink.
// Merge payload-detected PUT flows into a scheduler, count once, then forward to inspector
// Search: output 0 = match, 1 = no match. Match should go to inspector.
put_search[1] -> cnt_inspect_put_search -> q_insp
put_body[0] -> cnt_inspect_put_body0 -> q_insp   // keyword matched -> insp
put_body[1] -> cnt_inspect_put_body1 -> q_insp
put_body[2] -> cnt_inspect_put_body2 -> q_insp
put_body[3] -> cnt_inspect_put_body3 -> q_insp
put_body[4] -> cnt_inspect_put_body4 -> q_insp
put_body[5] -> cnt_put_clean -> q3_put_clean   // clean PUT -> allow

DriverManager(
    print "IDS starting",
    pause,
    print "=== IDS Report ===",
    print "ARP packets:            ", read cnt_arp.count,
    print "ICMP packets:           ", read cnt_icmp.count,
    print "TCP signaling (other):  ", read cnt_tcpsig.count,
    print "TCP signaling (port80 no-payload):", read cnt_tcpsig_no_payload.count,
    print "HTTP responses:         ", read cnt_resp.count,
    print "HTTP POST allowed:      ", read cnt_post.count,
    print "HTTP PUT total:         ", read cnt_put.count,
    print "HTTP PUT clean:         ", read cnt_put_clean.count,
    print "Inspector(GET):", read cnt_inspect_get.count,
    print "Inspector(HEAD):", read cnt_inspect_head.count,
    print "Inspector(DELETE):", read cnt_inspect_delete.count,
    print "Inspector(OPTIONS):", read cnt_inspect_options.count,
    print "Inspector(TRACE):", read cnt_inspect_trace.count,
    print "Inspector(CONNECT):", read cnt_inspect_connect.count,
    print "Inspector(DEFAULT):", read cnt_inspect_default.count,
    print "Inspector(PUT search):", read cnt_inspect_put_search.count,
    print "Inspector(PUT body0):", read cnt_inspect_put_body0.count,
    print "Inspector(PUT body1):", read cnt_inspect_put_body1.count,
    print "Inspector(PUT body2):", read cnt_inspect_put_body2.count,
    print "Inspector(PUT body3):", read cnt_inspect_put_body3.count,
    print "Inspector(PUT body4):", read cnt_inspect_put_body4.count,
    print "Non-IP dropped:         ", read cnt_drop.count,
)
