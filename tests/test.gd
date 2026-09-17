extends SceneTree

func _init():
	print('BEGIN')
	# var v_dumper_script: Script = load('gnumaru_godot_native_types_info_dumper.gd')
	# var v_dumper: RefCounted = v_dumper_script.new()
	# v_dumper.dump_all('/sync/opt/godot/godot4.x86_64')

	# "preload" accepts relative file directiores like ../ , but "load" does not accept, so whe are required to use preload instead of load here
	var v_tokenizer_script: Script = preload('../gnumarus_gdscript_tokenizer.gd')
	var v_tokenizer: RefCounted = v_tokenizer_script.new()
	var v_tokens: Array = v_tokenizer.tokenize('tests/ValidScript0.gd')

	var v_syn_parser_script: Script = preload('../gnumarus_gdscript_syntatic_parser.gd')
	var v_syn_parser: RefCounted = v_syn_parser_script.new()
	var v_ast: Dictionary = v_syn_parser.parse_tokens(v_tokens)
	print(v_ast)
	print('END')
	quit()