import filed.settings;
import filed.service;
import vibe.d;

import std.algorithm;
import std.getopt;
import std.regex;
import std.stdio;

int main(string[] args)
{
    enum APP_NAME       = "filed";
    enum APP_VERSION    = "0.4.0";
    enum APP_AUTHORS    = [ "Remi A. Solås (remi@npolar.on)" ];

    ushort  port        = 0xEA7;    // Listening port number (3751)
    string  fileDir     = "files";  // File storage directory
    string  maxFileSize = "10MiB";  // Maximum file upload size (kB/MB/GB/KiB/MiB/GiB)
    bool    corsEnabled = false;    // Cross-origin resource sharing

    bool optHelp, optVersion;
    auto optParser = getopt(args,
        "d|file-dir",   "existing file upload save path (default: files)",  &fileDir,
        "m|max-size",   "maximum file size for uploads (default: 10MiB)",   &maxFileSize,
        "p|port",       "filed server listening port (default: 3751)",      &port,
        "cors",         "enable cross-origin resource sharing (CORS)",      &corsEnabled,
        "help",         "display this help information and exit",           &optHelp,
        "version",      "display version information and exit",             &optVersion
    );

    // Remove default help option
    optParser.options = optParser.options[0..$-1];

    if(optHelp)
    {
        auto longest = (optParser.options.maxElement!"a.optLong.length").optLong.length;
        string options;

        foreach(opt; optParser.options)
            options ~= format("  %s %-*s %s\n", (opt.optShort ? opt.optShort ~ "," : "    "), longest, opt.optLong, opt.help);

        writefln(
            "Usage: %s [OPTION]... [APPLICATON]...\n" ~
            "Listen for incoming files through HTTP for local storing\n" ~
            "Optionally piping the result through each APPLICATION specified\n" ~
            "\nAvailable options:\n%s",
            args[0], options
        );

        return 0;
    }

    if(optVersion)
    {
        writefln(
            "%s %s - HTTP file storage service\n" ~
            "Copyright (C) %s - Norwegian Polar Institute\n" ~
            "Licenced under the MIT license <http://opensource.org/licences/MIT>\n" ~
            "This is free software; you are free to change and redistribute it.\n" ~
            "Written by: %s",
            APP_NAME, APP_VERSION, __DATE__[7..$], APP_AUTHORS.join(", ")
        );

        return 0;
    }

    auto    maxFileSizeMatch = maxFileSize.matchFirst(regex(`([1-9]\d*)([kmg]i?b?)`, "i"));
    size_t  maxFileSizeBytes;

    if(!maxFileSizeMatch.empty)
    {
        maxFileSizeBytes = to!ulong(maxFileSizeMatch[1]);

        switch(maxFileSizeMatch[2])
        {
        case "k", "kb", "KiB":  maxFileSizeBytes *= 1024;               break;
        case "K", "kB", "KB":   maxFileSizeBytes *= 1000;               break;
        case "m", "mb", "MiB":  maxFileSizeBytes *= 1024 * 1024;        break;
        case "M", "MB":         maxFileSizeBytes *= 1000 * 1000;        break;
        case "g", "gb", "GiB":  maxFileSizeBytes *= 1024 * 1024 * 1024; break;
        case "G", "GB":         maxFileSizeBytes *= 1000 * 1000 * 1000; break;
        default:                maxFileSizeBytes = 0;                   break;
        }
    }

    if(!maxFileSizeBytes)
    {
        writefln(
            "Unrecognized maximum file size: %s" ~
            "Expected one of the following suffixes: %s",
            maxFileSize, "KiB, KB, MiB, MB, GiB, GB"
        );

        return 1;
    }

    auto router             = new URLRouter;
    auto settings           = new HTTPServerSettings;

    settings.options        = HTTPServerOption.parseFormBody | HTTPServerOption.parseURL;
    settings.maxRequestSize = maxFileSizeBytes;
    settings.port           = port;

    FiledSettings filedSettings;
    filedSettings.corsEnabled   = corsEnabled;
    filedSettings.fileDirectory = fileDir;
    filedSettings.maxFileSize   = maxFileSizeBytes;
    filedSettings.pipeCommands  = args[1..$];

    // TODO: Add HTTPS support (settings.tlsContext)

    router.registerWebInterface(new FiledService(filedSettings));
    listenHTTP(settings, router);
    return runEventLoop();
}

