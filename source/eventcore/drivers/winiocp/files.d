module eventcore.drivers.winiocp.files;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winiocp.core;
import eventcore.internal.win32;

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
		auto creation = mode == FileOpenMode.createTrunc ? CREATE_ALWAYS : mode == FileOpenMode.append ? OPEN_ALWAYS : OPEN_EXISTING;

		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, access, shareMode, null, creation,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
		} ();

		auto errorcode = GetLastError();
		if (handle == INVALID_HANDLE_VALUE)
			return FileFD.invalid;

		if (mode == FileOpenMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS) {
			BOOL result = () @trusted { return SetEndOfFile(handle); } ();
			if (!result) {
				() @trusted { return CloseHandle(handle); } ();
				return FileFD.init;
			}
		}

		return adopt(cast(int)handle);
	}

	override FileFD adopt(int system_handle)
	{
		auto handle = () @trusted { return cast(HANDLE) system_handle; } ();
		DWORD f;
		if (!() @trusted { return GetHandleInformation(handle, &f); } ())
			return FileFD.init;

		m_core.setupSlot!FileSlot(handle);

		return FileFD(system_handle);
	}

	override void close(FileFD id)
	{
		auto handle = idToHandle(id);
		with (m_core.m_handles[handle].file) {
			if (!closed) {
				if (() @trusted { return CloseHandle(handle); } ()) {
					closed = true;
				} else {
					// TODO: error handling
				}
			}
		}
	}

	override ulong getSize(FileFD id)
	{
		LARGE_INTEGER size;
		auto succeeded = () @trusted { return GetFileSizeEx(idToHandle(id), &size); } ();
		if (!succeeded || size.QuadPart < 0)
			return ulong.max;
		return size.QuadPart;
	}

	override void write(FileFD id, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		if (!buffer.length) {
			on_write_finish(id, IOStatus.ok, 0);
			return;
		}

		auto handle = idToHandle(id);
		with (m_core.m_handles[handle].file) {
			write.bytesTransferred = 0;
			write.offset = offset;
			write.buffer = buffer;
			write.mode = mode;
			write.callback = on_write_finish;
			startIO!(WriteFile, true)(m_core, handle, write);
		}
	}

	override void read(FileFD id, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		if (!buffer.length) {
			on_read_finish(id, IOStatus.ok, 0);
			return;
		}

		auto handle = idToHandle(id);
		with (m_core.m_handles[handle].file) {
			read.bytesTransferred = 0;
			read.offset = offset;
			read.buffer = buffer;
			read.mode = mode;
			read.callback = on_read_finish;
			startIO!(ReadFile, false)(m_core, handle, read);
		}
	}

	override void cancelWrite(FileFD id)
	{
		auto handle = idToHandle(id);
		cancelIO!true(handle, m_core.m_handles[handle].file.write);
	}

	override void cancelRead(FileFD id)
	{
		auto handle = idToHandle(id);
		cancelIO!false(handle, m_core.m_handles[handle].file.read);
	}

	override void addRef(FileFD id)
	{
		m_core.m_handles[idToHandle(id)].addRef();
	}

	override bool releaseRef(FileFD id)
	{
		auto handle = idToHandle(id);
		return m_core.m_handles[handle].releaseRef({
			close(id);
			m_core.freeSlot(handle);
		});
	}

	private static void startIO(alias fun, bool RO)(WinIOCPEventDriverCore core, HANDLE handle, ref FileSlot.Direction!RO dir)
	{
		with (dir) {
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = cast(uint)(offset & 0xFFFFFFFF);
			overlapped.OffsetHigh = cast(uint)(offset >> 32);
			overlapped.hEvent = null;

			if (() @trusted { return fun(handle, buffer.ptr, cast(DWORD) (buffer.length > DWORD.max ? DWORD.max: buffer.length), NULL, &overlapped); } ()) {
				// Operation completed synchronously
				invokeCallback(handle, IOStatus.ok, bytesTransferred);
			} else {
				if (GetLastError() == ERROR_IO_PENDING) {
					// Operation scheduled for execution
					core.addWaiter();
				} else {
					invokeCallback(handle, IOStatus.error, bytesTransferred);
				}
			}
		}
	}

	private static void cancelIO(bool RO)(HANDLE handle, ref FileSlot.Direction!RO dir) @trusted
	{
		CancelIoEx(handle, &dir.overlapped);
	}

	static private void invokeFileCallback(alias fun, bool RO)(WinIOCPEventDriverCore core, ref FileSlot.Direction!RO dir, HANDLE handle, DWORD error, DWORD bytes_transferred)
	{
		auto id = FileFD(cast(int) handle);

		with (dir) {
			if (error != 0) {
				invokeCallback(handle, IOStatus.error, bytesTransferred + bytes_transferred);
				return;
			}

			bytesTransferred += bytes_transferred;
			offset += bytes_transferred;

			if (bytesTransferred >= buffer.length || mode != IOMode.all) {
				invokeCallback(handle, IOStatus.ok, bytesTransferred);
			} else {
				startIO!(fun, RO)(core, handle, dir);
			}
		}

		core.removeWaiter();
	}

	private static HANDLE idToHandle(FileFD id)
	@trusted {
		return cast(HANDLE) cast(int) id;
	}

	package struct FileSlot {
		static struct Direction(bool RO) {
			OVERLAPPED overlapped;
			FileIOCallback callback;
			ulong offset;
			size_t bytesTransferred;
			IOMode mode;
			static if (RO) const(ubyte)[] buffer;
			else ubyte[] buffer;

			void invokeCallback(HANDLE handle, IOStatus status, size_t bytes_transferred)
			@safe nothrow {
				auto cb = this.callback;
				this.callback = null;
				assert(cb !is null);
				cb(FileFD(cast(int) handle), status, bytes_transferred);
			}
		}
		bool closed;
		Direction!false read;
		Direction!true write;

		void dispatchCallback(WinIOCPEventDriverCore core, HANDLE handle, LPOVERLAPPED overlapped_ptr, size_t bytes_transferred)
		@safe nothrow {
			DWORD error = 0; //TODO
			// TODO figure out error handling
			// 	IOStatus status = operlapped_ptr.Internal == 0 ? IOStatus.ok : IOStatus.error;

		 	if (&read.overlapped == overlapped_ptr) {
				invokeFileCallback!(ReadFile, false)(core, read, handle, error, bytes_transferred);
			} else if (overlapped_ptr == &write.overlapped) {
				invokeFileCallback!(WriteFile, true)(core, write, handle, error, bytes_transferred);
			} else assert(false, "Pointer to unknown overlapped struct received!");
		}
	}
}
