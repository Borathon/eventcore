module eventcore.drivers.winiocp.files;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winiocp.core;
import eventcore.internal.win32;

private extern(Windows) @trusted nothrow @nogc {
	BOOL SetEndOfFile(HANDLE hFile);
	BOOL CancelIoEx(HANDLE hFile, OVERLAPPED* lpOverlapped);
}

final class WinIOCPEventDriverFiles : EventDriverFiles {
@safe /*@nogc*/ nothrow:
	private {
		WinIOCPEventDriverCore m_core;
	}

	this(WinIOCPEventDriverCore core)
	{
		m_core = core;
	}

	override FileFD open(string path, FileOpenMode mode)
	{
		import std.utf : toUTF16z;

		auto access = mode == FileOpenMode.readWrite || mode == FileOpenMode.createTrunc ? (GENERIC_WRITE | GENERIC_READ) :
						mode == FileOpenMode.append ? GENERIC_WRITE : GENERIC_READ;
		auto shareMode = mode == FileOpenMode.read ? FILE_SHARE_READ : 0;
		auto creation = mode == FileOpenMode.createTrunc ? CREATE_ALWAYS : mode == FileOpenMode.append? OPEN_ALWAYS : OPEN_EXISTING;

		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, access, shareMode, null, creation,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
		} ();
		auto errorcode = GetLastError();
		if (handle == INVALID_HANDLE_VALUE)
			return FileFD.invalid;

		if (mode == FileOpenMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS) {
			BOOL ret = SetEndOfFile(handle);
			if (!ret) {
				CloseHandle(handle);
				return FileFD.init;
			}
		}

		return adopt(cast(int)handle);
	}

	override FileFD adopt(int system_handle)
	{
		auto handle = () @trusted { return cast(HANDLE)system_handle; } ();
		DWORD f;
		if (!() @trusted { return GetHandleInformation(handle, &f); } ())
			return FileFD.init;

		auto s = m_core.setupSlot!FileSlot(handle);
		s.read.handle = s.write.handle = handle;

		return FileFD(system_handle);
	}

	override void close(FileFD file)
	{
		auto h = idToHandle(file);
		auto slot = () @trusted { return &m_core.m_handles[h].file(); } ();
		if (slot.read.handle != INVALID_HANDLE_VALUE) {
			CloseHandle(h);
			slot.read.handle = slot.write.handle = INVALID_HANDLE_VALUE;
		}
	}

	override ulong getSize(FileFD file)
	{
		LARGE_INTEGER size;
		auto succeeded = () @trusted { return GetFileSizeEx(idToHandle(file), &size); } ();
		if (!succeeded || size.QuadPart < 0)
			return ulong.max;
		return size.QuadPart;
	}

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		if (!buffer.length) {
			on_write_finish(file, IOStatus.ok, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.write;
		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_write_finish;
		startIO!(WriteFileEx, true)(h, slot);
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		if (!buffer.length) {
			on_read_finish(file, IOStatus.ok, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.read;
		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_read_finish;
		startIO!(ReadFileEx, false)(h, slot);
	}

	override void cancelWrite(FileFD file)
	{
		auto h = idToHandle(file);
		cancelIO!true(h, m_core.m_handles[h].file.write);
	}

	override void cancelRead(FileFD file)
	{
		auto h = idToHandle(file);
		cancelIO!false(h, m_core.m_handles[h].file.read);
	}

	override void addRef(FileFD descriptor)
	{
		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(FileFD descriptor)
	{
		auto h = idToHandle(descriptor);
		return m_core.m_handles[h].releaseRef({
			close(descriptor);
			m_core.freeSlot(h);
		});
	}

	private static void startIO(alias fun, bool RO)(HANDLE h, FileSlot.Direction!RO* slot)
	{
		import std.algorithm.comparison : min;

		with (slot.overlapped) {
			Internal = 0;
			InternalHigh = 0;
			Offset = cast(uint)(slot.offset & 0xFFFFFFFF);
			OffsetHigh = cast(uint)(slot.offset >> 32);
			hEvent = () @trusted { return cast(HANDLE)slot; } ();
		}

		auto nbytes = min(slot.buffer.length, DWORD.max);
		if (!() @trusted { return fun(h, &slot.buffer[0], nbytes, &slot.overlapped, &onIOFinished!(fun, RO)); } ()) {
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred);
		}
	}

	private static void cancelIO(bool RO)(HANDLE h, ref FileSlot.Direction!RO slot)
	{
		if (slot.callback) {
			//CancelIoEx(h, &slot.overlapped); // FIXME: currently causes linker errors for DMD due to outdated kernel32.lib files
			slot.callback = null;
			slot.buffer = null;
		}
	}

	private static extern(Windows)
	void onIOFinished(alias fun, bool RO)(DWORD error, DWORD bytes_transferred, OVERLAPPED* overlapped)
	{

		auto slot = () @trusted { return cast(FileSlot.Direction!RO*)overlapped.hEvent; } ();
		assert(slot !is null);
		HANDLE h = slot.handle;
		auto id = FileFD(cast(int)h);

		if (!slot.callback) {
			// request was already cancelled
			return;
		}

		if (error != 0) {
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred + bytes_transferred);
			return;
		}

		slot.bytesTransferred += bytes_transferred;
		slot.offset += bytes_transferred;

		if (slot.bytesTransferred >= slot.buffer.length || slot.mode != IOMode.all) {
			slot.invokeCallback(IOStatus.ok, slot.bytesTransferred);
		} else {
			startIO!(fun, RO)(h, slot);
		}
	}

	private static HANDLE idToHandle(FileFD id)
	@trusted {
		return cast(HANDLE)cast(int)id;
	}
}
