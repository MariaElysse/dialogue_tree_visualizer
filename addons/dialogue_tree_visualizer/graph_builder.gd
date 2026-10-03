## GraphBuilder: Constructs a dialogue graph from DialogueResource data.
##
## Reuses the Dialogue Manager addon's compiled data (DMCache / DialogueResource)
## to build a node-and-edge graph suitable for visualization in a GraphEdit.
##
## The plugin is deliberately tolerant of the Dialogue Manager version it runs
## against: v3.10 and earlier name the entry points "titles" while newer builds
## name them "cues". Line type strings are compared against local constants so
## the script does not depend on DMConstants members that may not exist.
class_name DialogueTreeGraphBuilder extends RefCounted

## Compiled line type strings. These match the wire values produced by both the
## "title" and "cue" generations of Dialogue Manager.
const LINE_TYPE_TITLE: String = "title"
const LINE_TYPE_CUE: String = "cue"
const LINE_TYPE_DIALOGUE: String = "dialogue"
const LINE_TYPE_RESPONSE: String = "response"
const LINE_TYPE_CONDITION: String = "condition"
const LINE_TYPE_WHILE: String = "while"
const LINE_TYPE_MATCH: String = "match"
const LINE_TYPE_WHEN: String = "when"
const LINE_TYPE_MUTATION: String = "mutation"
const LINE_TYPE_GOTO: String = "goto"
const LINE_TYPE_RANDOM: String = "random"

## Visual category for a graph node.
enum NodeType {CUE, DIALOGUE, RESPONSE, CONDITION, MUTATION, GOTO, WHILE, MATCH, WHEN, RANDOM, END}  # Entry point (~ cue / title)  # Character speaks  # Player choice  # if / elif / else  # do / set  # => jump  # while loop  # match expression  # when case  # % weighted random  # => END marker

## Connection arrow style between nodes.
enum EdgeType {
	SEQUENTIAL,  # Normal flow (solid arrow)
	GOTO,  # Jump target (dashed arrow)
	CONDITION_TRUE,  # If-branch (green tint)
	CONDITION_FALSE,  # Else/elif-branch (orange tint)
	RESPONSE,  # Response choice (blue tint)
	RANDOM,  # Random branch (purple tint)
}


## Build a complete graph from one or more DialogueResources.
## Returns a dictionary with:
##   {
##     nodes: Array[Dictionary]  # Each: { id, title, type, character, text, file, position }
##     edges: Array[Dictionary]  # Each: { from, to, edge_type, label }
##     titles: PackedStringArray # List of all title/cue names across files
##   }
static func build(resources: Array[DialogueResource]) -> Dictionary:
	var nodes: Array[Dictionary] = []
	var edges: Array[Dictionary] = []
	var all_titles: PackedStringArray = []
	var seen_ids: Dictionary = {}  # "file:id" -> node ref

	for resource: DialogueResource in resources:
		var file_path: String = resource.resource_path
		all_titles.append_array(_get_title_names(resource))

		# Build nodes and edges for this resource
		_build_resource_nodes(resource, nodes, edges, seen_ids, file_path)

	return {"nodes": nodes, "edges": edges, "titles": all_titles}


## Build graph from file paths directly (loads DialogueResources).
static func build_from_paths(file_paths: PackedStringArray) -> Dictionary:
	var resources: Array[DialogueResource] = []
	for path: String in file_paths:
		var resource: DialogueResource = load(path)
		if resource is DialogueResource:
			resources.append(resource)

	if resources.is_empty():
		return {"nodes": [], "edges": [], "titles": []}

	return build(resources)


## Read the title/cue map from a DialogueResource across Dialogue Manager versions.
static func _get_title_map(resource: DialogueResource) -> Dictionary:
	# Newer versions expose "cues"; older versions expose "titles".
	var cues: Variant = resource.get("cues")
	if cues is Dictionary:
		return cues
	var titles: Variant = resource.get("titles")
	if titles is Dictionary:
		return titles
	return {}


