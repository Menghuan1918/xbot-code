// Package main implements an xbot stdio plugin that automatically discovers
// and loads AGENTS.md files from the project root to the current working
// directory, replicating codex's project-level instruction loading logic.
//
// The plugin communicates with xbot via JSON-over-stdio protocol:
//   - Receives {"method":"activate"} on startup → responds with enricher declaration
//   - Receives {"method":"enrich","params":{...}} → reads CWD from xbot's
//     session_cwd directory (updated by Cd) and returns AGENTS.md content
//
// AGENTS.md discovery (matching codex exactly):
//  1. Walk up from CWD to find project root (looking for `.git` marker)
//  2. Collect directories from project root → CWD (root first)
//  3. In each directory, try AGENTS.override.md → AGENTS.md (first found wins)
//  4. Total byte budget: 32 KiB across all files. Truncate if exceeded.
//  5. Concatenate files with \n\n separator, wrap in XML markers
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// ---------------------------------------------------------------------------
// Protocol types (matching xbot's plugin/runtime.go)
// ---------------------------------------------------------------------------

type pluginRequest struct {
	Method string          `json:"method"`
	Params map[string]any `json:"params,omitempty"`
}

type pluginResponse struct {
	Result    string        `json:"result,omitempty"`
	Error     string        `json:"error,omitempty"`
	Enrichers []enricherReg `json:"enrichers,omitempty"`
}

type enricherReg struct {
	Name string `json:"name"`
}

// ---------------------------------------------------------------------------
// Codex-compatible AGENTS.md loading logic
// ---------------------------------------------------------------------------

const (
	// defaultProjectRootMarker defines the markers used to identify the
	// project root when walking up the directory tree. Codex defaults to [".git"].
	defaultProjectRootMarker = ".git"

	// defaultProjectDocMaxBytes is the total byte budget across ALL discovered
	// AGENTS.md files. Codex defaults to 32 KiB. Files are truncated if the
	// budget is exceeded.
	defaultProjectDocMaxBytes = 32 * 1024

	// candidateFilenames lists the files to try in each directory, in priority
	// order. First found file per directory wins. Codex tries:
	//   1. AGENTS.override.md (local override)
	//   2. AGENTS.md (default)
	candidateOverrideFilename = "AGENTS.override.md"
	candidateDefaultFilename  = "AGENTS.md"
)

// instructionEntry holds the content and provenance of a single AGENTS.md file.
type instructionEntry struct {
	content string
	path    string
}

// findProjectRoot walks up from dir until it finds a directory containing
// a project root marker (e.g. .git). Returns the project root directory,
// or dir itself if no marker is found (codex behavior: search only cwd).
func findProjectRoot(dir string) string {
	current := dir
	for {
		markerPath := filepath.Join(current, defaultProjectRootMarker)
		if info, err := os.Stat(markerPath); err == nil {
			// Codex checks for existence, not whether it's a directory.
			// .git can be a directory (normal repos) or a file (worktrees/submodules).
			_ = info
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			// Reached filesystem root without finding a marker.
			// Codex behavior: only search in cwd.
			return dir
		}
		current = parent
	}
}

// collectSearchDirs builds the list of directories to search, from project
// root to cwd (inclusive). If no project root marker was found, only cwd
// is searched.
func collectSearchDirs(cwd string) []string {
	root := findProjectRoot(cwd)
	if root == cwd {
		return []string{cwd}
	}

	// Walk up from cwd to root, collecting directories.
	var dirs []string
	cursor := cwd
	for {
		dirs = append(dirs, cursor)
		if cursor == root {
			break
		}
		parent := filepath.Dir(cursor)
		if parent == cursor {
			break
		}
		cursor = parent
	}

	// Reverse: root → cwd order.
	for i, j := 0, len(dirs)-1; i < j; i, j = i+1, j-1 {
		dirs[i], dirs[j] = dirs[j], dirs[i]
	}
	return dirs
}

// findAgentsMdInDir searches for the first matching AGENTS.md file in dir.
// Priority: AGENTS.override.md → AGENTS.md. First found file wins.
// Returns the file path and content, or empty strings if none found.
func findAgentsMdInDir(dir string) (path string, content string) {
	candidates := []string{candidateOverrideFilename, candidateDefaultFilename}
	for _, name := range candidates {
		fullPath := filepath.Join(dir, name)
		info, err := os.Stat(fullPath)
		if err != nil || info.IsDir() {
			continue
		}
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		text := strings.TrimSpace(string(data))
		if text == "" {
			continue
		}
		return fullPath, text
	}
	return "", ""
}

// loadProjectInstructions discovers and reads AGENTS.md files from the project
// root to the cwd's PARENT directory, applying the byte budget.
//
// The CWD itself is intentionally EXCLUDED — xbot's built-in ProjectContextMiddleware
// (Priority 5) already loads a single AGENTS.md from CWD into SystemParts["05_project_context"].
// This plugin complements that by loading the ANCESTOR directories (root → parent of CWD)
// that xbot's middleware does not traverse. This avoids duplicate injection of the CWD file.
func loadProjectInstructions(cwd string) []instructionEntry {
	searchDirs := collectSearchDirs(cwd)

	// Exclude the last element (CWD itself) — xbot's built-in middleware handles it.
	if len(searchDirs) > 1 {
		searchDirs = searchDirs[:len(searchDirs)-1]
	}

	var entries []instructionEntry
	remaining := defaultProjectDocMaxBytes

	for _, dir := range searchDirs {
		path, content := findAgentsMdInDir(dir)
		if path == "" {
			continue
		}

		// Apply byte budget (codex truncates silently with a warning log).
		if remaining <= 0 {
			break
		}
		if len(content) > remaining {
			content = content[:remaining]
		}
		remaining -= len(content)

		entries = append(entries, instructionEntry{
			content: content,
			path:    path,
		})
	}

	return entries
}

