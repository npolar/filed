module filed.service;

import filed.settings;
import filed.metadata;

import vibe.d;

import std.algorithm;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.uuid;

class WebService
{
    this(FiledSettings settings)
    {
        corsEnabled_    = settings.corsEnabled;
        fileDir_        = settings.fileDirectory;
        maxFileSize_    = settings.maxFileSize;
        pipeCmds_       = settings.pipeCommands;
    }

    @path("/") // @contentType("application/json")
    void getList(HTTPServerRequest req, HTTPServerResponse res)
    {
        struct FileEntry
        {
            string  name;
            string  type;
            size_t  size;
            string  path;
        }

        FileEntry[] entries;

        try
        {
            foreach(string dirEntry; dirEntries(fileDir_, SpanMode.breadth))
            {
                if(dirEntry.endsWith(".meta"))
                {
                    FileEntry entry;
                    auto file = File(dirEntry, "r");
                    file.readf("%s\n%s\n%s\n", &entry.name, &entry.type, &entry.size);
                    entry.path = req.fullURL.toString ~ dirEntry.baseName(".meta");
                    entries ~= entry;
                }
            }

            return res.writeJsonBody(entries);
        }
        catch(Exception e)
            return res.writeBody(e.msg, HTTPStatus.internalServerError);
    }

    @path("/") @method(HTTPMethod.OPTIONS)
    void options(HTTPServerRequest req, HTTPServerResponse res)
    {
        if(corsEnabled_)
            addCorsHeaders(res);

        res.headers["Allow"] = "POST,OPTIONS";
        res.writeBody("", HTTPStatus.ok);
    }

    void post(HTTPServerRequest req, HTTPServerResponse res)
    {
        if(corsEnabled_)
            addCorsHeaders(res);

        return (
            req.files.length ?
            postFormData(req, res) :
            postChunkedData(req, res)
        );
    }

    @path("/:uuid")
    void get(HTTPServerRequest req, HTTPServerResponse res)
    {
        auto uuid   = ("uuid" in req.params);
        auto range  = ("Range" in req.headers);

        if(uuid && exists(fileDir_ ~ "/" ~ (*uuid)))
        {
            string filePath = (fileDir_ ~ "/" ~ (*uuid));
            string fileName, fileType, fileSize;
            auto fileStream = openFile(filePath, FileMode.read);

            if(exists(filePath ~ ".meta"))
            {
                MetaData metaData;
                metaData.readFromFile(filePath);

                fileName = metaData.name;
                fileType = metaData.type;
                fileSize = metaData.size.to!string;
           }

            res.headers["Content-Disposition"]  = format("attachment; filename=\"%s\"", fileName);
            res.headers["Content-Length"]       = fileSize;
            res.headers["Content-Type"]         = fileType;
            res.headers["Accept-Ranges"]        = "bytes";

            size_t fromByte, toByte;

            // Enable seeking (useful for media streaming)
            if(range)
            {
                auto rangeMatch = matchFirst(*range, regex(`bytes=(\d+)-(\d+)`, "i"));

                if(!rangeMatch.empty)
                {
                    fromByte    = rangeMatch[1].to!size_t;
                    toByte      = rangeMatch[2].to!size_t;
                    fileStream.seek(fromByte);

                    return res.writeRawBody(
                        fileStream,
                        toByte - fromByte
                    );
                }
            }

            return res.writeBody(fileStream);
        }
    }

