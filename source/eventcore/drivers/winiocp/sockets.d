module eventcore.drivers.winiocp.sockets;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winiocp.core;
import eventcore.internal.win32;
import eventcore.internal.utils : AlgebraicChoppedVector, print;
import std.socket : Address;

private enum WM_USER_SOCKET = WM_USER + 1;


final class WinIOCPEventDriverSockets : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	private {
		alias SocketVector = AlgebraicChoppedVector!(SocketSlot, StreamSocketSlot, StreamListenSocketSlot, DatagramSocketSlot);
		SocketVector m_sockets;
		WinIOCPEventDriverCore m_core;
		DWORD m_tid;
		HWND m_hwnd;
		size_t m_waiters;
	}

	this(WinIOCPEventDriverCore core)
	@trusted {
		m_tid = GetCurrentThreadId();
		m_core = core;

		// setup socket event message window
		setupWindowClass();
		m_hwnd = CreateWindowA("VibeWin32MessageWindow", "VibeWin32MessageWindow", 0, 0,0,0,0, HWND_MESSAGE,null,null,null);
		SetWindowLongPtrA(m_hwnd, GWLP_USERDATA, cast(ULONG_PTR)cast(void*)this);
		assert(cast(WinIOCPEventDriverSockets)cast(void*)GetWindowLongPtrA(m_hwnd, GWLP_USERDATA) is this);
	}

	package @property size_t waiterCount() const { return m_waiters; }

	override StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect)
	@trusted {
		assert(m_tid == GetCurrentThreadId());

		auto fd = WSASocketW(peer_address.addressFamily, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED);
		if (fd == INVALID_SOCKET)
			return StreamSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closesocket(fd); fd = INVALID_SOCKET; }

		int bret;
		if (bind_address !is null)
			bret = bind(fd, bind_address.name, bind_address.nameLen);
		if (bret != 0) {
			invalidateSocket();
			on_connect(StreamSocketFD.invalid, ConnectStatus.bindFailure);
			return StreamSocketFD.invalid;
		}

		auto sock = adoptStreamInternal(fd);

		auto ret = .connect(fd, peer_address.name, peer_address.nameLen);
		//auto ret = WSAConnect(m_socket, peer_address.name, peer_address.nameLen, null, null, null, null);

		if (ret == 0) {
			m_sockets[sock].specific.state = ConnectionState.connected;
			on_connect(sock, ConnectStatus.connected);
			return sock;
		}

		auto err = WSAGetLastError();
		if (err == WSAEWOULDBLOCK) {
			with (m_sockets[sock].streamSocket) {
				connectCallback = on_connect;
				state = ConnectionState.connecting;
			}
			return sock;
		} else {
			clearSocketSlot(sock);
			invalidateSocket();
			on_connect(StreamSocketFD.invalid, ConnectStatus.unknownError);
			return StreamSocketFD.invalid;
		}
	}

	override StreamSocketFD adoptStream(int socket)
	{
		return adoptStreamInternal(socket);
	}

	private StreamSocketFD adoptStreamInternal(SOCKET socket)
	{
		auto fd = StreamSocketFD(socket);
		if (m_sockets[fd].common.refCount) // FD already in use?
			return StreamSocketFD.invalid;

		// done by wsaasyncselect
		//uint enable = 1;
		//() @trusted { ioctlsocket(socket, FIONBIO, &enable); } ();

		void setupOverlapped(ref WSAOVERLAPPEDX overlapped) @trusted @nogc nothrow {
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = 0;
			overlapped.OffsetHigh = 0;
			overlapped.hEvent = cast(HANDLE)cast(void*)&m_sockets[socket];
		}

		initSocketSlot(fd);
		with (m_sockets[socket]) {
			specific = StreamSocketSlot.init;
			setupOverlapped(streamSocket.write.overlapped);
			setupOverlapped(streamSocket.read.overlapped);
		}

		() @trusted { WSAAsyncSelect(socket, m_hwnd, WM_USER_SOCKET, FD_READ|FD_WRITE|FD_CONNECT|FD_CLOSE); } ();

		return fd;
	}

	alias listenStream = EventDriverSockets.listenStream;
	override StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept)
	{
		auto fd = () @trusted { return WSASocketW(bind_address.addressFamily, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED); } ();
		if (fd == INVALID_SOCKET)
			return StreamListenSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closesocket(fd); fd = INVALID_SOCKET; }

		() @trusted {
			int tmp_reuse = 1;
			if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0) {
				invalidateSocket();
				return;
			}

			// FIXME: should SO_EXCLUSIVEADDRUSE be used of StreamListenOptions.reuseAddress isn't set?

			if (bind(fd, bind_address.name, bind_address.nameLen) != 0) {
				invalidateSocket();
				return;
			}
			if (listen(fd, 128) != 0) {
				invalidateSocket();
				return;
			}
		} ();

		if (fd == INVALID_SOCKET)
			return StreamListenSocketFD.invalid;

		auto sock = cast(StreamListenSocketFD)fd;
		initSocketSlot(sock);
		m_sockets[sock].specific = StreamListenSocketSlot.init;

		if (on_accept) waitForConnections(sock, on_accept);

		return sock;
	}

	override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		assert(!m_sockets[sock].streamListen.acceptCallback);
		m_sockets[sock].streamListen.acceptCallback = on_accept;
		() @trusted { WSAAsyncSelect(sock, m_hwnd, WM_USER_SOCKET, FD_ACCEPT); } ();
		m_core.addWaiter();
	}

	override ConnectionState getConnectionState(StreamSocketFD sock)
	{
		return m_sockets[sock].streamSocket.state;
	}

	override bool getLocalAddress(SocketFD sock, scope RefAddress dst)
	{
		socklen_t addr_len = dst.nameLen;
		if (() @trusted { return getsockname(sock, dst.name, &addr_len); } () != 0)
			return false;
		dst.cap(addr_len);
		return true;
	}

	override bool getRemoteAddress(SocketFD sock, scope RefAddress dst)
	{
		socklen_t addr_len = dst.nameLen;
		if (() @trusted { return getpeername(sock, dst.name, &addr_len); } () != 0)
			return false;
		dst.cap(addr_len);
		return true;
	}

	override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	@trusted {
		BOOL eni = enable;
		setsockopt(INVALID_SOCKET, IPPROTO_TCP, TCP_NODELAY, &eni, eni.sizeof);
	}

	override void setKeepAlive(StreamSocketFD socket, bool enable)
	@trusted {
		BOOL eni = enable;
		setsockopt(INVALID_SOCKET, SOL_SOCKET, SO_KEEPALIVE, &eni, eni.sizeof);
	}

	override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		auto slot = () @trusted { return &m_sockets[socket].streamSocket(); } ();
		slot.read.buffer = buffer;
		slot.read.mode = mode;
		slot.read.wsabuf[0].len = buffer.length;
		slot.read.wsabuf[0].buf = () @trusted { return buffer.ptr; } ();

		auto ovl = mode == IOMode.immediate ? null : &slot.read.overlapped;
		DWORD flags = 0;
		auto ret = () @trusted { return WSARecv(socket, &slot.read.wsabuf[0], slot.read.wsabuf.length, null, &flags, ovl, &onIOReadCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (mode == IOMode.immediate) {
					on_read_finish(socket, IOStatus.wouldBlock, 0);
					return;
				}
			} else {
				on_read_finish(socket, IOStatus.error, 0);
				return;
			}
		}
		slot.read.callback = on_read_finish;
		m_core.addWaiter();
	}


	private static extern(System) nothrow
	void onIOReadCompleted(DWORD dwError, DWORD cbTransferred, WSAOVERLAPPEDX* lpOverlapped, DWORD dwFlags)
	{
		auto slot = () @trusted { return cast(SocketVector.FullField*)lpOverlapped.hEvent; } ();

		if (!slot.streamSocket.read.callback) return;

		void invokeCallback(IOStatus status, size_t nsent)
		@safe nothrow {
			slot.common.core.removeWaiter();
			auto cb = slot.streamSocket.read.callback;
			slot.streamSocket.read.callback = null;
			cb(cast(StreamSocketFD)slot.common.fd, status, nsent);
		}

		slot.streamSocket.read.bytesTransferred += cbTransferred;
		slot.streamSocket.read.buffer = slot.streamSocket.read.buffer[cbTransferred .. $];

		if (dwError) {
			invokeCallback(IOStatus.error, 0);
			return;
		}

		if (slot.streamSocket.read.mode == IOMode.once || !slot.streamSocket.read.buffer.length) {
			invokeCallback(IOStatus.ok, cbTransferred);
			return;
		}

		slot.streamSocket.read.wsabuf[0].len = slot.streamSocket.read.buffer.length;
		slot.streamSocket.read.wsabuf[0].buf = () @trusted { return cast(ubyte*)slot.streamSocket.read.buffer.ptr; } ();
		auto ovl = slot.streamSocket.read.mode == IOMode.immediate ? null : &slot.streamSocket.read.overlapped;
		DWORD flags = 0;
		auto ret = () @trusted { return WSARecv(slot.common.fd, &slot.streamSocket.read.wsabuf[0], slot.streamSocket.read.wsabuf.length, null, &flags, ovl, &onIOReadCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (slot.streamSocket.read.mode == IOMode.immediate) {
					invokeCallback(IOStatus.wouldBlock, 0);
				}
			} else {
				invokeCallback(IOStatus.error, 0);
			}
		}
	}

	override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		auto slot = () @trusted { return &m_sockets[socket].streamSocket(); } ();
		slot.write.buffer = buffer;
		slot.write.mode = mode;
		slot.write.wsabuf[0].len = buffer.length;
		slot.write.wsabuf[0].buf = () @trusted { return cast(ubyte*)buffer.ptr; } ();

		auto ovl = mode == IOMode.immediate ? null : &m_sockets[socket].streamSocket.write.overlapped;
		auto ret = () @trusted { return WSASend(socket, &slot.write.wsabuf[0], slot.write.wsabuf.length, null, 0, ovl, &onIOWriteCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (mode == IOMode.immediate) {
					on_write_finish(socket, IOStatus.wouldBlock, 0);
					return;
				}
			} else {
				on_write_finish(socket, IOStatus.error, 0);
				return;
			}
		}
		m_sockets[socket].streamSocket.write.callback = on_write_finish;
		m_core.addWaiter();
	}

	private static extern(System) nothrow
	void onIOWriteCompleted(DWORD dwError, DWORD cbTransferred, WSAOVERLAPPEDX* lpOverlapped, DWORD dwFlags)
	{
		auto slot = () @trusted { return cast(SocketVector.FullField*)lpOverlapped.hEvent; } ();

		if (!slot.streamSocket.write.callback) return;

		void invokeCallback(IOStatus status, size_t nsent)
		@safe nothrow {
			slot.common.core.removeWaiter();
			auto cb = slot.streamSocket.write.callback;
			slot.streamSocket.write.callback = null;
			cb(cast(StreamSocketFD)slot.common.fd, status, nsent);
		}

		slot.streamSocket.write.bytesTransferred += cbTransferred;
		slot.streamSocket.write.buffer = slot.streamSocket.write.buffer[cbTransferred .. $];

		if (dwError) {
			invokeCallback(IOStatus.error, 0);
			return;
		}

		if (slot.streamSocket.write.mode == IOMode.once || !slot.streamSocket.write.buffer.length) {
			invokeCallback(IOStatus.ok, cbTransferred);
			return;
		}

		slot.streamSocket.write.wsabuf[0].len = slot.streamSocket.write.buffer.length;
		slot.streamSocket.write.wsabuf[0].buf = () @trusted { return cast(ubyte*)slot.streamSocket.write.buffer.ptr; } ();
		auto ovl = slot.streamSocket.write.mode == IOMode.immediate ? null : &slot.streamSocket.write.overlapped;
		auto ret = () @trusted { return WSASend(slot.common.fd, &slot.streamSocket.write.wsabuf[0], slot.streamSocket.write.wsabuf.length, null, 0, ovl, &onIOWriteCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (slot.streamSocket.write.mode == IOMode.immediate) {
					invokeCallback(IOStatus.wouldBlock, 0);
				}
			} else {
				invokeCallback(IOStatus.error, 0);
			}
		}
	}

	override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		assert(false, "TODO!");
	}

	override void shutdown(StreamSocketFD socket, bool shut_read = true, bool shut_write = true)
	{
		() @trusted { WSASendDisconnect(socket, null); } ();
		with (m_sockets[socket].streamSocket) {
			state = ConnectionState.closed;
		}
	}

	override void cancelRead(StreamSocketFD socket)
	@trusted {
		if (!m_sockets[socket].streamSocket.read.callback) return;
		CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&m_sockets[socket].streamSocket.read.overlapped);
		m_sockets[socket].streamSocket.read.callback = null;
		m_core.removeWaiter();
	}

	override void cancelWrite(StreamSocketFD socket)
	@trusted {
		if (!m_sockets[socket].streamSocket.write.callback) return;
		CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&m_sockets[socket].streamSocket.write.overlapped);
		m_sockets[socket].streamSocket.write.callback = null;
		m_core.removeWaiter();
	}

	final override DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address)
	{
		auto fd = () @trusted { return WSASocketW(bind_address.addressFamily, SOCK_DGRAM, IPPROTO_UDP, null, 0, WSA_FLAG_OVERLAPPED); } ();
		if (fd == INVALID_SOCKET)
			return DatagramSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closesocket(fd); fd = INVALID_SOCKET; }

		() @trusted {
			if (bind(fd, bind_address.name, bind_address.nameLen) != 0) {
				invalidateSocket();
				return;
			}
		} ();

		if (fd == INVALID_SOCKET)
			return DatagramSocketFD.invalid;

		auto sock = adoptDatagramSocketInternal(fd);

		if (target_address !is null)
			setTargetAddress(sock, target_address);

		return sock;
	}

	final override DatagramSocketFD adoptDatagramSocket(int socket)
	{
		return adoptDatagramSocketInternal(socket);
	}

	private DatagramSocketFD adoptDatagramSocketInternal(SOCKET socket)
	{
		auto fd = DatagramSocketFD(socket);
		if (m_sockets[fd].common.refCount) // FD already in use?
			return DatagramSocketFD.invalid;

		void setupOverlapped(ref WSAOVERLAPPEDX overlapped) @trusted @nogc nothrow {
			overlapped.Internal = 0;
			overlapped.InternalHigh = 0;
			overlapped.Offset = 0;
			overlapped.OffsetHigh = 0;
			overlapped.hEvent = cast(HANDLE)cast(void*)&m_sockets[socket];
		}

		initSocketSlot(fd);
		with (m_sockets[socket]) {
			specific = DatagramSocketSlot.init;
			setupOverlapped(datagramSocket.write.overlapped);
			setupOverlapped(datagramSocket.read.overlapped);
		}

		//() @trusted { WSAAsyncSelect(socket, m_hwnd, WM_USER_SOCKET, FD_READ|FD_WRITE|FD_CONNECT|FD_CLOSE); } ();

		return fd;
	}

	final override void setTargetAddress(DatagramSocketFD socket, scope Address target_address)
	{
		() @trusted { connect(cast(SOCKET)socket, target_address.name, target_address.nameLen); } ();
	}

	final override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		int tmp_broad = enable;
		return () @trusted { return setsockopt(cast(SOCKET)socket, SOL_SOCKET, SO_BROADCAST, &tmp_broad, tmp_broad.sizeof); } () == 0;
	}

	override void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_read_finish)
	{
		auto slot = () @trusted { return &m_sockets[socket].datagramSocket(); } ();
		slot.read.buffer = buffer;
		slot.read.wsabuf[0].buf = () @trusted { return buffer.ptr; } ();
		slot.read.wsabuf[0].len = buffer.length;
		slot.read.mode = mode;
		slot.sourceAddrLen = DatagramSocketSlot.sourceAddr.sizeof;

		auto ovl = &slot.read.overlapped;
		DWORD flags = 0;
		auto ret = () @trusted { return WSARecvFrom(socket, &slot.read.wsabuf[0], slot.read.wsabuf.length, null, &flags, cast(SOCKADDR*)&slot.sourceAddr, &slot.sourceAddrLen, ovl, &onIOReceiveCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err != WSA_IO_PENDING) {
				on_read_finish(socket, IOStatus.error, 0, null);
				return;
			}
		}

		if (mode == IOMode.immediate)
			() @trusted { CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&slot.read.overlapped); } ();

		slot.read.callback = on_read_finish;
		m_core.addWaiter();
	}

	override void cancelReceive(DatagramSocketFD socket)
	@trusted {
		if (!m_sockets[socket].datagramSocket.read.callback) return;
		CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&m_sockets[socket].datagramSocket.read.overlapped);
		m_sockets[socket].datagramSocket.read.callback = null;
		m_core.removeWaiter();
	}

	private static extern(System) nothrow
	void onIOReceiveCompleted(DWORD dwError, DWORD cbTransferred, WSAOVERLAPPEDX* lpOverlapped, DWORD dwFlags)
	{
		auto slot = () @trusted { return cast(SocketVector.FullField*)lpOverlapped.hEvent; } ();

		if (!slot.datagramSocket.read.callback) return;

		void invokeCallback(IOStatus status, size_t nsent)
		@safe nothrow {
			slot.common.core.removeWaiter();
			auto cb = slot.datagramSocket.read.callback;
			slot.datagramSocket.read.callback = null;
			scope addr = new RefAddress(cast(sockaddr*)&slot.datagramSocket.sourceAddr, slot.datagramSocket.sourceAddrLen);
			cb(cast(DatagramSocketFD)slot.common.fd, status, nsent, status == IOStatus.ok ? addr : null);
		}

		slot.datagramSocket.read.bytesTransferred += cbTransferred;
		slot.datagramSocket.read.buffer = slot.datagramSocket.read.buffer[cbTransferred .. $];

		if (!dwError && (slot.datagramSocket.read.mode != IOMode.all || !slot.datagramSocket.read.buffer.length)) {
			invokeCallback(IOStatus.ok, cbTransferred);
			return;
		}

		if (dwError == WSA_OPERATION_ABORTED && slot.datagramSocket.write.mode == IOMode.immediate) {
			invokeCallback(IOStatus.wouldBlock, 0);
			return;
		}

		if (dwError) {
			invokeCallback(IOStatus.error, 0);
			return;
		}

		slot.datagramSocket.read.wsabuf[0].len = slot.datagramSocket.read.buffer.length;
		slot.datagramSocket.read.wsabuf[0].buf = () @trusted { return cast(ubyte*)slot.datagramSocket.read.buffer.ptr; } ();
		auto ovl = slot.datagramSocket.read.mode == IOMode.immediate ? null : &slot.datagramSocket.read.overlapped;
		DWORD flags = 0;
		auto ret = () @trusted { return WSARecvFrom(slot.common.fd, &slot.datagramSocket.read.wsabuf[0], slot.datagramSocket.read.wsabuf.length, null, &flags, cast(SOCKADDR*)&slot.datagramSocket.sourceAddr, &slot.datagramSocket.sourceAddrLen, ovl, &onIOReceiveCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (slot.datagramSocket.read.mode == IOMode.immediate) {
					invokeCallback(IOStatus.wouldBlock, 0);
				}
			} else {
				invokeCallback(IOStatus.error, 0);
			}
		}
	}

	override void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_write_finish)
	{
		auto slot = () @trusted { return &m_sockets[socket].datagramSocket(); } ();
		slot.write.buffer = buffer;
		slot.write.wsabuf[0].len = buffer.length;
		slot.write.wsabuf[0].buf = () @trusted { return cast(ubyte*)buffer.ptr; } ();
		slot.write.mode = mode;
		slot.targetAddr = target_address;

		auto ovl = &slot.write.overlapped;
		auto tan = target_address ? target_address.name : null;
		auto tal = target_address ? target_address.nameLen : 0;
		auto ret = () @trusted { return WSASendTo(socket, &slot.write.wsabuf[0], slot.write.wsabuf.length, null, 0, tan, tal, ovl, &onIOSendCompleted); } ();

		if (ret != 0) {
			auto err = WSAGetLastError();
			if (err != WSA_IO_PENDING) {
				on_write_finish(socket, IOStatus.error, 0, null);
				return;
			}
		}

		if (mode == IOMode.immediate)
			() @trusted { CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&slot.write.overlapped); } ();

		slot.write.callback = on_write_finish;
		m_core.addWaiter();
	}

	override void cancelSend(DatagramSocketFD socket)
	@trusted {
		if (!m_sockets[socket].datagramSocket.write.callback) return;
		CancelIoEx(cast(HANDLE)cast(SOCKET)socket, cast(LPOVERLAPPED)&m_sockets[socket].datagramSocket.write.overlapped);
		m_sockets[socket].datagramSocket.write.callback = null;
		m_core.removeWaiter();
	}

	private static extern(System) nothrow
	void onIOSendCompleted(DWORD dwError, DWORD cbTransferred, WSAOVERLAPPEDX* lpOverlapped, DWORD dwFlags)
	{
		auto slot = () @trusted { return cast(SocketVector.FullField*)lpOverlapped.hEvent; } ();

		if (!slot.datagramSocket.write.callback) return;

		void invokeCallback(IOStatus status, size_t nsent)
		@safe nothrow {
			slot.common.core.removeWaiter();
			auto cb = slot.datagramSocket.write.callback;
			auto addr = slot.datagramSocket.targetAddr;
			slot.datagramSocket.write.callback = null;
			slot.datagramSocket.targetAddr = null;

			if (addr) {
				scope raddr = new RefAddress(addr.name, addr.nameLen);
				cb(cast(DatagramSocketFD)slot.common.fd, status, nsent, raddr);
			} else {
				cb(cast(DatagramSocketFD)slot.common.fd, status, nsent, null);
			}
		}

		slot.datagramSocket.write.bytesTransferred += cbTransferred;
		slot.datagramSocket.write.buffer = slot.datagramSocket.write.buffer[cbTransferred .. $];

		if (!dwError && (slot.datagramSocket.write.mode != IOMode.all || !slot.datagramSocket.write.buffer.length)) {
			invokeCallback(IOStatus.ok, cbTransferred);
			return;
		}

		if (dwError == WSA_OPERATION_ABORTED && slot.datagramSocket.write.mode == IOMode.immediate) {
			invokeCallback(IOStatus.wouldBlock, 0);
			return;
		}

		if (dwError) {
			invokeCallback(IOStatus.error, 0);
			return;
		}

		slot.datagramSocket.write.wsabuf[0].len = slot.datagramSocket.write.buffer.length;
		slot.datagramSocket.write.wsabuf[0].buf = () @trusted { return cast(ubyte*)slot.datagramSocket.write.buffer.ptr; } ();
		auto tan = slot.datagramSocket.targetAddr ? slot.datagramSocket.targetAddr.name : null;
		auto tal = slot.datagramSocket.targetAddr ? slot.datagramSocket.targetAddr.nameLen : 0;
		auto ovl = slot.datagramSocket.write.mode == IOMode.immediate ? null : &slot.datagramSocket.write.overlapped;
		auto ret = () @trusted { return WSASendTo(slot.common.fd, &slot.datagramSocket.write.wsabuf[0], slot.datagramSocket.write.wsabuf.length, null, 0, tan, tal, ovl, &onIOSendCompleted); } ();
		if (ret == SOCKET_ERROR) {
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING) {
				if (slot.datagramSocket.write.mode == IOMode.immediate) {
					invokeCallback(IOStatus.wouldBlock, 0);
				}
			} else {
				invokeCallback(IOStatus.error, 0);
			}
		}
	}

	override void addRef(SocketFD fd)
	{
		assert(m_sockets[fd].common.refCount > 0, "Adding reference to unreferenced socket FD.");
		m_sockets[fd].common.refCount++;
	}

	override bool releaseRef(SocketFD fd)
	{
		import taggedalgebraic : hasType;
		assert(m_sockets[fd].common.refCount > 0, "Releasing reference to unreferenced socket FD.");
		if (--m_sockets[fd].common.refCount == 0) {
			final switch (m_sockets[fd].specific.kind) with (SocketVector.FieldType) {
				case Kind.none: break;
				case Kind.streamSocket:
					cancelRead(cast(StreamSocketFD)fd);
					cancelWrite(cast(StreamSocketFD)fd);
					break;
				case Kind.streamListen:
					if (m_sockets[fd].streamListen.acceptCallback)
						m_core.removeWaiter();
					break;
				case Kind.datagramSocket:
					cancelReceive(cast(DatagramSocketFD)fd);
					cancelSend(cast(DatagramSocketFD)fd);
					break;
			}

			clearSocketSlot(fd);
			() @trusted { closesocket(fd); } ();
			return false;
		}
		return true;
	}

	final protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	final protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	private void* rawUserDataImpl(FD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		SocketSlot* fds = &m_sockets[descriptor].common;
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= SocketSlot.userData.length, "Requested user data is too large.");
		if (size > SocketSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return m_sockets[descriptor].common.userData.ptr;
	}

	private void initSocketSlot(SocketFD fd)
	{
		m_sockets[fd.value].common.refCount = 1;
		m_sockets[fd.value].common.fd = fd;
		m_sockets[fd.value].common.core = m_core;
	}

	package void clearSocketSlot(FD fd)
	{
		auto slot = () @trusted { return &m_sockets[fd]; } ();
		if (slot.common.userDataDestructor)
			() @trusted { slot.common.userDataDestructor(slot.common.userData.ptr); } ();
		*slot = m_sockets.FullField.init;
	}

	private static nothrow extern(System)
	LRESULT onMessage(HWND wnd, UINT msg, WPARAM wparam, LPARAM lparam)
	{
		auto driver = () @trusted { return cast(WinIOCPEventDriverSockets)cast(void*)GetWindowLongPtrA(wnd, GWLP_USERDATA); } ();
		switch(msg){
			default: break;
			case WM_USER_SOCKET:
				SOCKET sock = cast(SOCKET)wparam;
				auto evt = () @trusted { return LOWORD(lparam); } ();
				auto err = () @trusted { return HIWORD(lparam); } ();
				auto slot = () @trusted { return &driver.m_sockets[sock]; } ();
				final switch (slot.specific.kind) with (SocketVector.FieldType) {
					case Kind.none: break;
					case Kind.streamSocket:
						switch (evt) {
							default: break;
							case FD_CONNECT:
								auto cb = slot.streamSocket.connectCallback;
								slot.streamSocket.connectCallback = null;
								if (err) {
									slot.streamSocket.state = ConnectionState.closed;
									cb(cast(StreamSocketFD)sock, ConnectStatus.refused);
								} else {
									slot.streamSocket.state = ConnectionState.connected;
									cb(cast(StreamSocketFD)sock, ConnectStatus.connected);
								}
								break;
							case FD_READ:
								break;
							case FD_WRITE:
								break;
						}
						break;
					case Kind.streamListen:
						if (evt == FD_ACCEPT) {
							/*
			sock_t sockfd;
			sockaddr_storage addr;
			socklen_t addr_len = addr.sizeof;
			() @trusted { sockfd = accept(cast(sock_t)listenfd, () @trusted { return cast(sockaddr*)&addr; } (), &addr_len); } ();
			if (sockfd == -1) break;

			setSocketNonBlocking(cast(SocketFD)sockfd);
			auto fd = cast(StreamSocketFD)sockfd;
			initSocketSlot(fd);
			m_sockets[fd].specific = StreamSocketSlot.init;
			m_sockets[fd].streamSocket.state = ConnectionState.connected;
			m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
			m_loop.setNotifyCallback!(EventType.status)(fd, &onConnectError);
			releaseRef(fd); // setNotifyCallback adds a reference, but waiting for status/disconnect should not affect the ref count
			//print("accept %d", sockfd);
			scope RefAddress addrc = new RefAddress(() @trusted { return cast(sockaddr*)&addr; } (), addr_len);
			m_sockets[listenfd].streamListen.acceptCallback(cast(StreamListenSocketFD)listenfd, fd, addrc);
							*/
							SOCKADDR_STORAGE addr;
							socklen_t addr_len = addr.sizeof;
							auto clientsockfd = () @trusted { return WSAAccept(sock, cast(sockaddr*)&addr, &addr_len, null, 0); } ();
							if (clientsockfd == INVALID_SOCKET) return 0;
							auto clientsock = driver.adoptStreamInternal(clientsockfd);
							scope RefAddress addrc = new RefAddress(() @trusted { return cast(sockaddr*)&addr; } (), addr_len);
							slot.streamListen.acceptCallback(cast(StreamListenSocketFD)sock, clientsock, addrc);
						}
						break;
					case Kind.datagramSocket:
						break;
				}
				return 0;
		}
		return () @trusted { return DefWindowProcA(wnd, msg, wparam, lparam); } ();
	}
}

