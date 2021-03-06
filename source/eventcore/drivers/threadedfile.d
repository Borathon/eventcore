module eventcore.drivers.threadedfile;

import eventcore.driver;
import eventcore.internal.utils;
import core.atomic;
import core.stdc.errno;
import std.algorithm.comparison : among, min;

version(Posix){
	import core.sys.posix.fcntl;
	import core.sys.posix.sys.stat;
	import core.sys.posix.unistd;
}
version(Windows){
	static if (__VERSION__ >= 2070)
		import core.sys.windows.stat;
	else
		import std.c.windows.stat;

	private {
		// TODO: use CreateFile/HANDLE instead of the Posix API on Windows

		extern(C) nothrow {
			alias off_t = sizediff_t;
			int open(in char* name, int mode, ...);
			int chmod(in char* name, int mode);
			int close(int fd) @safe;
			int read(int fd, void *buffer, uint count);
			int write(int fd, in void *buffer, uint count);
			off_t lseek(int fd, off_t offset, int whence) @safe;
		}

		enum O_RDONLY = 0;
		enum O_WRONLY = 1;
		enum O_RDWR = 2;
		enum O_APPEND = 8;
		enum O_CREAT = 0x0100;
		enum O_TRUNC = 0x0200;
		enum O_BINARY = 0x8000;

		enum _S_IREAD = 0x0100;          /* read permission, owner */
		enum _S_IWRITE = 0x0080;          /* write permission, owner */
		alias stat_t = struct_stat;
	}
}
else
{
	enum O_BINARY = 0;
}

private {
	enum SEEK_SET = 0;
	enum SEEK_CUR = 1;
	enum SEEK_END = 2;
}


final class ThreadedFileEventDriver(Events : EventDriverEvents) : EventDriverFiles
{
	import std.parallelism;

	private {
		enum ThreadedFileStatus {
			idle,         // -> initiated                 (by caller)
			initiated,    // -> processing                (by worker)
			processing,   // -> cancelling, finished      (by caller, worker)
			cancelling,   // -> cancelled                 (by worker)
			cancelled,    // -> idle                      (by event receiver)
			finished      // -> idle                      (by event receiver)
		}

		static struct IOInfo {
			FileIOCallback callback;
			shared ThreadedFileStatus status;
			shared size_t bytesWritten;
			IOStatus ioStatus;

			void finalize(FileFD fd, scope void delegate() @safe nothrow pre_cb)
			@safe nothrow {
				if (() @trusted { return cas(&this.status, ThreadedFileStatus.finished, ThreadedFileStatus.idle); } ()) {
					pre_cb();
					auto cb = this.callback;
					this.callback = null;
					if (cb) {
						log("fire callback");
						cb(fd, ioStatus, safeAtomicLoad(this.bytesWritten));
					}
				} else if (() @trusted { return cas(&this.status, ThreadedFileStatus.cancelled, ThreadedFileStatus.idle); } ()) {
					pre_cb();
					this.callback = null;
					log("ignore callback due to cancellation");
				}
			}
		}

		static struct FileInfo {
			IOInfo read;
			IOInfo write;
			int refCount;
		}

		TaskPool m_fileThreadPool;
		ChoppedVector!FileInfo m_files;
		SmallIntegerSet!FileFD m_activeReads;
		SmallIntegerSet!FileFD m_activeWrites;
		EventID m_readyEvent;
		bool m_waiting;
		Events m_events;
	}

	@safe: nothrow:

	this(Events events)
	{
		m_events = events;
		m_readyEvent = events.create();
	}

	void dispose()
	{
		if (m_fileThreadPool) {
			log("finishing thread pool");
			try m_fileThreadPool.finish();
			catch (Exception e) {
				//logError("Failed to shut down file I/O thread pool.");
			}
		}
		log("finishing file events");
		m_events.cancelWait(m_readyEvent, &onReady);
		onReady(m_readyEvent);
		m_events.releaseRef(m_readyEvent);
		log("finished file events");
	}

