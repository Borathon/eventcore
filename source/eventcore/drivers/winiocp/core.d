module eventcore.drivers.winiocp.core;

version (Windows):

import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.internal.win32;
import core.time : Duration;
import taggedalgebraic;


final class WinIOCPEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	private {
		bool m_exit;
		size_t m_waiterCount;
		HANDLE m_completionPort;
		LoopTimeoutTimerDriver m_timers;
	}

	package {
		HandleSlot[HANDLE] m_handles; // FIXME: use allocator based hash map
	}

	this(LoopTimeoutTimerDriver timers)
	{
		m_timers = timers;
		m_completionPort = () @trusted { return CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0); } ();
	}

	override size_t waiterCount() { return m_waiterCount + m_timers.pendingCount; }

	package void addWaiter() { m_waiterCount++; }
	package void removeWaiter() { m_waiterCount--; }

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		import std.algorithm : min;
		import core.time : hnsecs, seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		bool got_event;

		if (timeout <= 0.seconds) {
			got_event = doProcessEvents(0.seconds);
			got_event |= m_timers.process(currStdTime);
			return got_event ? ExitReason.idle : ExitReason.timeout;
		} else {
			long now = currStdTime;
			do {
				auto nextto = min(m_timers.getNextTimeout(now), timeout);
				got_event |= doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				got_event |= m_timers.process(now);

				if (m_exit) {
					m_exit = false;
					return ExitReason.exited;
				} else if (got_event) break;
				if (timeout != Duration.max)
					timeout -= (now - prev_step).hnsecs;
			} while (timeout > 0.seconds);
		}

		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_event) return ExitReason.idle;
		return ExitReason.timeout;
	}

	override void exit()
	@trusted {
		m_exit = true;
		PostQueuedCompletionStatus(m_completionPort, 0, 0, null);
	}

	override void clearExitFlag()
	{
		m_exit = false;
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	private bool doProcessEvents(Duration max_wait)
	{
		import core.time : seconds;
		import std.algorithm.comparison : min;

		if (max_wait > 0.seconds) {
			DWORD timeout_msecs = max_wait == Duration.max ? INFINITE : cast(DWORD)min(max_wait.total!"msecs", DWORD.max);

			DWORD bytes_transferred;
			ULONG_PTR completion_key;
			LPOVERLAPPED overlapped_ptr;
			auto result = () @trusted { return GetQueuedCompletionStatus(m_completionPort, &bytes_transferred, &completion_key, &overlapped_ptr, timeout_msecs); } ();
			if (result != 0 && overlapped_ptr != null && completion_key != 0) {
				auto handle = () @trusted { return cast(HANDLE) completion_key; } ();
				if (handle in m_handles) m_handles[handle].dispatchCallback(this, handle, overlapped_ptr, bytes_transferred);
				return true;
			}
		}

		return false;
	}

	package ref SlotType setupSlot(SlotType)(HANDLE handle)
	{
		assert(handle !in m_handles, "Handle already in use.");
		with (m_handles[handle] = HandleSlot.init) {
			refCount = 1;
			specific = SlotType.init;
			dispatchCallback = &specific.get!SlotType().dispatchCallback;
			
			// TODO: Error handling
			() @trusted { CreateIoCompletionPort(handle, m_completionPort, cast(ULONG_PTR) handle, 0); } ();

			return specific.get!SlotType(); 
		}
	}

	package void freeSlot(HANDLE handle)
	{
		assert(handle in m_handles, "Handle not in use - cannot free.");
		m_handles.remove(handle);
	}
}

private long currStdTime()
@safe nothrow {
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

private struct HandleSlot {
	import eventcore.drivers.winiocp.watchers: WinIOCPEventDriverWatchers;
	alias WatcherSlot = WinIOCPEventDriverWatchers.WatcherSlot;
	import eventcore.drivers.winiocp.files: WinIOCPEventDriverFiles;
	alias FileSlot = WinIOCPEventDriverFiles.FileSlot;
	static union SpecificTypes {
		typeof(null) none;
		FileSlot files;
		WatcherSlot watcher;
	}
	int refCount;
	TaggedAlgebraic!SpecificTypes specific;

	@safe nothrow:

	@property ref FileSlot file() { return specific.get!FileSlot; }
	@property ref WatcherSlot watcher() { return specific.get!WatcherSlot; }

	void addRef()
	{
		assert(refCount > 0);
		refCount++;
	}

	bool releaseRef(scope void delegate() @safe nothrow on_free)
	{
		assert(refCount > 0);
		if (--refCount == 0) {
			on_free();
			return false;
		}
		return true;
	}

	void delegate(WinIOCPEventDriverCore core, HANDLE handle, LPOVERLAPPED overlapped_ptr, size_t bytes_transferred) dispatchCallback;	
}

