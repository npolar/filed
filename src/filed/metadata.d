module filed.metadata;

import std.algorithm;
import std.conv;
import std.datetime;
import std.regex;
import std.stdio;

struct MetaData
{
    string  name;
    string  type;
    size_t  size;
    string  peer;
    string  time;

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
        enum timeExpr = ctRegex!`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z`;
        assert(!time.matchFirst(timeExpr).empty);
    }
}