## Read the list of title/cue names from a DialogueResource across versions.
static func _get_title_names(resource: DialogueResource) -> PackedStringArray:
	if resource.has_method("get_cues"):
		return resource.call("get_cues")
	if resource.has_method("get_titles"):
		return resource.call("get_titles")
	return PackedStringArray()


## Build nodes and edges for a single DialogueResource.
static func _build_resource_nodes(
	resource: DialogueResource,
	nodes: Array[Dictionary],
	edges: Array[Dictionary],
	seen_ids: Dictionary,
	file_path: String
) -> void:
	var titles: Dictionary = _get_title_map(resource)
	var lines: Dictionary = resource.lines

	# Collect all line IDs for iteration
	var all_line_ids: PackedStringArray = lines.keys()
	if all_line_ids.is_empty():
		return

	var src_lines: PackedStringArray = _read_source_lines(file_path)

	# Create nodes for all lines
	for line_id: String in all_line_ids:
		var line_data: Dictionary = lines[line_id]
		if not line_data.is_empty():
			_create_node(
				line_id,
				line_data,
				nodes,
				edges,
				seen_ids,
				file_path,
				titles,
				resource.character_names,
				src_lines
			)

	# Fold "if/elif/else" sibling chains into a single node with one branch per
	# condition, so they read as branches rather than a linear chain.
	_group_conditions(nodes, edges, file_path, lines, src_lines)

	# Collapse runs of consecutive dialogue lines into a single multi-line node.
	_group_dialogue_runs(nodes, edges, file_path, lines)

	# Drop dialogue nodes that carry no dialogue at all (blank/unknown lines).
	_remove_empty_dialogue_nodes(nodes, edges, file_path)


## Read the source lines of a [.dialogue] file for branch labelling.
## Returns an empty array when the file is missing or uses "import" (which would
## offset the compiled line ids).
static func _read_source_lines(file_path: String) -> PackedStringArray:
	if not FileAccess.file_exists(file_path):
		return PackedStringArray()
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text: String = file.get_as_text()
	file.close()
	for line: String in text.split("\n"):
		if line.strip_edges().begins_with("import "):
			return PackedStringArray()
	return text.split("\n")


