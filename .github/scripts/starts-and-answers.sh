#!/bin/bash
#
# Does the DNS server start, and does it answer in what it is there for?
# Run by ci.yml and nightly.yml on the Debian leg, after a Release build.
#
# Records in a configuration file of their own, the server started on ports
# nobody else has and none below 1024 - 53 would need CAP_NET_BIND_SERVICE -
# and six questions asked of it:
#
#  * "/" must come back as the embedded web interface - that it is inside the
#    assembly rather than merely to have been built;
#  * the JSON API must answer 401: it is nobody's business until somebody has
#    signed in, and a 200 would mean the door had come off;
#  * the SSH server - the command line - must say its version;
#  * dig must get the A record over UDP and over TCP;
#  * and the AAAA, the TXT and the CNAME record, each as a zone file writes it;
#  * and NXDOMAIN for a name it has no record of.
#
# Everything it writes goes to a temporary directory: a first start makes an
# account store, a certificate store and a log, and none of that belongs in a
# workspace whose cleanliness the build stamps into every assembly.

set -u

tmp="$(mktemp -d)"

cat > "$tmp/configuration.json" <<'JSON'
{ "dnsServer": { "records": [ "www.example.org.  600 IN A     192.0.2.10",
                               "www.example.org.  600 IN AAAA  2001:db8::10",
                               "example.org.      600 IN TXT   \"v=spf1 -all\"",
                               "docs.example.org. 600 IN CNAME www.example.org." ] } }
JSON

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
none="$(dig @127.0.0.1 -p 15353 +time=2 +tries=1 nothere.example.org A 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' || true)"

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
echo "UDP nothere.example.org -> ${none:-nothing}"

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
[ "$none" = NXDOMAIN ]   || { echo "A name without a record was not answered NXDOMAIN."; fault=1; }

if [ "$fault" != 0 ]; then
    echo
    echo "What it said, without the first-start password:"
    grep -v -i password "$tmp/console.log" || echo "(nothing at all)"
    exit 1
fi