// renderInstructions concatenates the discovered AGENTS.md entries and wraps
// them in XML markers, matching codex's ContextUserInstructions::render().
//
// Note: This only contains ANCESTOR directory files (root → parent of CWD).
// The CWD's own AGENTS.md is handled by xbot's built-in ProjectContextMiddleware.
//
// Output format:
//
//	# AGENTS.md instructions for {cwd}
//
//	<INSTRUCTIONS>
//	{file1 content}
//
//	{file2 content}
//	</INSTRUCTIONS>
func renderInstructions(cwd string, entries []instructionEntry) string {
	if len(entries) == 0 {
		return ""
	}

	// Concatenate entries with \n\n separator (codex's legacy_text with only
	// project entries — no user-level instructions, so no --- project-doc --- separator).
	var parts []string
	for _, entry := range entries {
		parts = append(parts, entry.content)
	}
	concatenated := strings.Join(parts, "\n\n")

	// Wrap in XML markers matching codex's format.
	var sb strings.Builder
	sb.WriteString("# AGENTS.md instructions for ")
	sb.WriteString(cwd)
	sb.WriteString("\n\n")
	sb.WriteString("<INSTRUCTIONS>\n")
	sb.WriteString(concatenated)
	sb.WriteString("\n</INSTRUCTIONS>\n")
	return sb.String()
}

// loadAndRender is the top-level entry point: discovers AGENTS.md files,
// reads them with the byte budget, and renders the final output.
func loadAndRender(cwd string) string {
	entries := loadProjectInstructions(cwd)
	return renderInstructions(cwd, entries)
}

// ---------------------------------------------------------------------------
// CWD resolution — reads from xbot's session_cwd directory
// ---------------------------------------------------------------------------

// resolveCWD determines the current working directory for AGENTS.md discovery.
//
// xbot persists each session's CWD to ~/.xbot/session_cwd/<hash>.txt whenever
// the Cd tool is used (via TenantSession.SetCurrentDir). We scan this directory
// and return the most recently modified entry — this is the active session's
// CWD. No hooks or xbot source modifications required.
//
// Limitation: with multiple concurrent sessions, the most-recently-modified
// heuristic may pick the wrong one. This is acceptable for the common case of
// a single active session.
func resolveCWD() string {
	// Resolve xbot home: check XBOT_HOME env, then default to ~/.xbot
	xbotHome := os.Getenv("XBOT_HOME")
	if xbotHome == "" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		xbotHome = filepath.Join(homeDir, ".xbot")
	}

	cwdDir := filepath.Join(xbotHome, "session_cwd")
	matches, err := filepath.Glob(filepath.Join(cwdDir, "*.txt"))
	if err != nil || len(matches) == 0 {
		return ""
	}

	// Pick the most recently modified file — it's the active session.
	var mostRecent string
	var maxModTime int64
	for _, m := range matches {
		info, err := os.Stat(m)
		if err != nil {
			continue
		}
		if info.ModTime().UnixNano() > maxModTime {
			maxModTime = info.ModTime().UnixNano()
			mostRecent = m
		}
	}
	if mostRecent == "" {
		return ""
	}

	data, err := os.ReadFile(mostRecent)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// ---------------------------------------------------------------------------
// JSON-over-stdio protocol handler
// ---------------------------------------------------------------------------

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024) // 1MB buffer

	writer := bufio.NewWriter(os.Stdout)
	defer writer.Flush()

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req pluginRequest
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("failed to parse request: %v", err)
			continue
		}

		resp := handleRequest(&req)
		data, err := json.Marshal(resp)
		if err != nil {
			log.Printf("failed to marshal response: %v", err)
			continue
		}
		writer.Write(data)
		writer.WriteByte('\n')
		writer.Flush()
	}

	if err := scanner.Err(); err != nil && err != io.EOF {
		log.Fatalf("stdin scanner error: %v", err)
	}
}

func handleRequest(req *pluginRequest) pluginResponse {
	switch req.Method {
	case "activate":
		return pluginResponse{
			Enrichers: []enricherReg{
				{Name: "agents-md"},
			},
		}

	case "enrich":
		return handleEnrich(req)

	case "deactivate":
		return pluginResponse{}

	default:
		return pluginResponse{Error: fmt.Sprintf("unknown method: %s", req.Method)}
	}
}

func handleEnrich(req *pluginRequest) pluginResponse {
	// Resolve CWD from xbot's session_cwd directory (written by TenantSession.SetCurrentDir).
	cwd := resolveCWD()
	if cwd == "" {
		return pluginResponse{Result: ""}
	}

	content := loadAndRender(cwd)
	return pluginResponse{Result: content}
}
