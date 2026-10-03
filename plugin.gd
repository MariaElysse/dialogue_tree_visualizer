## DialogueTreeVisualizerPlugin — Godot 4 editor plugin for visualizing dialogue trees.
##
## Adds a new main-screen tab that shows all .dialogue files as an interactive
## node graph using GraphEdit / GraphNode.
@tool
extends EditorPlugin

const NODE_WIDTH: int = 260
const NODE_HEIGHT: int = 80
const HEADER_HEIGHT: int = 28

# Color palette for node types
const COLOR_CUE: Color = Color(0.25, 0.55, 0.95)
const COLOR_DIALOGUE: Color = Color(0.2, 0.75, 0.35)
const COLOR_RESPONSE: Color = Color(0.95, 0.6, 0.15)
const COLOR_CONDITION: Color = Color(0.95, 0.8, 0.1)
const COLOR_MUTATION: Color = Color(0.7, 0.3, 0.9)
const COLOR_GOTO: Color = Color(0.15, 0.8, 0.85)
const COLOR_WHILE: Color = Color(0.85, 0.35, 0.5)
const COLOR_MATCH: Color = Color(0.6, 0.2, 0.7)
const COLOR_WHEN: Color = Color(0.5, 0.7, 0.2)
const COLOR_RANDOM: Color = Color(0.6, 0.6, 0.65)
const COLOR_END: Color = Color(0.85, 0.2, 0.2)

# Edge colors by type
const EDGE_COLOR_SEQUENTIAL: Color = Color(0.5, 0.5, 0.55)
const EDGE_COLOR_GOTO: Color = Color(0.4, 0.5, 0.9)
const EDGE_COLOR_CONDITION_TRUE: Color = Color(0.2, 0.8, 0.3)
const EDGE_COLOR_CONDITION_FALSE: Color = Color(0.9, 0.55, 0.15)
const EDGE_COLOR_RESPONSE: Color = Color(0.2, 0.5, 0.9)
const EDGE_COLOR_RANDOM: Color = Color(0.7, 0.3, 0.8)

var main_screen_editor: Object
var dialogue_tab: Control
var graph_edit: GraphEdit
var files_popup: PopupMenu
var file_menu_button: MenuButton
var auto_layout_button: Button
var clear_button: Button
var show_all_checkbox: CheckBox
var file_list_button: Button
var zoom_slider: HSlider

# Current state
var current_files: PackedStringArray = []
var current_selection: int = 0
var graph_data: Dictionary = {}
var node_map: Dictionary = {}  # node_key -> GraphNode
var is_loading: bool = false
var arrange_pending: bool = false
var arrange_running: bool = false

# Status bar references
var status_message_label: Label
var status_count_label: Label


func _enter_tree() -> void:
	# Create the main screen and tab
	main_screen_editor = EditorInterface.get_editor_main_screen()
	dialogue_tab = Control.new()
	dialogue_tab.name = "DialogueTree"
	dialogue_tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialogue_tab.grow_horizontal = Control.GROW_DIRECTION_BOTH
	dialogue_tab.grow_vertical = Control.GROW_DIRECTION_BOTH
	dialogue_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dialogue_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL

	main_screen_editor.add_child(dialogue_tab)

	# Build the UI
	_build_ui()

	# Connect file-system signals to refresh the file list
	EditorInterface.get_file_system_dock().files_moved.connect(_on_files_moved)
	EditorInterface.get_file_system_dock().file_removed.connect(_on_file_removed)
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed)

	_make_visible(false)


func _exit_tree() -> void:
	# Clean up connections
	if is_instance_valid(EditorInterface.get_file_system_dock()):
		EditorInterface.get_file_system_dock().files_moved.disconnect(_on_files_moved)
		EditorInterface.get_file_system_dock().file_removed.disconnect(_on_file_removed)
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_on_filesystem_changed)

	if is_instance_valid(dialogue_tab):
		dialogue_tab.queue_free()


func _has_main_screen() -> bool:
	return true


