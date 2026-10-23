package gateway

import (
	"os"
	"path/filepath"
	"testing"
)

// The fixtures are requests the agents sent an upstream, run in a sandbox
// home from a folder named "a&b <c> 中文" (Claude Code 2.1.296, Codex
// 0.162.0) or "My Proj" (Pi 1.1.0); the sandbox's path is replaced with
// /Users/me/work. ZCode's is the body its 3.16.3 wrote its own log, its
// paths those of a user called justin.
func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "workdir", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Each agent's folder is read from its own request, entities and all.
func TestWorkDirOfEachAgent(t *testing.T) {
	for _, tc := range []struct {
		file  string
		parse func([]byte) (*Request, error)
		want  string
	}{
		{"claude-code-2.1.296.json", parseAnthropic, "/Users/me/work/proj/a&b <c> 中文"},
		{"codex-0.162.0.json", parseResponses, "/Users/me/work/proj/a&b <c> 中文"},
		{"pi-1.1.0.json", parseChat, "/Users/me/work/proj/My Proj"},
		// ZCode's own body: its system's environment says
		// "- Primary working directory: C:\Users\…", and its turn says no
		// other.
		{"zcode-3.16.3.json", parseAnthropic, `C:\Users\justin\.zcode\workspace\default`},
	} {
		req, err := tc.parse(fixture(t, tc.file))
		if err != nil {
			t.Fatal(tc.file, err)
		}
		if got := workDir(req); got != tc.want {
			t.Errorf("%s: %q, want %q", tc.file, got, tc.want)
		}
	}
}