## Merge every "if/elif/else" sibling chain in [param lines] into its head node.
## The head gains a "branches" array and the outgoing edges become the branches;
## the other chain members are removed as separate nodes.
static func _group_conditions(
	nodes: Array[Dictionary],
	edges: Array[Dictionary],
	file_path: String,
	lines: Dictionary,
	src_lines: PackedStringArray
) -> void:
	var cond_nodes: Dictionary = {}
	for node: Dictionary in nodes:
		if node.get("type") == NodeType.CONDITION and node.get("file") == file_path:
			cond_nodes[str(node.get("id", ""))] = node

	if cond_nodes.is_empty():
		return

	# A chain head is a condition that no other condition links to via next_sibling_id.
	var is_sibling: Dictionary = {}
	for cid: String in cond_nodes:
		var sib: String = str((lines.get(cid, {}) as Dictionary).get("next_sibling_id", ""))
		if sib != "" and sib != "0":
			is_sibling[sib] = true

	var absorbed: Dictionary = {}  # composite node key -> true
	var replaced_keys: Dictionary = {}  # edge _edge_key -> true

	var ordered_ids: Array = cond_nodes.keys()
	ordered_ids.sort_custom(func(a: String, b: String) -> bool: return a.to_int() < b.to_int())

	for cid: String in ordered_ids:
		if is_sibling.has(cid) or absorbed.has(file_path + ":" + cid):
			continue

		# Walk the next_sibling_id chain.
		var chain: Array = [cid]
		var cur: String = str((lines.get(cid, {}) as Dictionary).get("next_sibling_id", ""))
		while cur != "" and cur != "0" and cond_nodes.has(cur) and not chain.has(cur):
			chain.append(cur)
			cur = str((lines.get(cur, {}) as Dictionary).get("next_sibling_id", ""))

		if chain.size() < 2:
			continue

		var head: Dictionary = cond_nodes[cid]
		var branches: Array = []
		var labels: PackedStringArray = []

		for i: int in range(chain.size()):
			var member_id: String = chain[i]
			var member: Dictionary = lines.get(member_id, {})
			var is_else: bool = (member.get("condition", {}) as Dictionary).is_empty()
			var label: String = "else" if is_else else ("if" if i == 0 else "elif")
			branches.append(
				{
					"label": label,
					"text": _condition_source_text(is_else, src_lines, member_id),
					"to": file_path + ":" + str(member.get("next_id", ""))
				}
			)
			labels.append(label)

			# The chain member's own condition edges are replaced by branch edges.
			replaced_keys[file_path + ":next:" + member_id] = true
			replaced_keys[file_path + ":after:" + member_id] = true
			replaced_keys[file_path + ":sibling:" + member_id] = true
			if i > 0:
				absorbed[file_path + ":" + member_id] = true

		head["branches"] = branches
		head["title"] = " / ".join(labels)

		var after_id: String = str((lines.get(cid, {}) as Dictionary).get("next_id_after", ""))
		if after_id != "" and after_id != "0":
			head["after"] = file_path + ":" + after_id

	# Remove absorbed nodes.
	var kept_nodes: Array[Dictionary] = []
	for node: Dictionary in nodes:
		if not absorbed.has(str(node.get("key", ""))):
			kept_nodes.append(node)
	nodes.clear()
	nodes.append_array(kept_nodes)

	# Remove absorbed nodes' edges plus the replaced condition edges.
	var kept_edges: Array[Dictionary] = []
	for edge: Dictionary in edges:
		if absorbed.has(str(edge.get("from", ""))) or absorbed.has(str(edge.get("to", ""))):
			continue
		if replaced_keys.has(str(edge.get("_edge_key", ""))):
			continue
		kept_edges.append(edge)
	edges.clear()
	edges.append_array(kept_edges)

	# Emit one branch edge per condition, from its own output port.
	for node: Dictionary in nodes:
		var branches: Array = node.get("branches", [])
		if branches.is_empty():
			continue
		var head_key: String = str(node.get("key", ""))
		for i: int in range(branches.size()):
			var branch: Dictionary = branches[i]
			_append_edge(
				edges,
				"%s:branch:%d" % [head_key, i],
				head_key,
				str(branch.get("to", "")),
				EdgeType.CONDITION_TRUE,
				str(branch.get("label", "")),
				i
			)
		var after_key: String = str(node.get("after", ""))
		if not after_key.is_empty():
			_append_edge(
				edges,
				head_key + ":after",
				head_key,
				after_key,
				EdgeType.CONDITION_FALSE,
				"after",
				0
			)


