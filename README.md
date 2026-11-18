# DNSServerCLI

[![CI](https://github.com/OpenChargingCloud/DNSServerCLI/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenChargingCloud/DNSServerCLI/actions/workflows/ci.yml)

One name server for a local network: authoritative DNS over UDP and TCP,
with a JSON API and a prompt - at the console and over SSH - until 'quit' or
Ctrl+C.

It answers with the records it is given: at its prompt (`aRecords add
www.lan 192.168.1.10`), over SSH, or in the `dnsServer` section of its
configuration file - and whatever is added or removed at the prompt is in
effect at once and written back to that file, so that the next start answers
the same.

It is a sibling of [NTSServerCLI](https://github.com/OpenChargingCloud/NTSServerCLI),
[PKICLI](https://github.com/OpenChargingCloud/PKICLI) and the others, and is
built the same way. The DNS server itself - the wire format, the listeners,
the authoritative lookups - is [Hermod](https://github.com/Vanaheimr/Hermod)'s;
what every program of the family has - the sign-in, the name servers it asks
itself, the groups of time servers and the certificates they are held to, the
SSH server with its command line, and the log - is
[WWCP_Node](https://github.com/OpenChargingCloud/WWCP_Node); what is the DNS
server's own is in [DNSServer](https://github.com/OpenChargingCloud/DNSServer).


### Getting it

The libraries it is built from are submodules, so they have to come along:

```
git clone --recurse-submodules https://github.com/OpenChargingCloud/DNSServerCLI.git
```

If you already cloned it without them:

```
git submodule update --init --recursive
```

**On Windows**, turn long paths on first: `git config --global core.longpaths true`.


### Building and running it

.NET 11. There is no web interface yet, so there is nothing for npm to build.

```
dotnet build DNSServerCLI.slnx
dotnet run --project DNSServerCLI
```

or `./run.sh`, which takes the same switches. `--help` lists all of them.
Without a configuration file it answers DNS on port 53, UDP and TCP, on every
address of both families, with no record at all - and serves its JSON API and
its command line over SSH on 127.0.0.1 only: http://127.0.0.1:2362/ and port
22362 (`--any` for every address). At the first start it makes one account,
`root`, and shows its password once, on the console.

Two things may stand in the way of port 53:

* **On Linux**, a port below 1024 takes `CAP_NET_BIND_SERVICE`:
  `sudo setcap cap_net_bind_service=+ep $(readlink -f $(which dotnet))`, or a
  systemd unit with `AmbientCapabilities=CAP_NET_BIND_SERVICE` - and
  systemd-resolved may hold 127.0.0.53:53 already.
* **On Windows**, the DNS Server role or Internet Connection Sharing hold 53.

A start that cannot have its port ends there and says which switch to give
instead. Every switch of the name server says for one start what the
`dnsServer` section says for every start:

| switch | |
|---|---|
| `--dns-port <n>` | the UDP and TCP port of DNS (53) |
| `--listen <address>` | where DNS listens (`any`, every address of both families) |
| `--no-udp` | no DNS over UDP |
| `--no-tcp` | no DNS over TCP |

For a first try without privileges:

```
dotnet run --project DNSServerCLI -- --dns-port 5353 --listen 127.0.0.1
```

and, at its prompt, `aRecords add www.example.org 192.0.2.10`; then, from
another terminal, `dig @127.0.0.1 -p 5353 www.example.org`.


### The configuration

`configuration.json` below the repository root, or what `--config` names. The
section of the name server, with every key and its default:

```json
{
  "dnsServer": {
    "listen":      "any",
    "port":        53,
    "udp":         true,
    "tcp":         true,
    "defaultTTL":  3600,
    "records":     [
                     "www.example.org.         600     IN   A          192.0.2.10"
                   ]
  }
}
```

The records are zone-file lines (RFC 1035 § 5.1), each with its name complete,
as the prompt writes them. That is the one form every type of record has: a
record the prompt cannot make yet - an AAAA, an MX, a TXT - can be written into
the file by hand, and is answered from the next start on. A line that cannot
be read stops the start with what is wrong in it.


### The prompt

Beside every node's commands - `queryDNS` among them, which asks the name
servers this node uses itself - the DNS server has:

* `dnsServer` - where it listens, how many records of which type it answers
  with, and how much it answered;
* `records [<name>]` - every record, or those of one name, as zone-file lines;
* `aRecords [<name>]` - the A records, or those of one name;
* `aRecords add <name> <IPv4> [<ttl>]` - the name answers with the address as
  well. The TTL is a number of seconds, or one with `s`, `m`, `h` or `d` after
  it (`10m`, `1h`); without one, `defaultTTL`. The records of one name and type
  share their TTL (RFC 2181 § 5.2), so a TTL given now is the other A records'
  of the name as well, and the answer says so;
* `aRecords remove <name> [<IPv4>]` - the name no longer answers with the
  address, or with any where none is given (`delete` works as well).

A name is complete, with or without its trailing dot, and compared without
regard to case. Every change is logged with whoever made it.

The prompt is the console's, and every account's over SSH:
`ssh -p 22362 root@127.0.0.1`. The commands are the DNS server's and not this
program's: they live in `libs/DNSServer/DNSServer/CommandLine/`, the node hands
them to whoever signs in over SSH by itself, and `libs/DNSServer` tests them -
so that a DNS server run by another program can be told the same.


### Who may do what

One resource beside the node's: `nameserver` - read, how the name server
stands and its records; edited, its records. Two roles beside the node's
viewer and administrators: `operator`, who reads everything and asks the name
and time servers, and `hostmaster`, who reads everything and adds and removes
records.


### Where things are

| | |
|---|---|
| `DNSServerCLI/` | the command line: the name server's own switches, and its lines of what the console says at a start |
| `libs/DNSServer/` | the DNS server itself - its settings, its records, Hermod's server around them, what can be typed at it (`dnsServer`, `records`, `aRecords`) - and its tests |
| `libs/WWCP_Node/` | what every one of these programs shares: the configuration file, the log, name resolution and the time, the certificate store, who may sign in, the command line over SSH, and the switches, the usage and the banner every node has |
| `libs/WWCP_Core/` | of WWCP Core only WWCP_CoreData, which WWCP_Node builds on |
| `libs/Hermod/` | the network below all of them: HTTP, TLS, SSH and DNS |
| `libs/Norn/` | NTS and NTP, with which the node checks its clock |
| `libs/Styx/`, `libs/Urdr/` | the basics below that, and time stamps (RFC 3161) |
| `.github/workflows/` | what runs on every push |


### Its tests

```
dotnet test libs/DNSServer/DNSServerTests/DNSServerTests.csproj
```

A DNS server started on the loopback address, told at its console what to
answer, and asked over UDP and TCP as any resolver would: an A record added
is answered at once and written to the file, twice the same is refused, the
RRset shares its TTL, one address and then the whole name removed, the records
answered again after a restart, what is no address, TTL or name refused, and a
record in the file that cannot be read is no start. Nothing in them leaves the
machine.

**CI** runs them on every push, beside the node's own tests, on Windows and on
Debian 13; on Debian it then starts the server with a record in its file and
asks it over UDP and TCP with `dig`.


## Your participation

This software is Open Source under the **Affero GPL 3.0 license**.
We appreciate your participation in this ongoing project, and your help to
improve it and the e-mobility ICT in general. If you find bugs, want to
request a feature or send us a pull request, feel free to use the normal
GitHub features to do so. For this please read the Contributor License
Agreement carefully and send us a signed copy or use a similar free and
open license.
