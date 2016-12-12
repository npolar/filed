module filed.metadata;

import std.algorithm;
import std.conv;
import std.datetime;
import std.file;
import std.regex;
import std.stdio;

struct MetaData
{
    string  name;
    string  type;
    size_t  size;
    string  peer;
    string  time;

    this(string name, string type, size_t size, string peer)
    {
        this.name = name;
        this.type = type;
        this.size = size;
        this.peer = peer;
    }

    this(string filename)
    {
        if(filename.exists)
            readFromFile(filename);
    }

    void writeToFile(string filename)
    {
        auto now = Clock.currTime(UTC());
        now.fracSecs = 0.msecs;
        time = now.toISOExtString;

        auto file = File(filename, "w");
        [ name, type, size.to!string, peer, time ]
        .each!(a=>file.writeln(a));
    }

    void readFromFile(string filename)
    {
        auto file = File(filename, "r");

        file.readf(
            "%s\n"~ "%s\n"~ "%s\n"~ "%s\n"~ "%s\n",
            &name,  &type,  &size,  &peer,  &time
        );
    }

    invariant
    {
        if(time.length)
        {
            enum timeExpr = ctRegex!`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z`;
            assert(!time.matchFirst(timeExpr).empty);
        }
    }
}