func _make_visible(next_visible: bool) -> void:
	if is_instance_valid(dialogue_tab):
		dialogue_tab.visible = next_visible
	if not next_visible:
		return
	# Populate the graph the first time the tab is opened, otherwise re-arrange
	# the nodes now that the tab is on screen.
	if is_instance_valid(graph_edit) and node_map.is_empty() and not is_loading:
		_refresh_graph()
	else:
		_request_arrange()


func _get_plugin_name() -> String:
	return "Dialogue Tree"


func _get_plugin_icon() -> Texture2D:
	# Try to load the addon's icon as a fallback
	var icon_path: String = get_plugin_path() + "/icon.svg"
	if FileAccess.file_exists(icon_path):
		return load(icon_path)
	# Fallback: try the Dialogue Manager addon icon
	var dm_icon_path: String = "res://addons/dialogue_manager/assets/icon.svg"
	if FileAccess.file_exists(dm_icon_path):
		return load(dm_icon_path)
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")


func _make_bottom_panel_item_visible(_item: Control) -> void:
	pass  # Not using bottom panel


func _build() -> bool:
	# Rebuild graph on each project build
	if is_instance_valid(graph_edit) and not is_loading:
		_refresh_graph()
	return true


func _build_ui() -> void:
	# Root layout
	var root: VBoxContainer = VBoxContainer.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_FILL
	root.size_flags_vertical = Control.SIZE_FILL
	dialogue_tab.add_child(root)

	# Toolbar
	var toolbar: HBoxContainer = _create_toolbar()
	root.add_child(toolbar)

	# Graph area
	graph_edit = GraphEdit.new()
	graph_edit.name = "GraphEdit"
	graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_edit.custom_minimum_size = Vector2(400, 300)
	graph_edit.snapping_enabled = true
	graph_edit.snapping_distance = 20
	graph_edit.show_grid = true
	graph_edit.show_arrange_button = true

	# Apply editor-themed colors
	_themes_graph_edit()

	root.add_child(graph_edit)

	# Status bar (single line of text)
	var status_bar: HBoxContainer = HBoxContainer.new()
	status_bar.name = "StatusBar"
	status_bar.size_flags_horizontal = Control.SIZE_FILL
	status_bar.size_flags_vertical = Control.SIZE_FILL

	status_message_label = Label.new()
	status_message_label.name = "StatusLabel"
	status_message_label.text = "No dialogue files loaded"
	status_message_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_message_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_bar.add_child(status_message_label)

	# Spacer keeps the count label at the right edge on the same line
	var status_spacer: Control = Control.new()
	status_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_bar.add_child(status_spacer)

	status_count_label = Label.new()
	status_count_label.name = "NodeCountLabel"
	status_count_label.text = ""
	status_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_count_label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
	status_bar.add_child(status_count_label)

	root.add_child(status_bar)

	# Connect graph signals
	graph_edit.connection_request.connect(_on_graph_connection_request)
	graph_edit.disconnection_request.connect(_on_graph_disconnection_request)

	# Render the initial graph so the tab is populated the first time it opens
	_refresh_graph()


