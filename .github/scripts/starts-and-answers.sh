#!/bin/bash
#
# Does the DNS server start, and does it answer in what it is there for?
# Run by ci.yml and nightly.yml on the Debian leg, after a Release build.
#
# Records in a configuration file of their own, the server started on ports
# nobody else has and none below 1024 - 53 would need CAP_NET_BIND_SERVICE -
# and nine questions asked of it:
#
#  * "/" must come back as the embedded web interface - that it is inside the
#    assembly rather than merely to have been built;
#  * the JSON API must answer 401: it is nobody's business until somebody has
#    signed in, and a 200 would mean the door had come off;
#  * the SSH server - the command line - must say its version;
#  * dig must get the A record over UDP and over TCP;
#  * and the AAAA, the TXT and the CNAME record, each as a zone file writes it;
#  * the MX and the SRV record, and the PTR record of 192.0.2.10 (dig -x);
#  * the SOA and NS records the zone example.org. makes;
#  * NXDOMAIN for a name it has no record of - authoritative, with the
#    zone's SOA in the authority section (RFC 2308);
#  * and the A record over SSH, asked by OpenSSH's ssh -s as a DNS client of
#    the section with a key of its own, over the subsystem
#    dns@open.charging.cloud - which carries DNS as over TCP.
#
# Everything it writes goes to a temporary directory: a first start makes an
# account store, a certificate store and a log, and none of that belongs in a
# workspace whose cleanliness the build stamps into every assembly.

set -u

tmp="$(mktemp -d)"

# The key of the DNS client that asks over SSH - made here, for this run alone.
ssh-keygen -q -t ed25519 -N '' -C smoke -f "$tmp/client"

cat > "$tmp/configuration.json" <<'JSON'
{ "dnsServer": { "records": [ "www.example.org.  600 IN A     192.0.2.10",
                               "www.example.org.  600 IN AAAA  2001:db8::10",
                               "example.org.      600 IN TXT   \"v=spf1 -all\"",
                               "docs.example.org. 600 IN CNAME www.example.org.",
                               "ns.example.org.   600 IN A     192.0.2.53",
                               "example.org.      600 IN MX    10 mail.example.org.",
                               "_ocpp._tcp.example.org.  600 IN SRV 0 5 443 csms.example.org.",
                               "10.2.0.192.in-addr.arpa. 600 IN PTR www.example.org." ],
                 "zones":   [ { "name": "example.org.", "serial": 2026112500 } ],
                 "ssh":     { "clients": [ { "name": "smoke", "keys": [ "SMOKE_KEY" ] } ] } } }
JSON

sed -i "s|SMOKE_KEY|$(cat "$tmp/client.pub")|" "$tmp/configuration.json"

dotnet DNSServerCLI/bin/Release/net11.0/DNSServerCLI.dll \
    --port        18362 \
    --ssh-port    22462 \
    --dns-port    15353 \
    --listen      127.0.0.1 \
    --accounts    "$tmp/accounts" \
    --config      "$tmp/configuration.json" \
    --log-file    "$tmp/logs" \
    < /dev/null > "$tmp/console.log" 2>&1 &
pid=$!

# curl -w writes "000" itself when it could not connect; "|| true" keeps its
# exit code from ending the script, and ${:-000} is for no curl at all.
root=000
for _ in $(seq 1 60); do
    root="$(curl -sS -o "$tmp/index.html" -w '%{http_code}' http://127.0.0.1:18362/ 2>/dev/null || true)"
    root="${root:-000}"
    [ "$root" != 000 ] && break
    # Gone rather than slow: stop waiting for it.
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done

api="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18362/api/v1/dnsServer 2>/dev/null || true)"
api="${api:-000}"

# The first line the SSH server says: its version, "SSH-2.0-...".
ssh_banner="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22462 && head -n 1 <&3' 2>/dev/null | tr -d '\r' || true)"

udp="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 www.example.org A 2>/dev/null || true)"
tcp="$(dig @127.0.0.1 -p 15353 +tcp +short +time=2 +tries=1 www.example.org A 2>/dev/null || true)"
aaaa="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 www.example.org AAAA 2>/dev/null || true)"
txt="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 example.org TXT 2>/dev/null || true)"
cname="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 docs.example.org CNAME 2>/dev/null || true)"
mx="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 example.org MX 2>/dev/null || true)"
srv="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 _ocpp._tcp.example.org SRV 2>/dev/null || true)"
ptr="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 -x 192.0.2.10 2>/dev/null || true)"
soa="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 example.org SOA 2>/dev/null || true)"
ns="$(dig @127.0.0.1 -p 15353 +short +time=2 +tries=2 example.org NS 2>/dev/null || true)"
dig @127.0.0.1 -p 15353 +time=2 +tries=1 nothere.example.org A > "$tmp/nothere.txt" 2>/dev/null || true
none="$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' "$tmp/nothere.txt")"
none_flags="$(sed -n 's/.*flags: \([a-z ]*\);.*/\1/p' "$tmp/nothere.txt")"
none_soa="$(awk '/AUTHORITY SECTION/ { f = 1; next } f && $4 == "SOA" { print $1; exit }' "$tmp/nothere.txt")"

