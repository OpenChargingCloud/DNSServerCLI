/*
 * Copyright (c) 2026 GraphDefined GmbH <achim.friedland@graphdefined.com>
 * This file is part of DNSServerCLI <https://github.com/OpenChargingCloud/DNSServerCLI>
 *
 * Licensed under the Affero GPL license, Version 3.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.gnu.org/licenses/agpl.html
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#region Usings

using org.GraphDefined.Vanaheimr.Hermod;

using cloud.charging.open.protocols.WWCP.Node;
using cloud.charging.open.protocols.WWCP.Node.CommandLine;
using cloud.charging.open.protocols.WWCP.Node.Configuration;

using cloud.charging.open.DNSServer.CommandLine;

#endregion

namespace cloud.charging.open.DNSServer
{

    /// <summary>
    /// One DNS server, with a prompt, until 'quit', Ctrl+C or SIGTERM.
    /// </summary>
    /// <remarks>
    /// What every kind of node's program does is the node's: the switches and
    /// the words -h explains them with, why it could not be set up or could not
    /// start, what goes into the certificate store, the banner and the prompt.
    /// What is left here is the name server's: the switches that say for one
    /// start what the "dnsServer" section says for every start, and what the
    /// banner says of DNS and its records.
    /// </remarks>
    public class Program
    {

        #region (private static) Usage

        /// <summary>
        /// What -h shows: every node's switches, in a DNS server's words, and
        /// the name server's own.
        /// </summary>
        private static readonly NodeUsage Usage = new (

            Program:               "DNSServerCLI",
            Kind:                  DNSServerNode.DNSServerKind,
            DefaultPort:           DNSServerNode.DefaultHTTPPort,
            FrontendSources:       "libs/DNSServer/DNSServer/Frontend",
            ConfigurationSays:     "where the name server, its records, the name servers and the groups of time servers of this " +
                                  $"DNS server live (default: {WWCPConfigFile.DefaultFileName} below the repository root). Without the file " +
                                   "it answers on the standard port with no record at all; the \"dnsServer\" section says otherwise - " +
                                   "see the README.",
            CertificateKinds:      DNSServerNode.CertificateKinds,
            Synopsis:              [ "[--dns-port <n>]", "[--listen <address>]", "[--no-udp | --no-tcp]" ],
            AfterTheWebInterface: [
                .. NodeUsage.Wrap("The name server - each of these says for this start what the \"dnsServer\" section of the " +
                                  "configuration file says for every start:",
                                  "",
                                  ""),
                .. NodeUsage.Switch("--dns-port <n>",     $"the UDP and TCP port of DNS (default: {DNSServerSettings.DefaultDNSPort}). " +
                                                          "On Linux a port below 1024 takes CAP_NET_BIND_SERVICE; on Windows the DNS " +
                                                          "Client or ICS may hold 53 on some addresses."),
                .. NodeUsage.Switch("--listen <address>", "the address DNS listens on (default: \"any\", every address of both " +
                                                          "families). Not --any, which is the web interface's."),
                .. NodeUsage.Switch("--no-udp",           "do not answer DNS over UDP."),
                .. NodeUsage.Switch("--no-tcp",           "do not answer DNS over TCP."),
                ""
            ]

        );

        #endregion

        #region (private static) WhatToDoAbout(Problem) / SwitchOf(Problem)

        /// <summary>
        /// The way past a port of the name server, in the words of whoever
        /// started it; null for the web interface's, which is every node's.
        /// </summary>
        private static String? WhatToDoAbout(PortUnavailableException Problem)

            => Problem.Whose == DNSServerNode.DNSUDPPort || Problem.Whose == DNSServerNode.DNSTCPPort
                   ? "Stop whatever has it - another name server, dnsmasq, systemd-resolved on Linux, the DNS server or ICS on " +
                     "Windows - or give DNS another port with --dns-port <number>, or one address with --listen <address>."
                   : null;

        private static String? SwitchOf(PortUnavailableException Problem)

            => Problem.Whose == DNSServerNode.DNSUDPPort || Problem.Whose == DNSServerNode.DNSTCPPort
                   ? "--dns-port"
                   : null;

        #endregion

        #region (private static) BesideTheWebInterface(Node) / OfTheKind(Node)

        /// <summary>
        /// What the name server listens on, beside the web interface.
        /// </summary>
        private static IEnumerable<(String Label, String Value)> BesideTheWebInterface(DNSServerNode Node)
        {
            yield return ("DNS", Node.ListenersText());
        }

        /// <summary>
        /// What the name server answers with.
        /// </summary>
        private static IEnumerable<(String Label, String Value)> OfTheKind(DNSServerNode Node)
        {

            var records = Node.Records.All;

            yield return ("records", records.Count == 0
                                         ? $"none yet - '{ARecordsCommand.CommandName} add <name> <IPv4>' adds one"
                                         : $"{records.Count}: " + String.Join(", ", records.GroupBy (record => record.Type).
                                                                                            OrderBy (group  => group.Key.ToString()).
                                                                                            Select  (group  => $"{group.Count()} {group.Key}")));

        }

        #endregion


        public static async Task<Int32> Main(String[] Arguments)
        {

            Console.OutputEncoding = System.Text.Encoding.UTF8;

            #region Arguments

            // Every node's switches first. What is left is the name server's
            // own, as it was typed.
            var arguments = NodeArguments.Parse(Arguments);

            if (arguments.Refused(Usage) is Int32 refused)
                return refused;

            IPPort?      dnsPort  = null;
            IPAddress?   listen   = null;
            var          noUDP    = false;
            var          noTCP    = false;

            var rest = arguments.Rest;

            for (var i = 0; i < rest.Count; i++)
            {
                switch (rest[i])
                {

                    case "--dns-port":
                        if (i + 1 < rest.Count && UInt16.TryParse(rest[i + 1], out var parsedDNSPort) && parsedDNSPort > 0)
                        {
                            dnsPort = IPPort.Parse(parsedDNSPort);
                            i++;
                        }
                        else
                        {
                            NodeProgram.Say(Console.Error, "Missing or invalid port number after --dns-port!");
                            return 2;
                        }
                        break;

                    case "--listen":
                        if (!NodeArguments.TryTakeValue(rest, ref i, out var listenText) ||
                            !DNSServerSettings.TryParseListen(listenText, out var parsedListen))
                        {
                            NodeProgram.Say(Console.Error, "Missing or invalid address after --listen: an IPv4 or IPv6 address, or \"any\"!");
                            return 2;
                        }
                        listen = parsedListen;
                        break;

                    case "--no-udp":
                        noUDP = true;
                        break;

                    case "--no-tcp":
                        noTCP = true;
                        break;

                    default:
                        return NodeArguments.Unknown(rest[i], Usage);

                }
            }

            if (noUDP && noTCP)
            {
                NodeProgram.Say(Console.Error, "--no-udp and --no-tcp together leave DNS answered nowhere!");
                return 2;
            }

            var root = NodeProgram.RepositoryRoot("DNSServerCLI.slnx");

            #endregion

            #region The DNS server

            DNSServerNode node;

            try
            {
                node = new DNSServerNode(
                           HTTPHostname:      arguments.HTTPHostname,
                           HTTPPort:          arguments.Port,
                           AccountsPath:      arguments.AccountsPathBelow(root),
                           ConfigFile:        new WWCPConfigFile(arguments.ConfigFilePathBelow(root)),
                           Frontend:          arguments.Frontend,
                           CertificatesPath:  arguments.CertificatesPath,
                           ConsoleLogLevel:   arguments.ConsoleLogLevel,
                           LogPath:           arguments.LogPathBelow(root),
                           BridgeDebugLog:    !arguments.NoTrace,
                           SSH:               arguments.SSH,
                           Web:               arguments.Web,

                           // The switches of this start, over the "dnsServer"
                           // section: for this start only, never written back.
                           CommandLine:       settings => settings with {
                                                  Port    = dnsPort ?? settings.Port,
                                                  Listen  = listen  ?? settings.Listen,
                                                  UDP     = !noUDP && settings.UDP,
                                                  TCP     = !noTCP && settings.TCP
                                              }
                       );
            }
            catch (Exception e)
            {
                return NodeProgram.CouldNotBeSetUp(DNSServerNode.DNSServerKind, e, arguments.Verbose);
            }

            await using (node)
            {

                if (node.ImportCertificates(arguments, out _) is Int32 notImported)
                    return notImported;

                if (arguments.ListCertificates)
                    node.ListCertificates();

                if (await node.Started(arguments.Verbose, WhatToDoAbout, SwitchOf: SwitchOf) is Int32 notStarted)
                    return notStarted;

                #region What somebody who just started this needs to know

                foreach (var line in node.Banner(BesideTheInterfaces:  BesideTheWebInterface(node),
                                                 OfTheKind:            OfTheKind(node)))
                    Console.WriteLine(line);

                #endregion

                #region The command line, until 'quit', Ctrl+C or SIGTERM

                // The node's: a prompt where somebody can type, and waiting
                // where nobody can, with the log sharing the screen.
                await new DNSServerCLI(node).RunUntilStopped();

                #endregion

            }

            #endregion

            return 0;

        }

    }

}