## Create the toolbar with controls.
func _create_toolbar() -> HBoxContainer:
	var toolbar: HBoxContainer = HBoxContainer.new()
	toolbar.name = "Toolbar"
	toolbar.custom_minimum_size = Vector2(0, 36)

	# File selector label
	var file_label: Label = Label.new()
	file_label.text = "File:"
	file_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	toolbar.add_child(file_label)

	# File selector (a MenuButton renders the dropdown; a bare PopupMenu does not)
	file_menu_button = MenuButton.new()
	file_menu_button.name = "FileSelector"
	file_menu_button.text = "All Files"
	file_menu_button.tooltip_text = "Select a dialogue file to visualize"
	files_popup = file_menu_button.get_popup()
	files_popup.id_pressed.connect(_on_file_selected)
	toolbar.add_child(file_menu_button)

	# Separator
	var separator: Container = Container.new()
	separator.custom_minimum_size = Vector2(8, 1)
	toolbar.add_child(separator)

	# Show All checkbox
	show_all_checkbox = CheckBox.new()
	show_all_checkbox.text = "Show All"
	show_all_checkbox.button_pressed = true
	show_all_checkbox.toggled.connect(_on_show_all_toggled)
	toolbar.add_child(show_all_checkbox)

	# Separator
	separator = Container.new()
	separator.custom_minimum_size = Vector2(8, 1)
	toolbar.add_child(separator)

	# File list button
	file_list_button = Button.new()
	file_list_button.text = "List"
	file_list_button.tooltip_text = "List all dialogue files"
	file_list_button.pressed.connect(_on_file_list_clicked)
	toolbar.add_child(file_list_button)

	# Spacer
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(10, 1)
	spacer.size_flags_horizontal = Control.SIZE_FILL
	toolbar.add_child(spacer)

	# Zoom slider
	var zoom_label: Label = Label.new()
	zoom_label.text = "Zoom:"
	zoom_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	toolbar.add_child(zoom_label)

	zoom_slider = HSlider.new()
	zoom_slider.name = "ZoomSlider"
	zoom_slider.min_value = 0.25
	zoom_slider.max_value = 2.0
	zoom_slider.step = 0.05
	zoom_slider.value = 1.0
	zoom_slider.custom_minimum_size = Vector2(100, 16)
	zoom_slider.value_changed.connect(_on_zoom_changed)
	toolbar.add_child(zoom_slider)

	# Spacer
	spacer = Control.new()
	spacer.custom_minimum_size = Vector2(10, 1)
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	# Auto Layout button
	auto_layout_button = Button.new()
	auto_layout_button.text = "Auto Layout"
	auto_layout_button.tooltip_text = "Arrange nodes in layered layout"
	auto_layout_button.pressed.connect(_on_auto_layout_clicked)
	toolbar.add_child(auto_layout_button)

	# Clear button
	clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.tooltip_text = "Clear the graph"
	clear_button.pressed.connect(_on_clear_clicked)
	toolbar.add_child(clear_button)

	# Refresh button
	var refresh_button: Button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.tooltip_text = "Reload all dialogue files"
	refresh_button.pressed.connect(_on_refresh_clicked)
	toolbar.add_child(refresh_button)

	# Populate file list
	_populate_file_list()

	return toolbar


## Apply editor-themed colors to the GraphEdit.
func _themes_graph_edit() -> void:
	# Use per-property overrides so the editor theme (icons, fonts) is preserved.
	var bg_stylebox: StyleBoxFlat = StyleBoxFlat.new()
	bg_stylebox.bg_color = Color(0.12, 0.12, 0.14)
	graph_edit.add_theme_stylebox_override("panel", bg_stylebox)
	graph_edit.add_theme_color_override("grid_major", Color(0.16, 0.16, 0.18))
	graph_edit.add_theme_color_override("grid_minor", Color(0.13, 0.13, 0.15))


## Populate the file selector with all .dialogue files.
func _populate_file_list() -> void:
	if is_loading:
		return

	is_loading = true

	# Clear existing entries
	files_popup.clear()

	# Get all dialogue files from the cache or by scanning
	current_files = _get_dialogue_files()

	if current_files.is_empty():
		files_popup.add_item("No dialogue files found")
		files_popup.set_item_disabled(0, true)
		if is_instance_valid(file_menu_button):
			file_menu_button.text = "No files"
		is_loading = false
		return

	# Add individual files (item id == index into current_files)
	for i: int in range(current_files.size()):
		var file_name: String = current_files[i].get_file().replace(".dialogue", "")
		files_popup.add_item(file_name, i)

	# Keep the selection within range and reflect it on the button
	if current_selection < 0 or current_selection >= current_files.size():
		current_selection = 0
	if is_instance_valid(file_menu_button):
		file_menu_button.text = _current_file_label()

	is_loading = false


## Text shown on the file selector button for the current selection.
func _current_file_label() -> String:
	if show_all_checkbox == null or show_all_checkbox.button_pressed:
		return "All Files"
	if current_selection >= 0 and current_selection < current_files.size():
		return current_files[current_selection].get_file().replace(".dialogue", "")
	return "All Files"


