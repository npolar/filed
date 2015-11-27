import vibe.d;

import std.algorithm    : max;
import std.conv         : to;
import std.file         : append, copy, exists, getSize, mkdirRecurse, remove, tempDir;
import std.getopt       : getopt;
import std.regex        : matchFirst, regex;
import std.stdio        : File, readln, stderr, writeln, writefln;
import std.string       : strip;
import std.uuid         : UUID, randomUUID;

struct FileMetaData
{
	string  name;
	string  type;
	ulong   size;
}

int main(string[] args)
{
	enum    PROGRAM_VERSION     = 0.12;
	enum    PROGRAM_BUILD_YEAR  = "2015";

	ushort  port                = 0xEA7;    // Listening port number (3751)
	string  fileDir             = "files";  // File storage directory
	string  maxFileSize         = "10MiB";  // Maximum file upload size (kB/MB/GB/KiB/MiB/GiB)
	bool    corsEnabled         = false;    // Cross-origin resource sharing

	// Parse program arguments as options
	bool optHelp, optVersion;
	auto optParser = getopt(args,
		"m|max-size",   "maximum file size for uploads (default: 10MiB)",   &maxFileSize,
		"p|port",       "filed server listening port (default: 3751)",      &port,
		"cors",         "enable cross-origin resource sharing (CORS)",      &corsEnabled,
		"help",         "display this help information and exit",           &optHelp,
		"version",      "display version information and exit",             &optVersion
	);

	// Remove default help option
	optParser.options = optParser.options[0 .. $-1];

	// Handle custom help output
	if(optHelp)
	{
		writefln("Usage: %s [OPTION]...\n", args[0]);

		size_t longestLength;

		foreach(opt; optParser.options)
			longestLength = max(longestLength, opt.optLong.length);

		foreach(opt; optParser.options)
			writefln("  %s %-*s %s", (opt.optShort ? opt.optShort ~ "," : "   "), longestLength, opt.optLong, opt.help);

		return 0;
	}

	// Handle version output
	if(optVersion)
	{
		writefln("filed - Simple RESTful File Server v%s", PROGRAM_VERSION);
		writefln("Copyright (C) %s - Norwegian Polar Institute", PROGRAM_BUILD_YEAR);
		writefln("Licensed under the MIT license <http://opensource.org/licenses/MIT>");
		writefln("This is free software; you are free to change and redistribute it.");
		writefln("\nWritten by: Remi A. Solås (remi@npolar.no)");
		return 0;
	}

	auto maxFileSizeMatch = matchFirst(maxFileSize, regex(`([1-9]\d*)([kmg]i?b?)`, "i"));
	ulong maxFileSizeBytes;

	if(!maxFileSizeMatch.empty)
	{
		maxFileSizeBytes = to!ulong(maxFileSizeMatch[1]);

		switch(maxFileSizeMatch[2])
		{
		case "k", "kb", "KiB":
			maxFileSizeBytes *= 1024;
			break;

		case "K", "kB", "KB":
			maxFileSizeBytes *= 1000;
			break;

		case "m", "mb", "MiB":
			maxFileSizeBytes *= 1024 * 1024;
			break;

		case "M", "MB":
			maxFileSizeBytes *= 1000 * 1000;
			break;

		case "g", "gb", "GiB":
			maxFileSizeBytes *= 1024 * 1024 * 1024;
			break;

		case "G", "GB":
			maxFileSizeBytes *= 1000 * 1000 * 1000;
			break;

		default:
			break;
		}
	}

	if(!maxFileSizeBytes)
	{
		writefln("Unrecognized maximum file size: %s", maxFileSize);
		writefln("Expected one of the following suffixes: KiB/KB/MiB/MB/GiB/GB");
		return 1;
	}

	void routeDefault(HTTPServerRequest req, HTTPServerResponse res)
	{
		// Enable CORS support if required
		if(corsEnabled)
		{
			res.headers["Access-Control-Allow-Headers"] = "Authorization,Content-Type,X-File-Name,X-File-Size";
			res.headers["Access-Control-Allow-Origin"] = "*";
		}

		// TODO: Handle DELETE requests
		// TODO: Handle HEAD requests

		// Handle OPTIONS requests
		if(req.method == HTTPMethod.OPTIONS)
		{
			res.headers["Allow"] = "GET,HEAD,POST,OPTIONS";
			return res.writeVoidBody();
		}

		// Handle POST requests
		if(req.method == HTTPMethod.POST)
		{
			// Create directory for saving files if needed
			mkdirRecurse(fileDir);

			string clientAddr = req.clientAddress.toAddressString();

			// Save all files from form-data if applicable
			if(req.files.length)
			{
				FileMetaData[string] fileMap;

				foreach(file; req.files)
				{
					string uuid = randomUUID().toString(), tempPath = file.tempPath.toString(), filePath = fileDir ~ "/" ~ uuid;
					string fileName = file.filename.toString();
					string fileType = ("Content-Type" in file.headers ? file.headers["Content-Type"] : "application/octet-stream");
					ulong fileSize = getSize(tempPath);

					// TODO: Exception handling
					copy(tempPath, filePath);
					remove(tempPath);

					// Create metadata file, and add filename, type, size and client address
					auto metaFile = File(filePath ~ ".meta", "a");
					metaFile.writeln(fileName);
					metaFile.writeln(fileType);
					metaFile.writeln(to!string(fileSize));
					metaFile.writeln(clientAddr);

					fileMap[uuid] = FileMetaData(fileName, fileType, fileSize);
				}

				// TODO: Generate JSON reply
				res.statusCode = HTTPStatus.created;
				return res.writeVoidBody();
			}

			// Otherwise save a single file from the request body
			else
			{
				// Require the custom X-File-Name and X-File-Size headers
				if("X-File-Name" in req.headers && "X-File-Size" in req.headers)
				{
					string uuid = randomUUID().toString(), tempPath = tempDir() ~ "/", filePath = fileDir ~ "/" ~ uuid;
					string fileName = req.headers["X-File-Name"];
					string fileSizeString = req.headers["X-File-Size"];
					string fileType = ("Content-Type" in req.headers ? req.headers["Content-Type"] : "application/octet-stream");

					tempPath ~= "filed-" ~ clientAddr ~ "." ~ fileName ~ "." ~ fileSizeString ~ ".part";
					ulong fileSize = to!ulong(fileSizeString);
					ulong tempFileSize = exists(tempPath) ? getSize(tempPath) : 0;

					// Return 413 if the file is too large to be received
					if(fileSize > maxFileSizeBytes || (tempFileSize + req.bodyReader.leastSize()) > maxFileSizeBytes)
					{
						if(tempFileSize)
							remove(tempPath);

						res.statusCode = HTTPStatus.requestEntityTooLarge;
						return res.writeVoidBody();
					}

					// TODO: Exception handling
					auto fileStream = openFile(tempPath, FileMode.append);
					fileStream.write(req.bodyReader);
					fileStream.finalize();

					// Return 201 if the entire file has been received
					if(fileSize == (tempFileSize = getSize(tempPath)))
					{
						copy(tempPath, filePath);
						remove(tempPath);

						// Create metadata file, and add filename, type, size and client address
						auto metaFile = File(filePath ~ ".meta", "a");
						metaFile.writeln(fileName);
						metaFile.writeln(fileType);
						metaFile.writeln(to!string(getSize(filePath)));
						metaFile.writeln(clientAddr);

						res.headers["Content-Location"] = "/" ~ uuid;
						return res.writeJsonBody([
							"uuid": uuid,
							"type": req.contentType,
							"path": "/" ~ uuid
						], HTTPStatus.created);
					}

					// Return 202 to indicate that the chunk was received
					else if(tempFileSize < fileSize)
					{
						res.statusCode = HTTPStatus.accepted;
						return res.writeVoidBody();
					}

					// Return 500 to indicate a server error if the received file is too big
					else
					{
						remove(tempPath);
						res.statusCode = HTTPStatus.internalServerError;
						return res.writeVoidBody();
					}
				}

				// Return 412 if the required headers are missing
				else
				{
					res.statusCode = HTTPStatus.preconditionFailed;
					return res.writeVoidBody();
				}
			}
		}

		// Handle GET requests
		if(req.method == HTTPMethod.GET)
		{
			if("uuid" in req.params && exists(fileDir ~ "/" ~ req.params["uuid"]))
			{
				string filePath = fileDir ~ "/" ~ req.params["uuid"];
				auto fileStream = openFile(filePath, FileMode.read);
				string fileName, fileType, fileSize;

				if(exists(filePath ~ ".meta"))
				{
					auto metaFile = File(filePath ~ ".meta", "r");
					fileName = strip(metaFile.readln());
					fileType = strip(metaFile.readln());
					fileSize = strip(metaFile.readln());
				}

				res.headers["Content-Disposition"] = "attachment; filename=\"" ~ fileName ~ "\"";
				res.headers["Content-Length"] = fileSize;
				return res.writeBody(fileStream, fileType);
			}
		}

		// Yield 405 if this point was reached
		res.statusCode = HTTPStatus.methodNotAllowed;
		return res.writeVoidBody();
	}

	// Create URL routes
	auto router = new URLRouter;
	router
	.any("/", &routeDefault)
	.any("/:uuid", &routeDefault);

	// Enable worker-thread distribution, and set desired server options
	auto httpSettings               = new HTTPServerSettings;
	httpSettings.options            = HTTPServerOption.distribute | HTTPServerOption.parseURL | HTTPServerOption.parseFormBody;
	httpSettings.port               = port;
	httpSettings.maxRequestSize     = maxFileSizeBytes;
	httpSettings.keepAliveTimeout   = 0.seconds;
	// TODO: Add HTTPS support (httpSettings.tlsContext)

	// Start HTTP listening, and run event loop
	listenHTTP(httpSettings, router);
	return runEventLoop();
}
