# IDS payload checks without regex

This guide explains how to implement the assignment's IDS payload keyword checks **without** `RegexClassifier`, using only standard Click elements (`Search`, `Classifier`, `Strip`).

## Why this approach

- The assignment expects exact HTTP-method and payload-pattern inspection.
- Some Click builds do not include PCRE support, so `RegexClassifier` is unavailable.
- `Search + Classifier` gives deterministic, prefix-based matching and avoids regex dependency.

## Requirement to satisfy

For HTTP requests:

- Allow only `POST` and `PUT` to continue toward `lb1`.
- Divert all other methods to `insp`.
- For `PUT`, inspect payload and divert if payload starts with one of:
  - `cat /etc/passwd`
  - `cat /var/log/`
  - `INSERT`
  - `UPDATE`
  - `DELETE`

## High-level pipeline

1. Classify ARP/ICMP/TCP as usual.
2. For TCP dst port 80, classify HTTP method at payload start (your existing offset-based method check).
3. `POST` -> allow.
4. Non-`POST`/`PUT` methods -> divert.
5. `PUT` -> parse request body boundary, then run prefix matching on first body bytes.

## Suggested Click structure

Use this as a template for the `PUT` branch (adapt names/queues to your file):

```click
// method_cl[1] is PUT branch after method classification
method_cl[1]
  -> cnt_put::Counter
  -> Strip(54)                  // strip Eth+IPv4(no opts)+TCP(no opts)
  -> find_body::Search("\r\n\r\n")
  -> body_kw::Classifier(
       0/636174202f6574632f706173737764,  // "cat /etc/passwd"
       0/636174202f7661722f6c6f672f,      // "cat /var/log/"
       0/494e53455254,                    // "INSERT"
       0/555044415445,                    // "UPDATE"
       0/44454c455445,                    // "DELETE"
       -                                  // clean PUT
     );

// suspicious
body_kw[0] -> cnt_malicious::Counter -> q2;
body_kw[1] -> cnt_malicious;
body_kw[2] -> cnt_malicious;
body_kw[3] -> cnt_malicious;
body_kw[4] -> cnt_malicious;

// clean PUT
body_kw[5] -> cnt_put_clean::Counter -> q3;
```

## Notes on `Search`

`Search("\r\n\r\n")` is used to locate the HTTP header terminator.

Depending on Click version/build, `Search` behavior can differ (e.g., output semantics and pointer handling). Validate with:

```bash
man Search
```

If needed, add a small debugging chain (`Print`) to confirm that the packet pointer reaches the first payload byte before `Classifier`.

## Important caveat: fixed offset `54`

`Strip(54)` assumes:

- Ethernet header = 14 bytes
- IPv4 header = 20 bytes (no IP options)
- TCP header = 20 bytes (no TCP options)

This matches most simple `curl` traffic used in the course tests, but it is not fully robust for packets with IP/TCP options. If robust parsing is required, use header-aware elements before stripping.

## Validation checklist

After wiring this:

1. `POST` to VIP succeeds.
2. `PUT` with empty/benign body succeeds.
3. `GET/HEAD/OPTIONS/DELETE/...` are diverted (service access fails as expected).
4. `PUT` body starting with each required keyword is diverted to inspector.
5. IDS counters show:
   - increased `cnt_post` for allowed POST
   - increased `cnt_put_clean` for benign PUT
   - increased `cnt_malicious` for keyword PUT
   - increased blocked-method counter for non-POST/PUT methods

## Why this is better than length heuristics

- Length-based checks are approximate and can produce false positives/false negatives.
- Prefix matching on body bytes aligns with assignment intent and is reproducible across runs.