## Get all .dialogue file paths from the project.
func _get_dialogue_files() -> PackedStringArray:
	var files: PackedStringArray = []

	# Try to use DMCache if available
	if ClassDB.class_exists("DMCache"):
		var cache_path: String = "res://addons/dialogue_manager/utilities/dialogue_cache.gd"
		if FileAccess.file_exists(cache_path):
			var cache_class: GDScript = load(cache_path)
			if cache_class.has_method("get_files"):
				var cached: PackedStringArray = cache_class.call_static("get_files")
				if not cached.is_empty():
					return cached

	# Fallback: scan the filesystem
	files = _scan_for_dialogue_files("res://")
	return files


## Recursively scan for .dialogue files.
func _scan_for_dialogue_files(path: String) -> PackedStringArray:
	var files: PackedStringArray = []

	if not DirAccess.dir_exists_absolute(path):
		return files

	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return files

	dir.list_dir_begin()
	var file_name: String = dir.get_next()

	while file_name != "":
		var full_path: String = (path + "/" + file_name).simplify_path()

		if dir.current_is_dir():
			# Skip hidden and generated directories
			if not file_name.begins_with(".") and file_name != ".godot":
				files.append_array(_scan_for_dialogue_files(full_path))
		elif file_name.ends_with(".dialogue"):
			files.append(full_path)

		file_name = dir.get_next()

	return files


## Handle file selection from the dropdown.
func _on_file_selected(id: int) -> void:
	current_selection = id
	# Choosing a specific file turns off the "Show All" mode.
	show_all_checkbox.set_pressed_no_signal(false)
	if is_instance_valid(file_menu_button):
		file_menu_button.text = _current_file_label()
	_refresh_graph()


## Handle "Show All" toggle.
func _on_show_all_toggled(value: bool) -> void:
	if is_instance_valid(file_menu_button):
		file_menu_button.text = _current_file_label()
	_refresh_graph()


## Handle file list button click.
func _on_file_list_clicked() -> void:
	_populate_file_list()


## Handle file system changes.
func _on_files_moved(old_file: String, new_file: String) -> void:
	_populate_file_list()


func _on_file_removed(file: String) -> void:
	_populate_file_list()


func _on_filesystem_changed() -> void:
	_populate_file_list()


## Refresh the graph with current selection.
func _refresh_graph() -> void:
	if is_loading:
		return

	is_loading = true

	# Clear existing nodes and edges
	_clear_graph()

	# Determine which files to load
	var files_to_load: PackedStringArray = []

	if show_all_checkbox.button_pressed:
		files_to_load = current_files
	elif current_selection >= 0 and current_selection < current_files.size():
		files_to_load.append(current_files[current_selection])

	if files_to_load.is_empty():
		_update_status("No dialogue files to display", 0, 0)
		is_loading = false
		return

	# Load resources and build graph
	var resources: Array[DialogueResource] = []
	var load_errors: int = 0

	for file_path: String in files_to_load:
		var resource: Variant = load(file_path)
		if resource is DialogueResource:
			resources.append(resource)
		else:
			load_errors += 1

	if resources.is_empty():
		_update_status("No valid dialogue resources found", 0, 0)
		is_loading = false
		return

	# Build the graph using the graph builder
	graph_data = DialogueTreeGraphBuilder.build_from_paths(files_to_load)

	# Render the graph
	_render_graph()

	_update_status(
		(
			"Loaded "
			+ str(resources.size())
			+ " file(s)"
			+ ("" if load_errors == 0 else (", " + str(load_errors) + " errors"))
		),
		graph_data.get("nodes", []).size(),
		graph_data.get("edges", []).size()
	)

	is_loading = false


## Clear all nodes and edges from the GraphEdit.
func _clear_graph() -> void:
	node_map.clear()

	# Clear all connections first
	graph_edit.clear_connections()

	# Remove all child nodes that are GraphNodes
	var children: Array[Node] = graph_edit.get_children()
	for child: Node in children:
		if child is GraphNode:
			graph_edit.remove_child(child)
			child.queue_free()


