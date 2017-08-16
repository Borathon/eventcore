/**
	WinAPI based event driver implementation.

	This driver uses overlapped I/O to model asynchronous I/O operations
	efficiently. The driver's event loop processes UI messages, so that
	it integrates with GUI applications transparently.
*/
module eventcore.drivers.winiocp.driver;

version (Windows):

import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.drivers.winiocp.core;
import eventcore.drivers.winiocp.dns;
import eventcore.drivers.winiocp.events;
import eventcore.drivers.winiocp.files;
import eventcore.drivers.winiocp.signals;
import eventcore.drivers.winiocp.sockets;
import eventcore.drivers.winiocp.watchers;
import core.sys.windows.windows;

static assert(HANDLE.sizeof <= FD.BaseType.sizeof);
static assert(FD(cast(int)INVALID_HANDLE_VALUE) == FD.init);


final class WinIOCPEventDriver : EventDriver {
	private {
		WinIOCPEventDriverCore m_core;
		WinIOCPEventDriverFiles m_files;
		WinIOCPEventDriverSockets m_sockets;
		WinIOCPEventDriverDNS m_dns;
		LoopTimeoutTimerDriver m_timers;
		WinIOCPEventDriverEvents m_events;
		WinIOCPEventDriverSignals m_signals;
		WinIOCPEventDriverWatchers m_watchers;
	}

	static WinIOCPEventDriver threadInstance;

	this()
	@safe {
		assert(threadInstance is null);
		threadInstance = this;

		import std.exception : enforce;

		WSADATA wd;
		enforce(() @trusted { return WSAStartup(0x0202, &wd); } () == 0, "Failed to initialize WinSock");

		m_signals = new WinIOCPEventDriverSignals();
		m_timers = new LoopTimeoutTimerDriver();
		m_core = new WinIOCPEventDriverCore(m_timers);
		m_events = new WinIOCPEventDriverEvents(m_core);
		m_files = new WinIOCPEventDriverFiles(m_core);
		m_sockets = new WinIOCPEventDriverSockets(m_core);
		m_dns = new WinIOCPEventDriverDNS();
		m_watchers = new WinIOCPEventDriverWatchers(m_core);
	}

@safe: /*@nogc:*/ nothrow:

	override @property WinIOCPEventDriverCore core() { return m_core; }
	override @property WinIOCPEventDriverFiles files() { return m_files; }
	override @property WinIOCPEventDriverSockets sockets() { return m_sockets; }
	override @property WinIOCPEventDriverDNS dns() { return m_dns; }
	override @property LoopTimeoutTimerDriver timers() { return m_timers; }
	override @property WinIOCPEventDriverEvents events() { return m_events; }
	override @property shared(WinIOCPEventDriverEvents) events() shared { return m_events; }
	override @property WinIOCPEventDriverSignals signals() { return m_signals; }
	override @property WinIOCPEventDriverWatchers watchers() { return m_watchers; }

	override void dispose()
	{
		m_events.dispose();
		assert(threadInstance !is null);
		threadInstance = null;
	}
}
