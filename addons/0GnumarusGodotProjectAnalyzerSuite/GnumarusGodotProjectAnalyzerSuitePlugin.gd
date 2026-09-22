@tool
extends EditorPlugin

## Gnumarus Analyzer entry point: dumb proxy only. Every behavior
## lives in GnumarusGodotProjectAnalyzerSuitePluginImpl (RefCounted,
## headless-testable); this class just forwards the editor entry
## points and holds the plugin reference the impl needs for Node
## services (add_child, get_viewport).

const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuitePluginImpl.gd")

var _impl: Impl = null


func _enter_tree() -> void:
	_impl = Impl.new(self)
	_impl.enter_tree()


func _exit_tree() -> void:
	if _impl:
		_impl.exit_tree()
		_impl = null


func _input(event: InputEvent) -> void:
	if _impl:
		_impl._input(event)