## Render the graph data into the GraphEdit.
func _render_graph() -> void:
	var nodes: Array[Dictionary] = graph_data.get("nodes", [])
	var edges: Array[Dictionary] = graph_data.get("edges", [])

	if nodes.is_empty():
		return

	# Create nodes
	for node_data: Dictionary in nodes:
		_create_graph_node(node_data)

	# Create edges
	for edge: Dictionary in edges:
		_create_graph_edge(edge)

	# Automatically arrange every node as soon as the graph is rendered.
	_request_arrange()


## Request an automatic arrangement of all nodes once the graph is on screen.
## arrange_nodes() reads the GraphNode port caches, which only exist after the
## nodes have been laid out/drawn, so wait for that instead of a fixed delay.
func _request_arrange() -> void:
	if node_map.is_empty() or not is_instance_valid(graph_edit):
		return
	arrange_pending = true
	if graph_edit.is_visible_in_tree() and not arrange_running:
		_arrange_when_ready()


func _arrange_when_ready() -> void:
	arrange_running = true
	var waited: int = 0
	while waited < 120 and not _node_ports_ready():
		await get_tree().process_frame
		waited += 1
	if arrange_pending and _node_ports_ready() and is_instance_valid(graph_edit):
		arrange_pending = false
		graph_edit.arrange_nodes()
	arrange_running = false


## True once at least one GraphNode has a populated port cache.
func _node_ports_ready() -> bool:
	if not is_instance_valid(graph_edit):
		return false
	for child: Node in graph_edit.get_children():
		if child is GraphNode:
			return (child as GraphNode).get_output_port_count() > 0
	return false


## Create a GraphNode for a dialogue element.
func _create_graph_node(data: Dictionary) -> void:
	var node_key: String = data.get("key", data.get("id", ""))
	if node_key in node_map:
		return  # Skip duplicates

	var node_type: DialogueTreeGraphBuilder.NodeType = data.get(
		"type", DialogueTreeGraphBuilder.NodeType.DIALOGUE
	)
	var title: String = data.get("title", "Unknown")
	var character: String = data.get("character", "")
	var text: String = data.get("text", "")

	# Create the graph node
	var graph_node: GraphNode = GraphNode.new()
	graph_node.title = title.left(32)
	graph_node.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	graph_node.size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	graph_node.resizable = false
	graph_node.name = _node_name_for(node_key)

	# If/elif/else chains are rendered as a single node with one row (and one
	# output port) per branch.
	var branches: Array = data.get("branches", [])
	if not branches.is_empty():
		_build_branch_rows(graph_node, branches, node_type)
		_register_graph_node(graph_node, node_key, data)
		return

	# Create the node UI
	var container: VBoxContainer = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_FILL
	container.size_flags_vertical = Control.SIZE_FILL
	container.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	graph_node.add_child(container)

	# Header bar (colored strip)
	var header: ColorRect = ColorRect.new()
	header.color = _get_node_color(node_type)
	header.size_flags_horizontal = Control.SIZE_FILL
	header.custom_minimum_size = Vector2(NODE_WIDTH, HEADER_HEIGHT)
	container.add_child(header)

	# Header label
	var header_label: Label = Label.new()
	header_label.text = _get_node_type_label(node_type)
	header_label.add_theme_color_override("font_color", Color.WHITE)
	header_label.add_theme_font_override("font", _get_bold_font())
	header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	header_label.position = Vector2(4, 0)
	header_label.size_flags_horizontal = Control.SIZE_FILL
	container.add_child(header_label)

	# Content area
	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 2)
	content.size_flags_horizontal = Control.SIZE_FILL
	content.size_flags_vertical = Control.SIZE_FILL
	container.add_child(content)

	# Body: a merged dialogue run shows one row per line, otherwise a single
	# character + text preview.
	var merged_lines: Array = data.get("lines", [])
	if not merged_lines.is_empty():
		for line_entry: Dictionary in merged_lines:
			_add_line_row(
				content, str(line_entry.get("character", "")), str(line_entry.get("text", ""))
			)
		var height: int = HEADER_HEIGHT + 24 * merged_lines.size() + 8
		container.custom_minimum_size = Vector2(NODE_WIDTH, height)
		graph_node.custom_minimum_size = Vector2(NODE_WIDTH, height)
		graph_node.size = Vector2(NODE_WIDTH, height)
	else:
		# Character / identifier line
		if not character.is_empty():
			var char_label: Label = Label.new()
			char_label.text = character + ":"
			char_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
			char_label.add_theme_font_override("font", _get_bold_font())
			char_label.size_flags_horizontal = Control.SIZE_FILL
			content.add_child(char_label)

		# Text preview
		var text_label: Label = Label.new()
		var display_text: String = text.left(80)
		if text.length() > 80:
			display_text += "..."
		text_label.text = display_text
		text_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		text_label.add_theme_font_override("font", _get_regular_font())
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		text_label.size_flags_horizontal = Control.SIZE_FILL
		text_label.size_flags_vertical = Control.SIZE_FILL
		content.add_child(text_label)

	# Meta info line (tags, conditions, etc.)
	var meta_parts: PackedStringArray = []
	var tags: Array = data.get("tags", [])
	if not tags.is_empty():
		meta_parts.append("#" + ",".join(tags))

	var condition: Variant = data.get("condition", null)
	if condition != null and not str(condition).is_empty():
		var cond_str: String = str(condition).left(30)
		if not cond_str.is_empty():
			meta_parts.append(cond_str)

	if not meta_parts.is_empty():
		var meta_label: Label = Label.new()
		meta_label.text = "  " + " | ".join(meta_parts)
		meta_label.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
		meta_label.add_theme_font_override("font", _get_italic_font())
		meta_label.size_flags_horizontal = Control.SIZE_FILL
		content.add_child(meta_label)

	# Add input/output ports
	_configure_slots(graph_node, node_type)

	_register_graph_node(graph_node, node_key, data)


