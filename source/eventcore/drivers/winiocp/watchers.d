module eventcore.drivers.winiocp.watchers;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winiocp.core;
import eventcore.drivers.winiocp.driver : WinIOCPEventDriver; // FIXME: this is an ugly dependency
import eventcore.internal.win32;
import std.experimental.allocator : dispose, makeArray, theAllocator;


final class WinIOCPEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private {
		WinIOCPEventDriverCore m_core;
	}

	this(WinIOCPEventDriverCore core)
	{
		m_core = core;
	}

	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		import std.utf : toUTF16z;
		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, FILE_LIST_DIRECTORY,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				null, OPEN_EXISTING,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
				null);
		} ();
		
		if (handle == INVALID_HANDLE_VALUE)
			return WatcherID.invalid;

		auto updateSlotAndTriggerRead(ref WatcherSlot slot) {
			slot.directory = path;
			slot.recursive = recursive;
			slot.callback = callback;
			slot.buffer = () @trusted {
				try return theAllocator.makeArray!ubyte(16384);
				catch (Exception e) assert(false, "Failed to allocate directory watcher buffer.");
			} ();

			auto id = WatcherID(cast(int)handle);
			if (!triggerRead(m_core, slot, handle)) {
				releaseRef(id);
				return WatcherID.invalid;
			}

			return id;
		}

		return updateSlotAndTriggerRead(m_core.setupSlot!WatcherSlot(handle));
	}

	static private bool triggerRead(WinIOCPEventDriverCore core, ref WatcherSlot slot, HANDLE handle)
	{
		enum UINT notifications = FILE_NOTIFY_CHANGE_FILE_NAME|
			FILE_NOTIFY_CHANGE_DIR_NAME|FILE_NOTIFY_CHANGE_SIZE|
			FILE_NOTIFY_CHANGE_LAST_WRITE;

		with (slot) {
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = 0;
			overlapped.OffsetHigh = 0;
			overlapped.hEvent = null;

		    BOOL result = () @trusted {
			    return ReadDirectoryChangesW(handle, buffer.ptr, cast(DWORD) buffer.length, recursive, notifications, null, &overlapped, null);
		    } ();

			if (result != 0) core.addWaiter();

			return result != 0;
		}
	}

	override void addRef(WatcherID descriptor)
	{
		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(WatcherID descriptor)
	{
		auto handle = idToHandle(descriptor);
		return m_core.m_handles[handle].releaseRef(() nothrow {
			CloseHandle(handle);
			() @trusted {
				try theAllocator.dispose(m_core.m_handles[handle].watcher.buffer);
				catch (Exception e) assert(false, "Freeing directory watcher buffer failed.");
			} ();
			m_core.freeSlot(handle);
		});
	}

	package struct WatcherSlot {
		OVERLAPPED overlapped;
		ubyte[] buffer;
		string directory;
		bool recursive;
		FileChangesCallback callback;

		void dispatchCallback(WinIOCPEventDriverCore core, HANDLE handle, LPOVERLAPPED overlapped_ptr, size_t bytes_transferred)
		@trusted nothrow {
			assert(&overlapped == overlapped_ptr);
			invokeWatcherCallback(core, this, handle, bytes_transferred);
		}
	}

	static private void invokeWatcherCallback(WinIOCPEventDriverCore core, ref WatcherSlot slot, HANDLE handle, DWORD bytes_transferred)
	{
		import std.conv : to;

		auto id = WatcherID(cast(int)handle);
		ubyte[] result = slot.buffer[0 .. bytes_transferred];
		do {
			assert(result.length >= FILE_NOTIFY_INFORMATION.sizeof);
			auto fni = () @trusted { return cast(FILE_NOTIFY_INFORMATION*)result.ptr; } ();
			FileChange ch;
			switch (fni.Action) {
				default: ch.kind = FileChangeKind.modified; break;
				case 0x1: ch.kind = FileChangeKind.added; break;
				case 0x2: ch.kind = FileChangeKind.removed; break;
				case 0x3: ch.kind = FileChangeKind.modified; break;
				case 0x4: ch.kind = FileChangeKind.removed; break;
				case 0x5: ch.kind = FileChangeKind.added; break;
			}
			ch.directory = slot.directory;
			ch.isDirectory = false; // FIXME: is this right?
			ch.name = () @trusted { scope (failure) assert(false); return to!string(fni.FileName[0 .. fni.FileNameLength/2]); } ();
			slot.callback(id, ch);
			if (fni.NextEntryOffset == 0) break;
			result = result[fni.NextEntryOffset .. $];
		} while (result.length > 0);

		triggerRead(core, slot, handle);

		core.removeWaiter();
	}

	static private HANDLE idToHandle(WatcherID id) @trusted { return cast(HANDLE)cast(int)id; }
}