## Collapse runs of consecutive dialogue lines into a single node whose "lines"
## array holds each spoken line, so a chain like Dialogue -> Dialogue -> Dialogue
## becomes one node containing all three lines.
static func _group_dialogue_runs(
	nodes: Array[Dictionary], edges: Array[Dictionary], file_path: String, lines: Dictionary
) -> void:
	var node_by_key: Dictionary = {}
	for node: Dictionary in nodes:
		node_by_key[str(node.get("key", ""))] = node

	# Count incoming edges so we never absorb a node that other nodes point at.
	var in_degree: Dictionary = {}
	for edge: Dictionary in edges:
		var to_key: String = str(edge.get("to", ""))
		in_degree[to_key] = int(in_degree.get(to_key, 0)) + 1

	var dialogue_nodes: Array[Dictionary] = []
	for node: Dictionary in nodes:
		if node.get("type") == NodeType.DIALOGUE and node.get("file") == file_path:
			dialogue_nodes.append(node)
	dialogue_nodes.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return str(a.get("id", "")).to_int() < str(b.get("id", "")).to_int()
	)

	var absorbed: Dictionary = {}
	var removed_edge_keys: Dictionary = {}
	var heads: Array[Dictionary] = []
	var tails: PackedStringArray = []

	for node: Dictionary in dialogue_nodes:
		var head_key: String = str(node.get("key", ""))
		if absorbed.has(head_key):
			continue

		# Follow next_id while it stays a dialogue line that only this run feeds.
		var chain: Array[Dictionary] = [node]
		var chain_ids: PackedStringArray = [str(node.get("id", ""))]
		var cur_id: String = str((lines.get(chain_ids[0], {}) as Dictionary).get("next_id", ""))

		while cur_id != "" and cur_id != "0":
			var cur_key: String = file_path + ":" + cur_id
			if not node_by_key.has(cur_key):
				break
			var cur_node: Dictionary = node_by_key[cur_key]
			if cur_node.get("type") != NodeType.DIALOGUE:
				break
			if int(in_degree.get(cur_key, 0)) != 1:
				break
			chain.append(cur_node)
			chain_ids.append(cur_id)
			cur_id = str((lines.get(cur_id, {}) as Dictionary).get("next_id", ""))

		if chain.size() < 2:
			continue

		var merged_lines: Array = []
		for member: Dictionary in chain:
			var member_character: String = str(member.get("character", ""))
			var member_text: String = str(member.get("text", ""))
			if member_character.strip_edges().is_empty() and member_text.strip_edges().is_empty():
				continue  # skip blank lines so they don't appear as empty rows
			merged_lines.append({"character": member_character, "text": member_text})
		node["lines"] = merged_lines
		node["text"] = ""
		# If the run's first line was blank, name the node after its first real line.
		if not merged_lines.is_empty():
			var first_character: String = str(merged_lines[0].get("character", ""))
			var first_text: String = str(merged_lines[0].get("text", ""))
			node["character"] = first_character
			node["title"] = (
				(first_character + ": " + first_text.left(50))
				if not first_character.is_empty()
				else first_text.left(50)
			)

		for i: int in range(1, chain_ids.size()):
			absorbed[file_path + ":" + str(chain_ids[i])] = true
		for cid: String in chain_ids:
			removed_edge_keys[file_path + ":next:" + cid] = true

		heads.append(node)
		tails.append(str(chain[chain.size() - 1].get("key", "")))

	if absorbed.is_empty():
		return

	# Remember each tail's outgoing edges so they can move to the head.
	var tail_edges: Dictionary = {}
	for tail_key: String in tails:
		tail_edges[tail_key] = []
	for edge: Dictionary in edges:
		var from_key: String = str(edge.get("from", ""))
		if tail_edges.has(from_key):
			(tail_edges[from_key] as Array).append(edge)

	# Drop absorbed nodes.
	var kept_nodes: Array[Dictionary] = []
	for node: Dictionary in nodes:
		if not absorbed.has(str(node.get("key", ""))):
			kept_nodes.append(node)
	nodes.clear()
	nodes.append_array(kept_nodes)

	# Drop the internal edges and anything leaving an absorbed node.
	var kept_edges: Array[Dictionary] = []
	for edge: Dictionary in edges:
		if absorbed.has(str(edge.get("from", ""))):
			continue
		if removed_edge_keys.has(str(edge.get("_edge_key", ""))):
			continue
		kept_edges.append(edge)
	edges.clear()
	edges.append_array(kept_edges)

	# Re-attach each tail's outgoing edges to its head.
	for i: int in range(heads.size()):
		var head_key: String = str(heads[i].get("key", ""))
		var tail_key: String = tails[i]
		for edge: Dictionary in tail_edges.get(tail_key, []):
			_append_edge(
				edges,
				"%s:tail:%s" % [head_key, str(edge.get("_edge_key", ""))],
				head_key,
				str(edge.get("to", "")),
				edge.get("edge_type", EdgeType.SEQUENTIAL),
				str(edge.get("label", "")),
				int(edge.get("from_port", 0))
			)


