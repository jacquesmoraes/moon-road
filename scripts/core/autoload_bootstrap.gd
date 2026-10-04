extends RefCounted
class_name AutoloadBootstrap
## Shared helpers for autoload late-init. No scene Node dependencies.
## Hosts keep their own _init_state; this only provides connect/retry utilities.

const STATE_UNINITIALIZED := "UNINITIALIZED"
const STATE_INITIALIZING := "INITIALIZING"
const STATE_READY := "READY"
const STATE_FAILED := "FAILED"

## Finite deferred retries — never per-frame infinite loops.
const DEFAULT_MAX_ATTEMPTS := 8


## Idempotent signal connect. Returns true when connected (already or newly).
static func try_connect(source: Object, signal_name: String, callable: Callable) -> bool:
	if source == null or signal_name.is_empty() or not callable.is_valid():
		return false
	if not source.has_signal(signal_name):
		return false
	if source.is_connected(signal_name, callable):
		return true
	var err := source.connect(signal_name, callable)
	return err == OK


static func resolve(tree_root: Node, path: String) -> Node:
	if tree_root == null or path.is_empty():
		return null
	return tree_root.get_node_or_null(path)


## Returns true when every required path resolves under /root.
static func all_present(tree_root: Node, required_paths: PackedStringArray) -> bool:
	for path in required_paths:
		if resolve(tree_root, str(path)) == null:
			return false
	return true


static func missing_paths(tree_root: Node, required_paths: PackedStringArray) -> PackedStringArray:
	var missing := PackedStringArray()
	for path in required_paths:
		if resolve(tree_root, str(path)) == null:
			missing.append(str(path))
	return missing
