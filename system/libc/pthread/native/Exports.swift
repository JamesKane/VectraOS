// SPDX-License-Identifier: BSD-3-Clause

// pthreads under their C names, for native processes (M5k): what
// system/libc/include/pthread.h declares. Built only for croi's targets;
// the hosted build keeps the host's.

@c(pthread_create) public func exportedPthreadCreate(_ t: UnsafeMutablePointer<UInt>, _ a: UnsafeRawPointer?, _ s: StartRoutine, _ x: UnsafeMutableRawPointer?) -> Int32 { unsafe pthread_create(t, a, s, x) }

@c(pthread_join) public func exportedPthreadJoin(_ t: UInt, _ r: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 { unsafe pthread_join(t, r) }

@c(pthread_detach) public func exportedPthreadDetach(_ t: UInt) -> Int32 { pthread_detach(t) }

@c(pthread_self) public func exportedPthreadSelf() -> UInt { pthread_self() }

@c(pthread_equal) public func exportedPthreadEqual(_ a: UInt, _ b: UInt) -> Int32 { pthread_equal(a, b) }

@c(pthread_exit) public func exportedPthreadExit(_ r: UnsafeMutableRawPointer?) -> Never { unsafe pthread_exit(r) }

@c(pthread_attr_init) public func exportedPthreadAttrInit(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_attr_init(a) }

@c(pthread_attr_destroy) public func exportedPthreadAttrDestroy(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_attr_destroy(a) }

@c(pthread_attr_setdetachstate) public func exportedPthreadAttrSetdetachstate(_ a: UnsafeMutableRawPointer, _ s: Int32) -> Int32 { unsafe pthread_attr_setdetachstate(a, s) }

@c(pthread_attr_getdetachstate) public func exportedPthreadAttrGetdetachstate(_ a: UnsafeRawPointer, _ s: UnsafeMutablePointer<Int32>) -> Int32 { unsafe pthread_attr_getdetachstate(a, s) }

@c(pthread_attr_setstacksize) public func exportedPthreadAttrSetstacksize(_ a: UnsafeMutableRawPointer, _ s: Int) -> Int32 { unsafe pthread_attr_setstacksize(a, s) }

@c(pthread_attr_getstacksize) public func exportedPthreadAttrGetstacksize(_ a: UnsafeRawPointer, _ s: UnsafeMutablePointer<Int>) -> Int32 { unsafe pthread_attr_getstacksize(a, s) }

@c(pthread_mutexattr_init) public func exportedPthreadMutexattrInit(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutexattr_init(a) }

@c(pthread_mutexattr_destroy) public func exportedPthreadMutexattrDestroy(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutexattr_destroy(a) }

@c(pthread_mutexattr_settype) public func exportedPthreadMutexattrSettype(_ a: UnsafeMutableRawPointer, _ t: Int32) -> Int32 { unsafe pthread_mutexattr_settype(a, t) }

@c(pthread_mutexattr_gettype) public func exportedPthreadMutexattrGettype(_ a: UnsafeRawPointer, _ t: UnsafeMutablePointer<Int32>) -> Int32 { unsafe pthread_mutexattr_gettype(a, t) }

@c(pthread_mutex_init) public func exportedPthreadMutexInit(_ m: UnsafeMutableRawPointer, _ a: UnsafeRawPointer?) -> Int32 { unsafe pthread_mutex_init(m, a) }

@c(pthread_mutex_destroy) public func exportedPthreadMutexDestroy(_ m: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutex_destroy(m) }

@c(pthread_mutex_lock) public func exportedPthreadMutexLock(_ m: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutex_lock(m) }

@c(pthread_mutex_trylock) public func exportedPthreadMutexTrylock(_ m: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutex_trylock(m) }

@c(pthread_mutex_timedlock) public func exportedPthreadMutexTimedlock(_ m: UnsafeMutableRawPointer, _ t: UnsafeRawPointer) -> Int32 { unsafe pthread_mutex_timedlock(m, t) }

@c(pthread_mutex_unlock) public func exportedPthreadMutexUnlock(_ m: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_mutex_unlock(m) }

@c(pthread_condattr_init) public func exportedPthreadCondattrInit(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_condattr_init(a) }

@c(pthread_condattr_destroy) public func exportedPthreadCondattrDestroy(_ a: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_condattr_destroy(a) }

@c(pthread_condattr_setclock) public func exportedPthreadCondattrSetclock(_ a: UnsafeMutableRawPointer, _ c: Int32) -> Int32 { unsafe pthread_condattr_setclock(a, c) }

@c(pthread_condattr_getclock) public func exportedPthreadCondattrGetclock(_ a: UnsafeRawPointer, _ c: UnsafeMutablePointer<Int32>) -> Int32 { unsafe pthread_condattr_getclock(a, c) }

@c(pthread_cond_init) public func exportedPthreadCondInit(_ c: UnsafeMutableRawPointer, _ a: UnsafeRawPointer?) -> Int32 { unsafe pthread_cond_init(c, a) }

@c(pthread_cond_destroy) public func exportedPthreadCondDestroy(_ c: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_cond_destroy(c) }

@c(pthread_cond_wait) public func exportedPthreadCondWait(_ c: UnsafeMutableRawPointer, _ m: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_cond_wait(c, m) }

@c(pthread_cond_timedwait) public func exportedPthreadCondTimedwait(_ c: UnsafeMutableRawPointer, _ m: UnsafeMutableRawPointer, _ t: UnsafeRawPointer) -> Int32 { unsafe pthread_cond_timedwait(c, m, t) }

@c(pthread_cond_signal) public func exportedPthreadCondSignal(_ c: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_cond_signal(c) }

@c(pthread_cond_broadcast) public func exportedPthreadCondBroadcast(_ c: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_cond_broadcast(c) }

@c(pthread_rwlock_init) public func exportedPthreadRwlockInit(_ l: UnsafeMutableRawPointer, _ a: UnsafeRawPointer?) -> Int32 { unsafe pthread_rwlock_init(l, a) }

@c(pthread_rwlock_destroy) public func exportedPthreadRwlockDestroy(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_destroy(l) }

@c(pthread_rwlock_rdlock) public func exportedPthreadRwlockRdlock(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_rdlock(l) }

@c(pthread_rwlock_tryrdlock) public func exportedPthreadRwlockTryrdlock(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_tryrdlock(l) }

@c(pthread_rwlock_wrlock) public func exportedPthreadRwlockWrlock(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_wrlock(l) }

@c(pthread_rwlock_trywrlock) public func exportedPthreadRwlockTrywrlock(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_trywrlock(l) }

@c(pthread_rwlock_unlock) public func exportedPthreadRwlockUnlock(_ l: UnsafeMutableRawPointer) -> Int32 { unsafe pthread_rwlock_unlock(l) }

@c(pthread_once) public func exportedPthreadOnce(_ o: UnsafeMutablePointer<UInt32>, _ f: OnceRoutine) -> Int32 { unsafe pthread_once(o, f) }

@c(pthread_key_create) public func exportedPthreadKeyCreate(_ k: UnsafeMutablePointer<UInt32>, _ d: Destructor?) -> Int32 { unsafe pthread_key_create(k, d) }

@c(pthread_key_delete) public func exportedPthreadKeyDelete(_ k: UInt32) -> Int32 { pthread_key_delete(k) }

@c(pthread_getspecific) public func exportedPthreadGetspecific(_ k: UInt32) -> UnsafeMutableRawPointer? { unsafe pthread_getspecific(k) }

@c(pthread_setspecific) public func exportedPthreadSetspecific(_ k: UInt32, _ v: UnsafeRawPointer?) -> Int32 { unsafe pthread_setspecific(k, v) }