## Add a graph node to the graph, index it, and remember its source location.
func _register_graph_node(graph_node: GraphNode, node_key: String, data: Dictionary) -> void:
	graph_edit.add_child(graph_node)
	node_map[node_key] = graph_node
	graph_node.set_meta("dialogue_file", str(data.get("file", "")))
	graph_node.set_meta("dialogue_id", str(data.get("id", "")))
	graph_node.gui_input.connect(_on_graph_node_gui_input.bind(graph_node))


## Build one row per branch (if / elif / else) so each branch gets its own
## output port on the node.
func _build_branch_rows(
	node: GraphNode, branches: Array, node_type: DialogueTreeGraphBuilder.NodeType
) -> void:
	var in_color: Color = Color(0.75, 0.75, 0.78)
	var out_color: Color = _get_node_color(node_type)
	var row_height: int = 22

	for i: int in range(branches.size()):
		var branch: Dictionary = branches[i]

		var row: HBoxContainer = HBoxContainer.new()
		row.custom_minimum_size = Vector2(NODE_WIDTH, row_height)
		row.add_theme_constant_override("separation", 6)
		node.add_child(row)

		var branch_label: Label = Label.new()
		branch_label.text = str(branch.get("label", ""))
		branch_label.add_theme_color_override("font_color", out_color)
		branch_label.add_theme_font_override("font", _get_bold_font())
		row.add_child(branch_label)

		var branch_text: Label = Label.new()
		branch_text.text = str(branch.get("text", "")).left(48)
		branch_text.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		branch_text.add_theme_font_override("font", _get_regular_font())
		branch_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(branch_text)

		# Left (input) port on the first row only; a right (output) port per row.
		# Output port indices follow row order, matching each branch's from_port.
		node.set_slot(i, i == 0, 0, in_color, true, 1, out_color)

	node.custom_minimum_size = Vector2(NODE_WIDTH, HEADER_HEIGHT + row_height * branches.size())
	node.size = node.custom_minimum_size


## Add a single spoken line ("Character: text") as a row inside a node body.
func _add_line_row(parent: Control, character: String, text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_FILL
	parent.add_child(row)

	if not character.is_empty():
		var char_label: Label = Label.new()
		char_label.text = character + ":"
		char_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
		char_label.add_theme_font_override("font", _get_bold_font())
		row.add_child(char_label)

	var text_label: Label = Label.new()
	var display_text: String = text.left(80)
	if text.length() > 80:
		display_text += "..."
	text_label.text = display_text
	text_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	text_label.add_theme_font_override("font", _get_regular_font())
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_label)