	final override FileFD open(string path, FileOpenMode mode)
	{
		import std.string : toStringz;

		import std.conv : octal;
		int flags;
		int amode;
		final switch (mode) {
			case FileOpenMode.read: flags = O_RDONLY|O_BINARY; break;
			case FileOpenMode.readWrite: flags = O_RDWR|O_BINARY; break;
			case FileOpenMode.createTrunc: flags = O_RDWR|O_CREAT|O_TRUNC|O_BINARY; amode = octal!644; break;
			case FileOpenMode.append: flags = O_WRONLY|O_CREAT|O_APPEND|O_BINARY; amode = octal!644; break;
		}
		auto fd = () @trusted { return .open(path.toStringz(), flags, amode); } ();
		if (fd < 0) return FileFD.init;
		return adopt(fd);
	}

	final override FileFD adopt(int system_file_handle)
	{
		version (Windows) {
			// TODO: check if FD is a valid file!
		} else {
			auto flags = () @trusted { return fcntl(system_file_handle, F_GETFD); } ();
			if (flags == -1) return FileFD.invalid;
		}

		if (m_files[system_file_handle].refCount > 0) return FileFD.invalid;
		m_files[system_file_handle] = FileInfo.init;
		m_files[system_file_handle].refCount = 1;
		return FileFD(system_file_handle);
	}

	void close(FileFD file)
	{
		() @trusted { .close(cast(int)file); } ();
	}

	ulong getSize(FileFD file)
	{
		version (linux) {
			// stat_t seems to be defined wrong on linux/64
			return .lseek(cast(int)file, 0, SEEK_END);
		} else {
			stat_t st;
			() @trusted { fstat(cast(int)file, &st); } ();
			return st.st_size;
		}
	}