# www.example.org A over SSH: a two-octet length, then the query with the id
# 0x1234 - and the answer the same way, the address 192.0.2.10 (c000020a) in
# it. The host key is not checked: this is the server just started here.
printf '\x00\x21\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x07example\x03org\x00\x00\x01\x00\x01' > "$tmp/query.bin"
timeout 15 ssh -i "$tmp/client" -p 22462 -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -s smoke@127.0.0.1 dns@open.charging.cloud < "$tmp/query.bin" > "$tmp/answer.bin" 2> "$tmp/ssh.txt" || true
over_ssh="$(od -An -tx1 "$tmp/answer.bin" 2>/dev/null | tr -d ' \n')"

kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

echo "GET /                   -> $root"
echo "GET /api/v1/dnsServer   -> $api"
echo "SSH 22462               -> ${ssh_banner:-nothing}"
echo "UDP www.example.org     -> ${udp:-nothing}"
echo "TCP www.example.org     -> ${tcp:-nothing}"
echo "AAAA www.example.org    -> ${aaaa:-nothing}"
echo "TXT example.org         -> ${txt:-nothing}"
echo "CNAME docs.example.org  -> ${cname:-nothing}"
echo "MX example.org          -> ${mx:-nothing}"
echo "SRV _ocpp._tcp          -> ${srv:-nothing}"
echo "PTR 192.0.2.10          -> ${ptr:-nothing}"
echo "SOA example.org         -> ${soa:-nothing}"
echo "NS example.org          -> ${ns:-nothing}"
echo "UDP nothere.example.org -> ${none:-nothing}, flags ${none_flags:-none}, SOA of ${none_soa:-nothing}"
echo "SSH www.example.org     -> ${over_ssh:-nothing}"

# What the banner says this was built from - in every run, not only a red one.
awk '/^  built from/ { f = 1 } f && !/^  built from/ && !/^                 / { f = 0 } f' "$tmp/console.log" || true

fault=0

if [ "$root" != 200 ]; then
    echo "The web interface did not answer."
    fault=1
elif ! grep -q "<title>DNS Server</title>" "$tmp/index.html"; then
    echo "Something answered, but it is not the embedded web interface."
    fault=1
fi

[ "$api"  = 401 ]        || { echo "The JSON API answered $api where 401 was expected: it is supposed to be shut to anyone not signed in."; fault=1; }

case "$ssh_banner" in
    SSH-2.0-*) ;;
    *) echo "The SSH server did not answer on 22462."; fault=1 ;;
esac

[ "$udp"  = 192.0.2.10 ] || { echo "DNS over UDP did not answer with the record."; fault=1; }
[ "$tcp"  = 192.0.2.10 ] || { echo "DNS over TCP did not answer with the record."; fault=1; }
[ "$aaaa" = 2001:db8::10 ]       || { echo "DNS did not answer with the AAAA record."; fault=1; }
[ "$txt"  = '"v=spf1 -all"' ]    || { echo "DNS did not answer with the TXT record."; fault=1; }
[ "$cname" = www.example.org. ] || { echo "DNS did not answer with the CNAME record."; fault=1; }
[ "$mx"  = "10 mail.example.org." ]        || { echo "DNS did not answer with the MX record."; fault=1; }
[ "$srv" = "0 5 443 csms.example.org." ]   || { echo "DNS did not answer with the SRV record."; fault=1; }
[ "$ptr" = www.example.org. ]              || { echo "DNS did not answer with the PTR record of 192.0.2.10."; fault=1; }
[ "$soa" = "ns.example.org. hostmaster.example.org. 2026112500 86400 7200 1209600 3600" ] || { echo "DNS did not answer with the SOA the zone makes."; fault=1; }
[ "$ns"  = ns.example.org. ]     || { echo "DNS did not answer with the NS record the zone makes."; fault=1; }
[ "$none" = NXDOMAIN ]   || { echo "A name without a record was not answered NXDOMAIN."; fault=1; }
case " $none_flags " in
    *" aa "*) ;;
    *) echo "The NXDOMAIN was not authoritative."; fault=1 ;;
esac
[ "$none_soa" = example.org. ]  || { echo "The NXDOMAIN did not carry the SOA of the zone."; fault=1; }
case "$over_ssh" in
    ????1234*c000020a*) ;;
    *) echo "DNS over SSH did not answer with the record."; cat "$tmp/ssh.txt"; fault=1 ;;
esac

if [ "$fault" != 0 ]; then
    echo
    echo "What it said, without the first-start password:"
    grep -v -i password "$tmp/console.log" || echo "(nothing at all)"
    exit 1
fi
