#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"

#define LUMP_PAKFILE 40
#define SIG_CENTRAL 0x02014b50
#define SIG_EOCD 0x06054b50
#define EOCD_SEARCH 2048
#define CHUNK 2048

ConVar gCV_MaxFiles;
ConVar gCV_Extract;

public Plugin myinfo =
{
	name = "Casefold Fix",
	author = "ddyfad",
	description = "Extracts and sends map assets the engine can't resolve under single-letter folders",
	version = PLUGIN_VERSION,
	url = "https://github.com/ddyfad"
};

public void OnPluginStart()
{
	gCV_MaxFiles = CreateConVar("casefoldfix_max_files", "1500",
		"Most files to extract and queue for one map. 0 disables the plugin.",
		FCVAR_NOTIFY, true, 0.0, true, 4000.0);

	gCV_Extract = CreateConVar("casefoldfix_extract", "1",
		"Extract missing files into the game folder. 0 only queues them for download.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	AutoExecConfig(true, "plugin.casefoldfix");
}

static int ReadU16(const int[] b, int offset)
{
	return b[offset] | (b[offset + 1] << 8);
}

static int ReadU32(const int[] b, int offset)
{
	return b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16) | (b[offset + 3] << 24);
}

static bool Flatten(const char[] name, char[] out, int maxlen)
{
	int length = strlen(name);
	bool dropped = false;
	int start = 0;
	int written = 0;

	out[0] = '\0';

	for (int i = 0; i < length; i++)
	{
		if (name[i] != '/')
		{
			continue;
		}

		if (i - start == 1)
		{
			dropped = true;
		}
		else
		{
			written += StrCatEx(out, maxlen, written, name[start], i - start + 1);
		}

		start = i + 1;
	}

	if (!dropped)
	{
		return false;
	}

	StrCatEx(out, maxlen, written, name[start], length - start);
	return true;
}

static int StrCatEx(char[] buffer, int maxlen, int at, const char[] source, int count)
{
	int room = maxlen - at - 1;

	if (count > room)
	{
		count = room;
	}

	for (int i = 0; i < count; i++)
	{
		buffer[at + i] = source[i];
	}

	buffer[at + count] = '\0';
	return count;
}

static void MakeTree(const char[] path)
{
	char dir[PLATFORM_MAX_PATH];
	strcopy(dir, sizeof(dir), path);

	for (int i = 1; dir[i] != '\0'; i++)
	{
		if (dir[i] != '/')
		{
			continue;
		}

		dir[i] = '\0';

		if (!DirExists(dir))
		{
			CreateDirectory(dir, FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC |
				FPERM_G_READ | FPERM_G_EXEC | FPERM_O_READ | FPERM_O_EXEC);
		}

		dir[i] = '/';
	}
}

static bool CopyBytes(File bsp, const char[] dest, int length)
{
	MakeTree(dest);
	File out = OpenFile(dest, "wb");

	if (out == null)
	{
		return false;
	}

	int buffer[CHUNK];
	int left = length;

	while (left > 0)
	{
		int want = left < CHUNK ? left : CHUNK;
		int got = bsp.Read(buffer, want, 1);

		if (got <= 0)
		{
			delete out;
			DeleteFile(dest);
			return false;
		}

		out.Write(buffer, got, 1);
		left -= got;
	}

	delete out;
	return true;
}

public void OnMapStart()
{
	int max = gCV_MaxFiles.IntValue;

	if (max == 0)
	{
		return;
	}

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));

	char bspPath[PLATFORM_MAX_PATH];
	FormatEx(bspPath, sizeof(bspPath), "maps/%s.bsp", map);

	File bsp = OpenFile(bspPath, "rb");

	if (bsp == null)
	{
		return;
	}

	bool extract = gCV_Extract.BoolValue;

	int header[16];
	bsp.Seek(8 + LUMP_PAKFILE * 16, SEEK_SET);
	bsp.Read(header, 8, 1);
	int pakOffset = ReadU32(header, 0);
	int pakLength = ReadU32(header, 4);

	if (pakLength <= 0)
	{
		delete bsp;
		return;
	}

	int tail = pakLength < EOCD_SEARCH ? pakLength : EOCD_SEARCH;

	if (tail < 22)
	{
		delete bsp;
		return;
	}

	int scan[EOCD_SEARCH];
	bsp.Seek(pakOffset + pakLength - tail, SEEK_SET);
	bsp.Read(scan, tail, 1);

	int eocd = -1;

	for (int i = tail - 22; i >= 0; i--)
	{
		if (ReadU32(scan, i) == SIG_EOCD)
		{
			eocd = i;
			break;
		}
	}

	if (eocd < 0)
	{
		delete bsp;
		return;
	}

	int cdOffset = ReadU32(scan, eocd + 16);
	int entries = ReadU16(scan, eocd + 10);

	int queued, extracted, lzma;
	int record[46];
	int raw[PLATFORM_MAX_PATH];
	char name[PLATFORM_MAX_PATH];
	char flat[PLATFORM_MAX_PATH];
	char packed[PLATFORM_MAX_PATH];
	int walk = pakOffset + cdOffset;

	for (int i = 0; i < entries && queued < max; i++)
	{
		bsp.Seek(walk, SEEK_SET);

		if (bsp.Read(record, 46, 1) != 46 || ReadU32(record, 0) != SIG_CENTRAL)
		{
			break;
		}

		int method = ReadU16(record, 10);
		int compressed = ReadU32(record, 20);
		int nameLength = ReadU16(record, 28);
		int extraLength = ReadU16(record, 30);
		int commentLength = ReadU16(record, 32);
		int localHeader = ReadU32(record, 42);

		walk += 46 + nameLength + extraLength + commentLength;

		if (nameLength <= 0 || nameLength >= sizeof(name))
		{
			continue;
		}

		bsp.Read(raw, nameLength, 1);

		for (int c = 0; c < nameLength; c++)
		{
			name[c] = raw[c];
		}

		name[nameLength] = '\0';

		if (!Flatten(name, flat, sizeof(flat)))
		{
			continue;
		}

		FormatEx(packed, sizeof(packed), "%s.bz2", flat);

		if (extract && !FileExists(flat) && !FileExists(packed))
		{
			// stored entries only; anything compressed needs a decompressor
			if (method != 0)
			{
				lzma++;
				continue;
			}

			// the local header's name and extra fields can differ in length
			// from the central directory's, so re-read them here
			int local[30];
			bsp.Seek(pakOffset + localHeader, SEEK_SET);
			bsp.Read(local, 30, 1);
			bsp.Seek(pakOffset + localHeader + 30 + ReadU16(local, 26) + ReadU16(local, 28), SEEK_SET);

			if (!CopyBytes(bsp, flat, compressed))
			{
				continue;
			}

			extracted++;
		}

		AddFileToDownloadsTable(flat);
		queued++;
	}

	delete bsp;

	if (queued || lzma)
	{
		LogMessage("%s: queued %d file%s (%d newly extracted%s)", map, queued,
			queued == 1 ? "" : "s", extracted,
			lzma ? ", LZMA entries skipped" : "");
	}
}