	final override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode, FileIOCallback on_write_finish)
	{
		//assert(this.writable);
		auto f = &m_files[file].write;
		if (!safeCAS(f.status, ThreadedFileStatus.idle, ThreadedFileStatus.initiated))
			assert(false, "Concurrent file writes are not allowed.");
		assert(f.callback is null, "Concurrent file writes are not allowed.");
		f.callback = on_write_finish;
		m_activeWrites.insert(file);
log("start task");
		try {
			if (m_fileThreadPool is null) {
				m_fileThreadPool = new TaskPool(4);
				m_fileThreadPool.isDaemon = true;
			}
			m_fileThreadPool.put(task!(taskFun!("write", const(ubyte)))(this, file, offset, buffer));
			startWaiting();
		} catch (Exception e) {
			m_activeWrites.remove(file);
			on_write_finish(file, IOStatus.error, 0);
			return;
		}
	}

	final override void cancelWrite(FileFD file)
	{
		assert(m_activeWrites.contains(file), "Cancelling write when no write is in progress.");

		auto f = &m_files[file].write;
		f.callback = null;
		m_activeWrites.remove(file);
		m_events.trigger(m_readyEvent, true); // ensure that no stale wait operation is left behind
		safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.cancelling);
	}

	final override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode, FileIOCallback on_read_finish)
	{
		auto f = &m_files[file].read;
		if (!safeCAS(f.status, ThreadedFileStatus.idle, ThreadedFileStatus.initiated))
			assert(false, "Concurrent file reads are not allowed.");
		assert(f.callback is null, "Concurrent file reads are not allowed.");
		f.callback = on_read_finish;
		m_activeReads.insert(file);
		try {
			if (m_fileThreadPool is null) {
				m_fileThreadPool = new TaskPool(4);
				m_fileThreadPool.isDaemon = true;
			}
			m_fileThreadPool.put(task!(taskFun!("read", ubyte))(this, file, offset, buffer));
			startWaiting();
		} catch (Exception e) {
			m_activeReads.remove(file);
			on_read_finish(file, IOStatus.error, 0);
			return;
		}
	}

	final override void cancelRead(FileFD file)
	{
		assert(m_activeReads.contains(file), "Cancelling read when no read is in progress.");

		auto f = &m_files[file].read;
		f.callback = null;
		m_activeReads.remove(file);
		m_events.trigger(m_readyEvent, true); // ensure that no stale wait operation is left behind
		safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.cancelling);
	}

	final override void addRef(FileFD descriptor)
	{
		m_files[descriptor].refCount++;
	}

	final override bool releaseRef(FileFD descriptor)
	{
		auto f = () @trusted { return &m_files[descriptor]; } ();
		if (!--f.refCount) {
			.close(cast(int)descriptor);
			*f = FileInfo.init;
			assert(!m_activeReads.contains(descriptor));
			assert(!m_activeWrites.contains(descriptor));
			return false;
		}
		return true;
	}

	/// private
	static void taskFun(string op, UB)(ThreadedFileEventDriver fd, FileFD file, ulong offset, UB[] buffer)
	{
log("task fun");
		IOInfo* f = mixin("&fd.m_files[file]."~op);
log("start processing");

		if (!safeCAS(f.status, ThreadedFileStatus.initiated, ThreadedFileStatus.processing))
			assert(false, "File slot not in initiated state when processor task is started.");

		auto bytes = buffer;
		version (Windows) {
			assert(offset <= off_t.max);
			.lseek(cast(int)file, cast(off_t)offset, SEEK_SET);
		} else .lseek(cast(int)file, offset, SEEK_SET);

		scope (exit) {
log("trigger event");
			safeAtomicStore(f.bytesWritten, buffer.length - bytes.length);
			() @trusted { return cast(shared)fd.m_events; } ().trigger(fd.m_readyEvent, true);
		}

		while (bytes.length > 0) {
			auto sz = min(bytes.length, 4096);
			auto ret = () @trusted { return mixin("."~op)(cast(int)file, bytes.ptr, cast(uint)sz); } ();
			if (ret != sz) {
				f.ioStatus = IOStatus.error;
log("error");
				break;
			}
			bytes = bytes[sz .. $];
log("check for cancel");
			if (safeCAS(f.status, ThreadedFileStatus.cancelling, ThreadedFileStatus.cancelled)) return;
		}

		f.ioStatus = IOStatus.ok;

log("wait for status set");
		while (true) {
			if (safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.finished)) break;
			if (safeCAS(f.status, ThreadedFileStatus.cancelling, ThreadedFileStatus.cancelled)) break;
		}
	}

	private void onReady(EventID)
	{
log("ready event");
		foreach (f; m_activeReads)
			m_files[f].read.finalize(f, { m_activeReads.remove(f); });

		foreach (f; m_activeWrites)
			m_files[f].write.finalize(f, { m_activeWrites.remove(f); });

		m_waiting = false;
		startWaiting();
	}

	private void startWaiting()
	{
		if (!m_waiting && (!m_activeWrites.empty || !m_activeReads.empty)) {
			log("wait for ready");
			m_events.wait(m_readyEvent, &onReady);
			m_waiting = true;
		}
	}
}

private auto safeAtomicLoad(T)(ref shared(T) v) @trusted { return atomicLoad(v); }
private auto safeAtomicStore(T)(ref shared(T) v, T a) @trusted { return atomicStore(v, a); }
private auto safeCAS(T, U, V)(ref shared(T) v, U a, V b) @trusted { return cas(&v, a, b); }
private void safeYield() @trusted nothrow {
	import core.thread : Thread;
	import core.time : seconds;
	Thread.sleep(0.seconds);
}

private void log(ARGS...)(string fmt, ARGS args)
@trusted nothrow {
	debug (EventCoreLogFiles) {
		scope (failure) assert(false);
		import core.thread : Thread;
		import std.stdio : writef, writefln;
		writef("[%s] ", Thread.getThis().name);
		writefln(fmt, args);
	}
}
