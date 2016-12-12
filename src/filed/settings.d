module filed.settings;

struct FiledSettings
{
    bool        corsEnabled     = false;
    string      fileDirectory   = "files";
    size_t      maxFileSize     = 10 * 1024 * 1024; // 10 MiB
    string[]    pipeCommands    = [];
}

