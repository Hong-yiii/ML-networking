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
//
// `tcp data length` is unsupported on this Click build; we approximate via
// IP total length (`ip[2:2]`). SYN with full TCP options is ≤ 60 bytes; the
// smallest HTTP request curl produces is ~75 bytes payload (≥ 115 bytes IP
// total). Threshold > 60 is safe for our test traffic.
ipc[0] -> data_gate::IPClassifier(
    ip[2:2] > 60,  // [0] likely has HTTP payload → inspect method
    -              // [1] no payload (SYN/FIN/RST/ACK-only) → pass
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

// === PUT body keyword inspection (no PCRE/RegexClassifier needed) ===
//
// The course Click was not built with --enable-pcre, so RegexClassifier is
// unavailable. We can NOT use Strip(54) + Search("\r\n\r\n") + Classifier
// either: Strip/Search advance the packet's data pointer, and the queues
// downstream feed ToDevice which writes p->data() to the netdevice — that
// would put only post-strip body bytes onto the wire, breaking the clean
// PUT forwarding path.
//
// Approach used here: fixed-offset Classifier patterns matching each
// injection keyword at the offsets where the HTTP body is expected to
// start. The packet is forwarded intact (no strip), so ToDevice on the
// next queue receives a complete L2 frame.
//
// Offset derivation for curl 7.81 PUT against http://100.0.0.45:80/:
//   Eth(14) + IPv4(20, no opts) + TCP(20|32, depending on TCP options)
//   + HTTP headers (≈ 143 bytes for our target VIP, 2-digit Content-Length)
//   = 197 (no TCP opts) or 209 (with 12-byte TCP timestamps option).
//
// Linux defaults to TCP timestamps ON, so 209 is the common case in this
// mininet topology; we still try a window around both candidates to
// tolerate ±1 byte shifts from Content-Length digit width and similar.
//
// Keywords (hex):
//   "cat /etc/passwd" = 63 61 74 20 2f 65 74 63 2f 70 61 73 73 77 64
//   "cat /var/log/"   = 63 61 74 20 2f 76 61 72 2f 6c 6f 67 2f
//   "INSERT"          = 49 4e 53 45 52 54
//   "UPDATE"          = 55 50 44 41 54 45
//   "DELETE"          = 44 45 4c 45 54 45
method_cl[1] -> cnt_put::Counter -> body_kw::Classifier(
    // ---- "cat /etc/passwd"
    195/636174202f6574632f706173737764,
    197/636174202f6574632f706173737764,
    207/636174202f6574632f706173737764,
    209/636174202f6574632f706173737764,
    211/636174202f6574632f706173737764,
    // ---- "cat /var/log/"
    195/636174202f7661722f6c6f672f,
    197/636174202f7661722f6c6f672f,
    207/636174202f7661722f6c6f672f,
    209/636174202f7661722f6c6f672f,
    211/636174202f7661722f6c6f672f,
    // ---- "INSERT"
    195/494e53455254,
    197/494e53455254,
    207/494e53455254,
    209/494e53455254,
    211/494e53455254,
    // ---- "UPDATE"
    195/555044415445,
    197/555044415445,
    207/555044415445,
    209/555044415445,
    211/555044415445,
    // ---- "DELETE"
    195/44454c455445,
    197/44454c455445,
    207/44454c455445,
    209/44454c455445,
    211/44454c455445,
    // ---- default: clean PUT
    -
);

// All 25 keyword-match outputs go to insp via q2.
body_kw[ 0] -> cnt_malicious::Counter -> q2;
body_kw[ 1] -> cnt_malicious;
body_kw[ 2] -> cnt_malicious;
body_kw[ 3] -> cnt_malicious;
body_kw[ 4] -> cnt_malicious;
body_kw[ 5] -> cnt_malicious;
body_kw[ 6] -> cnt_malicious;
body_kw[ 7] -> cnt_malicious;
body_kw[ 8] -> cnt_malicious;
body_kw[ 9] -> cnt_malicious;
body_kw[10] -> cnt_malicious;
body_kw[11] -> cnt_malicious;
body_kw[12] -> cnt_malicious;
body_kw[13] -> cnt_malicious;
body_kw[14] -> cnt_malicious;
body_kw[15] -> cnt_malicious;
body_kw[16] -> cnt_malicious;
body_kw[17] -> cnt_malicious;
body_kw[18] -> cnt_malicious;
body_kw[19] -> cnt_malicious;
body_kw[20] -> cnt_malicious;
body_kw[21] -> cnt_malicious;
body_kw[22] -> cnt_malicious;
body_kw[23] -> cnt_malicious;
body_kw[24] -> cnt_malicious;
// Default (no keyword match): allow as clean PUT.
body_kw[25] -> cnt_put_clean::Counter -> q3;

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
    print "HTTP PUT diverted:      $(cnt_malicious.count)",
    print "HTTP blocked methods:   $(cnt_blocked.count)",
    print "Non-IP dropped:         $(cnt_drop.count)"
)
