# Dialogue Tree Visualizer

A Godot 4 editor plugin that renders [Dialogue Manager](https://github.com/nathanhoad/godot_dialogue_manager)
`.dialogue` files as an interactive node graph, so you can see how a conversation
flows without reading the script line by line.

The plugin adds a **Dialogue Tree** main-screen tab to the editor. Every cue,
line, response, branch and jump becomes a color-coded node connected by typed
edges, with automatic layered layout and double-click navigation back to the
source line.

## Features

- **Graph view of every `.dialogue` file** — one file at a time, or all files at once.
- **Color-coded node types** — cues, dialogue, responses, conditions, mutations,
  gotos, loops, matches, random branches and end markers each get their own color.
- **Typed edges** — sequential flow, jumps (`=>`), true/false condition branches,
  response choices and random branches are drawn with distinct colors.
- **Automatic layout** — nodes are arranged in a layered layout as soon as the
  graph is drawn, with a manual **Auto Layout** button to re-run it.
- **Double-click to jump to source** — double-click a node to open its
  `.dialogue` file in the Dialogue Manager editor, centered on the source line.
- **Readable grouping** — `if` / `elif` / `else` chains collapse into a single
  node with one output port per branch, and runs of consecutive dialogue lines
  merge into one multi-line node.
- **Live refresh** — the file list updates when files are added, moved or removed.

## Requirements

- **Godot 4.x** (developed against the Godot 4 editor API).
- **Dialogue Manager** addon installed at `res://addons/dialogue_manager/`.
  The plugin reads Dialogue Manager's compiled `DialogueResource` data and uses
  its `DMCache` / `DMPlugin` singletons when present. If Dialogue Manager is
  missing, file discovery falls back to a filesystem scan but no graph can be
  built from uncompiled files.

The plugin is tolerant of the Dialogue Manager version it runs against: it reads
both the newer `cues` API and the older `titles` API, and compares line types
against local string constants so it does not depend on `DMConstants` members
that may not exist.

## Installation

1. Copy the `dialogue_tree_visualizer` folder into your project's `addons/`
   directory so it sits at `res://addons/dialogue_tree_visualizer/`.
2. Open **Project → Project Settings → Plugins**.
3. Enable **Dialogue Tree Visualizer**.

The **Dialogue Tree** tab appears in the editor's main screen tab bar alongside
2D, 3D, Script and Dialogue Manager.

## Usage

Open the **Dialogue Tree** tab and use the toolbar:

| Control | Description |
| --- | --- |
| **File** dropdown | Select a single `.dialogue` file to visualize. |
| **Show All** | Show every dialogue file in one graph (on by default). |
| **List** | Refresh the list of discovered dialogue files. |
| **Zoom** | Zoom the graph from 0.25× to 2×. |
| **Auto Layout** | Re-arrange all nodes in a layered layout. |
| **Clear** | Remove all nodes and edges from the graph. |
| **Refresh** | Reload all dialogue files and rebuild the graph. |

The status bar at the bottom shows the current message and a live count of
nodes and edges in the graph.

### Node types

Each node header is tinted by the kind of dialogue line it represents:

| Type | Color | Represents |
| --- | --- | --- |
| `CUE` | `#408CF2` | Entry point — a `~ cue` / title. |
| `DIALOGUE` | `#33BF59` | A character speaking. |
| `RESPONSE` | `#F29926` | A player choice. |
| `CONDITION` | `#F2CC1A` | An `if` / `elif` / `else` branch. |
| `MUTATION` | `#B34DE6` | A `do` / `set` state change. |
| `GOTO` | `#26CCD9` | A `=>` jump. |
| `WHILE` | `#D95980` | A `while` loop. |
| `MATCH` | `#9933B3` | A `match` expression. |
| `WHEN` | `#80B333` | A `when` case. |
| `RANDOM` | `#9999A6` | A `%` weighted random branch. |
| `END` | `#D93333` | `=> END` — the end of the dialogue. |

`END` nodes have an input port but no output port, so the graph visibly
terminates there.

### Edge types

Connections between nodes are colored by how the dialogue flows between them:
sequential (default), goto (dashed jump), condition true / false branches,
response choices and random branches.

## Project structure

```
addons/dialogue_tree_visualizer/
├── plugin.cfg           # Plugin manifest (name, version, entry script)
├── plugin.gd            # EditorPlugin: tab, toolbar, GraphEdit rendering
├── graph_builder.gd     # DialogueTreeGraphBuilder: DialogueResource -> graph data
├── icon.svg             # Plugin icon
└── icon.svg.import
```

- **`plugin.gd`** — `DialogueTreeVisualizerPlugin`, an `@tool extends EditorPlugin`.
  Builds the main-screen tab, toolbar and status bar, renders graph data into
  `GraphEdit` / `GraphNode` instances, and handles selection, zoom, layout and
  double-click-to-source.
- **`graph_builder.gd`** — the `DialogueTreeGraphBuilder` class (a `RefCounted`).
  Pure data layer: turns one or more `DialogueResource` objects into a
  `{ nodes, edges, titles }` dictionary. It groups condition chains, collapses
  consecutive dialogue runs, and drops empty dialogue nodes while preserving
  flow. It has no editor-UI dependencies, so it can be reused or tested in
  isolation.

## Author

Maria Neptune — version 1.0.0.
