class_name GnumarusGodotProjectAnalyzerSuiteScanWorker
extends RefCounted

## Single-scan background runner: one WorkerThreadPool task per scan,
## polled from the plugin's _process (never call_deferred into a
## possibly-freed impl).
##
## Exclusive mode: while a task runs, the main thread performs no
## analysis (realtime skips, the frame pump sleeps), so Analyzer
## statics (roster, resolve stack) and user JSON writes belong to the
## worker alone — no mutexes around the pipeline, no races. The only
## shared state is the cancel/done/result flags below, guarded by one
## mutex. The work itself arrives as a Callable (warm/full closures
## live in the plugin impl, which owns every dependency), so this
## file preloads nothing and cannot form an import cycle.
##
## Usage (main thread):
##   var w := ScanWorker.new()
##   w.dispatch(Callable(self, "_warm_task").bind(w, root, opts), "warm")
##   # ... _process polls w.is_done() ...
##   w.wait_done()  # teardown only; polled finish never blocks.

## Task id from WorkerThreadPool.add_task (-1 before dispatch).
var _task_id := -1
## Work closure executed on the worker thread.
var _work: Callable = Callable()
## Result payload stored by the task, read on main after is_done().
## Written via set_result (never assigned directly: the plugin impl
## reaches the worker through Object.call, which needs a method).
var result := {}
## Kind label for logs ("warm"/"full").
var kind := ""

var _mutex := Mutex.new()
var _cancelled := false
var _done := false


## Dispatches the work closure on the pool. Returns the task id.
func dispatch(work: Callable, p_kind: String) -> int:
	_work = work
	kind = p_kind
	result = {}
	_mutex.lock()
	_cancelled = false
	_done = false
	_mutex.unlock()
	_task_id = WorkerThreadPool.add_task(Callable(self, "_run"), false, "Gnumarus scan (" + p_kind + ")")
	return _task_id


## Pool entry point: runs the closure, then flags done. The closure
## must never touch editor nodes/singletons; results hand back via
## set_result (read on main via get_result only after is_done()).
func _run() -> void:
	if _work.is_valid():
		_work.call()
	_mutex.lock()
	_done = true
	_mutex.unlock()


## Requests early termination (checked by the task at file
## boundaries). Thread-safe; teardown and queueing use it.
func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()


## True after cancel() (worker checks between files). Thread-safe.
func is_cancelled() -> bool:
	_mutex.lock()
	var c := _cancelled
	_mutex.unlock()
	return c


## Stores the task result payload (worker thread writes, main reads
## after is_done()). Thread-safe.
func set_result(payload: Dictionary) -> void:
	_mutex.lock()
	result = (payload as Dictionary).duplicate()
	_mutex.unlock()


## Copy of the task result payload. Thread-safe; read on main only
## after is_done().
func get_result() -> Dictionary:
	_mutex.lock()
	var out := (result as Dictionary).duplicate()
	_mutex.unlock()
	return out


## True once the task function returned (results readable).
## Thread-safe; polled from _process.
func is_done() -> bool:
	_mutex.lock()
	var d := _done
	_mutex.unlock()
	return d


## Blocks until the task ends. Teardown only: polled completion never
## blocks the main thread.
func wait_done() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