## Remove dialogue nodes that contain no dialogue (blank/unknown lines), wiring
## each removed node's incoming edges straight to its outgoing edges so the flow
## is preserved.
static func _remove_empty_dialogue_nodes(
	nodes: Array[Dictionary], edges: Array[Dictionary], file_path: String
) -> void:
	while true:
		var target_key: String = ""
		for node: Dictionary in nodes:
			if node.get("file") != file_path or node.get("type") != NodeType.DIALOGUE:
				continue
			if not (node.get("lines", []) as Array).is_empty():
				continue
			if not (
				str(node.get("character", "")).strip_edges().is_empty()
				and str(node.get("text", "")).strip_edges().is_empty()
			):
				continue
			target_key = str(node.get("key", ""))
			break

		if target_key.is_empty():
			return

		# Bypass: link every incoming edge's source to every outgoing edge's target.
		var incoming: Array[Dictionary] = []
		var outgoing: Array[Dictionary] = []
		for edge: Dictionary in edges:
			if str(edge.get("to", "")) == target_key:
				incoming.append(edge)
			elif str(edge.get("from", "")) == target_key:
				outgoing.append(edge)

		for in_edge: Dictionary in incoming:
			for out_edge: Dictionary in outgoing:
				var from_key: String = str(in_edge.get("from", ""))
				var to_key: String = str(out_edge.get("to", ""))
				if from_key == to_key:
					continue
				_append_edge(
					edges,
					"%s:bypass:%s" % [from_key, to_key],
					from_key,
					to_key,
					out_edge.get("edge_type", EdgeType.SEQUENTIAL),
					str(out_edge.get("label", "")),
					int(in_edge.get("from_port", 0))
				)

		# Drop the node and its edges, then re-check for more empty nodes.
		var kept_nodes: Array[Dictionary] = []
		for node: Dictionary in nodes:
			if str(node.get("key", "")) != target_key:
				kept_nodes.append(node)
		nodes.clear()
		nodes.append_array(kept_nodes)

		var kept_edges: Array[Dictionary] = []
		for edge: Dictionary in edges:
			if str(edge.get("from", "")) == target_key or str(edge.get("to", "")) == target_key:
				continue
			kept_edges.append(edge)
		edges.clear()
		edges.append_array(kept_edges)


## The expression text of a condition, taken from the source line.
static func _condition_source_text(
	is_else: bool, src_lines: PackedStringArray, line_id: String
) -> String:
	if is_else:
		return ""
	var line_number: int = line_id.to_int()
	if line_number < 0 or line_number >= src_lines.size():
		return ""
	var raw: String = src_lines[line_number].strip_edges()
	var comment: int = raw.find("#")
	if comment >= 0:
		raw = raw.substr(0, comment).strip_edges()
	if raw.begins_with("if "):
		raw = raw.substr(3).strip_edges()
	elif raw.begins_with("elif "):
		raw = raw.substr(5).strip_edges()
	return raw


## The name of a title/cue, taken from its source line ("~ name").
static func _title_source_name(src_lines: PackedStringArray, line_id: String) -> String:
	var line_number: int = line_id.to_int()
	if line_number < 0 or line_number >= src_lines.size():
		return ""
	var raw: String = src_lines[line_number].strip_edges()
	if raw.begins_with("~"):
		raw = raw.substr(1).strip_edges()
	var comment: int = raw.find("#")
	if comment >= 0:
		raw = raw.substr(0, comment).strip_edges()
	return raw


## The expression of a mutation, taken from its source line ("$> expr").
static func _mutation_source_text(src_lines: PackedStringArray, line_id: String) -> String:
	var line_number: int = line_id.to_int()
	if line_number < 0 or line_number >= src_lines.size():
		return ""
	var raw: String = src_lines[line_number].strip_edges()
	var comment: int = raw.find("#")
	if comment >= 0:
		raw = raw.substr(0, comment).strip_edges()
	if raw.begins_with("$>"):
		raw = raw.substr(2).strip_edges()
	elif raw.begins_with("set "):
		raw = raw.substr(4).strip_edges()
	elif raw.begins_with("do "):
		raw = raw.substr(3).strip_edges()
	return raw


