// IDS — IK2221 Phase 1
// eth1 (ids-eth1): toward sw2 / NAPT (client direction)
// eth2 (ids-eth2): toward insp  (suspicious-traffic sink)
// eth3 (ids-eth3): toward lb1   (allowed traffic)
//
// Policy (from client side, dst port 80):
//   - TCP control packets (SYN/FIN/RST/ACK-only, i.e. no payload) → pass through
//   - POST                 → pass through
//   - PUT (clean body)     → pass through
//   - PUT (injection keyword in body) → redirect to insp
//   - All other methods    → redirect to insp
//   ARP, ICMP, TCP responses (src port 80), other TCP → transparent pass through
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

q1::Queue -> td1
q2::Queue -> td2
q3::Queue -> td3

// === Ingress from client side (eth1) ===
fd1 -> ac_in1::AverageCounter -> cl1::Classifier(
    12/0806,        // [0] ARP
    12/0800 23/01,  // [1] ICMP
    12/0800 23/06,  // [2] TCP
    -               // [3] other — drop
);

// Return traffic from lb1 (eth3) and any traffic from insp (eth2) → back to clients.
fd3 -> ac_in3::AverageCounter -> q1
fd2 -> ac_in2::AverageCounter -> q1

// ARP and ICMP: pass transparently toward lb1 (eth3)
cl1[0] -> cnt_arp::Counter  -> q3
cl1[1] -> cnt_icmp::Counter -> q3
cl1[3] -> cnt_drop::Counter -> Discard

// TCP: split into to-port-80 (outbound requests), from-port-80 (responses), other
cl1[2] -> ipc::IPClassifier(
    dst port 80,  // [0] client → VIP:80 (requests and TCP control)
    src port 80,  // [1] lb1 → client (responses arriving on eth1, unusual)
    -             // [2] other TCP signaling (e.g. non-80 flows)
);

ipc[1] -> cnt_resp::Counter   -> q3   // responses → pass through
ipc[2] -> cnt_tcpsig::Counter -> q3   // other TCP → pass through

// === TCP to port 80: gate on whether the packet carries HTTP payload ===
// Packets without a TCP payload (SYN, FIN, RST, pure ACK) must pass transparently.
// Only data-carrying segments are handed to the HTTP method classifier.
ipc[0] -> data_gate::IPClassifier(
    tcp and tcp data length >= 1,  // [0] has payload → inspect HTTP method
    -                               // [1] no payload (SYN/FIN/RST/ACK-only) → pass
);
data_gate[1] -> cnt_tcpsig         // share counter with other TCP control

// === HTTP method classification (at offset 54 = start of TCP payload) ===
// Ethernet(14) + IP(20, no opts) + TCP(20, no opts) = 54
data_gate[0] -> method_cl::Classifier(
    54/504f5354,  // [0] "POST" → allow
    54/50555420,  // [1] "PUT " → inspect body
    -             // [2] other methods (GET/HEAD/DELETE/OPTIONS/…) → insp
);

method_cl[0] -> cnt_post::Counter    -> q3   // POST allowed
method_cl[2] -> cnt_blocked::Counter -> q2   // other methods → insp

// === PUT body inspection using RegexClassifier (full-packet scan) ===
// RegexClassifier scans the entire packet so keywords in the HTTP body are found
// regardless of header length. Output N (index 5) = no match = clean PUT.
method_cl[1] -> cnt_put::Counter -> regex_payload::RegexClassifier(
    "cat /etc/passwd",
    "cat /var/log/",
    "INSERT",
    "UPDATE",
    "DELETE"
);

regex_payload[0] -> cnt_malicious::Counter -> q2   // keyword matched → insp
regex_payload[1] -> cnt_malicious
regex_payload[2] -> cnt_malicious
regex_payload[3] -> cnt_malicious
regex_payload[4] -> cnt_malicious
regex_payload[5] -> cnt_put_clean::Counter -> q3   // clean PUT → allow

DriverManager(
    print "IDS starting",
    pause,
    print "=== IDS Report ===",
    print "ARP packets:            $(cnt_arp.count)",
    print "ICMP packets:           $(cnt_icmp.count)",
    print "TCP signaling / ctrl:   $(cnt_tcpsig.count)",
    print "HTTP responses:         $(cnt_resp.count)",
    print "HTTP POST allowed:      $(cnt_post.count)",
    print "HTTP PUT clean:         $(cnt_put_clean.count)",
    print "HTTP PUT malicious:     $(cnt_malicious.count)",
    print "HTTP blocked methods:   $(cnt_blocked.count)",
    print "Non-IP dropped:         $(cnt_drop.count)",
)
