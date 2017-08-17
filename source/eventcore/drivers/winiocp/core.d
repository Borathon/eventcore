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
		DWORD m_tid;
		LoopTimeoutTimerDriver m_timers;
		HANDLE[] m_registeredEvents;
		void delegate() @safe nothrow[HANDLE] m_eventCallbacks;
		HANDLE m_fileCompletionEvent;
		HANDLE m_completionPort;
	}

	package {
		HandleSlot[HANDLE] m_handles; // FIXME: use allocator based hash map
		IocpHandleSlot[HANDLE] m_iocpHandles; // FIXME: use allocator based hash map
	}

	this(LoopTimeoutTimerDriver timers)
	{
		m_timers = timers;
		m_tid = () @trusted { return GetCurrentThreadId(); } ();
		m_fileCompletionEvent = () @trusted { return CreateEventW(null, false, false, null); } ();
		registerEvent(m_fileCompletionEvent);
		m_completionPort = () @trusted { return CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0); } ();
		assert(m_completionPort != INVALID_HANDLE_VALUE);
		registerEvent(m_completionPort);
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
		PostThreadMessageW(m_tid, WM_QUIT, 0, 0);
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

		bool got_event;

		if (max_wait > 0.seconds) {
			DWORD timeout_msecs = max_wait == Duration.max ? INFINITE : cast(DWORD)min(max_wait.total!"msecs", DWORD.max);

			DWORD bytes_transferred;
			ULONG_PTR completion_key;
			LPOVERLAPPED overlapped_ptr;
			auto iocpResult = () @trusted { return GetQueuedCompletionStatus(m_completionPort, &bytes_transferred, &completion_key, &overlapped_ptr, timeout_msecs); } ();
			if (iocpResult != 0) {
				if (overlapped_ptr != null && completion_key != 0) {
					auto handle = () @trusted { return cast(HANDLE) completion_key; } ();
					m_iocpHandles[handle].dispatchCb(handle, overlapped_ptr, bytes_transferred);
					got_event = true;
				}
			} else {
				import std.conv: to;
				assert(false, GetLastError().to!string);
			}

			auto ret = () @trusted { return MsgWaitForMultipleObjectsEx(cast(DWORD)m_registeredEvents.length, m_registeredEvents.ptr,
				timeout_msecs, QS_ALLEVENTS, MWMO_ALERTABLE|MWMO_INPUTAVAILABLE); } ();
			
			if (ret == WAIT_IO_COMPLETION) got_event = true;
			else if (ret >= WAIT_OBJECT_0 && ret < WAIT_OBJECT_0 + m_registeredEvents.length) {
				if (auto pc = m_registeredEvents[ret - WAIT_OBJECT_0] in m_eventCallbacks) {
					(*pc)();
					got_event = true;
				}
			}

			/*if (ret == WAIT_OBJECT_0) {
				got_event = true;
				Win32TCPConnection[] to_remove;
				foreach( fw; m_fileWriters.byKey )
					if( fw.testFileWritten() )
						to_remove ~= fw;
				foreach( fw; to_remove )
				m_fileWriters.remove(fw);
			}*/
		}

		MSG msg;
		//uint cnt = 0;
		while (() @trusted { return PeekMessageW(&msg, null, 0, 0, PM_REMOVE); } ()) {
			if (msg.message == WM_QUIT && m_exit)
				break;

			() @trusted {
				TranslateMessage(&msg);
				DispatchMessageW(&msg);
			} ();

			got_event = true;

			// process timers every now and then so that they don't get stuck
			//if (++cnt % 10 == 0) processTimers();
		}

		return got_event;
	}


	package void registerEvent(HANDLE event, void delegate() @safe nothrow callback = null)
	{
		m_registeredEvents ~= event;
		if (callback) m_eventCallbacks[event] = callback;
	}

	package SlotType* setupSlot(SlotType)(HANDLE h)
	{
		assert(h !in m_handles, "Handle already in use.");
		HandleSlot s;
		s.refCount = 1;
		s.specific = SlotType.init;
		m_handles[h] = s;
		return () @trusted { return &m_handles[h].specific.get!SlotType(); } ();
	}

	package void freeSlot(HANDLE h)
	{
		assert(h in m_handles, "Handle not in use - cannot free.");
		m_handles.remove(h);
	}

	package SlotType* setupIocpSlot(SlotType)(HANDLE handle)
	{
		assert(handle !in m_handles, "Handle already in use.");
		IocpHandleSlot s;
		s.refCount = 1;
		s.specific = SlotType.init;
		s.dispatchCb = &s.specific.get!SlotType().invokeCallback;
		m_iocpHandles[handle] = s;
		return () @trusted {
			auto result = CreateIoCompletionPort(handle, m_completionPort, cast(ULONG_PTR) handle, 0); // TODO error handling
			assert(result == m_completionPort);
			return &m_iocpHandles[handle].specific.get!SlotType();
		} ();
	}

	package void freeIocpSlot(HANDLE h)
	{
		assert(h in m_handles, "Handle not in use - cannot free.");
		m_iocpHandles.remove(h);
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
	
}

private struct IocpHandleSlot {
	import eventcore.drivers.winiocp.watchers: WinIOCPEventDriverWatchers;
	alias WatcherSlot = WinIOCPEventDriverWatchers.WatcherSlot;
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
	void delegate(HANDLE handle, LPOVERLAPPED overlapped_ptr, size_t bytes_transferred) dispatchCb;
	
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
		HANDLE handle; // set to INVALID_HANDLE_VALUE when closed

		void invokeCallback(IOStatus status, size_t bytes_transferred)
		@safe nothrow {
			auto cb = this.callback;
			this.callback = null;
			assert(cb !is null);
			cb(FileFD(cast(int)this.handle), status, bytes_transferred);
		}
	}
	Direction!false read;
	Direction!true write;

	void invokeCallback(HANDLE handle, LPOVERLAPPED overlapped_ptr, size_t bytes_transferred)
	@safe nothrow {
	// 	IOStatus status = operlapped_ptr.Internal == 0 ? IOStatus.ok : IOStatus.error;

	// 	switch (overlapped_ptr)
	// 	{
	// 		default: assert(false, "Pointer to unknown overlapped struct passed!");
	// 		case &read.overlapped: read.invokeCallback(status, bytes_transferred); break;
	// 		case &write.overlapped: write.invokeCallback(status, bytes_transferred); break;
	// 	}
	}
}
