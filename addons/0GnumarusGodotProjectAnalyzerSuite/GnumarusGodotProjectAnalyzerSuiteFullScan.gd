@tool
extends EditorScript

## Gnumarus Full Scan entry point: dumb proxy only. Every behavior
## lives in GnumarusGodotProjectAnalyzerSuiteFullScanImpl (RefCounted,
## headless-testable); this script only forwards _run there, so it
## stays runnable from the Script Editor's File > Run menu.
## The same scan is also exposed under Project > Tools by the analyzer
## plugin (see GnumarusGodotProjectAnalyzerSuitePluginImpl).

const Impl = preload("res://addons/0GnumarusGodotProjectAnalyzerSuite/GnumarusGodotProjectAnalyzerSuiteFullScanImpl.gd")


func _run() -> void:
	Impl.new().run()