## Create a node for a compiled line.
static func _create_node(
	line_id: String,
	line_data: Dictionary,
	nodes: Array[Dictionary],
	edges: Array[Dictionary],
	seen_ids: Dictionary,
	file_path: String,
	titles: Dictionary,
	character_names: PackedStringArray,
	src_lines: PackedStringArray
) -> void:
	var node_key: String = file_path + ":" + line_id
	if seen_ids.has(node_key):
		return

	var line_type: String = str(line_data.get("type", ""))
	var node_type: NodeType = _line_type_to_node_type(line_type)
	# A "=> END" goto terminates the dialogue, so show it as an END node. Snippet
	# jumps keep a return edge, so they stay GOTO nodes with an output port.
	if (
		line_type == LINE_TYPE_GOTO
		and str(line_data.get("next_id", "")) in ["end", "end!"]
		and str(line_data.get("next_id_after", "")) in ["", "0"]
	):
		node_type = NodeType.END
	var title: String = _extract_title(line_data, line_type, line_id, titles, src_lines)
	var character: String = str(line_data.get("character", ""))
	var text: String = str(line_data.get("text", ""))
	# Mutations keep their expression in the source line ("$> expr"), not in the
	# compiled text, so surface it on the node body too.
	if text.is_empty() and line_type == LINE_TYPE_MUTATION:
		text = _mutation_source_text(src_lines, line_id)
	if node_type == NodeType.END:
		title = "END"
		text = "end of dialogue"

	var node: Dictionary = {
		"id": line_id,
		"key": node_key,
		"title": title,
		"type": node_type,
		"line_type": line_type,
		"character": character,
		"text": text,
		"file": file_path,
		"position": Vector2i(0, 0),
		"tags": line_data.get("tags", []),
		"responses": line_data.get("responses", []),
		"condition": line_data.get("condition", null),
		"mutation": line_data.get("mutation", null),
		"is_snippet": line_data.get("is_snippet", false)
	}

	nodes.append(node)
	seen_ids[node_key] = node

	# Create edges based on line type
	_create_edges_for_node(line_id, node, line_data, edges, file_path, titles)


## Create edges originating from a node.
static func _create_edges_for_node(
	line_id: String,
	node: Dictionary,
	line_data: Dictionary,
	edges: Array[Dictionary],
	file_path: String,
	titles: Dictionary
) -> void:
	var next_id: String = str(line_data.get("next_id", ""))
	var next_id_after: String = str(line_data.get("next_id_after", ""))
	var next_sibling_id: String = str(line_data.get("next_sibling_id", ""))
	var line_type: String = str(line_data.get("type", ""))

	# Sequential next_id edge
	if not next_id.is_empty() and next_id != "0":
		var edge_key: String = file_path + ":next:" + line_id
		var label: String = _get_edge_label(next_id, titles)
		_add_edge(edges, edge_key, file_path, line_id, next_id, EdgeType.SEQUENTIAL, label)

	# next_id_after edge (for conditions, responses, gotos)
	if not next_id_after.is_empty() and next_id_after != "0" and next_id_after != next_id:
		var edge_key: String = file_path + ":after:" + line_id
		var edge_type: EdgeType = EdgeType.SEQUENTIAL
		var label: String = "after"

		match line_type:
			LINE_TYPE_CONDITION:
				edge_type = EdgeType.CONDITION_FALSE
				label = "else/exit"
			LINE_TYPE_RESPONSE:
				edge_type = EdgeType.RESPONSE
				label = "chose"
			LINE_TYPE_GOTO:
				edge_type = EdgeType.GOTO
				label = "return"

		_add_edge(edges, edge_key, file_path, line_id, next_id_after, edge_type, label)

	# next_sibling_id edge (for conditions - elif chain)
	if not next_sibling_id.is_empty() and next_sibling_id != "0":
		var edge_key: String = file_path + ":sibling:" + line_id
		_add_edge(
			edges, edge_key, file_path, line_id, next_sibling_id, EdgeType.CONDITION_FALSE, "elif"
		)