    private
    {
        bool        corsEnabled_    = false;
        string      fileDir_        = "files";
        size_t      maxFileSize_    = 10 * 1024 * 1024; // 10 MiB
        string[]    pipeCmds_       = [];

        struct FileMetaData
        {
            string name;
            string type;
            size_t size;
        }

        void addCorsHeaders(ref HTTPServerResponse res)
        {
            res.headers["Access-Control-Allow-Headers"]     = "Authorization,Content-Type,X-File-Name,X-File-Size";
            res.headers["Access-Control-Allow-Origin"]      = "*";
            res.headers["Access-Control-Expose-Headers"]    = "Content-Location";
        }

        void postFormData(ref HTTPServerRequest req, ref HTTPServerResponse res)
        {   
            string clientAddr = req.clientAddress.toAddressString;
            MetaData[string] fileMap;
            
            try 
            {   
                foreach(file; req.files)
                {   
                    string tempPath = file.tempPath.toString;
                    string fileUUID = randomUUID.toString;
                    string filePath = fileDir_ ~ "/" ~ fileUUID;
                    string fileName = file.filename.toString;
                    string fileType = file.headers.get("Content-Type", "application/octet-stream");
                    size_t fileSize = tempPath.getSize;
                    
                    mkdirRecurse(fileDir_);
                    copy(tempPath, filePath);
                    remove(tempPath);

                    auto metaData = MetaData(fileName, fileType, fileSize, clientAddr);
                    metaData.writeToFile(filePath ~ ".meta");
                    fileMap[fileUUID] = metaData;
                }
            }
            catch(Exception e)
                res.writeBody(e.msg, HTTPStatus.internalServerError);
            
            res.writeJsonBody(fileMap, HTTPStatus.created);
        }

        void postChunkedData(ref HTTPServerRequest req, ref HTTPServerResponse res)
        {
            auto xFileName = ("X-File-Name" in req.headers);
            auto xFileSize = ("X-File-Size" in req.headers);
            string[] missingHeaders;

            if(!xFileName) missingHeaders ~= "X-File-Name";
            if(!xFileSize) missingHeaders ~= "X-File-Size";

            if(!missingHeaders.empty)
            {
                res.headers["Vary"] = missingHeaders.join(",");
                return res.writeBody("", HTTPStatus.preconditionFailed);
            }

            string clientAddr   = req.clientAddress.toAddressString;
            string fileUUID     = randomUUID.toString;
            string filePath     = fileDir_ ~ "/" ~ fileUUID;
            string fileType     = req.headers.get("Content-Type", "application/octet-stream");
            size_t fileSize     = (*xFileSize).to!size_t;
            string tempPath     = format("%s/filed-%s-%s-%s.part", tempDir(), clientAddr, *xFileName, fileSize);
            size_t tempSize     = (tempPath.exists ? tempPath.getSize : 0);

            // File too large
            if(fileSize > maxFileSize_ || (tempSize + req.bodyReader.leastSize) > maxFileSize_)
            {
                if(tempPath.exists)
                    remove(tempPath);

                return res.writeBody("", HTTPStatus.requestEntityTooLarge);
            }

            try
            {
                mkdirRecurse(fileDir_);

                auto metaFileName = filePath ~ ".meta";
                auto fileStream = openFile(tempPath, FileMode.append);
                fileStream.write(req.bodyReader);
                fileStream.finalize();

                // Entire file received
                if(fileSize == (tempSize = tempPath.getSize))
                {
                    try
                    {
                        bool created = true;
                        copy(tempPath, filePath);
                        remove(tempPath);

                        auto metaDataFile = File(metaFileName, "w");
                        [ *xFileName, fileType, fileSize.to!string, clientAddr ]
                        .each!(a=>metaDataFile.writeln(a));

                        string json = format(
                            "{\"uuid\":\"%s\",\"name\":\"%s\",\"size\":%s,\"type\":\"%s\",\"path\":\"%s\"}",
                            fileUUID, *xFileName, fileSize, fileType, req.fullURL.toString ~ fileUUID
                        );

                        if(!pipeCmds_.empty)
                        {
                            foreach(cmd; pipeCmds_)
                            {
                                string command = cmd ~ " " ~ filePath;
                                auto pipe = pipeShell(command);
                                pipe.stdin.writeln(json);
                                pipe.stdin.flush();
                                json = pipe.stdout.readln();

                                if(pipe.pid.wait() != 0)
                                {
                                    remove(filePath);
                                    remove(metaFileName);
                                    created = false;
                                    break;
                                }

                                if(string error = pipe.stderr.readln())
                                    throw new Exception(error);
                            }
                        }

                        if(created)
                            res.headers["Content-Location"] = req.fullURL.toString ~ fileUUID;

                        return res.writeJsonBody(parseJsonString(json), created ? HTTPStatus.created : HTTPStatus.unprocessableEntity);
                    }
                    catch(Exception e)
                    {
                        if(filePath.exists)
                            remove(filePath);

                        if(metaFileName.exists)
                            remove(metaFileName);

                        throw e;
                    }
                }

                // Chunk Received
                else if(tempSize < fileSize)
                {
                    return res.writeBody("", HTTPStatus.accepted);
                }

                // File size mismatch in reassembled file
                else
                {
                    remove(tempPath);
                    return res.writeBody("reassembled file size mismatch", HTTPStatus.internalServerError);
                }
            }
            catch(Exception e)
            {
                if(tempPath.exists)
                    remove(tempPath);

                return res.writeBody(e.msg, HTTPStatus.internalServerError);
            }
        }
    }
}