void setupWindowClass() nothrow
@trusted {
	static __gshared registered = false;

	if (registered) return;
	
	WNDCLASSA wc;
	wc.lpfnWndProc = &WinIOCPEventDriverSockets.onMessage;
	wc.lpszClassName = "VibeWin32MessageWindow";
	RegisterClassA(&wc);
	registered = true;
}

static struct SocketSlot {
	SocketFD fd; // redundant, but needed by the current IO Completion Routines based approach
	WinIOCPEventDriverCore core; // redundant, but needed by the current IO Completion Routines based approach
	int refCount;
	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}

private struct StreamSocketSlot {
	alias Handle = StreamSocketFD;
	StreamDirection!true write;
	StreamDirection!false read;
	ConnectCallback connectCallback;
	ConnectionState state;
}

static struct StreamDirection(bool RO) {
	WSAOVERLAPPEDX overlapped;
	static if (RO) const(ubyte)[] buffer;
	else ubyte[] buffer;
	WSABUF[1] wsabuf;
	size_t bytesTransferred;
	IOMode mode;
	IOCallback callback;
}

private struct StreamListenSocketSlot {
	alias Handle = StreamListenSocketFD;
	AcceptCallback acceptCallback;
}

private struct DatagramSocketSlot {
	alias Handle = DatagramSocketFD;
	DgramDirection!true write;
	DgramDirection!false read;
	Address targetAddr;
	SOCKADDR_STORAGE sourceAddr;
	INT sourceAddrLen;
}

static struct DgramDirection(bool RO) {
	WSAOVERLAPPEDX overlapped;
	static if (RO) const(ubyte)[] buffer;
	else ubyte[] buffer;
	WSABUF[1] wsabuf;
	size_t bytesTransferred;
	IOMode mode;
	DatagramIOCallback callback;
}