## Extract a display title for a node.
static func _extract_title(
	line_data: Dictionary,
	line_type: String,
	line_id: String,
	titles: Dictionary,
	src_lines: PackedStringArray
) -> String:
	match line_type:
		LINE_TYPE_TITLE, LINE_TYPE_CUE:
			# The compiled title line has no text; its name comes from the
			# source line ("~ name" / "~ name" for cues).
			var name_text: String = str(line_data.get("text", ""))
			if name_text.is_empty():
				name_text = _title_source_name(src_lines, line_id)
			return name_text if not name_text.is_empty() else ("title " + line_id)
		LINE_TYPE_DIALOGUE:
			var character: String = str(line_data.get("character", ""))
			var text: String = str(line_data.get("text", ""))
			var preview: String = text.left(50)
			if text.length() > 50:
				preview += "..."
			if not character.is_empty():
				return character + ": " + preview
			return preview
		LINE_TYPE_RESPONSE:
			var response_text: String = str(line_data.get("text", ""))
			return "- " + response_text.left(50)
		LINE_TYPE_CONDITION:
			var condition: Variant = line_data.get("condition", {})
			var cond_text: String = ""
			if condition is Dictionary and condition.has("text"):
				cond_text = str(condition.text)
			elif condition is String:
				cond_text = condition
			return cond_text.left(40)
		LINE_TYPE_MUTATION:
			var mutation: Variant = line_data.get("mutation", {})
			var mut_text: String = ""
			if mutation is Dictionary and mutation.has("text"):
				mut_text = str(mutation.text)
			elif mutation is String:
				mut_text = mutation
			if mut_text.is_empty():
				mut_text = _mutation_source_text(src_lines, line_id)
			return mut_text.left(60)
		LINE_TYPE_GOTO:
			var goto_text: String = str(line_data.get("text", ""))
			return goto_text.left(40)
		_:
			return "Line " + line_id

	return "Line " + line_id


## Convert a compiled line type to a visual NodeType.
static func _line_type_to_node_type(line_type: String) -> NodeType:
	match line_type:
		LINE_TYPE_TITLE, LINE_TYPE_CUE:
			return NodeType.CUE
		LINE_TYPE_DIALOGUE:
			return NodeType.DIALOGUE
		LINE_TYPE_RESPONSE:
			return NodeType.RESPONSE
		LINE_TYPE_CONDITION:
			return NodeType.CONDITION
		LINE_TYPE_MUTATION:
			return NodeType.MUTATION
		LINE_TYPE_GOTO:
			return NodeType.GOTO
		LINE_TYPE_WHILE:
			return NodeType.WHILE
		LINE_TYPE_MATCH:
			return NodeType.MATCH
		LINE_TYPE_WHEN:
			return NodeType.WHEN
		LINE_TYPE_RANDOM:
			return NodeType.RANDOM
		_:
			if "end" in line_type.to_lower():
				return NodeType.END
			return NodeType.DIALOGUE

	return NodeType.DIALOGUE


## Get a human-readable label for an edge.
static func _get_edge_label(next_id: String, titles: Dictionary) -> String:
	# Check if next_id points to a title/cue
	for title_name: String in titles:
		if str(titles[title_name]) == next_id:
			return "to " + title_name

	return ""


## Add an edge to the edges array.
## Endpoint ids are stored as composite "file:id" keys so they match the node
## "key" values produced by _create_node().
static func _add_edge(
	edges: Array[Dictionary],
	edge_key: String,
	file_path: String,
	from_id: String,
	to_id: String,
	edge_type: EdgeType,
	label: String,
	from_port: int = 0
) -> void:
	# Skip edges to END markers
	if to_id in ["end", "end!", ""]:
		return

	_append_edge(
		edges,
		edge_key,
		file_path + ":" + from_id,
		file_path + ":" + to_id,
		edge_type,
		label,
		from_port
	)


## Add an edge using already-composite endpoint keys.
static func _append_edge(
	edges: Array[Dictionary],
	edge_key: String,
	from_key: String,
	to_key: String,
	edge_type: EdgeType,
	label: String,
	from_port: int = 0
) -> void:
	edges.append(
		{
			"_edge_key": edge_key,
			"from": from_key,
			"to": to_key,
			"edge_type": edge_type,
			"label": label,
			"from_port": from_port
		}
	)