## Configure the node's ports. END terminals have an input but no output.
func _configure_slots(node: GraphNode, node_type: DialogueTreeGraphBuilder.NodeType) -> void:
	var in_color: Color = Color(0.75, 0.75, 0.78)
	var out_color: Color = _get_node_color(node_type)
	if node_type == DialogueTreeGraphBuilder.NodeType.END:
		# Terminal node: input only, so the graph shows the dialogue ending here.
		node.set_slot(0, true, 0, in_color, false, 0, out_color)
	else:
		# Slot 0 is the node's content row. Enable a left (input) and right (output) port.
		node.set_slot(0, true, 0, in_color, true, 1, out_color)


## Create a connection edge between two nodes.
func _create_graph_edge(edge: Dictionary) -> void:
	var from_key: String = edge.get("from", "")
	var to_key: String = edge.get("to", "")
	var from_port: int = int(edge.get("from_port", 0))

	var from_node: GraphNode = node_map.get(from_key)
	var to_node: GraphNode = node_map.get(to_key)

	if from_node == null or to_node == null:
		return  # Node not in graph yet

	graph_edit.connect_node(from_node.name, from_port, to_node.name, 0)


## Double-clicking a graph node opens the .dialogue file at the line it came from.
func _on_graph_node_gui_input(event: InputEvent, graph_node: GraphNode) -> void:
	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		if mouse_event.double_click and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_open_node_source(
				str(graph_node.get_meta("dialogue_file", "")),
				str(graph_node.get_meta("dialogue_id", ""))
			)
			graph_node.accept_event()


## Open [param file_path] in the Dialogue Manager editor, centred on the source
## line for [param line_id] (the compiled id is the 0-based line index).
func _open_node_source(file_path: String, line_id: String) -> void:
	var base_id: String = line_id.split(".")[0]
	if not base_id.is_valid_int() or not FileAccess.file_exists(file_path):
		return
	if DMPlugin.instance == null:
		return

	var main_view: Object = DMPlugin.instance.main_view
	if not is_instance_valid(main_view):
		return

	main_view.call("open_file", file_path)
	EditorInterface.set_main_screen_editor("Dialogue")

	var code_edit: Object = main_view.get("code_edit")
	if code_edit == null:
		return

	var line: int = base_id.to_int()  # 0-based
	code_edit.call("set_caret_line", line)
	code_edit.call("set_line_as_center_visible", line)
	code_edit.call("grab_focus")


func _on_graph_connection_request(
	from_node: StringName, from_port: int, to_node: StringName, to_port: int
) -> void:
	# Allow manual connections made by dragging between ports.
	graph_edit.connect_node(from_node, from_port, to_node, to_port)


func _on_graph_disconnection_request(
	from_node: StringName, from_port: int, to_node: StringName, to_port: int
) -> void:
	graph_edit.disconnect_node(from_node, from_port, to_node, to_port)


func _on_auto_layout_clicked() -> void:
	_request_arrange()
	graph_edit.scroll_offset = Vector2.ZERO


func _on_clear_clicked() -> void:
	_clear_graph()
	graph_data = {}
	_update_status("Graph cleared", 0, 0)


func _on_refresh_clicked() -> void:
	_populate_file_list()
	_refresh_graph()


func _on_zoom_changed(value: float) -> void:
	if is_instance_valid(graph_edit):
		graph_edit.zoom = value


## Get the color for a node type.
func _get_node_color(node_type: DialogueTreeGraphBuilder.NodeType) -> Color:
	match node_type:
		DialogueTreeGraphBuilder.NodeType.CUE:
			return COLOR_CUE
		DialogueTreeGraphBuilder.NodeType.DIALOGUE:
			return COLOR_DIALOGUE
		DialogueTreeGraphBuilder.NodeType.RESPONSE:
			return COLOR_RESPONSE
		DialogueTreeGraphBuilder.NodeType.CONDITION:
			return COLOR_CONDITION
		DialogueTreeGraphBuilder.NodeType.MUTATION:
			return COLOR_MUTATION
		DialogueTreeGraphBuilder.NodeType.GOTO:
			return COLOR_GOTO
		DialogueTreeGraphBuilder.NodeType.WHILE:
			return COLOR_WHILE
		DialogueTreeGraphBuilder.NodeType.MATCH:
			return COLOR_MATCH
		DialogueTreeGraphBuilder.NodeType.WHEN:
			return COLOR_WHEN
		DialogueTreeGraphBuilder.NodeType.RANDOM:
			return COLOR_RANDOM
		DialogueTreeGraphBuilder.NodeType.END:
			return COLOR_END
		_:
			return COLOR_DIALOGUE


## Get the color for an edge type.
func _get_edge_color(edge_type: DialogueTreeGraphBuilder.EdgeType) -> Color:
	match edge_type:
		DialogueTreeGraphBuilder.EdgeType.SEQUENTIAL:
			return EDGE_COLOR_SEQUENTIAL
		DialogueTreeGraphBuilder.EdgeType.GOTO:
			return EDGE_COLOR_GOTO
		DialogueTreeGraphBuilder.EdgeType.CONDITION_TRUE:
			return EDGE_COLOR_CONDITION_TRUE
		DialogueTreeGraphBuilder.EdgeType.CONDITION_FALSE:
			return EDGE_COLOR_CONDITION_FALSE
		DialogueTreeGraphBuilder.EdgeType.RESPONSE:
			return EDGE_COLOR_RESPONSE
		DialogueTreeGraphBuilder.EdgeType.RANDOM:
			return EDGE_COLOR_RANDOM
		_:
			return EDGE_COLOR_SEQUENTIAL


## Get a human-readable label for a node type.
func _get_node_type_label(node_type: DialogueTreeGraphBuilder.NodeType) -> String:
	match node_type:
		DialogueTreeGraphBuilder.NodeType.CUE:
			return "CUE"
		DialogueTreeGraphBuilder.NodeType.DIALOGUE:
			return "DIALOGUE"
		DialogueTreeGraphBuilder.NodeType.RESPONSE:
			return "RESPONSE"
		DialogueTreeGraphBuilder.NodeType.CONDITION:
			return "CONDITION"
		DialogueTreeGraphBuilder.NodeType.MUTATION:
			return "MUTATION"
		DialogueTreeGraphBuilder.NodeType.GOTO:
			return "GOTO"
		DialogueTreeGraphBuilder.NodeType.WHILE:
			return "WHILE"
		DialogueTreeGraphBuilder.NodeType.MATCH:
			return "MATCH"
		DialogueTreeGraphBuilder.NodeType.WHEN:
			return "WHEN"
		DialogueTreeGraphBuilder.NodeType.RANDOM:
			return "RANDOM"
		DialogueTreeGraphBuilder.NodeType.END:
			return "END"
		_:
			return "LINE"


## Get a bold font from the editor theme.
func _get_bold_font() -> Font:
	return _get_editor_font("bold")


## Get a regular font from the editor theme.
func _get_regular_font() -> Font:
	return _get_editor_font("main")


## Get an italic font from the editor theme.
func _get_italic_font() -> Font:
	return _get_editor_font("italic")


## Look up a named font in the editor theme, falling back to the default font.
## Membership in get_font_list() is checked because Theme.has_font() can report
## true for names the editor theme does not actually define.
func _get_editor_font(font_name: String) -> Font:
	var theme: Theme = EditorInterface.get_editor_theme()
	if font_name in theme.get_font_list("EditorFonts"):
		return theme.get_font(font_name, "EditorFonts")
	return theme.get_default_font()


## Update the status bar text.
func _update_status(message: String, node_count: int, edge_count: int) -> void:
	if is_instance_valid(status_message_label):
		status_message_label.text = message
	if is_instance_valid(status_count_label):
		status_count_label.text = "  " + str(node_count) + " nodes, " + str(edge_count) + " edges"


## Build a unique, valid Node name for a graph node.
func _node_name_for(node_key: String) -> String:
	return "dn_" + str(node_key.hash())


## Get the plugin's directory path.
func get_plugin_path() -> String:
	return get_script().resource_path.get_base_dir()
